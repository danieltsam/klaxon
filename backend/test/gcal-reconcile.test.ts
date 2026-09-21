import { describe, it, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { app } from '../src/server.js';
import { db, AlarmRepo } from '../src/db.js';
import { GcalMirror } from '../src/gcal.js';
import { reconcile } from '../src/gcal-reconcile.js';
import type { GcalTransport } from '../src/gcal.js';
import type { GoogleEvent } from '../src/gcal-events.js';

class RecordingTransport implements GcalTransport {
  inserted: string[] = [];
  deleted: string[] = [];
  constructor(private readonly existing: string[] = []) {}
  async ensureSecondaryCalendar(): Promise<string> {
    return 'cal-1';
  }
  async insertEvent(_c: string, event: GoogleEvent): Promise<void> {
    this.inserted.push(event.id);
  }
  async updateEvent(): Promise<void> {}
  async deleteEvent(_c: string, id: string): Promise<void> {
    this.deleted.push(id);
  }
  async listEventIds(): Promise<string[]> {
    return [...this.existing];
  }
}

const CONFIG = {
  clientId: 'id',
  clientSecret: 's',
  tokenPath: '/tmp/none.json',
  timeZone: 'Australia/Brisbane',
};

describe('reconcile', () => {
  before(async () => {
    await app.ready();
  });
  beforeEach(() => {
    db.prepare('DELETE FROM alarms').run();
    db.prepare("DELETE FROM settings WHERE key LIKE 'gcal_%'").run();
  });
  after(async () => {
    db.prepare('DELETE FROM alarms').run();
    db.prepare("DELETE FROM settings WHERE key LIKE 'gcal_%'").run();
    await app.close();
  });

  it('creates events missing from the calendar', async () => {
    AlarmRepo.create({
      id: '550e8400-e29b-41d4-a716-446655440000',
      target_time: '2030-01-01T21:00:00.000Z',
      label: 'Standup',
      status: 'pending',
    });
    const transport = new RecordingTransport([]);
    const result = await reconcile(new GcalMirror({ config: CONFIG, transport }));
    assert.strictEqual(result.created, 1);
    assert.deepStrictEqual(transport.inserted, ['550e8400e29b41d4a716446655440000']);
  });

  it('deletes orphan events with no matching alarm', async () => {
    const transport = new RecordingTransport(['deadbeefdeadbeefdeadbeefdeadbeef']);
    const result = await reconcile(new GcalMirror({ config: CONFIG, transport }));
    assert.strictEqual(result.deleted, 1);
    assert.deepStrictEqual(transport.deleted, ['deadbeefdeadbeefdeadbeefdeadbeef']);
  });

  it('leaves matching events alone', async () => {
    AlarmRepo.create({
      id: '550e8400-e29b-41d4-a716-446655440000',
      target_time: '2030-01-01T21:00:00.000Z',
      label: 'Standup',
      status: 'pending',
    });
    const transport = new RecordingTransport(['550e8400e29b41d4a716446655440000']);
    const result = await reconcile(new GcalMirror({ config: CONFIG, transport }));
    assert.strictEqual(result.created, 0);
    assert.strictEqual(result.deleted, 0);
  });

  it('is a no-op when the mirror is not configured', async () => {
    const transport = new RecordingTransport([]);
    const result = await reconcile(new GcalMirror({ config: null, transport }));
    assert.deepStrictEqual(result, { created: 0, deleted: 0, failed: 0 });
  });

  it('skips a malformed alarm id without aborting the others', async () => {
    AlarmRepo.create({
      id: 'zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz',
      target_time: '2030-01-01T20:00:00.000Z',
      label: 'Bad',
      status: 'pending',
    });
    AlarmRepo.create({
      id: '550e8400-e29b-41d4-a716-446655440000',
      target_time: '2030-01-01T21:00:00.000Z',
      label: 'Standup',
      status: 'pending',
    });
    const transport = new RecordingTransport([]);
    const result = await reconcile(new GcalMirror({ config: CONFIG, transport }));
    assert.strictEqual(result.created, 1);
    assert.strictEqual(result.failed, 0);
    assert.deepStrictEqual(transport.inserted, ['550e8400e29b41d4a716446655440000']);
  });

  it('reports failed: 1 and returns early when listing the calendar fails', async () => {
    class FailingListTransport extends RecordingTransport {
      override async listEventIds(): Promise<string[]> {
        throw new Error('list boom');
      }
    }
    const transport = new FailingListTransport(['deadbeefdeadbeefdeadbeefdeadbeef']);
    const result = await reconcile(new GcalMirror({ config: CONFIG, transport }));
    assert.deepStrictEqual(result, { created: 0, deleted: 0, failed: 1 });
    assert.deepStrictEqual(transport.inserted, []);
    assert.deepStrictEqual(transport.deleted, []);
  });

  it('continues to the next alarm when syncing one fails', async () => {
    class SelectiveFailTransport extends RecordingTransport {
      constructor(
        existing: string[],
        private readonly failId: string
      ) {
        super(existing);
      }
      override async insertEvent(_c: string, event: GoogleEvent): Promise<void> {
        if (event.id === this.failId) throw new Error('insert boom');
        this.inserted.push(event.id);
      }
    }
    AlarmRepo.create({
      id: '550e8400-e29b-41d4-a716-446655440000',
      target_time: '2030-01-01T21:00:00.000Z',
      label: 'Standup',
      status: 'pending',
    });
    AlarmRepo.create({
      id: '660e8400-e29b-41d4-a716-446655440000',
      target_time: '2030-01-01T22:00:00.000Z',
      label: 'Lunch',
      status: 'pending',
    });
    const transport = new SelectiveFailTransport([], '550e8400e29b41d4a716446655440000');
    const result = await reconcile(new GcalMirror({ config: CONFIG, transport }));
    assert.strictEqual(result.created, 1);
    assert.strictEqual(result.failed, 1);
    assert.deepStrictEqual(transport.inserted, ['660e8400e29b41d4a716446655440000']);
  });
});
