/**
 * Shared display formatters.
 *
 * `toLocalDate` is the ONE place that converts the server's UTC `target_time`
 * into a local wall-clock `Date`. Callers must never hand-roll a conversion.
 */

import type { Alarm, AlarmStatus, MissedReason } from "./types.js";

const WEEKDAYS_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS_SHORT = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];

/**
 * Derive the local wall-clock instant for an alarm.
 *
 * `new Date(isoString)` yields a Date whose *local* getters reflect the host
 * timezone — that is the entire conversion. There is exactly one of these.
 */
export function toLocalDate(alarm: Alarm): Date {
  return new Date(alarm.target_time);
}

/**
 * Human-readable status label — the one place a status becomes display text,
 * so every surface renders a new status the same way.
 *
 * `missed` means the alarm's time passed and it never rang, so it will not
 * ring. Never describe it as delivered, skipped, failed to deliver, or
 * disabled — nothing was delivered.
 *
 * The `Record` is exhaustive on purpose: adding a status to `AlarmStatus`
 * without a label here is a compile error, not a silent raw token.
 */
const STATUS_LABELS: Record<AlarmStatus, string> = {
  // Lower case deliberately. The CLI printed statuses in lower case before
  // `missed` existed, and it reads better inline ("status pending · tone
  // alarm"). Adding a status must not restyle the ones already there.
  pending: "pending",
  ringing: "ringing",
  dismissed: "dismissed",
  snoozed: "snoozed",
  canceled: "canceled",
  disabled: "disabled",
  missed: "missed",
};

export function formatStatus(status: AlarmStatus): string {
  return STATUS_LABELS[status];
}

/**
 * Readable, delivery-neutral rendering of `missed_reason` (spec §7).
 *
 * `dispatched_not_reported` means the system sent the alarm and the phone never
 * reported what happened — never that the phone received it. Mock mode reports
 * `sent > 0` while delivering nothing, so the wording must not overclaim.
 *
 * The lookup falls back on purpose: a value from a newer backend renders as
 * `unrecognised reason (<token>)` rather than crashing or showing `undefined`.
 */
const MISSED_REASON_LABELS: Record<MissedReason, string> = {
  no_device_registered: "no device was registered to receive it",
  delivery_failed: "the system could not deliver it",
  dispatched_not_reported:
    "the system sent it, but the phone never reported what happened",
  device_reported_stale: "the phone found it already past and did not arm it",
  device_reported_failed: "the phone tried but could not fire it",
  unknown: "no reason was recorded",
};

export function formatMissedReason(reason: string): string {
  return MISSED_REASON_LABELS[reason as MissedReason] ?? `unrecognised reason (${reason})`;
}

/** 12-hour clock, lower-case meridiem: `7:00am`, `12:00am`, `7:05pm`. */
export function formatClock(date: Date): string {
  const hours = date.getHours();
  const minutes = date.getMinutes();
  const suffix = hours < 12 ? "am" : "pm";
  const hour12 = hours % 12 === 0 ? 12 : hours % 12;
  return `${hour12}:${String(minutes).padStart(2, "0")}${suffix}`;
}

/** `Tue 22 Sep` (local). */
export function formatDate(date: Date): string {
  return `${WEEKDAYS_SHORT[date.getDay()]} ${date.getDate()} ${MONTHS_SHORT[date.getMonth()]}`;
}

/** `Tue 22 Sep, 7:00am` (local). */
export function formatLocal(date: Date): string {
  return `${formatDate(date)}, ${formatClock(date)}`;
}

/**
 * Coarse relative offset between two instants, compact style: `in 13h 40m`,
 * `in 25m`, `in 2d 3h`, `in 1mo`, `3h 5m ago`.
 *
 * The tier rule (and its expected strings) is pinned in
 * `fixtures/relative-time-cases.json`, which this function must match exactly:
 * under a minute renders `less than a minute`; otherwise the largest three
 * components are shown, zero-valued ones omitted. Months are a fixed 30 days
 * and years a fixed 365 days, so 359 days is `11mo 29d`.
 */
const MINUTE_SECONDS = 60;
const HOUR_SECONDS = 60 * MINUTE_SECONDS;
const DAY_SECONDS = 24 * HOUR_SECONDS;
const MONTH_SECONDS = 30 * DAY_SECONDS;
const YEAR_SECONDS = 365 * DAY_SECONDS;

type RelativeUnit = "min" | "hour" | "day" | "month" | "year";

const COMPACT_SUFFIX: Record<RelativeUnit, string> = {
  min: "m",
  hour: "h",
  day: "d",
  month: "mo",
  year: "y",
};

/**
 * Break a positive span into its tier's components, dropping zero-valued ones.
 * `totalSeconds` below one minute yields no components; the caller renders the
 * shared `less than a minute` phrase for that.
 */
function relativeComponents(totalSeconds: number): Array<{ value: number; unit: RelativeUnit }> {
  const parts: Array<{ value: number; unit: RelativeUnit }> = [];

  if (totalSeconds < MINUTE_SECONDS) {
    return parts;
  } else if (totalSeconds < HOUR_SECONDS) {
    parts.push({ value: Math.floor(totalSeconds / MINUTE_SECONDS), unit: "min" });
  } else if (totalSeconds < DAY_SECONDS) {
    parts.push({ value: Math.floor(totalSeconds / HOUR_SECONDS), unit: "hour" });
    parts.push({
      value: Math.floor((totalSeconds % HOUR_SECONDS) / MINUTE_SECONDS),
      unit: "min",
    });
  } else if (totalSeconds < MONTH_SECONDS) {
    parts.push({ value: Math.floor(totalSeconds / DAY_SECONDS), unit: "day" });
    parts.push({
      value: Math.floor((totalSeconds % DAY_SECONDS) / HOUR_SECONDS),
      unit: "hour",
    });
    parts.push({
      value: Math.floor((totalSeconds % HOUR_SECONDS) / MINUTE_SECONDS),
      unit: "min",
    });
  } else if (totalSeconds < YEAR_SECONDS) {
    parts.push({ value: Math.floor(totalSeconds / MONTH_SECONDS), unit: "month" });
    parts.push({
      value: Math.floor((totalSeconds % MONTH_SECONDS) / DAY_SECONDS),
      unit: "day",
    });
    parts.push({
      value: Math.floor((totalSeconds % DAY_SECONDS) / HOUR_SECONDS),
      unit: "hour",
    });
  } else {
    parts.push({ value: Math.floor(totalSeconds / YEAR_SECONDS), unit: "year" });
    parts.push({
      value: Math.floor((totalSeconds % YEAR_SECONDS) / MONTH_SECONDS),
      unit: "month",
    });
    parts.push({
      value: Math.floor(((totalSeconds % YEAR_SECONDS) % MONTH_SECONDS) / DAY_SECONDS),
      unit: "day",
    });
  }

  return parts.filter((part) => part.value > 0);
}

/** Compact body without the caller's direction: `13h 40m`, `1mo`, `less than a minute`. */
function formatRelativeBody(totalSeconds: number): string {
  if (totalSeconds < MINUTE_SECONDS) {
    return "less than a minute";
  }
  return relativeComponents(totalSeconds)
    .map((part) => `${part.value}${COMPACT_SUFFIX[part.unit]}`)
    .join(" ");
}

export function formatRelative(from: Date, to: Date): string {
  const diffMs = to.getTime() - from.getTime();
  const future = diffMs >= 0;
  const totalSeconds = Math.floor(Math.abs(diffMs) / 1000);
  const body = formatRelativeBody(totalSeconds);

  return future ? `in ${body}` : `${body} ago`;
}

/** `Tue 22 Sep, 7:00am (in 13h 40m)` — the absolute-local echo required by spec §6.5. */
export function formatInterpretation(date: Date, now: Date): string {
  return `${formatLocal(date)} (${formatRelative(now, date)})`;
}

/** Local wall-clock rendering of an alarm's UTC `target_time`. */
export function formatAlarm(alarm: Alarm): string {
  return formatLocal(toLocalDate(alarm));
}
