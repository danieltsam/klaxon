import { describe, it, before, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import { app } from '../src/server.js';
import { db } from '../src/db.js';
import {
  GcalApiError,
  GcalMirror,
  classifyGcalError,
  isStatus,
  type GcalTransport,
} from '../src/gcal.js';
import type { AlarmRecord } from '../src/db.js';

function alarm(overrides: Partial<AlarmRecord> = {}): AlarmRecord {
  return {
    id: '550e8400-e29b-41d4-a716-446655440000',
    target_time: '2026-09-21T21:00:00.000Z',
    label: 'Standup',
    status: 'pending',
    ...overrides,
  };
}

/** Records every call so tests can assert on the sequence. */
class FakeTransport implements GcalTransport {
  calls: string[] = [];
  constructor(private readonly failures: Record<string, Error> = {}) {}

  async ensureSecondaryCalendar(): Promise<string> {
    this.calls.push('ensureCalendar');
    return 'cal-1';
  }
  async insertEvent(_c: string, event: { id: string }): Promise<void> {
    this.calls.push(`insert:${event.id}`);
    if (this.failures.insert) throw this.failures.insert;
  }
  async updateEvent(_c: string, event: { id: string }): Promise<void> {
    this.calls.push(`update:${event.id}`);
    if (this.failures.update) throw this.failures.update;
  }
  async deleteEvent(_c: string, id: string): Promise<void> {
    this.calls.push(`delete:${id}`);
    if (this.failures.delete) throw this.failures.delete;
  }
  async listEventIds(): Promise<string[]> {
    this.calls.push('list');
    return [];
  }
}

const CONFIG = {
  clientId: 'id',
  clientSecret: 'secret',
  tokenPath: '/tmp/nonexistent-token.json',
  timeZone: 'Australia/Brisbane',
};

describe('gcal error classification', () => {
  it('classifies 401/403 invalid_grant as auth', () => {
    assert.strictEqual(classifyGcalError(new GcalApiError('nope', 401)), 'auth');
    assert.strictEqual(classifyGcalError(new Error('invalid_grant')), 'auth');
  });
  it('classifies 429 and 403 rate-limit text as rate_limit', () => {
    assert.strictEqual(classifyGcalError(new GcalApiError('slow down', 429)), 'rate_limit');
    assert.strictEqual(
      classifyGcalError(new GcalApiError('userRateLimitExceeded', 403)),
      'rate_limit'
    );
  });
  it('classifies 400 as permanent, not retryable', () => {
    assert.strictEqual(classifyGcalError(new GcalApiError('bad request', 400)), 'permanent');
  });
  it('classifies 5xx and network failures as transient', () => {
    assert.strictEqual(classifyGcalError(new GcalApiError('boom', 503)), 'transient');
    assert.strictEqual(classifyGcalError(new Error('fetch failed')), 'transient');
  });
});

describe('GcalMirror', () => {
  before(async () => {
    await app.ready();
  });
  beforeEach(() => {
    db.prepare("DELETE FROM settings WHERE key LIKE 'gcal_%'").run();
  });
  after(async () => {
    db.prepare("DELETE FROM settings WHERE key LIKE 'gcal_%'").run();
    await app.close();
  });

  it('is a no-op when not configured', async () => {
    const mirror = new GcalMirror({ config: null, transport: new FakeTransport() });
    assert.strictEqual(mirror.isConfigured(), false);
    await mirror.syncAlarm(alarm()); // must resolve, not throw
    assert.deepStrictEqual(mirror.status().configured, false);
  });

  it('upserts an active alarm via insert', async () => {
    const transport = new FakeTransport();
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm());
    assert.deepStrictEqual(transport.calls, [
      'ensureCalendar',
      'insert:550e8400e29b41d4a716446655440000',
    ]);
  });

  it('falls back to update when insert reports a duplicate', async () => {
    const transport = new FakeTransport({ insert: new GcalApiError('duplicate', 409) });
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm());
    assert.deepStrictEqual(transport.calls, [
      'ensureCalendar',
      'insert:550e8400e29b41d4a716446655440000',
      'update:550e8400e29b41d4a716446655440000',
    ]);
  });

  it('re-inserts when update finds the event was deleted by the user', async () => {
    const transport = new FakeTransport({
      insert: new GcalApiError('duplicate', 409),
      update: new GcalApiError('notFound', 404),
    });
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm());
    assert.deepStrictEqual(transport.calls, [
      'ensureCalendar',
      'insert:550e8400e29b41d4a716446655440000',
      'update:550e8400e29b41d4a716446655440000',
      'insert:550e8400e29b41d4a716446655440000',
    ]);
  });

  it('deletes the event for a cancelled or disabled alarm', async () => {
    const transport = new FakeTransport();
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm({ status: 'canceled' }));
    assert.deepStrictEqual(transport.calls, [
      'ensureCalendar',
      'delete:550e8400e29b41d4a716446655440000',
    ]);
  });

  it('does nothing for a dismissed alarm', async () => {
    const transport = new FakeTransport();
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm({ status: 'dismissed' }));
    assert.deepStrictEqual(transport.calls, []);
  });

  it('treats a 404 on delete as already-gone success', async () => {
    const transport = new FakeTransport({ delete: new GcalApiError('notFound', 404) });
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm({ status: 'canceled' })); // must not throw
    assert.deepStrictEqual(transport.calls, [
      'ensureCalendar',
      'delete:550e8400e29b41d4a716446655440000',
    ]);
  });

  it('skips a malformed alarm id rather than throwing', async () => {
    const transport = new FakeTransport();
    const mirror = new GcalMirror({ config: CONFIG, transport });
    // Note: deriveEventId accepts base32hex ids, so the malformed input must
    // contain a character outside [0-9a-v] (an underscore). 'not-a-uuid' would
    // be accepted because hyphens are stripped and its letters are in range.
    await mirror.syncAlarm(alarm({ id: 'not_a_uuid' }));
    assert.ok(!transport.calls.some((call) => call.startsWith('insert:')));
    assert.match(mirror.status().last_error ?? '', /cannot derive/i);
  });

  it('persists the calendar id so a later run does not create a second calendar', async () => {
    const transport = new FakeTransport();
    await new GcalMirror({ config: CONFIG, transport }).syncAlarm(alarm());
    // A second, fresh mirror (as after a process restart) must reuse the
    // stored id rather than calling calendars.insert a second time.
    await new GcalMirror({ config: CONFIG, transport }).syncAlarm(alarm());
    const ensureCalls = transport.calls.filter((call) => call === 'ensureCalendar').length;
    assert.strictEqual(ensureCalls, 1);
    const stored = db.prepare("SELECT value FROM settings WHERE key = 'gcal_calendar_id'").get() as
      | { value: string }
      | undefined;
    assert.strictEqual(stored?.value, 'cal-1');
  });

  it('records a failure in status and propagates it', async () => {
    const transport = new FakeTransport({ insert: new GcalApiError('boom', 500) });
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await assert.rejects(() => mirror.syncAlarm(alarm()));
    assert.strictEqual(mirror.status().ok, false);
    assert.match(mirror.status().last_error ?? '', /boom/);
  });

  it('flags needs_reauth when the failure is an auth failure', async () => {
    const transport = new FakeTransport({ insert: new GcalApiError('invalid_grant', 401) });
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await assert.rejects(() => mirror.syncAlarm(alarm()));
    assert.strictEqual(mirror.status().needs_reauth, true);
    assert.strictEqual(mirror.status().last_error_kind, 'auth');
  });

  it('does not flag needs_reauth for a non-auth failure', async () => {
    const transport = new FakeTransport({ insert: new GcalApiError('boom', 500) });
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await assert.rejects(() => mirror.syncAlarm(alarm()));
    assert.strictEqual(mirror.status().needs_reauth, false);
    assert.strictEqual(mirror.status().last_error_kind, 'transient');
  });

  it('clears needs_reauth after a later successful sync', async () => {
    const mirror = new GcalMirror({ config: CONFIG, transport: new FakeTransport() });
    // Nothing has failed yet.
    assert.strictEqual(mirror.status().needs_reauth, false);
    assert.strictEqual(mirror.status().last_error_kind, null);
    // noteError records without throwing (the reconciler's path).
    mirror.noteError(new GcalApiError('invalid_grant', 401));
    assert.strictEqual(mirror.status().needs_reauth, true);
    assert.strictEqual(mirror.status().last_error_kind, 'auth');
    // A later success resets the flags.
    await mirror.syncAlarm(alarm());
    assert.strictEqual(mirror.status().needs_reauth, false);
    assert.strictEqual(mirror.status().last_error_kind, null);
    assert.strictEqual(mirror.status().last_error, null);
  });

  it('isStatus only matches GcalApiError', () => {
    assert.ok(isStatus(new GcalApiError('x', 409), 409));
    assert.ok(!isStatus(new Error('409'), 409));
  });
});
