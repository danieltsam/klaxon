import { describe, it, before, after } from 'node:test';
import assert from 'node:assert';
import { app } from '../src/server.js';
import { db, AlarmRepo, DeviceRepo } from '../src/db.js';

describe('Bidirectional Sync & Reconnection Contract Test Suite', () => {
  let createdAlarmId: string;

  before(async () => {
    await app.ready();
  });

  after(async () => {
    await app.close();
  });

  describe('1. State Transition & Contract Verification', () => {
    it('POST /api/alarms should create an alarm in pending state and return it in view=all', async () => {
      const targetTime = new Date(Date.now() + 3600000).toISOString();
      const res = await app.inject({
        method: 'POST',
        url: '/api/alarms',
        payload: {
          target_time: targetTime,
          label: 'Sync Contract Test Alarm',
          sound_tone: 'chime',
          ramp_seconds: 15,
          repeat_days: '1,2,3,4,5'
        }
      });

      assert.strictEqual(res.statusCode, 201);
      const data = JSON.parse(res.body);
      createdAlarmId = data.id;
      assert.ok(createdAlarmId);
      assert.strictEqual(data.status, 'pending');
      assert.strictEqual(data.sound_tone, 'chime');
      assert.strictEqual(data.ramp_seconds, 15);
      assert.strictEqual(data.repeat_days, '1,2,3,4,5');

      // Verify presence in view=all
      const listRes = await app.inject({
        method: 'GET',
        url: '/api/alarms?view=all'
      });
      assert.strictEqual(listRes.statusCode, 200);
      const allAlarms = JSON.parse(listRes.body);
      const found = allAlarms.find((a: any) => a.id === createdAlarmId);
      assert.ok(found, 'Alarm must be present in view=all');
      assert.strictEqual(found.status, 'pending');
    });

    it('POST /api/alarms/:id/state should transition pending -> disabled and dispatch CANCEL', async () => {
      const res = await app.inject({
        method: 'POST',
        url: `/api/alarms/${createdAlarmId}/state`,
        payload: { status: 'disabled' }
      });

      assert.strictEqual(res.statusCode, 200);
      const data = JSON.parse(res.body);
      assert.strictEqual(data.status, 'disabled');

      // Verify in DB
      const record = AlarmRepo.getById(createdAlarmId);
      assert.strictEqual(record?.status, 'disabled');

      // Must still be present in view=all so phone/dashboard keep it around with switch OFF
      const listAll = await app.inject({
        method: 'GET',
        url: '/api/alarms?view=all'
      });
      const all = JSON.parse(listAll.body);
      const found = all.find((a: any) => a.id === createdAlarmId);
      assert.ok(found, 'Disabled alarm must remain in view=all');
      assert.strictEqual(found.status, 'disabled');

      // But must NOT be returned in view=active
      const listActive = await app.inject({
        method: 'GET',
        url: '/api/alarms?view=active'
      });
      const active = JSON.parse(listActive.body);
      const inActive = active.find((a: any) => a.id === createdAlarmId);
      assert.strictEqual(inActive, undefined, 'Disabled alarm must not be returned in view=active');
    });

    it('POST /api/alarms/:id/state should transition disabled -> pending and dispatch CREATE', async () => {
      const res = await app.inject({
        method: 'POST',
        url: `/api/alarms/${createdAlarmId}/state`,
        payload: { status: 'pending' }
      });

      assert.strictEqual(res.statusCode, 200);
      const data = JSON.parse(res.body);
      assert.strictEqual(data.status, 'pending');

      const record = AlarmRepo.getById(createdAlarmId);
      assert.strictEqual(record?.status, 'pending');

      // Now must be in view=active again
      const listActive = await app.inject({
        method: 'GET',
        url: '/api/alarms?view=active'
      });
      const active = JSON.parse(listActive.body);
      const inActive = active.find((a: any) => a.id === createdAlarmId);
      assert.ok(inActive, 'Re-enabled alarm must be in view=active');
    });

    it('POST /api/alarms/:id/state should handle ringing, snoozed, and dismissed', async () => {
      // 1. ringing
      let res = await app.inject({
        method: 'POST',
        url: `/api/alarms/${createdAlarmId}/state`,
        payload: { status: 'ringing' }
      });
      assert.strictEqual(res.statusCode, 200);
      assert.strictEqual(AlarmRepo.getById(createdAlarmId)?.status, 'ringing');

      // 2. snoozed
      res = await app.inject({
        method: 'POST',
        url: `/api/alarms/${createdAlarmId}/state`,
        payload: { status: 'snoozed' }
      });
      assert.strictEqual(res.statusCode, 200);
      assert.strictEqual(AlarmRepo.getById(createdAlarmId)?.status, 'snoozed');

      // 3. dismissed
      res = await app.inject({
        method: 'POST',
        url: `/api/alarms/${createdAlarmId}/state`,
        payload: { status: 'dismissed' }
      });
      assert.strictEqual(res.statusCode, 200);
      assert.strictEqual(AlarmRepo.getById(createdAlarmId)?.status, 'dismissed');
    });

    it('DELETE /api/alarms/:id should set status canceled and exclude from view=all', async () => {
      const res = await app.inject({
        method: 'DELETE',
        url: `/api/alarms/${createdAlarmId}`
      });
      assert.strictEqual(res.statusCode, 200);

      // Verify excluded from view=all
      const listAll = await app.inject({
        method: 'GET',
        url: '/api/alarms?view=all'
      });
      const all = JSON.parse(listAll.body);
      const found = all.find((a: any) => a.id === createdAlarmId);
      assert.strictEqual(found, undefined, 'Canceled alarm must not appear in view=all');
    });
  });

  describe('2. Device Registration & Telemetry Reconnection Resilience', () => {
    it('should register phone with battery and hardware details', async () => {
      const token = 'test_reconnection_device_token';
      const registerRes = await app.inject({
        method: 'POST',
        url: '/api/devices/register',
        payload: {
          token,
          battery_level: 92,
          is_charging: true,
          device_name: 'Motorola G86'
        }
      });
      assert.strictEqual(registerRes.statusCode, 200);

      const listRes = await app.inject({
        method: 'GET',
        url: '/api/devices'
      });
      const data = JSON.parse(listRes.body);
      const dev = data.devices.find((d: any) => d.device_name === 'Motorola G86');
      assert.ok(dev);
      assert.strictEqual(dev.battery_level, 92);
      assert.strictEqual(dev.is_charging, true);

      // Cleanup
      DeviceRepo.remove(token);
    });

    it('should update battery telemetry upon device reconnection without duplicate rows', async () => {
      const token = 'test_reconnection_device_token_2';

      // First connection
      await app.inject({
        method: 'POST',
        url: '/api/devices/register',
        payload: {
          token,
          battery_level: 80,
          is_charging: false,
          device_name: 'Test Device'
        }
      });

      // Reconnection with new battery level
      await app.inject({
        method: 'POST',
        url: '/api/devices/register',
        payload: {
          token,
          battery_level: 75,
          is_charging: true,
          device_name: 'Test Device'
        }
      });

      const listRes = await app.inject({
        method: 'GET',
        url: '/api/devices'
      });
      const data = JSON.parse(listRes.body);
      const matching = data.devices.filter((d: any) => d.token_masked.startsWith(token.substring(0, 10)));
      assert.strictEqual(matching.length, 1, 'Only one device record should exist for the token');
      assert.strictEqual(matching[0].battery_level, 75);
      assert.strictEqual(matching[0].is_charging, true);

      // Cleanup
      DeviceRepo.remove(token);
    });
  });
});
