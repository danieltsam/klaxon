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
 * Coarse relative offset between two instants: `in 13h 40m`, `in 25m`,
 * `in 2d 3h`, `3h 5m ago`.
 */
export function formatRelative(from: Date, to: Date): string {
  const diffMs = to.getTime() - from.getTime();
  const future = diffMs >= 0;
  let totalMinutes = Math.round(Math.abs(diffMs) / 60000);

  const days = Math.floor(totalMinutes / (60 * 24));
  totalMinutes -= days * 60 * 24;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes - hours * 60;

  const parts: string[] = [];
  if (days > 0) parts.push(`${days}d`);
  if (hours > 0) parts.push(`${hours}h`);
  if (minutes > 0 || parts.length === 0) parts.push(`${minutes}m`);

  return future ? `in ${parts.join(" ")}` : `${parts.join(" ")} ago`;
}

/** `Tue 22 Sep, 7:00am (in 13h 40m)` — the absolute-local echo required by spec §6.5. */
export function formatInterpretation(date: Date, now: Date): string {
  return `${formatLocal(date)} (${formatRelative(now, date)})`;
}

/** Local wall-clock rendering of an alarm's UTC `target_time`. */
export function formatAlarm(alarm: Alarm): string {
  return formatLocal(toLocalDate(alarm));
}
