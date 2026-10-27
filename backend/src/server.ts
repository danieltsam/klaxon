import fastify from 'fastify';
import cors from '@fastify/cors';
import fastifyStatic from '@fastify/static';
import path from 'path';
import { v4 as uuidv4 } from 'uuid';
import dotenv from 'dotenv';
import { AlarmRepo, DeviceRepo, SettingsRepo, AlarmRecord, AppSettings, db } from './db.js';
import { initFirebase, isFirebaseReady, sendFcmDataMessage, sendFcmNotification, FcmPayload } from './fcm.js';
import { GcalMirror, unconfiguredTransport, classifyGcalError, type GcalTransport } from './gcal.js';
import { createGcalTransport } from './gcal-google.js';
import { resolveGcalConfig } from './gcal-config.js';
import { reconcile } from './gcal-reconcile.js';
import { evaluateDeliveryHealth, shouldSendAlert, sendWebhookAlert, healthchecksUrl, type DeliveryHealth, type WebhookKind } from './alerts.js';

dotenv.config();

const app = fastify({ logger: true });

// Empty-tolerant JSON parser. Fastify's default rejects an empty body when a
// client sends Content-Type: application/json, which turns bodyless POSTs into
// spurious 400s. Empty input becomes {}; malformed JSON still fails.
app.removeContentTypeParser('application/json');
app.addContentTypeParser('application/json', { parseAs: 'string' }, (_req, body, done) => {
  const raw = typeof body === 'string' ? body.trim() : '';
  if (raw.length === 0) return done(null, {});
  try {
    done(null, JSON.parse(raw));
  } catch (err) {
    // Preserve Fastify's default contract: malformed JSON is a 400, not a 500.
    (err as { statusCode?: number }).statusCode = 400;
    done(err as Error, undefined);
  }
});

// Register CORS for client access
await app.register(cors, {
  origin: true,
  methods: ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS']
});

// Serve static dashboard files
await app.register(fastifyStatic, {
  root: path.resolve(process.cwd(), 'public'),
  prefix: '/'
});

// Initialize Firebase
initFirebase();

// Google Calendar mirror. Unconfigured is a supported, silent state: it must
// never prevent an alarm from being created or delivered (spec §10).
const gcalResolution = resolveGcalConfig();
let gcalConfig = gcalResolution.config;
let gcalReason = gcalResolution.reason;
let gcalTransport: GcalTransport;

if (gcalConfig) {
  try {
    gcalTransport = createGcalTransport(gcalConfig);
  } catch (err) {
    // A missing/unreadable token file is the *normal* state before the owner
    // runs `npm run gcal:auth`. It must degrade to genuinely unconfigured —
    // never crash the process, and never claim to be configured while every
    // call throws. Passing config: null forces isConfigured() to false, so
    // operations are no-ops and /api/calendar/status honestly reports the
    // reason (spec §10).
    gcalReason = `token unavailable: ${err instanceof Error ? err.message : String(err)}`;
    gcalConfig = null;
    gcalTransport = unconfiguredTransport();
  }
} else {
  gcalTransport = unconfiguredTransport();
}

const gcal = new GcalMirror({
  config: gcalConfig,
  transport: gcalTransport,
  reason: gcalReason,
});

if (!gcal.isConfigured() && gcalReason) {
  console.error(`[gcal] disabled: ${gcalReason}`);
} else if (gcal.isConfigured()) {
  console.log(`[gcal] enabled for timezone ${gcal.timeZone()}`);
}

const GCAL_PUSH_TIMEOUT_MS = 3_000;
const GCAL_RECONCILE_INTERVAL_MS = 15 * 60 * 1_000;

/**
 * Missed-alarm policy (spec §4). A one-time alarm not armed within five
 * minutes of its time is treated as failed: recorded, never revived, and
 * visible to the owner. Recurring alarms are unaffected (§2).
 */
export const MISSED_GRACE_MS = 5 * 60 * 1_000;
export const MISSED_SWEEP_INTERVAL_MS = 60 * 1_000;

/**
 * The reason set is closed (spec §7). Both producers must use one of these six
 * values so the vocabulary cannot drift apart. `device_reported_*` are set only
 * by the device report path; the rest are derived by the sweep.
 */
export type MissedReason =
  | 'no_device_registered'
  | 'delivery_failed'
  | 'dispatched_not_reported'
  | 'unknown'
  | 'device_reported_stale'
  | 'device_reported_failed';

/** Reasons a device may report. Deliberately a subset of MissedReason. */
export const DEVICE_MISSED_REASONS: readonly MissedReason[] = [
  'device_reported_stale',
  'device_reported_failed',
];

/**
 * True when this process is a test run.
 *
 * `NODE_ENV` alone is not enough. Only the npm test script sets it, so a bare
 * `tsx --test <file>` reports `undefined` and would start the real timers
 * against the real database. That happened, and hung the process for seven
 * minutes on a live 60-second timer. Node's test runner sets
 * `NODE_TEST_CONTEXT` in every worker regardless of `NODE_ENV`, so checking
 * both closes that hole however the tests are invoked.
 */
const isTestRun =
  process.env.NODE_ENV === 'test' || process.env.NODE_TEST_CONTEXT !== undefined;

/** True once the sweep timer is armed. Stays false under a test run. */
export let missedSweepStarted = false;

/**
 * When the last delivery-health alert was sent, so repeated sweep ticks during
 * a persistent outage are throttled (spec §5.4). Module-level by design: it
 * must survive across timer ticks.
 */
let lastAlertAt: Date | null = null;

/**
 * Derive the miss reason from the last persisted dispatch outcome (spec §7).
 *
 * `sent > 0` is NOT proof of delivery — mock-mode FCM reports `sent =
 * deviceCount` while delivering nothing (§3) — so the wording is deliberately
 * `dispatched_not_reported`, never "delivered".
 */
export function deriveMissedReason(
  alarm: Pick<AlarmRecord, 'last_dispatch_sent' | 'last_dispatch_failed'>
): MissedReason {
  const sent = alarm.last_dispatch_sent;
  const failed = alarm.last_dispatch_failed;
  if (sent == null && failed == null) return 'unknown';
  const sentCount = sent ?? 0;
  const failedCount = failed ?? 0;
  if (sentCount === 0 && failedCount === 0) return 'no_device_registered';
  if (failedCount > 0) return 'delivery_failed';
  if (sentCount > 0) return 'dispatched_not_reported';
  return 'unknown';
}

/**
 * Mark overdue one-time `pending` and `snoozed` alarms as `missed` (spec §6.1,
 * §15 item 3).
 *
 * Purely time-based and cause-agnostic (§4.1). A `snoozed` alarm is swept too:
 * its next-ring time lives in `target_time`, so a snooze that passed without
 * ringing is the same failure as a stale one-time alarm (spec §15 item 3, now
 * closed). Recurring alarms carry `repeat_days` — including fortnightly alarms —
 * and are never swept. Every alarm is handled independently: one bad row must
 * not stall the sweep.
 */
export function sweepMissedAlarms(now: Date = new Date()): number {
  let candidates: AlarmRecord[];
  try {
    candidates = db.prepare(`
      SELECT * FROM alarms
      WHERE status IN ('pending', 'snoozed')
        AND (repeat_days IS NULL OR TRIM(repeat_days) = '')
    `).all() as AlarmRecord[];
  } catch (err) {
    console.error('[sweep] failed to read pending alarms:', err);
    return 0;
  }

  const nowMs = now.getTime();
  const nowIso = now.toISOString();
  let marked = 0;

  for (const alarm of candidates) {
    try {
      const targetMs = new Date(alarm.target_time).getTime();
      if (isNaN(targetMs)) continue;
      if (targetMs + MISSED_GRACE_MS >= nowMs) continue;

      const reason = deriveMissedReason(alarm);

      // Record every unconfirmed pass. A row whose reason is silence
      // (`dispatched_not_reported` / `unknown`) is still recorded, because the
      // alternative is claiming a dismissal nobody made: that is how a failed
      // 06:30 alarm became invisible. Delivery health deliberately ignores those
      // reasons, so the record exists without crying wolf (alerts.ts).
      if (!AlarmRepo.markMissed(alarm.id, reason, nowIso)) continue;
      marked++;

      // Keep the calendar entry, annotated rather than deleted (spec §9).
      // mirrorSafely never throws and is a no-op under test.
      void mirrorSafely({
        ...alarm,
        status: 'missed',
        missed_at: nowIso,
        missed_reason: reason,
      });
    } catch (err) {
      console.error(`[sweep] failed to mark alarm ${alarm.id} missed:`, err);
    }
  }

  return marked;
}

/**
 * How long a `ringing` alarm may stay unacknowledged before the abandoned-ring
 * sweep resolves it.
 *
 * This is NOT a ring timeout. An alarm rings until it is dismissed, so there is
 * no legitimate upper bound on a *ring* — the bound is on how long "still
 * ringing" stays credible. The window is chosen to be clearly "nobody is coming
 * back" rather than "still ringing":
 *
 * - far beyond the alarm's own cadence — a snooze is ~9 minutes and the longest
 *   volume ramp is 60 seconds;
 * - far beyond any plausible deliberate ring — a person dismisses a blaring
 *   alarm within minutes, and two hours of continuous ringing is not a state
 *   anyone intentionally holds;
 * - short enough that the 17-hour ghost that motivated this cannot recur.
 *
 * `target_time` is the reference, not a new column: it is already authoritative
 * for the moment an alarm next rings (spec §6.3), so for a `ringing` alarm it is
 * the moment the ring began. A late `ringing` report cannot make a fresh ring
 * look old, because the phone only rings at `target_time`.
 */
export const RINGING_ABANDON_MS = 2 * 60 * 60 * 1_000;

/**
 * Resolve a `ringing` alarm that has rung unacknowledged past
 * `RINGING_ABANDON_MS` (spec §6.1's sweep, extended to the abandoned ring).
 *
 * The transition is `dismissed`, deliberately NOT `missed`. The live failure
 * this closes was a *lost dismissal report*: the alarm rang, the owner dismissed
 * it, and the report never reached the backend, so the row sat `ringing` for
 * ~17 hours and produced a permanent ghost banner. `dismissed` is exactly the
 * state that lost report would have set, so the sweep *repairs the missing
 * report* instead of reclassifying the alarm. `missed` would be wrong on two
 * counts: it means "it did not fire" (spec §5) and this alarm did fire, and the
 * owner already reported that a dismissed alarm reading as missed is confusing.
 * Reusing `dismissed` also keeps the reason set closed — no new `missed_reason`
 * and no new status is introduced, so every existing reader (dashboard, clients,
 * calendar mapping) already handles the result.
 *
 * A resolved alarm is logged with its full unacknowledged duration so the lost
 * report remains visible in the audit trail even though the row no longer
 * carries a failure reason.
 *
 * One-time and recurring alarms are both swept: the phone reports `dismissed`
 * for either, so the repaired state is the same for both. The sweep never sends
 * FCM — it exists precisely because the phone is not answering, and a normal
 * dismissal is silent on the backend too.
 *
 * Independent of `sweepMissedAlarms`: that sweep reads only `pending`/`snoozed`,
 * so the two cannot contend for the same row.
 */
export function sweepAbandonedRingingAlarms(now: Date = new Date()): number {
  let candidates: AlarmRecord[];
  try {
    candidates = db.prepare(`
      SELECT * FROM alarms
      WHERE status = 'ringing'
    `).all() as AlarmRecord[];
  } catch (err) {
    console.error('[sweep] failed to read ringing alarms:', err);
    return 0;
  }

  const nowMs = now.getTime();
  let resolved = 0;

  for (const alarm of candidates) {
    try {
      const ringingSinceMs = new Date(alarm.target_time).getTime();
      if (isNaN(ringingSinceMs)) continue;
      if (ringingSinceMs + RINGING_ABANDON_MS >= nowMs) continue;

      if (!AlarmRepo.markDismissed(alarm.id)) continue;
      resolved++;

      const ringingForMinutes = Math.round((nowMs - ringingSinceMs) / 60_000);
      console.error(
        `[sweep] alarm ${alarm.id} rang unacknowledged for ${ringingForMinutes} min ` +
        `(> ${RINGING_ABANDON_MS / 60_000} min): resolving as dismissed`
      );

      // A dismissal leaves the past calendar entry in place (spec §9). Never
      // throws; a no-op under test.
      void mirrorSafely({ ...alarm, status: 'dismissed' });
    } catch (err) {
      console.error(`[sweep] failed to resolve abandoned ringing alarm ${alarm.id}:`, err);
    }
  }

  return resolved;
}

/**
 * A rejected or expired credential stalls the calendar silently, so it gets a
 * loud, actionable message distinct from a transient Google failure. Both the
 * push path and the reconcile path emit it: a dead token is most likely to be
 * discovered during reconciliation, when nobody is creating alarms.
 */
const GCAL_AUTH_FAILED_MESSAGE =
  '[gcal] AUTH FAILED — Google rejected the stored credential. Calendar sync is paused.\n' +
  '       Re-run `npm run gcal:auth` on a machine with a browser, then copy the token file.';

/** Time-boxed mirror. Never throws: a Google failure must not affect the caller. */
export async function mirrorSafely(alarm: AlarmRecord): Promise<void> {
  if (!gcal.isConfigured()) return;

  // Tests must never write to a real Google account.
  //
  // dotenv loads backend/.env into test processes, so a developer with real
  // credentials in .env resolves a LIVE gcal config. A :memory: database never
  // holds a gcal_calendar_id, so an unguarded push calls calendars.insert and
  // creates a real calendar -- once per test file. That happened: 20 stray
  // "Klaxon" calendars.
  //
  // The reconcile scheduler is guarded the same way, for the same reason.
  // GCAL_ENABLED=false in the test script stops this at the config layer; this
  // guard stops it at the call site, so a test that opts into live config still
  // cannot push.
  if (isTestRun) return;

  try {
    await Promise.race([
      gcal.syncAlarm(alarm),
      new Promise((_resolve, reject) =>
        setTimeout(() => reject(new Error('gcal push timed out')), GCAL_PUSH_TIMEOUT_MS)
      ),
    ]);
  } catch (err) {
    if (classifyGcalError(err) === 'auth') {
      console.error(GCAL_AUTH_FAILED_MESSAGE);
    } else {
      console.error('[gcal] mirror failed:', err instanceof Error ? err.message : err);
    }
  }
}

/**
 * Compute the current delivery health from live state. Used by both the sweep
 * (to log/scream) and `/api/health` (to surface it). Due-aware, not a heartbeat:
 * a quiet interval with no alarms stays healthy (spec §5.4).
 */
export function computeDeliveryHealth(
  now: Date = new Date(),
  firebaseReady: boolean = isFirebaseReady()
): DeliveryHealth {
  return evaluateDeliveryHealth({
    deviceCount: DeviceRepo.getAllDevices().length,
    alarms: AlarmRepo.getAll('all'),
    now,
    firebaseReady
  });
}

// 0. GET /api/health: Healthcheck and connectivity test
app.get('/api/health', async (_request, reply) => {
  return reply.send({
    status: 'ok',
    timestamp: new Date().toISOString(),
    delivery_health: computeDeliveryHealth()
  });
});

// 1. GET /api/alarms: Return alarms filtered by view ('active' | 'history' | 'all')
app.get<{
  Querystring: { view?: 'active' | 'history' | 'all' }
}>('/api/alarms', async (request, reply) => {
  const view = request.query?.view || 'active';
  const alarms = AlarmRepo.getAll(view);
  return reply.send(alarms);
});

// 1b. GET /api/calendar.ics: Export active alarms as standard RFC 5545 iCalendar feed
app.get('/api/calendar.ics', async (_request, reply) => {
  const alarms = AlarmRepo.getAll('active');

  const pad = (n: number) => n.toString().padStart(2, '0');
  const formatIcalDate = (date: Date): string => {
    return (
      date.getUTCFullYear() +
      pad(date.getUTCMonth() + 1) +
      pad(date.getUTCDate()) +
      'T' +
      pad(date.getUTCHours()) +
      pad(date.getUTCMinutes()) +
      pad(date.getUTCSeconds()) +
      'Z'
    );
  };

  const dayMap: Record<string, string> = {
    '1': 'MO',
    '2': 'TU',
    '3': 'WE',
    '4': 'TH',
    '5': 'FR',
    '6': 'SA',
    '7': 'SU'
  };

  const nowStamp = formatIcalDate(new Date());

  let icsLines: string[] = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Klaxon//Klaxon//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'X-WR-CALNAME:Klaxon',
    'X-WR-TIMEZONE:UTC'
  ];

  for (const alarm of alarms) {
    const startDate = new Date(alarm.target_time);
    if (isNaN(startDate.getTime())) continue;

    // Alarm duration shown in calendar as 15 minutes
    const endDate = new Date(startDate.getTime() + 15 * 60 * 1000);

    icsLines.push('BEGIN:VEVENT');
    icsLines.push(`UID:${alarm.id}@remotealarm`);
    icsLines.push(`DTSTAMP:${nowStamp}`);
    icsLines.push(`DTSTART:${formatIcalDate(startDate)}`);
    icsLines.push(`DTEND:${formatIcalDate(endDate)}`);
    icsLines.push(`SUMMARY:⏰ ${alarm.label}`);
    icsLines.push(`DESCRIPTION:Alarm ID: ${alarm.id}\\nStatus: ${alarm.status}\\nManaged by Klaxon`);

    if (alarm.repeat_days) {
      const days = alarm.repeat_days
        .split(',')
        .map(d => dayMap[d.trim()])
        .filter(Boolean);
      if (days.length > 0) {
        icsLines.push(`RRULE:FREQ=WEEKLY;BYDAY=${days.join(',')}`);
      }
    }

    icsLines.push('END:VEVENT');
  }

  icsLines.push('END:VCALENDAR');

  const icsBody = icsLines.join('\r\n') + '\r\n';

  return reply
    .header('Content-Type', 'text/calendar; charset=utf-8')
    .header('Content-Disposition', 'inline; filename="alarms.ics"')
    .header('Cache-Control', 'no-cache, no-store, must-revalidate')
    .send(icsBody);
});

// 2. POST /api/alarms: Create new alarm and broadcast FCM CREATE
app.post<{
  Body: {
    target_time: string;
    label: string;
    description?: string;
    repeat_days?: string | number[];
    sound_tone?: string;
    ramp_seconds?: number;
    recurrence_interval_weeks?: number;
    recurrence_anchor_date?: string;
  }
}>('/api/alarms', async (request, reply) => {
  const { target_time, label, description, repeat_days, sound_tone, ramp_seconds, recurrence_interval_weeks, recurrence_anchor_date } = request.body || {};

  if (!target_time || !label) {
    return reply.status(400).send({
      error: 'Missing required fields: target_time and label are required.'
    });
  }

  // Validate target_time format
  const dateObj = new Date(target_time);
  if (isNaN(dateObj.getTime())) {
    return reply.status(400).send({
      error: 'Invalid target_time: must be a valid ISO 8601 UTC timestamp.'
    });
  }

  // Align seconds and milliseconds to :00.000 for standard clock alarms
  dateObj.setSeconds(0, 0);

  // Normalize repeat_days to string
  let repeatDaysStr: string | undefined;
  if (Array.isArray(repeat_days)) {
    repeatDaysStr = repeat_days.join(',');
  } else if (typeof repeat_days === 'string' && repeat_days.trim().length > 0) {
    repeatDaysStr = repeat_days.trim();
  }

  // Roll a stale target forward so a raw/strange request cannot create an
  // instantly-missed alarm. Recurring past targets always advance; one-time
  // past targets within the 5-minute grace window are left alone (a one-time
  // alarm may still ring up to 5 min late).
  const nowMs = Date.now();
  const isRecurring = !!repeatDaysStr && repeatDaysStr.trim().length > 0;
  const targetIsPast = dateObj.getTime() < nowMs;
  const beyondGrace = dateObj.getTime() + MISSED_GRACE_MS < nowMs;
  const effectiveTargetIso =
    (isRecurring && targetIsPast) || (!isRecurring && beyondGrace)
      ? rollTargetTimeToFuture(dateObj.toISOString(), repeatDaysStr)
      : dateObj.toISOString();

  if (ramp_seconds !== undefined && (typeof ramp_seconds !== 'number' || ramp_seconds < 0 || !Number.isInteger(ramp_seconds))) {
    return reply.status(400).send({
      error: 'Invalid ramp_seconds: must be a non-negative integer.'
    });
  }

  // Validate recurrence_interval_weeks: 1 (weekly, default) or 2 (fortnightly)
  let normalizedInterval = 1;
  if (recurrence_interval_weeks !== undefined) {
    if (!Number.isInteger(recurrence_interval_weeks) || recurrence_interval_weeks < 1 || recurrence_interval_weeks > 2) {
      return reply.status(400).send({
        error: 'Invalid recurrence_interval_weeks: must be an integer 1 (weekly) or 2 (fortnightly).'
      });
    }
    normalizedInterval = recurrence_interval_weeks;
  }

  // Validate recurrence_anchor_date: must be an ISO date "YYYY-MM-DD"
  let normalizedAnchorDate: string | undefined;
  if (recurrence_anchor_date !== undefined) {
    if (
      typeof recurrence_anchor_date !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}$/.test(recurrence_anchor_date) ||
      isNaN(new Date(`${recurrence_anchor_date}T00:00:00Z`).getTime())
    ) {
      return reply.status(400).send({
        error: 'Invalid recurrence_anchor_date: must be in YYYY-MM-DD format.'
      });
    }
    normalizedAnchorDate = recurrence_anchor_date;
  }

  // Auto-anchor: a fortnightly alarm without an anchor defaults to its start date
  if (normalizedInterval === 2 && !normalizedAnchorDate) {
    normalizedAnchorDate = effectiveTargetIso.slice(0, 10);
  }

  // A retry or a double submit must not create a second alarm for the same
  // instant and label. Duplicates are not harmless: the phone keeps one alarm
  // per instant, so the second silently replaces the first, and cancelling it
  // leaves nothing armed. That is how the 2026-10-27 06:30 alarm was lost.
  const duplicate = db.prepare(`
    SELECT * FROM alarms
    WHERE target_time = ?
      AND LOWER(TRIM(label)) = LOWER(TRIM(?))
      AND status IN ('pending', 'snoozed', 'ringing')
    LIMIT 1
  `).get(effectiveTargetIso, label.trim()) as AlarmRecord | undefined;

  if (duplicate) {
    return reply.status(200).send({
      ...duplicate,
      deduplicated: true,
      fcm_dispatch: { sent: 0, failed: 0 }
    });
  }

  const id = uuidv4();
  const normalizedTone = sound_tone && ['alarm', 'chime', 'digital'].includes(sound_tone.trim().toLowerCase())
    ? sound_tone.trim().toLowerCase()
    : 'alarm';
  const normalizedRamp = ramp_seconds !== undefined ? ramp_seconds : 30;

  const newAlarm: AlarmRecord = {
    id,
    target_time: effectiveTargetIso,
    label: label.trim(),
    description: description ? description.trim() : undefined,
    status: 'pending',
    repeat_days: repeatDaysStr,
    sound_tone: normalizedTone,
    ramp_seconds: normalizedRamp,
    recurrence_interval_weeks: normalizedInterval,
    recurrence_anchor_date: normalizedAnchorDate
  };

  AlarmRepo.create(newAlarm);

  // Send FCM Data Message
  const fcmPayload: FcmPayload = {
    id: newAlarm.id,
    target_time: newAlarm.target_time,
    label: newAlarm.label,
    sound_tone: normalizedTone,
    ramp_seconds: normalizedRamp,
    recurrence_interval_weeks: normalizedInterval,
    recurrence_anchor_date: normalizedAnchorDate
  };
  if (newAlarm.description) {
    fcmPayload.description = newAlarm.description;
  }
  if (repeatDaysStr) {
    fcmPayload.repeat_days = repeatDaysStr;
  }

  const dispatchResult = await sendFcmDataMessage('CREATE', fcmPayload);
  AlarmRepo.recordDispatch(newAlarm.id, dispatchResult.sent, dispatchResult.failed);

  await mirrorSafely(newAlarm);

  return reply.status(201).send({
    ...newAlarm,
    fcm_dispatch: dispatchResult
  });
});

// 3. DELETE /api/alarms/:id: Cancel alarm and broadcast FCM CANCEL
app.delete<{
  Params: { id: string }
}>('/api/alarms/:id', async (request, reply) => {
  const { id } = request.params;
  const existing = AlarmRepo.getById(id);

  if (!existing) {
    return reply.status(404).send({ error: 'Alarm not found' });
  }

  // Tell the phone first. Marking the row cancelled before the dispatch means a
  // CANCEL that never reaches the phone leaves it ringing with no live row and
  // a healthy system, which is the same silent failure the missed work exists
  // to stop. If nothing was reached, keep the alarm as it was and say so.
  const dispatchResult = await sendFcmDataMessage('CANCEL', { id });
  AlarmRepo.recordDispatch(id, dispatchResult.sent, dispatchResult.failed);

  // sent === 0 with failed === 0 means no device is registered: there is no
  // phone to ring, so cancelling is still correct. A real failure is failed > 0.
  if (dispatchResult.sent === 0 && dispatchResult.failed > 0) {
    return reply.status(502).send({
      error: 'The phone was not reached, so the alarm was not cancelled. Try again.',
      fcm_dispatch: dispatchResult
    });
  }

  AlarmRepo.cancel(id);

  await mirrorSafely({ ...existing, status: 'canceled' });

  return reply.send({
    success: true,
    id,
    status: 'canceled',
    fcm_dispatch: dispatchResult
  });
});

// 3b. POST /api/alarms/:id/silence: Remotely silence a ringing alarm and broadcast FCM DISMISS
app.post<{
  Params: { id: string }
}>('/api/alarms/:id/silence', async (request, reply) => {
  const { id } = request.params;
  const existing = AlarmRepo.getById(id);

  if (!existing) {
    return reply.status(404).send({ error: 'Alarm not found' });
  }

  // Dispatch first. A DISMISS that never reaches the phone must not mark the
  // row resolved: the phone keeps ringing while every surface says it stopped.
  const dispatchResult = await sendFcmDataMessage('DISMISS', { id });
  AlarmRepo.recordDispatch(id, dispatchResult.sent, dispatchResult.failed);

  if (dispatchResult.sent === 0 && dispatchResult.failed > 0) {
    return reply.status(502).send({
      error: 'The phone was not reached, so the alarm is still ringing.',
      fcm_dispatch: dispatchResult
    });
  }

  AlarmRepo.updateStatus(id, 'dismissed');

  await mirrorSafely({ ...existing, status: 'dismissed' });

  return reply.send({
    success: true,
    id,
    status: 'dismissed',
    fcm_dispatch: dispatchResult
  });
});

// 3c. PATCH /api/alarms/:id: Update alarm fields and broadcast FCM CREATE
app.patch<{
  Params: { id: string };
  Body: {
    target_time?: string;
    label?: string;
    description?: string;
    repeat_days?: string | number[];
    sound_tone?: string;
    ramp_seconds?: number;
    status?: 'pending' | 'ringing' | 'dismissed' | 'snoozed' | 'canceled' | 'disabled';
    recurrence_interval_weeks?: number;
    recurrence_anchor_date?: string;
  };
}>('/api/alarms/:id', async (request, reply) => {
  const { id } = request.params;
  const existing = AlarmRepo.getById(id);

  if (!existing) {
    return reply.status(404).send({ error: 'Alarm not found' });
  }

  const { target_time, label, description, repeat_days, sound_tone, ramp_seconds, status, recurrence_interval_weeks, recurrence_anchor_date } = request.body || {};

  const updates: Partial<AlarmRecord> = {};

  if (target_time !== undefined) {
    const dateObj = new Date(target_time);
    if (isNaN(dateObj.getTime())) {
      return reply.status(400).send({ error: 'Invalid target_time: must be a valid ISO 8601 UTC timestamp.' });
    }
    dateObj.setSeconds(0, 0);
    updates.target_time = dateObj.toISOString();
  }

  if (label !== undefined) {
    if (!label.trim()) {
      return reply.status(400).send({ error: 'Label cannot be empty.' });
    }
    updates.label = label.trim();
  }

  if (description !== undefined) {
    updates.description = description.trim();
  }

  if (repeat_days !== undefined) {
    if (Array.isArray(repeat_days)) {
      updates.repeat_days = repeat_days.join(',');
    } else if (typeof repeat_days === 'string') {
      updates.repeat_days = repeat_days.trim();
    }
  }

  if (sound_tone !== undefined) {
    const normTone = sound_tone.trim().toLowerCase();
    if (['alarm', 'chime', 'digital'].includes(normTone)) {
      updates.sound_tone = normTone;
    }
  }

  if (ramp_seconds !== undefined) {
    if (typeof ramp_seconds !== 'number' || ramp_seconds < 0 || !Number.isInteger(ramp_seconds)) {
      return reply.status(400).send({ error: 'Invalid ramp_seconds: must be a non-negative integer.' });
    }
    updates.ramp_seconds = ramp_seconds;
  }

  if (status !== undefined) {
    // This was written unchecked, so a raw HTTP client could set "missed" --
    // which is system-set only (spec §5) -- or any arbitrary string, and
    // corrupt the row. Validate against the set the declared type promises.
    // `missed` is deliberately absent: only the sweep and the device report
    // may set it.
      const patchableStatuses: readonly string[] = [
        'pending',
        'ringing',
        'dismissed',
        'canceled',
        'disabled'
      ];
      // A snooze is a timed transition, not a field edit: it carries a next-ring
      // time about nine minutes out. Letting PATCH set the status alone would
      // leave the old target_time in place, and the sweep would then read a
      // healthy snooze as a failure (spec §6.3). Send the caller to the endpoint
      // that sets both, rather than accepting a row the sweep will misread.
      if (status === 'snoozed') {
        return reply.status(400).send({
          error: 'Cannot set "snoozed" here: a snooze carries a next-ring time. Use POST /api/alarms/:id/state.'
        });
      }
      if (!patchableStatuses.includes(status)) {
      return reply.status(400).send({
        error: `Invalid status. Must be one of: ${patchableStatuses.join(', ')}.`
      });
    }
    updates.status = status;
  }

  if (recurrence_interval_weeks !== undefined) {
    if (!Number.isInteger(recurrence_interval_weeks) || recurrence_interval_weeks < 1 || recurrence_interval_weeks > 2) {
      return reply.status(400).send({
        error: 'Invalid recurrence_interval_weeks: must be an integer 1 (weekly) or 2 (fortnightly).'
      });
    }
    updates.recurrence_interval_weeks = recurrence_interval_weeks;
  }

  if (recurrence_anchor_date !== undefined) {
    if (
      typeof recurrence_anchor_date !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}$/.test(recurrence_anchor_date) ||
      isNaN(new Date(`${recurrence_anchor_date}T00:00:00Z`).getTime())
    ) {
      return reply.status(400).send({
        error: 'Invalid recurrence_anchor_date: must be in YYYY-MM-DD format.'
      });
    }
    updates.recurrence_anchor_date = recurrence_anchor_date;
  }

  // Auto-anchor: a fortnightly alarm without an anchor defaults to its start date
  const effectiveInterval = updates.recurrence_interval_weeks ?? existing.recurrence_interval_weeks ?? 1;
  if (effectiveInterval === 2 && updates.recurrence_anchor_date === undefined && !existing.recurrence_anchor_date) {
    const effectiveTarget = updates.target_time ?? existing.target_time;
    if (effectiveTarget) {
      updates.recurrence_anchor_date = effectiveTarget.slice(0, 10);
    }
  }

  AlarmRepo.update(id, updates);
  const updated = AlarmRepo.getById(id)!;

  // Broadcast FCM update
  const fcmPayload: FcmPayload = {
    id: updated.id,
    target_time: updated.target_time,
    label: updated.label,
    sound_tone: updated.sound_tone || 'alarm',
    ramp_seconds: updated.ramp_seconds ?? 30,
    recurrence_interval_weeks: updated.recurrence_interval_weeks ?? 1,
    recurrence_anchor_date: updated.recurrence_anchor_date
  };
  if (updated.description) fcmPayload.description = updated.description;
  if (updated.repeat_days) fcmPayload.repeat_days = updated.repeat_days;

  const dispatchResult = await sendFcmDataMessage('CREATE', fcmPayload);
  AlarmRepo.recordDispatch(updated.id, dispatchResult.sent, dispatchResult.failed);

  await mirrorSafely(updated);

  return reply.send({
    ...updated,
    fcm_dispatch: dispatchResult
  });
});

export function rollTargetTimeToFuture(targetTimeStr: string, repeatDaysStr?: string | null, mockNow?: Date): string {
  const now = mockNow || new Date();
  const currentTarget = new Date(targetTimeStr);
  if (isNaN(currentTarget.getTime())) {
    return targetTimeStr;
  }

  // If already in the future, return as-is
  if (currentTarget.getTime() > now.getTime()) {
    return currentTarget.toISOString();
  }

  // If recurring with repeat days (1=Mon ... 7=Sun)
  if (repeatDaysStr && repeatDaysStr.trim().length > 0) {
    const days = repeatDaysStr.split(',').map(s => parseInt(s.trim(), 10)).filter(d => d >= 1 && d <= 7);
    if (days.length > 0) {
      for (let dayOffset = 0; dayOffset <= 7; dayOffset++) {
        const candidate = new Date(now.getTime());
        candidate.setUTCDate(candidate.getUTCDate() + dayOffset);
        candidate.setUTCHours(
          currentTarget.getUTCHours(),
          currentTarget.getUTCMinutes(),
          0,
          0
        );
        if (candidate.getTime() <= now.getTime()) {
          continue;
        }
        const jsDay = candidate.getUTCDay();
        const isoDay = jsDay === 0 ? 7 : jsDay;
        if (days.includes(isoDay)) {
          return candidate.toISOString();
        }
      }
    }
  }

  // One-time alarm: roll to today at same time, or tomorrow if time passed today
  const candidate = new Date(now.getTime());
  candidate.setUTCHours(
    currentTarget.getUTCHours(),
    currentTarget.getUTCMinutes(),
    0,
    0
  );
  if (candidate.getTime() <= now.getTime()) {
    candidate.setUTCDate(candidate.getUTCDate() + 1);
  }
  return candidate.toISOString();
}

// 4. POST /api/alarms/:id/state: Update status ('ringing' | 'dismissed' | 'snoozed' | 'pending' | 'disabled')
app.post<{
  Params: { id: string };
  Body: {
    status: 'ringing' | 'dismissed' | 'snoozed' | 'pending' | 'disabled';
    target_time?: string;
  }
}>('/api/alarms/:id/state', async (request, reply) => {
  const { id } = request.params;
  const { status, target_time } = request.body || {};

  const validStatuses = ['ringing', 'dismissed', 'snoozed', 'pending', 'disabled'];
  if (!status || !validStatuses.includes(status)) {
    return reply.status(400).send({
      error: `Invalid status. Must be one of: ${validStatuses.join(', ')}.`
    });
  }

  const existing = AlarmRepo.getById(id);
  if (!existing) {
    return reply.status(404).send({ error: 'Alarm not found' });
  }

  AlarmRepo.updateStatus(id, status);

  let effectiveTargetTime = existing.target_time;
  let fcmResult;

  if (status === 'disabled') {
    fcmResult = await sendFcmDataMessage('DISABLE', { id });
  } else if (status === 'pending') {
    if (target_time && !isNaN(Date.parse(target_time))) {
      effectiveTargetTime = new Date(target_time).toISOString();
    } else {
      effectiveTargetTime = rollTargetTimeToFuture(existing.target_time, existing.repeat_days);
    }

    if (effectiveTargetTime !== existing.target_time) {
      AlarmRepo.updateTargetTime(id, effectiveTargetTime);
    }

    const fcmPayload: FcmPayload = {
      id: existing.id,
      target_time: effectiveTargetTime,
      label: existing.label,
      sound_tone: existing.sound_tone || 'alarm',
      ramp_seconds: existing.ramp_seconds ?? 30
    };
    if (existing.description) {
      fcmPayload.description = existing.description;
    }
    if (existing.repeat_days) {
      fcmPayload.repeat_days = existing.repeat_days;
    }
    fcmResult = await sendFcmDataMessage('CREATE', fcmPayload);
  } else if (status === 'snoozed') {
    // A snooze's next-ring time is stored in the existing `target_time` column,
    // with no new column (spec §15 item 3, now closed). No FCM is sent: there is
    // no SNOOZE action, and the phone has already armed the snooze locally. No
    // dispatch happened, so last_dispatch_* is deliberately left untouched.
    if (target_time && !isNaN(Date.parse(target_time))) {
      effectiveTargetTime = new Date(target_time).toISOString();
    } else {
      // The fallback mirrors the phone's own snooze computation (now floored to
      // the minute, plus 9 minutes, UTC) so an older app that sends no
      // target_time cannot produce a stale time the sweep would misread.
      effectiveTargetTime = new Date(
        Math.floor(Date.now() / 60000) * 60000 + 9 * 60000
      ).toISOString();
    }
    AlarmRepo.updateTargetTime(id, effectiveTargetTime);
  }

  if (fcmResult) {
    AlarmRepo.recordDispatch(id, fcmResult.sent, fcmResult.failed);
  }

    // Mirror the row as it now stands, not as it was read: a `pending` alarm may
    // have been rolled forward and a `snoozed` one has a new next-ring time, and
    // the calendar event must sit at the time the alarm will actually ring.
    await mirrorSafely({ ...existing, status, target_time: effectiveTargetTime });

    return reply.send({
      success: true,
      id,
      status,
      target_time: effectiveTargetTime,
      fcm_dispatch: fcmResult
    });
});

// 4b. POST /api/alarms/report-missed: batched device report on reconnect (§6.2).
// Named with a `report-` prefix so the path can never be read as an `:id`.
app.post<{
  Body: { ids?: unknown; reason?: string };
}>('/api/alarms/report-missed', async (request, reply) => {
  const { ids, reason } = request.body || {};

  if (!Array.isArray(ids)) {
    return reply.status(400).send({ error: 'ids must be an array of alarm ids.' });
  }

  if (!reason || !DEVICE_MISSED_REASONS.includes(reason as MissedReason)) {
    return reply.status(400).send({
      error: `Invalid reason. Must be one of: ${DEVICE_MISSED_REASONS.join(', ')}.`
    });
  }

  const deviceReason = reason as MissedReason;
  const now = new Date().toISOString();
  let updated = 0;

  // A device report must never 500: unknown ids are skipped, malformed
  // entries are ignored, and each row is updated independently.
  for (const id of ids) {
    if (typeof id !== 'string' || id.length === 0) continue;
    try {
      const alarm = AlarmRepo.getById(id);
      if (!alarm) continue;
      if (!AlarmRepo.markMissed(id, deviceReason, now)) continue;
      updated++;
      void mirrorSafely({
        ...alarm,
        status: 'missed',
        missed_at: now,
        missed_reason: deviceReason,
      });
    } catch (err) {
      console.error(`[report-missed] failed to update alarm ${id}:`, err);
    }
  }

  return reply.send({ updated });
});

// 5. POST /api/devices/register: Upsert device token with battery and status metadata
app.post<{
  Body: {
    token: string;
    battery_level?: number | null;
    is_charging?: boolean | number | null;
    device_name?: string | null;
  }
}>('/api/devices/register', async (request, reply) => {
  const { token, battery_level, is_charging, device_name } = request.body || {};

  if (!token || typeof token !== 'string') {
    return reply.status(400).send({
      error: 'Missing or invalid device token'
    });
  }

  DeviceRepo.upsert(token.trim(), {
    battery_level,
    is_charging,
    device_name
  });

  return reply.send({
    success: true,
    message: 'Device registered successfully'
  });
});

// 6. GET /api/devices: List count, devices with battery telemetry, and masked tokens
app.get('/api/devices', async (_request, reply) => {
  const devices = DeviceRepo.getAllDevices();
  return reply.send({
    count: devices.length,
    tokens: devices.map(d => `${d.token.slice(0, 10)}...${d.token.slice(-6)}`),
    devices: devices.map(d => ({
      token_masked: `${d.token.slice(0, 10)}...${d.token.slice(-6)}`,
      device_name: d.device_name || 'Android Phone',
      battery_level: d.battery_level,
      is_charging: d.is_charging === 1 || d.is_charging === true,
      updated_at: d.updated_at
    }))
  });
});

// 7. GET /api/settings: Return persisted application settings
app.get('/api/settings', async (_request, reply) => {
  const settings = SettingsRepo.getAll();
  return reply.send(settings);
});

// 8. POST /api/settings: Update application settings
app.post<{
  Body: Partial<AppSettings>;
}>('/api/settings', async (request, reply) => {
  const { sound_tone, ramp_seconds, date_format, time_format } = request.body || {};

  const updates: Partial<AppSettings> = {};

  if (sound_tone !== undefined) {
    const validTones = ['alarm', 'chime', 'digital'];
    if (!validTones.includes(sound_tone)) {
      return reply.status(400).send({
        error: `Invalid sound_tone. Must be one of: ${validTones.join(', ')}.`
      });
    }
    updates.sound_tone = sound_tone;
  }

  if (ramp_seconds !== undefined) {
    const validRamps = [0, 15, 30, 60];
    if (typeof ramp_seconds !== 'number' || !validRamps.includes(ramp_seconds)) {
      return reply.status(400).send({
        error: `Invalid ramp_seconds. Must be one of: ${validRamps.join(', ')}.`
      });
    }
    updates.ramp_seconds = ramp_seconds;
  }

  if (date_format !== undefined) {
    const validDates = ['dd/mm/yyyy', 'mm/dd/yyyy', 'yyyy-mm-dd'];
    if (!validDates.includes(date_format)) {
      return reply.status(400).send({
        error: `Invalid date_format. Must be one of: ${validDates.join(', ')}.`
      });
    }
    updates.date_format = date_format;
  }

  if (time_format !== undefined) {
    const validTimes = ['24h', '12h'];
    if (!validTimes.includes(time_format)) {
      return reply.status(400).send({
        error: `Invalid time_format. Must be one of: ${validTimes.join(', ')}.`
      });
    }
    updates.time_format = time_format;
  }

  const updated = SettingsRepo.update(updates);
  return reply.send({
    success: true,
    settings: updated
  });
});

// 9. GET /api/calendar/status: visibility into the Google Calendar mirror.
// Reports configuration and sync health only; never credentials (spec §10).
app.get('/api/calendar/status', async (_request, reply) => {
  return reply.send(gcal.status());
});

export { app };

if (!isTestRun) {
  const PORT = parseInt(process.env.PORT || '3000', 10);
  const HOST = process.env.HOST || '0.0.0.0';

  try {
    await app.listen({ port: PORT, host: HOST });
    console.log(`\n[Server] Klaxon Backend running at http://${HOST}:${PORT}`);
    console.log(`[Server] Dashboard available at http://localhost:${PORT}\n`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }

  // Periodic drift repair (spec §9.4). This MUST stay inside the
  // NODE_ENV !== 'test' guard: it opens a timer and, once configured, makes
  // outbound Google calls. Under test the guard keeps the suite fast, silent
  // and offline.
  if (gcal.isConfigured()) {
    const runReconcile = () => {
      reconcile(gcal)
        .then((result) => {
          if (result.created || result.deleted || result.failed) {
            console.log('[gcal] reconcile:', result);
          }
          // reconcile() catches its own errors, so a credential failure here
          // never reaches mirrorSafely's handler. Without this check a dead
          // token would surface only as an unexplained `failed: 1` each
          // interval — which is the state nobody is watching for.
          if (result.failed > 0 && gcal.status().needs_reauth) {
            console.error(GCAL_AUTH_FAILED_MESSAGE);
          }
        })
        .catch((err) => console.error('[gcal] reconcile failed:', err));
    };
    runReconcile();
    setInterval(runReconcile, GCAL_RECONCILE_INTERVAL_MS);
  }

  // Missed-alarm sweep (spec §6.1). Guarded by the same NODE_ENV !== 'test'
  // block as the reconcile timer: it touches the database and, once configured,
  // mirrors the missed alarm to Google. Keeping it hermetic is mandatory — an
  // unguarded timer here is how the suite would reach outside itself.
  setInterval(() => {
    try {
      sweepMissedAlarms();
      // Resolve a `ringing` alarm that was never acknowledged, so a lost
      // dismissal report cannot leave a permanent ghost "ringing" banner.
      sweepAbandonedRingingAlarms();
      // Delivery-health monitor (spec §5.4): a dead token, a failed dispatch, or
      // an alarm now missed must surface instead of going quiet.
      const health = computeDeliveryHealth();
      const webhookUrl = process.env.ALERT_WEBHOOK_URL ?? '';
      const webhookKind = (process.env.ALERT_WEBHOOK_KIND as WebhookKind) ?? 'generic';

      // Healthchecks is a dead-man's switch: it alerts when pings STOP. So ping
      // on EVERY sweep, healthy or not, independent of the 30-minute throttle —
      // and use /fail when unhealthy so a broken backend still raises the alert.
      // Pinging only when unhealthy would reset Healthchecks' timer precisely
      // when the backend is broken, suppressing the very alert it exists to
      // raise (spec §5.4).
      if (webhookKind === 'healthchecks' && webhookUrl) {
        void sendWebhookAlert(healthchecksUrl(webhookUrl, health.ok), 'healthchecks', {
          title: 'Klaxon healthcheck',
          body: health.ok ? 'ok' : health.reasons.join(', ')
        });
      }

      if (!health.ok) {
        console.error('[alerts] delivery unhealthy:', health.reasons);
        const decision = shouldSendAlert(health.reasons[0], new Date(), lastAlertAt);
        if (decision.send) {
          lastAlertAt = decision.sentAt;
          // Message kinds (generic/discord/slack) get the throttled on-unhealthy
          // POST; Healthchecks already got its liveness ping above.
          if (webhookKind !== 'healthchecks') {
            void sendWebhookAlert(webhookUrl, webhookKind, {
              title: 'Klaxon delivery unhealthy',
              body: health.reasons.join(', ')
            });
          }
          // Best-effort phone push, alongside the webhook. It cannot reach a
          // force-stopped phone, which is why the dashboard and webhook exist.
          void sendFcmNotification('Klaxon delivery unhealthy', health.reasons.join(', '));
        }
      }
    } catch (err) {
      // sweepMissedAlarms catches per-alarm errors; this is the last line of
      // defence so a failure can never kill the timer.
      console.error('[sweep] failed:', err);
    }
  }, MISSED_SWEEP_INTERVAL_MS);
  missedSweepStarted = true;
}
