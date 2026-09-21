import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  actionForStatus,
  deriveEventId,
  recurrenceRule,
  toGoogleEvent,
  zonedDateTime,
} from '../src/gcal-events.js';
import type { AlarmRecord } from '../src/db.js';

const TZ = 'Australia/Brisbane';

function alarm(overrides: Partial<AlarmRecord> = {}): AlarmRecord {
  return {
    id: '550e8400-e29b-41d4-a716-446655440000',
    target_time: '2026-09-21T21:00:00.000Z', // 07:00 Brisbane
    label: 'Standup',
    status: 'pending',
    sound_tone: 'alarm',
    ramp_seconds: 30,
    ...overrides,
  };
}

describe('deriveEventId', () => {
  it('strips hyphens and lowercases', () => {
    assert.strictEqual(
      deriveEventId('550E8400-E29B-41D4-A716-446655440000'),
      '550e8400e29b41d4a716446655440000'
    );
  });

  it('produces a value inside the base32hex alphabet Google accepts', () => {
    const id = deriveEventId('550e8400-e29b-41d4-a716-446655440000');
    assert.match(id, /^[0-9a-v]{5,1024}$/);
    assert.strictEqual(id.length, 32);
  });

  it('is deterministic', () => {
    assert.strictEqual(deriveEventId(alarm().id), deriveEventId(alarm().id));
  });

  it('rejects a malformed id instead of emitting something invalid', () => {
    assert.throws(() => deriveEventId('not a uuid!'), /cannot derive/i);
    assert.throws(() => deriveEventId(''), /cannot derive/i);
    assert.throws(() => deriveEventId('zzz'), /cannot derive/i); // 'z' is outside base32hex
  });
});

describe('recurrenceRule', () => {
  it('maps ISO weekdays to Google day codes', () => {
    assert.deepStrictEqual(recurrenceRule('1,2,3,4,5'), [
      'RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
    ]);
    assert.deepStrictEqual(recurrenceRule('6,7'), ['RRULE:FREQ=WEEKLY;BYDAY=SA,SU']);
  });

  it('sorts and de-duplicates', () => {
    assert.deepStrictEqual(recurrenceRule('5,1,1,3'), [
      'RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR',
    ]);
  });

  it('returns undefined when there is nothing valid', () => {
    assert.strictEqual(recurrenceRule(undefined), undefined);
    assert.strictEqual(recurrenceRule(null), undefined);
    assert.strictEqual(recurrenceRule(''), undefined);
    assert.strictEqual(recurrenceRule('0,9,-1,junk'), undefined);
  });

  it('filters junk but keeps the valid days', () => {
    assert.deepStrictEqual(recurrenceRule('0,2,9'), ['RRULE:FREQ=WEEKLY;BYDAY=TU']);
  });

  it('never emits DTSTART (Google forbids it in recurrence)', () => {
    const rule = recurrenceRule('1')![0];
    assert.ok(!rule.includes('DTSTART'));
  });
});

describe('zonedDateTime', () => {
  it('renders a UTC instant as local wall clock with the right offset', () => {
    assert.deepStrictEqual(zonedDateTime('2026-09-21T21:00:00.000Z', TZ), {
      dateTime: '2026-09-22T07:00:00+10:00',
      timeZone: TZ,
    });
  });

  it('handles an offset that changes across a DST boundary', () => {
    // Europe/London is +01:00 in July and +00:00 in January.
    const summer = zonedDateTime('2026-07-01T12:00:00.000Z', 'Europe/London');
    const winter = zonedDateTime('2026-01-01T12:00:00.000Z', 'Europe/London');
    assert.strictEqual(summer.dateTime, '2026-07-01T13:00:00+01:00');
    assert.strictEqual(winter.dateTime, '2026-01-01T12:00:00+00:00');
  });

  it('uses h23 so midnight is 00, never 24', () => {
    const midnight = zonedDateTime('2026-09-21T14:00:00.000Z', TZ); // 00:00 Brisbane
    assert.strictEqual(midnight.dateTime, '2026-09-22T00:00:00+10:00');
  });

  it('adds minutes for the end time', () => {
    const end = zonedDateTime('2026-09-21T21:00:00.000Z', TZ, 15);
    assert.strictEqual(end.dateTime, '2026-09-22T07:15:00+10:00');
  });
});

describe('actionForStatus', () => {
  it('maps every alarm status exactly as the spec requires', () => {
    assert.strictEqual(actionForStatus('pending'), 'upsert');
    assert.strictEqual(actionForStatus('ringing'), 'upsert');
    assert.strictEqual(actionForStatus('snoozed'), 'upsert');
    assert.strictEqual(actionForStatus('canceled'), 'delete');
    assert.strictEqual(actionForStatus('disabled'), 'delete');
    assert.strictEqual(actionForStatus('dismissed'), 'leave');
  });
});

describe('toGoogleEvent', () => {
  it('builds the documented payload for a one-time alarm', () => {
    const event = toGoogleEvent(alarm(), TZ);
    assert.strictEqual(event.id, '550e8400e29b41d4a716446655440000');
    assert.strictEqual(event.summary, 'Standup');
    assert.deepStrictEqual(event.start, {
      dateTime: '2026-09-22T07:00:00+10:00',
      timeZone: TZ,
    });
    assert.deepStrictEqual(event.end, {
      dateTime: '2026-09-22T07:15:00+10:00',
      timeZone: TZ,
    });
    assert.strictEqual(event.recurrence, undefined);
  });

  it('suppresses reminders so the hardware alarm is not duplicated', () => {
    assert.deepStrictEqual(toGoogleEvent(alarm(), TZ).reminders, { useDefault: false });
  });

  it('is transparent so mirrored alarms never mark you busy', () => {
    assert.strictEqual(toGoogleEvent(alarm(), TZ).transparency, 'transparent');
  });

  it('attaches recurrence and a zone for a recurring alarm', () => {
    const event = toGoogleEvent(alarm({ repeat_days: '1,2,3,4,5' }), TZ);
    assert.deepStrictEqual(event.recurrence, ['RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR']);
    assert.strictEqual(event.start.timeZone, TZ);
  });

  it('never leaks credentials into any field', () => {
    const serialized = JSON.stringify(
      toGoogleEvent(alarm({ description: 'Take minutes' }), TZ)
    ).toLowerCase();
    for (const forbidden of ['token', 'secret', 'refresh', 'client_id', 'password', 'fcm']) {
      assert.ok(!serialized.includes(forbidden), `payload leaked "${forbidden}"`);
    }
  });
});
