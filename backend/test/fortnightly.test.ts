import { describe, it, before, after } from 'node:test';
import assert from 'node:assert';
import { app } from '../src/server.js';
import { db, AlarmRepo, DeviceRepo } from '../src/db.js';
import { recurrenceRule, toGoogleEvent } from '../src/gcal-events.js';
import type { AlarmRecord } from '../src/db.js';

describe('Fortnightly Recurrence (recurrence_interval_weeks)', () => {
  const testToken = 'test_fortnightly_device_token';
  const createdIds: string[] = [];

  before(async () => {
    await app.ready();
    DeviceRepo.upsert(testToken);
  });

  after(async () => {
    for (const id of createdIds) {
      db.prepare('DELETE FROM alarms WHERE id = ?').run(id);
    }
    DeviceRepo.remove(testToken);
    await app.close();
  });

  it('POST /api/alarms with recurrence_interval_weeks: 2 defaults anchor to the target_time date', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: {
        target_time: '2026-10-07T07:00:00Z',
        label: 'Fortnightly Auto-Anchor',
        recurrence_interval_weeks: 2,
        repeat_days: [3]
      }
    });
    assert.strictEqual(response.statusCode, 201);
    const data = JSON.parse(response.body);
    createdIds.push(data.id);
    assert.strictEqual(data.recurrence_interval_weeks, 2);
    assert.strictEqual(data.recurrence_anchor_date, '2026-10-07');

    const record = AlarmRepo.getById(data.id);
    assert.strictEqual(record?.recurrence_interval_weeks, 2);
    assert.strictEqual(record?.recurrence_anchor_date, '2026-10-07');
  });

  it('POST /api/alarms with recurrence_interval_weeks: 2 and an explicit anchor persists it', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: {
        target_time: '2026-11-04T07:00:00Z',
        label: 'Fortnightly Explicit Anchor',
        recurrence_interval_weeks: 2,
        recurrence_anchor_date: '2026-10-21',
        repeat_days: [3]
      }
    });
    assert.strictEqual(response.statusCode, 201);
    const data = JSON.parse(response.body);
    createdIds.push(data.id);
    assert.strictEqual(data.recurrence_anchor_date, '2026-10-21');

    const record = AlarmRepo.getById(data.id);
    assert.strictEqual(record?.recurrence_anchor_date, '2026-10-21');
  });

  it('POST /api/alarms with recurrence_interval_weeks: 3 is rejected with 400', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: {
        target_time: '2026-10-07T07:00:00Z',
        label: 'Invalid Interval',
        recurrence_interval_weeks: 3
      }
    });
    assert.strictEqual(response.statusCode, 400);
  });

  it('POST /api/alarms with a malformed recurrence_anchor_date is rejected with 400', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: {
        target_time: '2026-10-07T07:00:00Z',
        label: 'Bad Anchor',
        recurrence_interval_weeks: 2,
        recurrence_anchor_date: '07-10-2026'
      }
    });
    assert.strictEqual(response.statusCode, 400);
  });

  it('FCM CREATE payload includes recurrence_interval_weeks and recurrence_anchor_date as strings', async () => {
    // Earlier POSTs trigger real FCM sends against the fake token, which fail
    // and prune it. Re-register so the dispatch path actually logs a payload.
    DeviceRepo.upsert(testToken);
    let capturedPayload: Record<string, string> | undefined;
    const originalLog = console.log;
    console.log = (...args: any[]) => {
      if (typeof args[0] === 'string' && args[0].includes('[FCM] Dispatching CREATE')) {
        capturedPayload = args[1];
      }
      originalLog.apply(console, args);
    };
    try {
      const response = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: {
          target_time: '2026-10-07T07:00:00Z',
          label: 'Fortnightly FCM',
          recurrence_interval_weeks: 2,
          repeat_days: [3]
        }
      });
      assert.strictEqual(response.statusCode, 201);
      createdIds.push(JSON.parse(response.body).id);
    } finally {
      console.log = originalLog;
    }

    assert.ok(capturedPayload, 'FCM dispatch payload should have been logged');
    assert.strictEqual(capturedPayload.recurrence_interval_weeks, '2');
    assert.strictEqual(capturedPayload.recurrence_anchor_date, '2026-10-07');
  });

  it('PATCH /api/alarms/:id can change recurrence_interval_weeks from 1 to 2', async () => {
    const createRes = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: {
        target_time: '2026-12-01T08:00:00Z',
        label: 'Weekly To Fortnightly',
        repeat_days: [1]
      }
    });
    const created = JSON.parse(createRes.body);
    createdIds.push(created.id);
    assert.strictEqual(created.recurrence_interval_weeks, 1);

    const patchRes = await app.inject({
      method: 'PATCH',
      url: `/api/alarms/${created.id}`,
      payload: { recurrence_interval_weeks: 2 }
    });
    assert.strictEqual(patchRes.statusCode, 200);
    const updated = JSON.parse(patchRes.body);
    assert.strictEqual(updated.recurrence_interval_weeks, 2);
    assert.strictEqual(updated.recurrence_anchor_date, '2026-12-01');

    const record = AlarmRepo.getById(created.id);
    assert.strictEqual(record?.recurrence_interval_weeks, 2);
    assert.strictEqual(record?.recurrence_anchor_date, '2026-12-01');
  });

  it('GET /api/alarms returns recurrence_interval_weeks and recurrence_anchor_date', async () => {
    const createRes = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: {
        target_time: '2026-10-07T07:00:00Z',
        label: 'Fortnightly Get',
        recurrence_interval_weeks: 2,
        repeat_days: [3]
      }
    });
    const created = JSON.parse(createRes.body);
    createdIds.push(created.id);

    const response = await app.inject({
      method: 'GET',
      url: '/api/alarms?view=active'
    });
    assert.strictEqual(response.statusCode, 200);
    const alarms = JSON.parse(response.body);
    const found = alarms.find((a: any) => a.id === created.id);
    assert.ok(found, 'Created fortnightly alarm should appear in active view');
    assert.strictEqual(found.recurrence_interval_weeks, 2);
    assert.strictEqual(found.recurrence_anchor_date, '2026-10-07');
  });

  describe('gcal RRULE emission', () => {
    it('includes ;INTERVAL=2 when recurrence_interval_weeks is 2', () => {
      assert.deepStrictEqual(recurrenceRule('3', 2), [
        'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=WE'
      ]);
    });

    it('omits INTERVAL when recurrence_interval_weeks is 1 or unset', () => {
      assert.deepStrictEqual(recurrenceRule('3'), ['RRULE:FREQ=WEEKLY;BYDAY=WE']);
      assert.deepStrictEqual(recurrenceRule('3', 1), ['RRULE:FREQ=WEEKLY;BYDAY=WE']);
      assert.deepStrictEqual(recurrenceRule('3', null), ['RRULE:FREQ=WEEKLY;BYDAY=WE']);
    });

    it('toGoogleEvent carries the interval into the recurrence', () => {
      const alarm: AlarmRecord = {
        id: '550e8400-e29b-41d4-a716-446655440000',
        target_time: '2026-10-07T07:00:00.000Z',
        label: 'Fortnightly',
        status: 'pending',
        repeat_days: '3',
        recurrence_interval_weeks: 2
      };
      const event = toGoogleEvent(alarm, 'UTC');
      assert.deepStrictEqual(event.recurrence, [
        'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=WE'
      ]);
    });
  });
});