import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { evaluateDeliveryHealth } from '../src/alerts.js';

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
