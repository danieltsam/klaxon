/**
 * Occurrence arithmetic for skipping exactly one instance of a recurring alarm.
 *
 * This module deliberately does NOT reuse `rollTargetTimeToFuture`: that helper
 * reads UTC weekdays and ignores the interval and anchor, so for a Brisbane
 * (UTC+10) 9am alarm it compares the wrong weekday and would move a fortnightly
 * alarm onto the wrong week (design §3 constraint 4, §5.5).
 *
 * The pattern is stepped from the row's own `target_time`, which is already a
 * valid occurrence, rather than from `recurrence_anchor_date`: the anchor is
 * written as a UTC date by the backend but a local date by the phone, so it is
 * not a reliable phase source (design §5.5).
 *
 * `utcOffsetMinutes` is minutes east of UTC (Brisbane = +600), matching
 * `-new Date().getTimezoneOffset()` in JS and `timeZoneOffset.inMinutes` in Dart.
 * A fixed offset means no DST handling; that is stated rather than guessed at.
 */

export interface Pattern {
  repeatDays: number[];   // ISO weekdays, 1 (Mon) .. 7 (Sun)
  intervalWeeks: number;  // 1 (weekly) or 2 (fortnightly)
}

/** True when the alarm repeats: weekday pattern, or an interval greater than one with an anchor. */
export function isRecurring(
  repeatDays: number[],
  intervalWeeks: number,
  anchorDate?: string | null
): boolean {
  if (repeatDays.length > 0) return true;
  return intervalWeeks > 1 && !!anchorDate;
}

/**
 * Shift an instant into the caller's local wall clock. The returned Date's UTC
 * components are the local wall-clock components.
 */
function toLocal(instant: Date, utcOffsetMinutes: number): Date {
  return new Date(instant.getTime() + utcOffsetMinutes * 60_000);
}

/** Shift a local wall-clock Date (read via its UTC components) back to an instant. */
function toInstant(local: Date, utcOffsetMinutes: number): Date {
  return new Date(local.getTime() - utcOffsetMinutes * 60_000);
}

/** ISO weekday of a local wall-clock Date: 1 (Mon) .. 7 (Sun). */
function isoWeekday(local: Date): number {
  const day = local.getUTCDay();
  return day === 0 ? 7 : day;
}

/**
 * Step one occurrence forward in the pattern.
 *
 * An interval pattern moves `7 x intervalWeeks` local days. A weekday pattern
 * advances one local day at a time (at most a week) until the local weekday is
 * in `repeatDays`, so Friday on a Mon-Fri alarm lands on Monday, never Saturday.
 */
export function stepOccurrence(
  occurrence: Date,
  pattern: Pattern,
  utcOffsetMinutes: number
): Date {
  const local = toLocal(occurrence, utcOffsetMinutes);

  if (pattern.intervalWeeks > 1 || pattern.repeatDays.length === 0) {
    const weeks = Math.max(1, pattern.intervalWeeks);
    local.setUTCDate(local.getUTCDate() + 7 * weeks);
    return toInstant(local, utcOffsetMinutes);
  }

  for (let i = 0; i < 7; i++) {
    local.setUTCDate(local.getUTCDate() + 1);
    if (pattern.repeatDays.includes(isoWeekday(local))) break;
  }
  return toInstant(local, utcOffsetMinutes);
}

/**
 * The first occurrence strictly after `after`: `occurrence` itself when it is
 * already in the future, otherwise the pattern stepped forward until it is.
 * Capped so a malformed pattern cannot spin forever.
 */
export function firstOccurrenceAfter(
  occurrence: Date,
  pattern: Pattern,
  utcOffsetMinutes: number,
  after: Date
): Date {
  let candidate = occurrence;
  for (let i = 0; i < 400; i++) {
    if (candidate.getTime() > after.getTime()) return candidate;
    const stepped = stepOccurrence(candidate, pattern, utcOffsetMinutes);
    // A step that does not advance would loop forever; bail with the best guess.
    if (stepped.getTime() === candidate.getTime()) return stepped;
    candidate = stepped;
  }
  return candidate;
}
