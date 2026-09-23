import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  app,
  sweepMissedAlarms,
  deriveMissedReason,
  missedSweepStarted,
  DEVICE_MISSED_REASONS,
  MISSED_GRACE_MS,
} from '../src/server.js';
import { db, AlarmRepo } from '../src/db.js';
import { actionForStatus, toGoogleEvent } from '../src/gcal-events.js';
import type { AlarmRecord } from '../src/db.js';

const NOW = new Date('2026-09-23T12:00:00.000Z');
const BASE_TARGET = '2026-09-23T11:00:00.000Z'; // an hour before NOW

let counter = 0;
function insertAlarm(overrides: Partial<AlarmRecord> = {}): AlarmRecord {
  const alarm: AlarmRecord = {
    id: `test-missed-${Date.now()}-${counter++}`,
    target_time: BASE_TARGET,
    label: 'Sweep fixture',
    status: 'pending',
    ...overrides,
  };
  AlarmRepo.create(alarm);
  return alarm;
}

describe('Missed alarms: sweep, reason, report, calendar', () => {
  before(async () => {
    await app.ready();
  });

  after(async () => {
    db.prepare("DELETE FROM alarms WHERE id LIKE 'test-missed-%'").run();
    await app.close();
  });

  describe('deriveMissedReason — the closed reason set (spec §7)', () => {
    it('returns unknown when no dispatch was ever recorded', () => {
      assert.strictEqual(deriveMissedReason({}), 'unknown');
      assert.strictEqual(
        deriveMissedReason({ last_dispatch_sent: null, last_dispatch_failed: null }),
        'unknown'
      );
    });

    it('returns no_device_registered when nothing was sent and nothing failed', () => {
      assert.strictEqual(
        deriveMissedReason({ last_dispatch_sent: 0, last_dispatch_failed: 0 }),
        'no_device_registered'
      );
    });

    it('returns delivery_failed when any token failed', () => {
      assert.strictEqual(
        deriveMissedReason({ last_dispatch_sent: 2, last_dispatch_failed: 1 }),
        'delivery_failed'
      );
      assert.strictEqual(
        deriveMissedReason({ last_dispatch_sent: 0, last_dispatch_failed: 1 }),
        'delivery_failed'
      );
    });

    it('treats mock-mode sent>0 as dispatched_not_reported, never "delivered"', () => {
      // Mock-mode FCM reports sent = deviceCount while delivering nothing
      // (spec §3). The reason must not overclaim delivery (spec §7).
      const reason = deriveMissedReason({ last_dispatch_sent: 3, last_dispatch_failed: 0 });
      assert.strictEqual(reason, 'dispatched_not_reported');
      assert.ok(!reason.includes('deliver'), 'sent>0 must never be labelled as delivered');
    });

    it('the vocabulary is exactly the six spec values', () => {
      const expected = [
        'no_device_registered',
        'delivery_failed',
        'dispatched_not_reported',
        'unknown',
        'device_reported_stale',
        'device_reported_failed',
      ];
      const derived = [
        deriveMissedReason({ last_dispatch_sent: 0, last_dispatch_failed: 0 }),
        deriveMissedReason({ last_dispatch_sent: 0, last_dispatch_failed: 1 }),
        deriveMissedReason({ last_dispatch_sent: 1, last_dispatch_failed: 0 }),
        deriveMissedReason({}),
        ...DEVICE_MISSED_REASONS,
      ];
      assert.deepStrictEqual([...new Set(derived)].sort(), [...expected].sort());
    });
  });

  describe('sweepMissedAlarms (spec §6.1)', () => {
    it('marks a past one-time alarm missed with timestamp and reason', () => {
      const alarm = insertAlarm();
      sweepMissedAlarms(NOW);
      const row = AlarmRepo.getById(alarm.id)!;
      assert.strictEqual(row.status, 'missed');
      assert.strictEqual(row.missed_at, NOW.toISOString());
      assert.strictEqual(row.missed_reason, 'unknown'); // no dispatch recorded
    });

    it('records no_device_registered when the last dispatch had zero devices', () => {
      const alarm = insertAlarm();
      AlarmRepo.recordDispatch(alarm.id, 0, 0);
      sweepMissedAlarms(NOW);
      const row = AlarmRepo.getById(alarm.id)!;
      assert.strictEqual(row.status, 'missed');
      assert.strictEqual(row.missed_reason, 'no_device_registered');
    });

    it('does not mark a recurring alarm as missed', () => {
      const alarm = insertAlarm({ repeat_days: '1,2,3,4,5' });
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(alarm.id)!.status, 'pending');
    });

    it('does not mark a fortnightly alarm as missed', () => {
      const alarm = insertAlarm({
        repeat_days: '1',
        recurrence_interval_weeks: 2,
        recurrence_anchor_date: '2026-09-07',
      });
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(alarm.id)!.status, 'pending');
    });

    it('does not mark an alarm still inside the five-minute grace window', () => {
      const alarm = insertAlarm({
        target_time: new Date(NOW.getTime() - 2 * 60_000).toISOString(),
      });
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(alarm.id)!.status, 'pending');
    });

    it('does not mark an alarm exactly on the grace boundary', () => {
      const alarm = insertAlarm({
        target_time: new Date(NOW.getTime() - MISSED_GRACE_MS).toISOString(),
      });
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(alarm.id)!.status, 'pending');
    });

    it('does not mark a future alarm', () => {
      const alarm = insertAlarm({
        target_time: new Date(NOW.getTime() + 60 * 60_000).toISOString(),
      });
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(alarm.id)!.status, 'pending');
    });

    it('does not sweep a ringing alarm (spec §15 item 3)', () => {
      const ringing = insertAlarm({ status: 'ringing' });
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(ringing.id)!.status, 'ringing');
    });

    it('sweeps a snoozed one-time alarm whose time is beyond grace (spec §15 item 3)', () => {
      const snoozed = insertAlarm({ status: 'snoozed' });
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(snoozed.id)!.status, 'missed');
    });

    it('does not sweep a snoozed alarm whose next ring time is in the future', () => {
      const snoozed = insertAlarm({
        status: 'snoozed',
        target_time: new Date(NOW.getTime() + 60 * 60_000).toISOString(),
      });
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(snoozed.id)!.status, 'snoozed');
    });

    it('does not sweep a snoozed alarm still inside the grace window', () => {
      const snoozed = insertAlarm({
        status: 'snoozed',
        target_time: new Date(NOW.getTime() - 2 * 60_000).toISOString(),
      });
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(snoozed.id)!.status, 'snoozed');
    });

    it('does not sweep a snoozed recurring alarm', () => {
      const snoozed = insertAlarm({ status: 'snoozed', repeat_days: '1,2,3,4,5' });
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(snoozed.id)!.status, 'snoozed');
    });

    it('old-app snooze without target_time stays snoozed after an immediate sweep', async () => {
      // An older app sends { status: 'snoozed' } with no target_time. The
      // endpoint's fallback (~9 minutes out) must not be misread as stale.
      const alarm = insertAlarm();
      const response = await app.inject({
        method: 'POST',
        url: `/api/alarms/${alarm.id}/state`,
        payload: { status: 'snoozed' },
      });
      assert.strictEqual(response.statusCode, 200);
      sweepMissedAlarms();
      assert.strictEqual(AlarmRepo.getById(alarm.id)!.status, 'snoozed');
    });

    it('one bad row does not stop the sweep (spec §4.1)', () => {
      const bad = insertAlarm({ target_time: 'not-a-timestamp' });
      const good = insertAlarm();
      sweepMissedAlarms(NOW);
      assert.strictEqual(AlarmRepo.getById(bad.id)!.status, 'pending'); // skipped
      assert.strictEqual(AlarmRepo.getById(good.id)!.status, 'missed'); // still processed
    });
  });

  describe('POST /api/alarms/:id/state rejects missed (spec §5)', () => {
    it('returns 400 and leaves the alarm untouched', async () => {
      const alarm = insertAlarm();
      const response = await app.inject({
        method: 'POST',
        url: `/api/alarms/${alarm.id}/state`,
        payload: { status: 'missed' },
      });
      assert.strictEqual(response.statusCode, 400);
      assert.strictEqual(AlarmRepo.getById(alarm.id)!.status, 'pending');
    });
  });

  describe('dispatch outcome persistence (spec §5.1)', () => {
    it('records the FCM result and timestamp when an alarm is created', async () => {
      // No device tokens are registered in this file, so the dispatch is
      // deterministically { sent: 0, failed: 0 } regardless of FCM init.
      const response = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: { target_time: '2026-09-23T13:00:00.000Z', label: 'Dispatch persistence' },
      });
      assert.strictEqual(response.statusCode, 201);
      const created = JSON.parse(response.body);
      const row = AlarmRepo.getById(created.id)!;
      assert.strictEqual(row.last_dispatch_sent, 0);
      assert.strictEqual(row.last_dispatch_failed, 0);
      assert.ok(row.last_dispatch_at, 'dispatch timestamp must be persisted');
      db.prepare('DELETE FROM alarms WHERE id = ?').run(created.id);
    });
  });

  describe('POST /api/alarms/report-missed (spec §6.2)', () => {
    it('accepts device_reported_stale and counts the update', async () => {
      const alarm = insertAlarm();
      const response = await app.inject({
        method: 'POST',
        url: '/api/alarms/report-missed',
        payload: { ids: [alarm.id], reason: 'device_reported_stale' },
      });
      assert.strictEqual(response.statusCode, 200);
      assert.deepStrictEqual(JSON.parse(response.body), { updated: 1 });
      const row = AlarmRepo.getById(alarm.id)!;
      assert.strictEqual(row.status, 'missed');
      assert.strictEqual(row.missed_reason, 'device_reported_stale');
      assert.ok(row.missed_at);
    });

    it('accepts device_reported_failed', async () => {
      const alarm = insertAlarm();
      const response = await app.inject({
        method: 'POST',
        url: '/api/alarms/report-missed',
        payload: { ids: [alarm.id], reason: 'device_reported_failed' },
      });
      assert.strictEqual(response.statusCode, 200);
      assert.deepStrictEqual(JSON.parse(response.body), { updated: 1 });
      assert.strictEqual(AlarmRepo.getById(alarm.id)!.missed_reason, 'device_reported_failed');
    });

    it('rejects sweep-only and unknown reasons', async () => {
      for (const reason of ['delivery_failed', 'dispatched_not_reported', 'made_up']) {
        const response = await app.inject({
          method: 'POST',
          url: '/api/alarms/report-missed',
          payload: { ids: [], reason },
        });
        assert.strictEqual(response.statusCode, 400, `reason "${reason}" must be rejected`);
      }
    });

    it('skips unknown ids without failing', async () => {
      const response = await app.inject({
        method: 'POST',
        url: '/api/alarms/report-missed',
        payload: { ids: ['does-not-exist'], reason: 'device_reported_stale' },
      });
      assert.strictEqual(response.statusCode, 200);
      assert.deepStrictEqual(JSON.parse(response.body), { updated: 0 });
    });

    it('handles a mixed batch and never 500s on malformed entries', async () => {
      const alarm = insertAlarm();
      const response = await app.inject({
        method: 'POST',
        url: '/api/alarms/report-missed',
        payload: {
          ids: [alarm.id, 'does-not-exist', 42, null, ''],
          reason: 'device_reported_stale',
        },
      });
      assert.strictEqual(response.statusCode, 200);
      assert.deepStrictEqual(JSON.parse(response.body), { updated: 1 });
    });
  });

  describe('view membership (spec §5)', () => {
    it('excludes missed from view=active and includes it in view=all', () => {
      const alarm = insertAlarm();
      AlarmRepo.markMissed(alarm.id, 'device_reported_stale', NOW.toISOString());

      const active = AlarmRepo.getAll('active').map((a) => a.id);
      const all = AlarmRepo.getAll('all').map((a) => a.id);

      assert.ok(!active.includes(alarm.id), 'missed must not be active');
      assert.ok(all.includes(alarm.id), 'missed must appear in view=all');
    });
  });

  describe('calendar mapping (spec §9)', () => {
    it("maps missed to 'upsert', not 'delete'", () => {
      assert.strictEqual(actionForStatus('missed'), 'upsert');
    });

    it('annotates the event description with the timestamp and reason', () => {
      const event = toGoogleEvent(
        {
          id: '550e8400-e29b-41d4-a716-446655440000',
          target_time: '2026-09-23T11:00:00.000Z',
          label: 'Standup',
          status: 'missed',
          missed_at: '2026-09-23T12:01:00.000Z',
          missed_reason: 'dispatched_not_reported',
        },
        'UTC'
      );
      assert.match(event.description ?? '', /MISSED/);
      assert.match(event.description ?? '', /2026-09-23T12:01:00\.000Z/);
      assert.match(event.description ?? '', /dispatched_not_reported/);
      assert.ok(!event.description!.includes('delivered'));
    });
  });

  describe('test hermeticity (spec §6.1, §13.3)', () => {
    it('does not start the sweep timer under NODE_ENV=test', () => {
      assert.strictEqual(process.env.NODE_ENV, 'test');
      assert.strictEqual(
        missedSweepStarted,
        false,
        'the sweep timer must not run under test or it will touch Google calendars'
      );
    });
  });
});
