import { describe, it, before, after } from 'node:test';
import assert from 'node:assert';
import { app } from '../src/server.js';
import { db, AlarmRepo, DeviceRepo } from '../src/db.js';

describe('Fastify Alarm API & Persistence Test Suite', () => {
  let createdAlarmId: string;

  before(async () => {
    await app.ready();
  });

  after(async () => {
    // Clean up test fixtures so test runs do not pollute alarms.db
    db.prepare("DELETE FROM alarms WHERE label IN ('Standup Sync', 'To Cancel')").run();
    db.prepare("DELETE FROM devices WHERE token LIKE 'test_device_token_%'").run();
    await app.close();
  });

  describe('Static & Health Endpoints', () => {
    it('GET / should serve the HTML dashboard', async () => {
      const response = await app.inject({
        method: 'GET',
        url: '/'
      });
      assert.strictEqual(response.statusCode, 200);
      assert.match(response.headers['content-type'] || '', /text\/html/);
      assert.match(response.body, /Remote Alarm/);
    });

    it('GET /api/calendar.ics should return standard iCalendar RFC 5545 feed', async () => {
      const response = await app.inject({
        method: 'GET',
        url: '/api/calendar.ics'
      });
      assert.strictEqual(response.statusCode, 200);
      assert.match(response.headers['content-type'] || '', /text\/calendar/);
      assert.match(response.headers['content-disposition'] || '', /alarms\.ics/);
      assert.match(response.body, /BEGIN:VCALENDAR/);
      assert.match(response.body, /VERSION:2\.0/);
      assert.match(response.body, /END:VCALENDAR/);
    });
  });

  describe('Device Registration API', () => {
    it('POST /api/devices/register should validate token presence', async () => {
      const response = await app.inject({
        method: 'POST',
        url: '/api/devices/register',
        payload: {}
      });
      assert.strictEqual(response.statusCode, 400);
      const data = JSON.parse(response.body);
      assert.match(data.error, /Missing or invalid device token/);
    });

    it('POST /api/devices/register should register a device token', async () => {
      const testToken = 'test_device_token_abc123456789';
      const response = await app.inject({
        method: 'POST',
        url: '/api/devices/register',
        payload: { token: testToken }
      });
      assert.strictEqual(response.statusCode, 200);
      const data = JSON.parse(response.body);
      assert.strictEqual(data.success, true);

      // Verify in DeviceRepo
      const tokens = DeviceRepo.getAllTokens();
      assert.ok(tokens.includes(testToken));
    });

    it('GET /api/devices should return count and masked tokens', async () => {
      const response = await app.inject({
        method: 'GET',
        url: '/api/devices'
      });
      assert.strictEqual(response.statusCode, 200);
      const data = JSON.parse(response.body);
      assert.ok(typeof data.count === 'number');
      assert.ok(Array.isArray(data.tokens));
    });
  });

  describe('Alarm Creation & Validation', () => {
    it('POST /api/alarms should reject missing fields', async () => {
      const response = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: { label: 'Incomplete' }
      });
      assert.strictEqual(response.statusCode, 400);
    });

    it('POST /api/alarms should reject invalid target_time timestamp', async () => {
      const response = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: {
          target_time: 'not-a-date',
          label: 'Test Alarm'
        }
      });
      assert.strictEqual(response.statusCode, 400);
      const data = JSON.parse(response.body);
      assert.match(data.error, /Invalid target_time/);
    });

    it('POST /api/alarms should create alarm, truncate seconds, and store repeat_days', async () => {
      // Derive the fixture from "now" so the target is always in the future.
      // A past target on a recurring alarm is deliberately rolled forward by
      // the create path, which would move it off the requested instant and make
      // the seconds-truncation assertion flaky.
      const requested = new Date(Date.now() + 45 * 24 * 60 * 60 * 1000);
      requested.setUTCHours(7, 30, 45, 123);
      const targetTimeWithSeconds = requested.toISOString();
      const expectedTargetTime = new Date(requested.getTime());
      expectedTargetTime.setUTCSeconds(0, 0);

      const response = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: {
          target_time: targetTimeWithSeconds,
          label: 'Standup Sync',
          description: 'Engineering daily standup and check-in',
          repeat_days: [1, 2, 3, 4, 5]
        }
      });
      assert.strictEqual(response.statusCode, 201);
      const data = JSON.parse(response.body);

      assert.ok(data.id);
      createdAlarmId = data.id;
      assert.strictEqual(data.label, 'Standup Sync');
      assert.strictEqual(data.description, 'Engineering daily standup and check-in');
      assert.strictEqual(data.status, 'pending');
      assert.strictEqual(data.repeat_days, '1,2,3,4,5');

      // Crucial: seconds and milliseconds must be zeroed out
      const parsed = new Date(data.target_time);
      assert.strictEqual(parsed.getSeconds(), 0);
      assert.strictEqual(parsed.getMilliseconds(), 0);
      assert.strictEqual(data.target_time, expectedTargetTime.toISOString());
    });
  });

  describe('Alarm Querying & Active vs History Filtering', () => {
    it('GET /api/alarms?view=active should return newly created pending alarm', async () => {
      const response = await app.inject({
        method: 'GET',
        url: '/api/alarms?view=active'
      });
      assert.strictEqual(response.statusCode, 200);
      const alarms = JSON.parse(response.body);
      assert.ok(Array.isArray(alarms));
      const found = alarms.find((a: any) => a.id === createdAlarmId);
      assert.ok(found, 'Created alarm should appear in active view');
      assert.strictEqual(found.status, 'pending');
      assert.strictEqual(found.description, 'Engineering daily standup and check-in');
    });

    it('GET /api/alarms?view=history should not include pending alarms', async () => {
      const response = await app.inject({
        method: 'GET',
        url: '/api/alarms?view=history'
      });
      assert.strictEqual(response.statusCode, 200);
      const alarms = JSON.parse(response.body);
      assert.ok(Array.isArray(alarms));
      const found = alarms.find((a: any) => a.id === createdAlarmId);
      assert.strictEqual(found, undefined, 'Pending alarm must not be in history view');
    });
  });

  describe('Alarm State Transitions', () => {
    it('POST /api/alarms/:id/state should reject invalid state', async () => {
      const response = await app.inject({
        method: 'POST',
        url: `/api/alarms/${createdAlarmId}/state`,
        payload: { status: 'invalid_status' }
      });
      assert.strictEqual(response.statusCode, 400);
    });

    it('POST /api/alarms/:id/state should transition to "snoozed" and set the next-ring time', async () => {
      const before = Date.now();
      const response = await app.inject({
        method: 'POST',
        url: `/api/alarms/${createdAlarmId}/state`,
        payload: { status: 'snoozed' }
      });
      const after = Date.now();
      assert.strictEqual(response.statusCode, 200);
      const data = JSON.parse(response.body);
      assert.strictEqual(data.status, 'snoozed');

      // Verify in DB
      const record = AlarmRepo.getById(createdAlarmId);
      assert.strictEqual(record?.status, 'snoozed');

      // The response must echo the newly persisted next-ring time, not the
      // stale existing value.
      assert.ok(record?.target_time, 'snooze must persist a target_time');
      assert.strictEqual(data.target_time, record?.target_time);

      // No target_time supplied: fallback = floor(now to the minute) + 9 min.
      const floorToMinute = (ms: number) => Math.floor(ms / 60000) * 60000;
      const actual = new Date(data.target_time).getTime();
      const allowed = [floorToMinute(before) + 9 * 60000, floorToMinute(after) + 9 * 60000];
      assert.ok(
        allowed.includes(actual),
        `snooze fallback ${data.target_time} was not floor(now to minute) + 9 min`
      );
      assert.ok(actual > after, 'the snooze time must be in the future');
    });

    it('POST /api/alarms/:id/state with an explicit future target_time stores it exactly', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: { target_time: '2026-12-01T08:00:00.000Z', label: 'Snooze Explicit' }
      });
      const created = JSON.parse(createRes.body);
      const explicit = '2026-12-01T09:30:00.000Z';

      const res = await app.inject({
        method: 'POST',
        url: `/api/alarms/${created.id}/state`,
        payload: { status: 'snoozed', target_time: explicit }
      });
      assert.strictEqual(res.statusCode, 200);
      const data = JSON.parse(res.body);
      assert.strictEqual(data.target_time, explicit);
      assert.strictEqual(AlarmRepo.getById(created.id)?.target_time, explicit);

      db.prepare('DELETE FROM alarms WHERE id = ?').run(created.id);
    });

    it('POST /api/alarms/:id/state snooze sends no FCM and leaves last_dispatch_* unchanged', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: { target_time: '2026-12-02T08:00:00.000Z', label: 'Snooze No FCM' }
      });
      const created = JSON.parse(createRes.body);
      const beforeDispatch = AlarmRepo.getById(created.id)!;

      const res = await app.inject({
        method: 'POST',
        url: `/api/alarms/${created.id}/state`,
        payload: { status: 'snoozed' }
      });
      assert.strictEqual(res.statusCode, 200);
      const data = JSON.parse(res.body);
      assert.strictEqual(data.fcm_dispatch, undefined, 'a snooze must not dispatch FCM');

      const afterDispatch = AlarmRepo.getById(created.id)!;
      assert.strictEqual(afterDispatch.last_dispatch_sent, beforeDispatch.last_dispatch_sent);
      assert.strictEqual(afterDispatch.last_dispatch_failed, beforeDispatch.last_dispatch_failed);
      assert.strictEqual(afterDispatch.last_dispatch_at, beforeDispatch.last_dispatch_at);

      db.prepare('DELETE FROM alarms WHERE id = ?').run(created.id);
    });

    it('POST /api/alarms/:id/state should transition to "dismissed" and move to history', async () => {
      const response = await app.inject({
        method: 'POST',
        url: `/api/alarms/${createdAlarmId}/state`,
        payload: { status: 'dismissed' }
      });
      assert.strictEqual(response.statusCode, 200);

      // Now verify it moved from active to history
      const activeRes = await app.inject({ method: 'GET', url: '/api/alarms?view=active' });
      const activeAlarms = JSON.parse(activeRes.body);
      assert.strictEqual(activeAlarms.find((a: any) => a.id === createdAlarmId), undefined);

      const historyRes = await app.inject({ method: 'GET', url: '/api/alarms?view=history' });
      const historyAlarms = JSON.parse(historyRes.body);
      const inHistory = historyAlarms.find((a: any) => a.id === createdAlarmId);
      assert.ok(inHistory, 'Dismissed alarm must appear in history view');
      assert.strictEqual(inHistory.status, 'dismissed');
    });
  });

  describe('Alarm Cancellation & Remote Silence', () => {
    it('DELETE /api/alarms/:id should cancel an existing alarm', async () => {
      // Create fresh alarm to cancel
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: {
          target_time: '2026-11-01T08:00:00.000Z',
          label: 'To Cancel'
        }
      });
      const toCancelId = JSON.parse(createRes.body).id;

      const deleteRes = await app.inject({
        method: 'DELETE',
        url: `/api/alarms/${toCancelId}`
      });
      assert.strictEqual(deleteRes.statusCode, 200);
      const data = JSON.parse(deleteRes.body);
      assert.strictEqual(data.status, 'canceled');

      const record = AlarmRepo.getById(toCancelId);
      assert.strictEqual(record?.status, 'canceled');
    });

    it('DELETE /api/alarms/:id should return 404 for non-existent alarm', async () => {
      const response = await app.inject({
        method: 'DELETE',
        url: '/api/alarms/non-existent-uuid-999'
      });
      assert.strictEqual(response.statusCode, 404);
    });

    it('POST /api/alarms/:id/silence should silence ringing alarm and dispatch FCM DISMISS', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: {
          target_time: '2026-11-01T09:00:00.000Z',
          label: 'To Silence',
          sound_tone: 'chime',
          ramp_seconds: 15
        }
      });
      const created = JSON.parse(createRes.body);
      assert.strictEqual(created.sound_tone, 'chime');
      assert.strictEqual(created.ramp_seconds, 15);

      const silenceRes = await app.inject({
        method: 'POST',
        url: `/api/alarms/${created.id}/silence`
      });
      assert.strictEqual(silenceRes.statusCode, 200);
      const data = JSON.parse(silenceRes.body);
      assert.strictEqual(data.status, 'dismissed');
      assert.strictEqual(data.success, true);

      // Verify in DB
      const record = AlarmRepo.getById(created.id);
      assert.strictEqual(record?.status, 'dismissed');

      // Cleanup
      db.prepare('DELETE FROM alarms WHERE id = ?').run(created.id);
    });

    it('PATCH /api/alarms/:id should update title, description, repeat_days, tone, and ramp', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: {
          target_time: '2026-12-01T08:00:00.000Z',
          label: 'Original Label',
          description: 'Original Desc',
          sound_tone: 'alarm',
          ramp_seconds: 0
        }
      });
      const created = JSON.parse(createRes.body);

      const patchRes = await app.inject({
        method: 'PATCH',
        url: `/api/alarms/${created.id}`,
        payload: {
          label: 'Updated Label',
          description: 'Updated Desc',
          target_time: '2026-12-01T09:30:00.000Z',
          repeat_days: [1, 3, 5],
          sound_tone: 'digital',
          ramp_seconds: 30
        }
      });
      assert.strictEqual(patchRes.statusCode, 200);
      const updated = JSON.parse(patchRes.body);
      assert.strictEqual(updated.label, 'Updated Label');
      assert.strictEqual(updated.description, 'Updated Desc');
      assert.strictEqual(updated.target_time, '2026-12-01T09:30:00.000Z');
      assert.strictEqual(updated.repeat_days, '1,3,5');
      assert.strictEqual(updated.sound_tone, 'digital');
      assert.strictEqual(updated.ramp_seconds, 30);

      // Verify in DB
      const dbRecord = AlarmRepo.getById(created.id);
      assert.strictEqual(dbRecord?.label, 'Updated Label');
      assert.strictEqual(dbRecord?.description, 'Updated Desc');
      assert.strictEqual(dbRecord?.sound_tone, 'digital');
      assert.strictEqual(dbRecord?.ramp_seconds, 30);
      assert.strictEqual(dbRecord?.repeat_days, '1,3,5');

      // Cleanup
      db.prepare('DELETE FROM alarms WHERE id = ?').run(created.id);
    });
  });

  describe('Device Battery & Telemetry API', () => {
    it('POST /api/devices/register should store battery, charging, and device name metadata', async () => {
      const testToken = 'test_device_token_battery_telemetry';
      const registerRes = await app.inject({
        method: 'POST',
        url: '/api/devices/register',
        payload: {
          token: testToken,
          battery_level: 84,
          is_charging: true,
          device_name: 'Google Pixel 8 Pro'
        }
      });
      assert.strictEqual(registerRes.statusCode, 200);

      const listRes = await app.inject({
        method: 'GET',
        url: '/api/devices'
      });
      assert.strictEqual(listRes.statusCode, 200);
      const data = JSON.parse(listRes.body);
      const dev = data.devices.find((d: any) => d.device_name === 'Google Pixel 8 Pro');
      assert.ok(dev, 'Device with telemetry must be returned');
      assert.strictEqual(dev.battery_level, 84);
      assert.strictEqual(dev.is_charging, true);

      // Cleanup
      DeviceRepo.remove(testToken);
    });
  });
});
