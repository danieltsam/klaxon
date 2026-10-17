import type { AlarmRecord } from './db.js';

/**
 * The closed set of reasons delivery is considered unhealthy. A quiet interval
 * with no alarms is NOT one of them: the monitor is due-aware, not a heartbeat.
 *
 * Every reason must be *transient*: it has to clear on its own once the
 * condition is fixed, or the webhook and phone push cry wolf forever (spec
 * §5.4, §8). That is why a failed dispatch only counts for an alarm that can
 * still be dispatched again (pending/snoozed) — a terminal alarm never sends
 * another message, so its historical failure is not actionable.
 */
export type DeliveryHealthReason =
  | 'no_registered_devices'
  | 'firebase_uninitialized'
  | 'dispatch_failed'
  | 'alarm_missed';

export interface DeliveryHealth {
  ok: boolean;
  reasons: DeliveryHealthReason[];
}

/**
 * How long a `missed` alarm stays actionable. A recently missed alarm is worth
 * raising; an older one is history, and flagging it would make `ok` false
 * forever because a missed alarm never transitions again.
 */
export const MISSED_ALERT_WINDOW_MS = 24 * 60 * 60 * 1000;

/**
 * Pure, due-aware delivery-health evaluation.
 *
 * Flags: zero registered devices; Firebase unable to send while a device is
 * registered (mock mode delivers nothing — spec §2); an active (pending or
 * snoozed) alarm whose most recent dispatch failed; and a `missed` alarm inside
 * the alert window. It never flags merely because time passed — quiet intervals
 * with no alarms stay healthy — and every reason clears when its cause does.
 */
export function evaluateDeliveryHealth(input: {
  deviceCount: number;
  alarms: AlarmRecord[];
  now: Date;
  firebaseReady?: boolean;
  missedAlertWindowMs?: number;
}): DeliveryHealth {
  const reasons: DeliveryHealthReason[] = [];
  const firebaseReady = input.firebaseReady ?? true;
  const missedAlertWindowMs = input.missedAlertWindowMs ?? MISSED_ALERT_WINDOW_MS;
  const nowMs = input.now.getTime();
  const missedFloorMs = nowMs - missedAlertWindowMs;

  if (input.deviceCount === 0) {
    reasons.push('no_registered_devices');
  } else if (!firebaseReady) {
    reasons.push('firebase_uninitialized');
  }

  let dispatchFailed = false;
  let alarmMissed = false;

  for (const alarm of input.alarms) {
    // Only an alarm that can still be dispatched again makes a past failure
    // actionable. A terminal alarm (missed/dismissed/disabled/canceled) never
    // sends another message, so its failure must not keep `ok` false.
    if (
      (alarm.status === 'pending' || alarm.status === 'snoozed') &&
      alarm.last_dispatch_failed != null &&
      alarm.last_dispatch_failed > 0
    ) {
      dispatchFailed = true;
    }

    if (alarm.status === 'missed' && alarm.missed_at) {
      const missedMs = new Date(alarm.missed_at).getTime();
      if (Number.isFinite(missedMs) && missedMs >= missedFloorMs && missedMs <= nowMs) {
        alarmMissed = true;
      }
    }
  }

  if (dispatchFailed) {
    reasons.push('dispatch_failed');
  }
  if (alarmMissed) {
    reasons.push('alarm_missed');
  }

  return { ok: reasons.length === 0, reasons };
}

export type WebhookKind = 'generic' | 'discord' | 'slack' | 'healthchecks';

/**
 * Throttle alerts so a persistently unhealthy system does not spam the webhook.
 * Sends when nothing was sent before, or when the cooldown has elapsed. The
 * `reason` names the condition for callers; the sweep keeps one cooldown clock.
 */
export function shouldSendAlert(
  reason: DeliveryHealthReason,
  now: Date,
  lastSentAt: Date | null,
  cooldownMs = 30 * 60 * 1000
): { send: boolean; sentAt: Date } {
  void reason;
  if (!lastSentAt || now.getTime() - lastSentAt.getTime() >= cooldownMs) {
    return { send: true, sentAt: now };
  }
  return { send: false, sentAt: lastSentAt };
}

export interface WebhookRequest {
  method: 'POST' | 'GET';
  headers: Record<string, string>;
  body?: string;
}

/**
 * Build a Healthchecks ping URL. Healthchecks is a dead-man's switch: it raises
 * an alert when pings STOP, so we ping on every sweep regardless of health and
 * add `/fail` when unhealthy so a bad sweep still trips the check. A trailing
 * slash on the base is dropped so the two parts join cleanly.
 */
export function healthchecksUrl(baseUrl: string, ok: boolean): string {
  const base = baseUrl.replace(/\/+$/, '');
  return ok ? base : `${base}/fail`;
}

/**
 * Shape an alert for a provider. Discord and Slack take a message JSON;
 * the generic kind POSTs `{ title, body }` as-is; Healthchecks is a heartbeat
 * ping (a GET with no body) — the alert fires when pings STOP, so the body is
 * meaningless to it.
 */
export function formatWebhookAlert(
  kind: WebhookKind,
  alert: { title: string; body: string }
): WebhookRequest {
  const text = `${alert.title}\n${alert.body}`;

  switch (kind) {
    case 'discord':
      return {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ content: text })
      };
    case 'slack':
      return {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ text })
      };
    case 'healthchecks':
      return { method: 'GET', headers: {} };
    case 'generic':
    default:
      return {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(alert)
      };
  }
}

/**
 * Send an alert to a webhook. A missing URL is a silent no-op (the feature is
 * optional). The call is bounded by a 5s timeout and never throws: a failed
 * webhook must not break the sweep.
 */
export async function sendWebhookAlert(
  url: string,
  kind: WebhookKind,
  alert: { title: string; body: string }
): Promise<boolean> {
  if (!url) {
    return false;
  }

  const request = formatWebhookAlert(kind, alert);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5000);

  try {
    const res = await fetch(url, {
      method: request.method,
      headers: request.headers,
      body: request.body,
      signal: controller.signal
    });
    return res.ok;
  } catch (err) {
    console.error('[alerts] webhook failed:', err instanceof Error ? err.message : err);
    return false;
  } finally {
    clearTimeout(timer);
  }
}
