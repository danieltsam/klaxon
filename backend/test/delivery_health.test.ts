import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { evaluateDeliveryHealth, shouldSendAlert } from '../src/alerts.js';
import { app, missedSweepStarted } from '../src/server.js';

const base = { deviceCount: 1, now: new Date('2026-10-16T00:00:00Z'), dueWithinMs: 900000 };

describe('evaluateDeliveryHealth', () => {
  it('flags zero registered devices', () => {
    const h = evaluateDeliveryHealth({ ...base, deviceCount: 0, alarms: [] });
    assert.equal(h.ok, false);
    assert.deepEqual(h.reasons, ['no_registered_devices']);
  });

  it('flags a failed last dispatch', () => {
    const h = evaluateDeliveryHealth({ ...base, alarms: [{ id: 'a', status: 'pending', target_time: '2026-10-17T00:00:00Z', last_dispatch_failed: 1 } as any] });
    assert.ok(h.reasons.includes('last_dispatch_failed'));
  });

  it('flags a due alarm the phone never reported on', () => {
    const h = evaluateDeliveryHealth({ ...base, alarms: [{ id: 'a', status: 'pending', target_time: '2026-10-16T00:05:00Z', last_dispatch_failed: 0 } as any] });
    assert.ok(h.reasons.includes('alarm_due_without_report'));
  });

  it('stays healthy through a quiet interval with no alarms', () => {
    assert.deepEqual(evaluateDeliveryHealth({ ...base, alarms: [] }), { ok: true, reasons: [] });
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
