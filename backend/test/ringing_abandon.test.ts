import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  sweepAbandonedRingingAlarms,
  sweepMissedAlarms,
  RINGING_ABANDON_MS,
} from '../src/server.js';
import { db, AlarmRepo } from '../src/db.js';
import type { AlarmRecord } from '../src/db.js';

const NOW = new Date('2026-09-23T12:00:00.000Z');

let counter = 0;
function insertAlarm(overrides: Partial<AlarmRecord> = {}): AlarmRecord {
  const alarm: AlarmRecord = {
    id: `test-ringing-${Date.now()}-${counter++}`,
    target_time: new Date(NOW.getTime() - RINGING_ABANDON_MS - 60_000).toISOString(),
    label: 'Abandoned ring fixture',
    status: 'ringing',
    ...overrides,
  };
  AlarmRepo.create(alarm);
  return alarm;
}

describe('Abandoned ringing alarms: the unacknowledged-ring sweep', () => {
  after(async () => {
    db.prepare("DELETE FROM alarms WHERE id LIKE 'test-ringing-%'").run();
  });

  it('resolves a ringing alarm beyond the threshold as dismissed', () => {
    const alarm = insertAlarm();
    const resolved = sweepAbandonedRingingAlarms(NOW);
    assert.ok(resolved >= 1);

    const row = AlarmRepo.getById(alarm.id)!;
    assert.strictEqual(row.status, 'dismissed');
    // It fired, so it must NOT be recorded as a miss.
    assert.strictEqual(row.missed_at ?? null, null);
    assert.strictEqual(row.missed_reason ?? null, null);
  });

  it('leaves a ringing alarm inside the window untouched', () => {
    const alarm = insertAlarm({
      target_time: new Date(NOW.getTime() - 60 * 60_000).toISOString(), // 1 hour
    });
    sweepAbandonedRingingAlarms(NOW);
    assert.strictEqual(AlarmRepo.getById(alarm.id)!.status, 'ringing');
  });

  it('leaves a ringing alarm exactly on the threshold untouched', () => {
    const alarm = insertAlarm({
      target_time: new Date(NOW.getTime() - RINGING_ABANDON_MS).toISOString(),
    });
    sweepAbandonedRingingAlarms(NOW);
    assert.strictEqual(AlarmRepo.getById(alarm.id)!.status, 'ringing');
  });

  it('does not re-process an already dismissed alarm', () => {
    const alarm = insertAlarm({ status: 'dismissed' });
    sweepAbandonedRingingAlarms(NOW);
    const row = AlarmRepo.getById(alarm.id)!;
    assert.strictEqual(row.status, 'dismissed');
    assert.strictEqual(row.missed_reason ?? null, null);
  });

  it('does not re-process an already missed alarm', () => {
    const alarm = insertAlarm({ status: 'pending' });
    AlarmRepo.markMissed(alarm.id, 'device_reported_stale', NOW.toISOString());
    sweepAbandonedRingingAlarms(NOW);
    const row = AlarmRepo.getById(alarm.id)!;
    assert.strictEqual(row.status, 'missed');
    assert.strictEqual(row.missed_reason, 'device_reported_stale');
  });

  it('does not fight the missed sweep: the missed sweep still ignores ringing', () => {
    const alarm = insertAlarm();
    sweepMissedAlarms(NOW);
    assert.strictEqual(
      AlarmRepo.getById(alarm.id)!.status,
      'ringing',
      'the overdue/missed sweep must not touch a ringing alarm'
    );
  });

  it('resolves a recurring abandoned ring the same way', () => {
    const alarm = insertAlarm({ repeat_days: '1,2,3,4,5' });
    sweepAbandonedRingingAlarms(NOW);
    assert.strictEqual(AlarmRepo.getById(alarm.id)!.status, 'dismissed');
  });
});
