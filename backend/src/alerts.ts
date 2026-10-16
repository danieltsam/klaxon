import type { AlarmRecord } from './db.js';

/**
 * The closed set of reasons delivery is considered unhealthy. A quiet interval
 * with no alarms is NOT one of them: the monitor is due-aware, not a heartbeat.
 */
export type DeliveryHealthReason =
  | 'no_registered_devices'
  | 'last_dispatch_failed'
  | 'alarm_due_without_report';

export interface DeliveryHealth {
  ok: boolean;
  reasons: DeliveryHealthReason[];
}

/** How far ahead an alarm counts as "due soon" for the without-report check. */
export const DUE_WITHIN_MS = 15 * 60 * 1000;

/**
 * Pure, due-aware delivery-health evaluation.
 *
 * Flags: zero registered devices; any alarm whose most recent dispatch failed;
 * and a pending/snoozed alarm that is due soon but was never dispatched
 * (`last_dispatch_sent` falsy). It never flags merely because time passed —
 * quiet intervals with no alarms stay healthy.
 */
export function evaluateDeliveryHealth(input: {
  deviceCount: number;
  alarms: AlarmRecord[];
  now: Date;
  dueWithinMs?: number;
}): DeliveryHealth {
  const reasons: DeliveryHealthReason[] = [];
  const dueWithinMs = input.dueWithinMs ?? DUE_WITHIN_MS;
  const nowMs = input.now.getTime();
  const horizonMs = nowMs + dueWithinMs;

  if (input.deviceCount === 0) {
    reasons.push('no_registered_devices');
  }

  let lastDispatchFailed = false;
  let dueWithoutReport = false;

  for (const alarm of input.alarms) {
    if (alarm.last_dispatch_failed != null && alarm.last_dispatch_failed > 0) {
      lastDispatchFailed = true;
    }

    if (alarm.status === 'pending' || alarm.status === 'snoozed') {
      const targetMs = new Date(alarm.target_time).getTime();
      const dueSoon = Number.isFinite(targetMs) && targetMs >= nowMs && targetMs <= horizonMs;
      if (dueSoon && !alarm.last_dispatch_sent) {
        dueWithoutReport = true;
      }
    }
  }

  if (lastDispatchFailed) {
    reasons.push('last_dispatch_failed');
  }
  if (dueWithoutReport) {
    reasons.push('alarm_due_without_report');
  }

  return { ok: reasons.length === 0, reasons };
}
