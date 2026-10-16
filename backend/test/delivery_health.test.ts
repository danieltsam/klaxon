import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { evaluateDeliveryHealth, shouldSendAlert, MISSED_ALERT_WINDOW_MS } from '../src/alerts.js';
import { app, missedSweepStarted } from '../src/server.js';

const NOW = new Date('2026-10-16T12:00:00Z');
const base = { deviceCount: 1, now: NOW };

function alarm(over: Record<string, unknown>) {
  return { id: 'a', target_time: '2026-10-16T12:00:00Z', ...over } as any;
}

describe('evaluateDeliveryHealth', () => {
  it('flags zero registered devices', () => {
    const h = evaluateDeliveryHealth({ ...base, deviceCount: 0, alarms: [] });
    assert.equal(h.ok, false);
    assert.deepEqual(h.reasons, ['no_registered_devices']);
  });

  it('flags firebase_uninitialized when firebase is not ready and a device exists', () => {
    const h = evaluateDeliveryHealth({ ...base, alarms: [], firebaseReady: false });
    assert.deepEqual(h.reasons, ['firebase_uninitialized']);
  });

  it('does not flag firebase_uninitialized when no device is registered', () => {
    const h = evaluateDeliveryHealth({ ...base, deviceCount: 0, alarms: [], firebaseReady: false });
    assert.deepEqual(h.reasons, ['no_registered_devices']);
  });

  it('flags dispatch_failed for an active alarm whose last dispatch failed', () => {
    const h = evaluateDeliveryHealth({
      ...base,
      alarms: [alarm({ status: 'pending', last_dispatch_failed: 1 })]
    });
    assert.deepEqual(h.reasons, ['dispatch_failed']);
  });

  it('flags dispatch_failed for a snoozed alarm whose last dispatch failed', () => {
    const h = evaluateDeliveryHealth({
      ...base,
      alarms: [alarm({ status: 'snoozed', last_dispatch_failed: 2 })]
    });
    assert.deepEqual(h.reasons, ['dispatch_failed']);
  });

  it('ignores a terminal alarm with a past dispatch failure', () => {
    const oldMissed = new Date(NOW.getTime() - MISSED_ALERT_WINDOW_MS - 1000).toISOString();
    const h = evaluateDeliveryHealth({
      ...base,
      alarms: [
        alarm({ id: 'm', status: 'missed', last_dispatch_failed: 1, missed_at: oldMissed }),
        alarm({ id: 'd', status: 'dismissed', last_dispatch_failed: 1 }),
        alarm({ id: 'x', status: 'disabled', last_dispatch_failed: 1 })
      ]
    });
    assert.equal(h.ok, true);
    assert.deepEqual(h.reasons, []);
  });

  it('flags alarm_missed when a missed alarm is inside the window', () => {
    const h = evaluateDeliveryHealth({
      ...base,
      alarms: [alarm({ status: 'missed', missed_at: '2026-10-16T06:00:00Z', last_dispatch_failed: 0 })]
    });
    assert.deepEqual(h.reasons, ['alarm_missed']);
  });

  it('does not flag alarm_missed for an old missed alarm', () => {
    const oldMissed = new Date(NOW.getTime() - MISSED_ALERT_WINDOW_MS - 1000).toISOString();
    const h = evaluateDeliveryHealth({
      ...base,
      alarms: [alarm({ status: 'missed', missed_at: oldMissed, last_dispatch_failed: 0 })]
    });
    assert.equal(h.ok, true);
    assert.deepEqual(h.reasons, []);
  });

  it('stays healthy through a quiet interval with no alarms', () => {
    assert.deepEqual(evaluateDeliveryHealth({ ...base, alarms: [] }), { ok: true, reasons: [] });
  });

  it('recovers once an active alarm failure is cleared', () => {
    const failing = alarm({ status: 'pending', last_dispatch_failed: 1 });
    assert.deepEqual(evaluateDeliveryHealth({ ...base, alarms: [failing] }).reasons, ['dispatch_failed']);
    const recovered = { ...failing, last_dispatch_failed: 0 };
    assert.deepEqual(evaluateDeliveryHealth({ ...base, alarms: [recovered] }), { ok: true, reasons: [] });
  });
});

describe('shouldSendAlert', () => {
  it('throttles repeated identical alerts', () => {
    const first = shouldSendAlert('no_registered_devices', new Date('2026-10-16T00:00:00Z'), null);
    assert.equal(first.send, true);
    const soon = shouldSendAlert('no_registered_devices', new Date('2026-10-16T00:05:00Z'), first.sentAt);
    assert.equal(soon.send, false);
    const later = shouldSendAlert('no_registered_devices', new Date('2026-10-16T01:00:00Z'), first.sentAt);
    assert.equal(later.send, true);
  });
});

describe('GET /api/health delivery health', () => {
  it('reports delivery health on /api/health', async () => {
    await app.ready();
    const res = await app.inject({ method: 'GET', url: '/api/health' });
    const body = res.json();
    assert.equal(typeof body.delivery_health.ok, 'boolean');
    assert.ok(Array.isArray(body.delivery_health.reasons));
  });

  it('does not start the real sweep timer under test', () => {
    assert.equal(missedSweepStarted, false);
  });
});
