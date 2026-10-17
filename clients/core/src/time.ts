/**
 * Natural-language time parser.
 *
 * Contract (spec §6):
 *   parseTime(input, now?) -> { targetTime, repeatDays, interpretation }
 *   throws TimeParseError on invalid input.
 *
 * Grammar is matched as the LONGEST LEADING PREFIX of a single expression
 * (never a concatenation). `parseLeadingTime` exposes that prefix split for the
 * CLI's time/label split, falling back to a span anywhere in the input when no
 * prefix parses (so label-first phrasing works); `parseTime` requires the whole
 * input to be consumed.
 *
 * The parser produces a LOCAL WALL-CLOCK `Date`. Conversion to UTC happens only
 * at the client boundary via `.toISOString()`.
 */

import { TimeParseError } from "./errors.js";
import { formatInterpretation } from "./format.js";
import type { SoundTone, Weekday } from "./types.js";

/**
 * Inline alarm metadata carried by the time expression itself (spec §9), e.g.
 * `chime 30s ramp tomorrow 7am note: gym`. Every field is optional and absent
 * means "unspecified" — never a default.
 */
export type AlarmMetadata = {
  sound_tone?: SoundTone;
  ramp_seconds?: number;
  description?: string;
};

/** A recurrence interval, e.g. `every 2 weeks` -> `{ count: 2, unit: "weeks" }`. */
export interface IntervalSpec {
  count: number;
  unit: "days" | "weeks";
}

export interface ParsedTime {
  /** Local wall-clock instant. */
  targetTime: Date;
  /** Empty = one-time. */
  repeatDays: Weekday[];
  /** Human-readable echo, e.g. "Tue 22 Sep, 7:00am (in 13h 40m)". */
  interpretation: string;
  /** Inline metadata; absent when the input named none. */
  alarm?: AlarmMetadata;
  /** Recurrence interval; absent for a one-time or plain-weekday expression. */
  interval?: IntervalSpec;
}

const ALL_DAYS: Weekday[] = [1, 2, 3, 4, 5, 6, 7];
const WEEKDAYS: Weekday[] = [1, 2, 3, 4, 5];
const WEEKENDS: Weekday[] = [6, 7];

const WEEKDAY_NAMES: Record<string, Weekday> = {
  mon: 1,
  monday: 1,
  tue: 2,
  tues: 2,
  tuesday: 2,
  wed: 3,
  weds: 3,
  wednesday: 3,
  thu: 4,
  thur: 4,
  thurs: 4,
  thursday: 4,
  fri: 5,
  friday: 5,
  sat: 6,
  saturday: 6,
  sun: 7,
  sunday: 7,
};

const CONNECTORS = new Set(["at", "in"]);

/** Month name (short and full) -> 1-based calendar month (spec §6.4). */
const MONTH_NAMES: Record<string, number> = {
  jan: 1,
  january: 1,
  feb: 2,
  february: 2,
  mar: 3,
  march: 3,
  apr: 4,
  april: 4,
  may: 5,
  jun: 6,
  june: 6,
  jul: 7,
  july: 7,
  aug: 8,
  august: 8,
  sep: 9,
  september: 9,
  oct: 10,
  october: 10,
  nov: 11,
  november: 11,
  dec: 12,
  december: 12,
};

/**
 * Day-period word -> its fixed clock anchor (spec §6.2). A period is a clock:
 * it resolves to this time and, like any passed clock, rolls forward a day.
 */
const DAY_PERIODS: Record<string, { hours: number; minutes: number }> = {
  morning: { hours: 9, minutes: 0 },
  afternoon: { hours: 15, minutes: 0 },
  evening: { hours: 19, minutes: 0 },
  tonight: { hours: 21, minutes: 0 },
  noon: { hours: 12, minutes: 0 },
  midnight: { hours: 0, minutes: 0 },
};

/** A calendar day with an optional explicit year (spec §6.4). */
interface AbsoluteDate {
  month: number;
  day: number;
  year?: number;
}

type DayQualifier =
  | { kind: "today" }
  | { kind: "tomorrow" }
  | { kind: "weekday"; weekday: Weekday }
  | { kind: "this-weekday"; weekday: Weekday; token: string }
  | { kind: "next-weekday"; weekday: Weekday }
  | { kind: "this-weekend" }
  | { kind: "next-week" }
  | { kind: "next-month" };

interface Clock {
  hours: number;
  minutes: number;
  /** Index into the token array just past the clock. */
  next: number;
  /** True only for the bare-integer form (`7`, no meridiem, no colon). */
  bare: boolean;
}

interface Duration {
  ms: number;
}

/** ISO weekday: 1 = Monday … 7 = Sunday. */
function isoWeekday(date: Date): Weekday {
  const day = date.getDay();
  return (day === 0 ? 7 : day) as Weekday;
}

function dedupe(days: Weekday[]): Weekday[] {
  const seen = new Set<Weekday>();
  const out: Weekday[] = [];
  for (const day of days) {
    if (!seen.has(day)) {
      seen.add(day);
      out.push(day);
    }
  }
  return out;
}

function expandRange(start: Weekday, end: Weekday): Weekday[] {
  const out: Weekday[] = [];
  let current = start;
  // Inclusive, wrapping forward (e.g. fri-mon -> 5,6,7,1).
  for (let guard = 0; guard < 7; guard++) {
    out.push(current);
    if (current === end) break;
    current = (current === 7 ? 1 : current + 1) as Weekday;
  }
  return out;
}

/**
 * Read a weekday list/range beginning at `i`. Handles `mon-fri`,
 * `mon,wed,fri`, and comma-separated multi-token forms (`mon, wed, fri`).
 * A lone weekday name is intentionally read as a single entry; callers decide
 * whether that means a recurring set or a one-off day qualifier.
 */
function readWeekdayGroup(
  toks: string[],
  i: number
): { days: Weekday[]; next: number } | null {
  const days: Weekday[] = [];
  let j = i;

  while (j < toks.length) {
    const raw = toks[j];
    const token = raw.replace(/,+$/, "");
    if (token.length === 0) break;

    if (token.includes("-")) {
      const [a, b] = token.split("-");
      const start = WEEKDAY_NAMES[a];
      const end = WEEKDAY_NAMES[b];
      if (!start || !end) return null;
      days.push(...expandRange(start, end));
      j++;
      if (raw.endsWith(",")) continue;
      break;
    }

    if (token.includes(",")) {
      const parts = token.split(",").filter((p) => p.length > 0);
      const mapped = parts.map((p) => WEEKDAY_NAMES[p]);
      if (mapped.length === 0 || mapped.some((d) => d === undefined)) return null;
      days.push(...(mapped as Weekday[]));
      j++;
      if (raw.endsWith(",")) continue;
      break;
    }

    const weekday = WEEKDAY_NAMES[token];
    if (!weekday) break;
    days.push(weekday);
    j++;
    if (raw.endsWith(",")) continue;
    break;
  }

  if (days.length === 0) return null;
  return { days, next: j };
}

function matchRecurrencePrefix(
  toks: string[],
  i: number
): { repeatDays: Weekday[]; next: number } | null {
  const first = toks[i];
  if (first === "daily") return { repeatDays: ALL_DAYS, next: i + 1 };
  if (first === "weekdays") return { repeatDays: WEEKDAYS, next: i + 1 };
  if (first === "weekends") return { repeatDays: WEEKENDS, next: i + 1 };

  if (first === "every") {
    const after = toks[i + 1];
    if (after === "day") return { repeatDays: ALL_DAYS, next: i + 2 };
    const group = readWeekdayGroup(toks, i + 1);
    if (group) return { repeatDays: dedupe(group.days), next: group.next };
    return null;
  }

  if (first && (first.includes("-") || first.includes(","))) {
    const group = readWeekdayGroup(toks, i);
    if (group) return { repeatDays: dedupe(group.days), next: group.next };
  }

  return null;
}

function matchDayQualifier(toks: string[], i: number): { qualifier: DayQualifier; next: number } | null {
  const first = toks[i];
  if (first === "tomorrow" || first === "tmr") {
    return { qualifier: { kind: "tomorrow" }, next: i + 1 };
  }
  if (first === "today") {
    return { qualifier: { kind: "today" }, next: i + 1 };
  }
  const weekday = WEEKDAY_NAMES[first];
  if (weekday) {
    return { qualifier: { kind: "weekday", weekday }, next: i + 1 };
  }
  return null;
}

/**
 * Read a `this` / `next` qualifier beginning at `i` (spec §6.3): `this
 * <weekday>`, `next <weekday>`, `this weekend`, `next week`, `next month`.
 * `last` is deliberately **not** a token (owner decision 3): `last friday` is
 * just the forward-only weekday `friday` with `last` left in the label.
 *
 * `this-weekday` records the matched phrase in `token` so a passed resolution
 * can name it in the `already_passed` refusal.
 */
function matchNextThis(
  toks: string[],
  i: number
): { qualifier: DayQualifier; next: number } | null {
  const first = toks[i];
  if (first === "this") {
    const second = toks[i + 1];
    const weekday = WEEKDAY_NAMES[second];
    if (weekday) {
      return {
        qualifier: { kind: "this-weekday", weekday, token: `${first} ${second}` },
        next: i + 2,
      };
    }
    if (second === "weekend") {
      return { qualifier: { kind: "this-weekend" }, next: i + 2 };
    }
    return null;
  }
  if (first === "next") {
    const second = toks[i + 1];
    const weekday = WEEKDAY_NAMES[second];
    if (weekday) {
      return { qualifier: { kind: "next-weekday", weekday }, next: i + 2 };
    }
    if (second === "week") {
      return { qualifier: { kind: "next-week" }, next: i + 2 };
    }
    if (second === "month") {
      return { qualifier: { kind: "next-month" }, next: i + 2 };
    }
    return null;
  }
  return null;
}

function makeClock(
  hour: number,
  minute: number,
  meridiem: string | undefined,
  next: number,
  bare: boolean
): Clock | null {
  if (!Number.isInteger(minute) || minute < 0 || minute > 59) return null;
  if (meridiem) {
    // A meridiem implies a 1–12 hour; `13pm` / `0am` are invalid.
    if (hour < 1 || hour > 12) return null;
    let hours = hour % 12;
    if (meridiem === "pm") hours += 12;
    return { hours, minutes: minute, next, bare };
  }
  // Bare / colon times without a meridiem are read as 24-hour.
  if (hour < 0 || hour > 23) return null;
  return { hours: hour, minutes: minute, next, bare };
}

/** Parse a clock token (possibly spread over two tokens, e.g. `7 am`). */
function parseClock(toks: string[], i: number): Clock | null {
  const first = toks[i];
  if (first === undefined) return null;

  // 7am / 12pm / 13pm (invalid)
  let match = /^(\d{1,2})(am|pm)$/.exec(first);
  if (match) {
    return makeClock(parseInt(match[1], 10), 0, match[2], i + 1, false);
  }

  // 7:30am / 07:00 / 19:00 / 7:30
  match = /^(\d{1,2}):(\d{2})(am|pm)?$/.exec(first);
  if (match) {
    let meridiem = match[3];
    let next = i + 1;
    if (!meridiem && next < toks.length && (toks[next] === "am" || toks[next] === "pm")) {
      meridiem = toks[next];
      next++;
    }
    return makeClock(parseInt(match[1], 10), parseInt(match[2], 10), meridiem, next, false);
  }

  // Bare hour: `7` -> 07:00, `19` -> 19:00, optionally followed by am/pm.
  match = /^(\d{1,2})$/.exec(first);
  if (match) {
    if (i + 1 < toks.length && (toks[i + 1] === "am" || toks[i + 1] === "pm")) {
      return makeClock(parseInt(match[1], 10), 0, toks[i + 1], i + 2, false);
    }
    return makeClock(parseInt(match[1], 10), 0, undefined, i + 1, true);
  }

  return null;
}

/**
 * Read a day period beginning at `i` (spec §6.2), optionally prefixed `this`
 * (`this morning`). Returns it as a `Clock` — never `bare`, so it is never
 * mistaken for the bare-integer trap — or `null` when no period is present.
 */
function parseDayPeriod(toks: string[], i: number): Clock | null {
  let j = i;
  if (toks[j] === "this") j++;
  const period = DAY_PERIODS[toks[j]];
  if (!period) return null;
  return { hours: period.hours, minutes: period.minutes, next: j + 1, bare: false };
}

/** Parse one or more duration components consuming the rest of the tokens. */
function parseDuration(toks: string[], i: number): Duration | null {
  const joined = toks.slice(i).join("");
  const match =
    /^(?:(\d+)(?:h|hr|hrs|hour|hours))?(?:(\d+)(?:m|min|mins|minute|minutes))?(?:(\d+)(?:s|sec|secs|second|seconds))?$/.exec(
      joined
    );
  if (!match) return null;
  const [, h, m, s] = match;
  if (h === undefined && m === undefined && s === undefined) return null;
  const hours = h ? parseInt(h, 10) : 0;
  const minutes = m ? parseInt(m, 10) : 0;
  const seconds = s ? parseInt(s, 10) : 0;
  return { ms: ((hours * 60 + minutes) * 60 + seconds) * 1000 };
}

/**
 * Read a whole-day offset beginning at `i`: `<n> days|day`, `<n> weeks|week`,
 * `<n>d`, `<n>w`, concatenated (`1w 2d`, `1w2d`), optionally led by the `in`
 * connector and optionally followed by `from now`. Returns the total whole days
 * (`weeks*7 + days`) and the index just past the offset, or `null`.
 *
 * Day/week units are deliberately kept out of `parseDuration`: an offset lands
 * on a wall-clock day, not a fixed millisecond span (spec §6.6), so the caller
 * resolves it with `setDate(getDate() + days)` rather than ms arithmetic.
 */
function parseDayWeekOffset(
  toks: string[],
  i: number
): { days: number; next: number } | null {
  let j = i;
  if (toks[j] === "in") j++;
  const joined = toks.slice(j).join("");
  const match = /^(?:(\d+)(?:w|week|weeks))?(?:(\d+)(?:d|day|days))?(?:fromnow)?$/.exec(joined);
  if (!match) return null;
  const [, w, d] = match;
  if (w === undefined && d === undefined) return null;
  const weeks = w ? parseInt(w, 10) : 0;
  const days = d ? parseInt(d, 10) : 0;
  return { days: weeks * 7 + days, next: toks.length };
}

/**
 * Read a day-of-month, tolerating an English ordinal suffix (`4th` -> `4`).
 * Returns `null` for anything that is not a 1–31 number.
 */
function parseDayNumber(token: string): number | null {
  const stripped = token.replace(/(st|nd|rd|th)$/, "");
  if (!/^\d{1,2}$/.test(stripped)) return null;
  const day = parseInt(stripped, 10);
  if (day < 1 || day > 31) return null;
  return day;
}

/**
 * Read a `<d>/<m>` numeric date (spec §6.5). The reading is day/month when
 * unambiguous: a first field over 12 must be the day, a second field over 12
 * makes the first the month. When both fields are ≤ 12 the default is
 * **day/month** (`03/04` = 3 Apr).
 */
function parseNumericDate(token: string): { month: number; day: number } | null {
  const match = /^(\d{1,2})\/(\d{1,2})$/.exec(token);
  if (!match) return null;
  const a = parseInt(match[1], 10);
  const b = parseInt(match[2], 10);
  if (a < 1 || a > 31 || b < 1 || b > 31) return null;

  let month: number;
  let day: number;
  if (a > 12) {
    day = a;
    month = b;
  } else if (b > 12) {
    month = a;
    day = b;
  } else {
    day = a;
    month = b;
  }
  if (month < 1 || month > 12) return null;
  return { month, day };
}

/**
 * Read an absolute date beginning at `i` (spec §6.4): `<month> <day>` (`dec 25`,
 * `december 25`), `<day> <month>` (`25 dec`, `25th december`), `<month>
 * <ordinal>` (`jan 4th`), `<d>/<m>` numeric (`25/12`), or ISO (`2026-12-31`).
 * Returns the date and the index just past it, or `null`.
 */
function parseAbsoluteDate(
  toks: string[],
  i: number
): { date: AbsoluteDate; next: number } | null {
  const first = toks[i];
  if (first === undefined) return null;

  // ISO `YYYY-MM-DD`.
  const iso = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(first);
  if (iso) {
    const year = parseInt(iso[1], 10);
    const month = parseInt(iso[2], 10);
    const day = parseInt(iso[3], 10);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return { date: { month, day, year }, next: i + 1 };
  }

  // `<d>/<m>` numeric.
  const numeric = parseNumericDate(first);
  if (numeric) {
    return { date: { month: numeric.month, day: numeric.day }, next: i + 1 };
  }

  const second = toks[i + 1];
  const firstMonth = MONTH_NAMES[first];
  if (firstMonth !== undefined) {
    // `<month> <day>` / `<month> <ordinal>`.
    if (second === undefined) return null;
    const day = parseDayNumber(second);
    if (day === null) return null;
    return { date: { month: firstMonth, day }, next: i + 2 };
  }

  // `<day> <month>` / `<ordinal> <month>`.
  const day = parseDayNumber(first);
  const secondMonth = second !== undefined ? MONTH_NAMES[second] : undefined;
  if (day !== null && secondMonth !== undefined) {
    return { date: { month: secondMonth, day }, next: i + 2 };
  }

  return null;
}

/**
 * Resolve a calendar date at `hours:minutes` to a local wall-clock instant
 * (spec §6.4). An explicit year is honoured verbatim, including a **past** year
 * (the §9 futurity check is a later concern). With no year the next occurrence
 * is used: a resolved instant at or before `now` rolls to the next year.
 */
function resolveAbsoluteDate(
  now: Date,
  date: AbsoluteDate,
  hours: number,
  minutes: number
): Date {
  const candidate = new Date(now.getTime());
  candidate.setHours(hours, minutes, 0, 0);
  if (date.year !== undefined) {
    candidate.setFullYear(date.year, date.month - 1, date.day);
    return candidate;
  }
  candidate.setMonth(date.month - 1, date.day);
  if (candidate.getTime() <= now.getTime()) {
    candidate.setFullYear(candidate.getFullYear() + 1);
  }
  return candidate;
}

interface BuildContext {
  now: Date;
}

function buildAbsolute(
  ctx: BuildContext,
  hours: number,
  minutes: number,
  targetDays: Weekday[]
): Date {
  // Today counts if the time has not passed; otherwise the next matching day.
  for (let offset = 0; offset <= 7; offset++) {
    const candidate = new Date(ctx.now.getTime());
    candidate.setDate(candidate.getDate() + offset);
    candidate.setHours(hours, minutes, 0, 0);
    if (candidate.getTime() <= ctx.now.getTime()) continue;
    if (targetDays.includes(isoWeekday(candidate))) return candidate;
  }
  // Unreachable for a non-empty targetDays set, but keep a total function.
  const fallback = new Date(ctx.now.getTime());
  fallback.setDate(fallback.getDate() + 7);
  fallback.setHours(hours, minutes, 0, 0);
  return fallback;
}

function buildClockTime(
  ctx: BuildContext,
  qualifier: DayQualifier | null,
  repeatDays: Weekday[],
  hours: number,
  minutes: number
): Date {
  if (qualifier?.kind === "tomorrow") {
    const candidate = new Date(ctx.now.getTime());
    candidate.setDate(candidate.getDate() + 1);
    candidate.setHours(hours, minutes, 0, 0);
    return candidate;
  }
  if (qualifier?.kind === "today") {
    const candidate = new Date(ctx.now.getTime());
    candidate.setHours(hours, minutes, 0, 0);
    // A passed "today" rolls forward rather than scheduling in the past.
    if (candidate.getTime() <= ctx.now.getTime()) {
      candidate.setDate(candidate.getDate() + 1);
    }
    return candidate;
  }
  if (qualifier?.kind === "weekday") {
    return buildAbsolute(ctx, hours, minutes, [qualifier.weekday]);
  }
  if (qualifier?.kind === "this-weekday") {
    // That weekday in the current Monday-start ISO week. A resolved instant at
    // or before `now` (equality included) is a hard refusal — never rolled
    // forward (spec §6.3/§10).
    const candidate = new Date(ctx.now.getTime());
    candidate.setDate(candidate.getDate() - (isoWeekday(candidate) - 1) + (qualifier.weekday - 1));
    candidate.setHours(hours, minutes, 0, 0);
    if (candidate.getTime() <= ctx.now.getTime()) {
      throw new TimeParseError(
        `"${qualifier.token}" has already passed.`,
        qualifier.token,
        "already_passed"
      );
    }
    return candidate;
  }
  if (qualifier?.kind === "next-weekday") {
    // That weekday in the next ISO week — always ahead of `now`.
    const candidate = new Date(ctx.now.getTime());
    candidate.setDate(
      candidate.getDate() - (isoWeekday(candidate) - 1) + 7 + (qualifier.weekday - 1)
    );
    candidate.setHours(hours, minutes, 0, 0);
    return candidate;
  }
  if (qualifier?.kind === "this-weekend") {
    // The coming Saturday: the nearest Saturday on or after today (today counts
    // when it is itself Saturday), so it anchors deterministically.
    const candidate = new Date(ctx.now.getTime());
    const delta = (6 - isoWeekday(candidate) + 7) % 7;
    candidate.setDate(candidate.getDate() + delta);
    candidate.setHours(hours, minutes, 0, 0);
    return candidate;
  }
  if (qualifier?.kind === "next-week") {
    // Same wall-clock time, one week ahead.
    const candidate = new Date(ctx.now.getTime());
    candidate.setDate(candidate.getDate() + 7);
    return candidate;
  }
  if (qualifier?.kind === "next-month") {
    // Same wall-clock time, one calendar month ahead. Clamp a month-end overflow
    // (e.g. 31 Jan -> 3 Mar) back to the last day of the intended month.
    const candidate = new Date(ctx.now.getTime());
    const targetDay = candidate.getDate();
    candidate.setMonth(candidate.getMonth() + 1);
    if (candidate.getDate() !== targetDay) {
      candidate.setDate(0);
    }
    return candidate;
  }
  if (repeatDays.length > 0) {
    return buildAbsolute(ctx, hours, minutes, repeatDays);
  }
  return buildAbsolute(ctx, hours, minutes, ALL_DAYS);
}

function finalize(
  targetTime: Date,
  repeatDays: Weekday[],
  now: Date
): ParsedTime {
  return {
    targetTime,
    repeatDays,
    interpretation: formatInterpretation(targetTime, now),
  };
}

/**
 * Try to parse a sequence of tokens as exactly one complete time expression.
 * Returns `null` if the tokens are not a single valid expression.
 *
 * `allowBareIntegerClock` is true only when `toks` is the entire input: a
 * bare-integer clock (`7`) is otherwise a trap, silently swallowing a number
 * that belongs to the label (spec §5.4/§11 #6).
 */
function tryParseExpression(
  toks: string[],
  now: Date,
  allowBareIntegerClock: boolean
): ParsedTime | null {
  const ctx: BuildContext = { now };
  let i = 0;

  const skipConnectors = () => {
    while (i < toks.length && CONNECTORS.has(toks[i])) i++;
  };

  skipConnectors();
  if (i >= toks.length) return null;

  let repeatDays: Weekday[] = [];
  let qualifier: DayQualifier | null = null;

  const recurrence = matchRecurrencePrefix(toks, i);
  if (recurrence) {
    repeatDays = recurrence.repeatDays;
    i = recurrence.next;
  } else {
    const nextThis = matchNextThis(toks, i);
    if (nextThis) {
      qualifier = nextThis.qualifier;
      i = nextThis.next;
    } else {
      const day = matchDayQualifier(toks, i);
      if (day) {
        qualifier = day.qualifier;
        i = day.next;
      }
    }
  }

  skipConnectors();

  if (i >= toks.length) {
    // No clock: a bare day qualifier means midnight; recurrence needs a time.
    if (repeatDays.length > 0) return null;
    if (qualifier) {
      return finalize(buildClockTime(ctx, qualifier, [], 0, 0), [], ctx.now);
    }
    return null;
  }

  // Absolute-date anchor (spec §6.4), standalone or joined to a clock in
  // either order (spec §5.4). A lone date resolves to 00:00 on that day.
  if (!qualifier && repeatDays.length === 0) {
    // Date → clock/period: `dec 25 7am`, `2026-12-31 9am`, `dec 25 noon`.
    const date = parseAbsoluteDate(toks, i);
    if (date) {
      let j = date.next;
      while (j < toks.length && CONNECTORS.has(toks[j])) j++;
      if (j === toks.length) {
        return finalize(resolveAbsoluteDate(ctx.now, date.date, 0, 0), [], ctx.now);
      }
      const clock = parseClock(toks, j) ?? parseDayPeriod(toks, j);
      if (clock && clock.next === toks.length && (!clock.bare || allowBareIntegerClock)) {
        return finalize(
          resolveAbsoluteDate(ctx.now, date.date, clock.hours, clock.minutes),
          [],
          ctx.now
        );
      }
    }

    // Clock → date: `5pm 10/31`.
    const clock = parseClock(toks, i);
    if (clock) {
      let j = clock.next;
      while (j < toks.length && CONNECTORS.has(toks[j])) j++;
      if (j < toks.length) {
        const trailingDate = parseAbsoluteDate(toks, j);
        if (trailingDate && trailingDate.next === toks.length) {
          return finalize(
            resolveAbsoluteDate(ctx.now, trailingDate.date, clock.hours, clock.minutes),
            [],
            ctx.now
          );
        }
      }
    }
  }

  // Duration form: only ever standalone (no day/recurrence qualifier).
  if (!qualifier && repeatDays.length === 0) {
    const duration = parseDuration(toks, i);
    if (duration) {
      const targetTime = new Date(ctx.now.getTime() + duration.ms);
      return finalize(targetTime, [], ctx.now);
    }

    // Day/week offset form: also standalone, and resolved on the wall clock.
    const offset = parseDayWeekOffset(toks, i);
    if (offset) {
      const targetTime = new Date(ctx.now.getTime());
      targetTime.setDate(targetTime.getDate() + offset.days);
      return finalize(targetTime, [], ctx.now);
    }
  }

  const clock = parseClock(toks, i);
  if (clock && clock.next === toks.length && (!clock.bare || allowBareIntegerClock)) {
    const targetTime = buildClockTime(ctx, qualifier, repeatDays, clock.hours, clock.minutes);
    return finalize(targetTime, repeatDays, ctx.now);
  }

  // Day period as a clock (spec §6.2): `afternoon`, `this morning`,
  // `tomorrow noon`. Never `bare`, so it always passes the trap guard above.
  const period = parseDayPeriod(toks, i);
  if (period && period.next === toks.length) {
    const targetTime = buildClockTime(ctx, qualifier, repeatDays, period.hours, period.minutes);
    return finalize(targetTime, repeatDays, ctx.now);
  }

  return null;
}

/**
 * Parse a complete time expression. Throws `TimeParseError` if the whole input
 * is not one valid expression.
 */
export function parseTime(input: string, now?: Date): ParsedTime {
  const nowDate = now ?? new Date();
  const raw = input.trim().split(/\s+/).filter(Boolean);
  if (raw.length === 0) {
    throw new TimeParseError("Empty time expression.", "");
  }

  const toks = raw.map((t) => t.toLowerCase());
  const parsed = tryParseExpression(toks, nowDate, true);
  if (parsed) return parsed;

  // Name the offending (first unconsumed) token when a valid prefix exists.
  for (let end = toks.length - 1; end >= 1; end--) {
    if (tryParseExpression(toks.slice(0, end), nowDate, false)) {
      throw new TimeParseError(
        `Could not parse time expression: "${raw[end]}".`,
        raw[end]
      );
    }
  }

  throw new TimeParseError(
    `Could not parse time expression: "${raw[0]}".`,
    raw[0]
  );
}

/**
 * When no leading prefix parses, locate a complete time expression *inside* the
 * input and treat the surrounding tokens as the label. A trailing span is
 * preferred (the natural "label first" phrasing, e.g. `gym tomorrow 7am`),
 * falling back to the longest span anywhere. Returns `null` when nothing parses.
 */
function findTimeSpan(
  raw: string[],
  toks: string[],
  now: Date
): { parsed: ParsedTime; rest: string } | null {
  // Prefer the longest trailing span: label first, time last. Iterating `start`
  // upward returns the smallest start (i.e. the longest suffix) that parses.
  for (let start = 0; start < toks.length; start++) {
    const parsed = tryParseExpression(toks.slice(start), now, false);
    if (parsed) {
      return { parsed, rest: raw.slice(0, start).join(" ") };
    }
  }
  // Otherwise the longest span anywhere; the surrounding tokens form the label.
  for (let len = toks.length; len >= 1; len--) {
    for (let start = 0; start + len <= toks.length; start++) {
      const parsed = tryParseExpression(toks.slice(start, start + len), now, false);
      if (parsed) {
        const label = raw.slice(0, start).concat(raw.slice(start + len));
        return { parsed, rest: label.join(" ") };
      }
    }
  }
  return null;
}

/**
 * Longest leading prefix that parses as a single time expression, plus the
 * unconsumed remainder. When no prefix parses, falls back to the longest
 * parseable span anywhere in the input (trailing spans preferred) so label-first
 * phrasing like `uni meeting tomorrow at 8pm` still splits into a time and a
 * label. Returns `null` only when no span parses at all.
 */
export function parseLeadingTime(
  input: string,
  now?: Date
): { parsed: ParsedTime; rest: string } | null {
  const nowDate = now ?? new Date();
  const raw = input.trim().split(/\s+/).filter(Boolean);
  if (raw.length === 0) return null;

  const toks = raw.map((t) => t.toLowerCase());
  for (let end = toks.length; end >= 1; end--) {
    // Only the whole input may carry a bare-integer clock; shorter prefixes
    // are slices, where a bare integer would swallow part of the label.
    const parsed = tryParseExpression(toks.slice(0, end), nowDate, end === toks.length);
    if (parsed) {
      return { parsed, rest: raw.slice(end).join(" ") };
    }
  }
  // No leading time prefix: fall back to a span anywhere in the input.
  return findTimeSpan(raw, toks, nowDate);
}
