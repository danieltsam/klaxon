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
      const targetTimeWithSeconds = '2026-10-15T07:30:45.123Z';
      const response = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: {
          target_time: targetTimeWithSeconds,
          label: 'Standup Sync',
          repeat_days: [1, 2, 3, 4, 5]
        }
      });
      assert.strictEqual(response.statusCode, 201);
      const data = JSON.parse(response.body);

      assert.ok(data.id);
      createdAlarmId = data.id;
      assert.strictEqual(data.label, 'Standup Sync');
      assert.strictEqual(data.status, 'pending');
      assert.strictEqual(data.repeat_days, '1,2,3,4,5');

      // Crucial: seconds and milliseconds must be zeroed out
      const parsed = new Date(data.target_time);
      assert.strictEqual(parsed.getSeconds(), 0);
      assert.strictEqual(parsed.getMilliseconds(), 0);
      assert.strictEqual(data.target_time, '2026-10-15T07:30:00.000Z');
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

    it('POST /api/alarms/:id/state should transition to "snoozed"', async () => {
      const response = await app.inject({
        method: 'POST',
        url: `/api/alarms/${createdAlarmId}/state`,
        payload: { status: 'snoozed' }
      });
      assert.strictEqual(response.statusCode, 200);
      const data = JSON.parse(response.body);
      assert.strictEqual(data.status, 'snoozed');

      // Verify in DB
      const record = AlarmRepo.getById(createdAlarmId);
      assert.strictEqual(record?.status, 'snoozed');
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
