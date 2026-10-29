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

/**
 * `1:45 p.m.` is the same clock as `1:45 pm`, but the periods survive
 * whitespace tokenisation. Strip them for the parse tokens only; the label
 * keeps the original text.
 */
function normalizeToken(token: string): string {
  const lower = token.toLowerCase();
  // `p.m.` and `a.m.` are the only tokens whose periods are decoration. A dot
  // inside `6.45` is a clock separator and must survive.
  return /^[ap]\.?m\.?$/.test(lower) ? lower.replace(/\./g, "") : lower;
}

/** Spoken counts in offsets, e.g. `in two days`. */
const NUMBER_WORDS: Record<string, string> = {
  a: "1",
  an: "1",
  one: "1",
  two: "2",
  three: "3",
  four: "4",
  five: "5",
  six: "6",
  seven: "7",
  eight: "8",
  nine: "9",
  ten: "10",
  eleven: "11",
  twelve: "12",
};

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

const CONNECTORS = new Set(["at", "in", "on"]);

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

/**
 * Ramp keyword phrase -> seconds (spec §8). A bare `<n>s` is deliberately
 * absent: only `<n>s ramp` is a ramp, so `30s` stays a duration.
 */
const RAMP_PHRASES: Record<string, number> = {
  "no ramp": 0,
  "quick ramp": 15,
  "gentle ramp": 30,
  "deep ramp": 60,
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
  | { kind: "in-days"; days: number }
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

/**
 * Read an interval beginning at `i`, i.e. the tokens just after `every` (spec
 * §5.3): `<n> weeks|week` → a week interval; `<n> days|day` → a day interval;
 * `other <weekday>` / `<n>nd <weekday>` → that weekday, every 2 weeks. A number
 * with a unit is an interval and is **never** a clock; a named day is a weekday
 * set. `day` (all days) and a bare `<weekday-group>` are deliberately left to
 * the caller's existing fallback, so only the interval forms are returned here.
 */
function parseInterval(
  toks: string[],
  i: number
): { interval: IntervalSpec; repeatDays: Weekday[]; next: number } | null {
  const countMatch = /^(\d+)$/.exec(toks[i]);
  const unit = toks[i + 1];
  if (countMatch) {
    const count = parseInt(countMatch[1], 10);
    if (unit === "week" || unit === "weeks") {
      return { interval: { count, unit: "weeks" }, repeatDays: [], next: i + 2 };
    }
    if (unit === "day" || unit === "days") {
      return { interval: { count, unit: "days" }, repeatDays: [], next: i + 2 };
    }
  }

  // `every other <weekday>` / `every <n>nd <weekday>`: a weekday set every 2 weeks.
  const weekday = WEEKDAY_NAMES[toks[i + 1]];
  if (weekday && (toks[i] === "other" || /^\d+nd$/.test(toks[i]))) {
    return { interval: { count: 2, unit: "weeks" }, repeatDays: [weekday], next: i + 2 };
  }

  return null;
}

function matchRecurrencePrefix(
  toks: string[],
  i: number
): { repeatDays: Weekday[]; interval?: IntervalSpec; next: number } | null {
  const first = toks[i];
  if (first === "daily") return { repeatDays: ALL_DAYS, next: i + 1 };
  if (first === "weekdays") return { repeatDays: WEEKDAYS, next: i + 1 };
  if (first === "weekends") return { repeatDays: WEEKENDS, next: i + 1 };

  if (first === "every") {
    const interval = parseInterval(toks, i + 1);
    if (interval) return interval;
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

/**
 * True when the token stream contains an `every` that does not begin a
 * recognized recurrence form. `every` is a strong recurrence signal, so an
 * `every <token>` the grammar cannot read must fail loudly rather than fall
 * through to a bare weekday and silently demote the recurrence to a one-time
 * alarm (spec §5.3/§10). The motivating case is `every 3rd monday`:
 * ordinal-of-month is not expressible and an interval of 3 is not storable, so
 * no reading is safe.
 */
function hasOrphanEvery(toks: string[]): boolean {
  for (let i = 0; i < toks.length; i++) {
    if (toks[i] === "every" && !matchRecurrencePrefix(toks, i)) return true;
  }
  return false;
}

function matchDayQualifier(toks: string[], i: number): { qualifier: DayQualifier; next: number } | null {
  const first = toks[i];
  if (first === "tomorrow" || first === "tmr") {
    return { qualifier: { kind: "tomorrow" }, next: i + 1 };
  }
  if (first === "day" && toks[i + 1] === "after" && toks[i + 2] === "tomorrow") {
    return { qualifier: { kind: "in-days", days: 2 }, next: i + 3 };
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

  // 6.45 / 6.45pm / 06.45 (dot separator, the AU way of writing a clock)
  match = /^(\d{1,2})\.(\d{2})(am|pm)?$/.exec(first);
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
  const joined = toks
    .slice(j)
    .map((token) => NUMBER_WORDS[token] ?? token)
    .join("");
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

/** Days in a 1-based month, for a given year (Feb 29 depends on it). */
function daysInMonth(month: number, year: number): number {
  return new Date(year, month, 0).getDate();
}

/**
 * Refuse a calendar date that does not exist. The date builders use
 * `setMonth`, which rolls 31 April into 1 May and Feb 30 into March, so an
 * impossible date used to resolve to a plausible wrong day. Scanning the token
 * stream before the ladder means the refusal cannot be swallowed by a
 * speculative parse that finds some shorter, valid pair.
 */
function assertRealDates(toks: string[], now: Date): void {
  const year = now.getFullYear();
  const check = (day: number, month: number, token?: string): void => {
    if (month < 1 || month > 12) return;
    if (day > daysInMonth(month, year)) {
      throw new TimeParseError(
        `"${token ?? `${day}/${month}`}" is not a real date in ${year}.`,
        token,
        "unparseable"
      );
    }
  };

  for (let i = 0; i < toks.length; i++) {
    const monthAfter = MONTH_NAMES[toks[i]];
    if (monthAfter) {
      const next = toks[i + 1];
      const day = next ? parseDayNumber(next) : null;
      if (day !== null) check(day, monthAfter, `${toks[i]} ${next}`);
    }
    const monthBefore = MONTH_NAMES[toks[i + 1]];
    if (monthBefore) {
      const day = parseDayNumber(toks[i]);
      if (day !== null) check(day, monthBefore, `${toks[i]} ${toks[i + 1]}`);
    }
    const numeric = parseNumericDate(toks[i]);
    if (numeric) check(numeric.day, numeric.month, toks[i]);
  }
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
  if (qualifier?.kind === "in-days") {
    const candidate = new Date(ctx.now.getTime());
    candidate.setDate(candidate.getDate() + qualifier.days);
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
    // `this weekend` is `this saturday` at 00:00: the Saturday of the current
    // Monday-start ISO week. A resolved instant at or before `now` — Saturday
    // after 00:00, or all of Sunday, once that week's Saturday has gone — is a
    // hard `already_passed` refusal, mirroring `this <weekday>` (spec §6.3).
    // Never roll forward: that would silently skip to the next weekend.
    const candidate = new Date(ctx.now.getTime());
    candidate.setDate(candidate.getDate() - (isoWeekday(candidate) - 1) + (6 - 1));
    candidate.setHours(hours, minutes, 0, 0);
    if (candidate.getTime() <= ctx.now.getTime()) {
      throw new TimeParseError(
        `"this weekend" has already passed.`,
        "this weekend",
        "already_passed"
      );
    }
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

/**
 * Anchor a weekday-less interval with no clock (spec §6.6): `now + interval`,
 * preserving the wall-clock time (day/week arithmetic on the calendar, never a
 * fixed millisecond span).
 */
function anchorInterval(ctx: BuildContext, interval: IntervalSpec): Date {
  const target = new Date(ctx.now.getTime());
  target.setDate(target.getDate() + interval.count * (interval.unit === "weeks" ? 7 : 1));
  return target;
}

function finalize(
  targetTime: Date,
  repeatDays: Weekday[],
  now: Date,
  interval?: IntervalSpec
): ParsedTime {
  const parsed: ParsedTime = {
    targetTime,
    repeatDays,
    interpretation: formatInterpretation(targetTime, now),
  };
  if (interval) parsed.interval = interval;
  return parsed;
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
  let interval: IntervalSpec | undefined;

  const recurrence = matchRecurrencePrefix(toks, i);
  if (recurrence) {
    repeatDays = recurrence.repeatDays;
    interval = recurrence.interval;
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
    // No clock: a bare day qualifier means midnight; recurrence needs a time —
    // except an interval, which anchors to now + interval (weekday-less) or to
    // the weekday's next occurrence at midnight (spec §6.6).
    if (interval) {
      if (repeatDays.length > 0) {
        return finalize(
          buildClockTime(ctx, qualifier, repeatDays, 0, 0),
          repeatDays,
          ctx.now,
          interval
        );
      }
      return finalize(anchorInterval(ctx, interval), [], ctx.now, interval);
    }
    if (repeatDays.length > 0) return null;
    if (qualifier) {
      return finalize(buildClockTime(ctx, qualifier, [], 0, 0), [], ctx.now);
    }
    return null;
  }

  // Absolute-date anchor (spec §6.4), standalone or joined to a clock in
  // either order (spec §5.4). A lone date resolves to 00:00 on that day. Not an
  // interval anchor: an interval must not be silently dropped here.
  if (!qualifier && repeatDays.length === 0 && interval === undefined) {
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

    // Clock → date: `5pm 10/31`. The same bare-integer guard as the date → clock
    // branch above: a bare integer is a clock only as the whole expression, so a
    // stray integer before a date stays in the label (spec §5.4/§11 #6).
    const clock = parseClock(toks, i);
    if (clock && (!clock.bare || allowBareIntegerClock)) {
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

    // Clock → day qualifier: `6pm tomorrow`, `1:45 pm today`, `6pm day after
    // tomorrow`. The ladder only tried qualifier → clock, so the trailing word
    // fell into the label and the alarm resolved to today.
    if (clock) {
      let j = clock.next;
      while (j < toks.length && CONNECTORS.has(toks[j])) j++;
      if (j < toks.length) {
        const trailingDay = matchDayQualifier(toks, j);
        if (trailingDay && trailingDay.next === toks.length) {
          return finalize(
            buildClockTime(ctx, trailingDay.qualifier, [], clock.hours, clock.minutes),
            [],
            ctx.now
          );
        }
      }
    }

    // Clock → recurrence: `7am every mon`, `2pm daily`, `7am weekends`. Without
    // this the prefix `7am` parses alone and the recurrence words become the
    // label, silently demoting a weekly alarm to one-time.
    if (clock) {
      let j = clock.next;
      while (j < toks.length && CONNECTORS.has(toks[j])) j++;
      if (j < toks.length) {
        const trailingRepeat = matchRecurrencePrefix(toks, j);
        if (trailingRepeat && trailingRepeat.next === toks.length) {
          return finalize(
            buildClockTime(ctx, null, trailingRepeat.repeatDays, clock.hours, clock.minutes),
            trailingRepeat.repeatDays,
            ctx.now,
            trailingRepeat.interval
          );
        }
      }
    }
  }

  // Duration form: only ever standalone (no day/recurrence qualifier). The
  // `interval === undefined` guard keeps an interval from being hijacked by the
  // day/week offset branch below, which would silently drop it (§5.3/§6.6).
  if (!qualifier && repeatDays.length === 0 && interval === undefined) {
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
    return finalize(targetTime, repeatDays, ctx.now, interval);
  }

  // Day period as a clock (spec §6.2): `afternoon`, `this morning`,
  // `tomorrow noon`. Never `bare`, so it always passes the trap guard above.
  const period = parseDayPeriod(toks, i);
  if (period) {
    let j = period.next;
    while (j < toks.length && CONNECTORS.has(toks[j])) j++;

    if (j === toks.length) {
      const targetTime = buildClockTime(ctx, qualifier, repeatDays, period.hours, period.minutes);
      return finalize(targetTime, repeatDays, ctx.now, interval);
    }

    // `noon tomorrow`, `evening friday`: a period followed by a day qualifier.
    const trailingDay = matchDayQualifier(toks, j);
    if (trailingDay && trailingDay.next === toks.length) {
      return finalize(
        buildClockTime(ctx, trailingDay.qualifier, repeatDays, period.hours, period.minutes),
        repeatDays,
        ctx.now,
        interval
      );
    }

    // `noon every day`.
    const trailingRepeat = matchRecurrencePrefix(toks, j);
    if (trailingRepeat && trailingRepeat.next === toks.length) {
      return finalize(
        buildClockTime(ctx, null, trailingRepeat.repeatDays, period.hours, period.minutes),
        trailingRepeat.repeatDays,
        ctx.now,
        trailingRepeat.interval
      );
    }
  }

  return null;
}

/**
 * Stage 0 metadata pre-pass (spec §5.1/§8). Recognizes metadata keywords as
 * standalone tokens anywhere in the input and removes them from the stream
 * before the time grammar runs, returning the cleaned `raw`/`toks` plus the
 * extracted `alarm` (absent when the input named none).
 *
 * `note:` is special: it consumes everything to the end of the input, verbatim
 * and with original casing, as the description — tokens after it are never
 * parsed as time. A bare `<n>s` is left alone on purpose: only `<n>s ramp` (the
 * number immediately followed by the literal word `ramp`) is a ramp, so `30s`
 * stays a duration (spec §8).
 */
function extractMetadata(
  raw: string[],
  toks: string[]
): { alarm: AlarmMetadata | undefined; raw: string[]; toks: string[] } {
  const alarm: AlarmMetadata = {};
  let found = false;

  // `note:` swallows the rest of the input verbatim (original casing preserved).
  let limit = toks.length;
  const noteIndex = toks.indexOf("note:");
  if (noteIndex !== -1) {
    alarm.description = raw.slice(noteIndex + 1).join(" ");
    found = true;
    limit = noteIndex;
  }

  const keptRaw: string[] = [];
  const keptToks: string[] = [];
  for (let i = 0; i < limit; i++) {
    const token = toks[i];

    if (token === "chime") {
      alarm.sound_tone = "chime";
      found = true;
      continue;
    }
    if (token === "digital") {
      // Alias `digital pulse`; the trailing word is consumed with it.
      if (toks[i + 1] === "pulse") i++;
      alarm.sound_tone = "digital";
      found = true;
      continue;
    }

    const seconds = /^(\d+)s$/.exec(token);
    if (seconds && toks[i + 1] === "ramp") {
      alarm.ramp_seconds = parseInt(seconds[1], 10);
      found = true;
      i++;
      continue;
    }

    const phrase = RAMP_PHRASES[`${token} ${toks[i + 1]}`];
    if (phrase !== undefined) {
      alarm.ramp_seconds = phrase;
      found = true;
      i++;
      continue;
    }

    keptRaw.push(raw[i]);
    keptToks.push(token);
  }

  return { alarm: found ? alarm : undefined, raw: keptRaw, toks: keptToks };
}

/**
 * Parse a complete time expression. Throws `TimeParseError` if the whole input
 * is not one valid expression.
 */
export function parseTime(input: string, now?: Date): ParsedTime {
  const nowDate = now ?? new Date();
  const inputRaw = input.trim().split(/\s+/).filter(Boolean);
  if (inputRaw.length === 0) {
    throw new TimeParseError("Empty time expression.", "");
  }

  const inputToks = inputRaw.map(normalizeToken);
  assertRealDates(inputToks, nowDate);
  const metadata = extractMetadata(inputRaw, inputToks);
  const raw = metadata.raw;
  const toks = metadata.toks;

  const parsed = tryParseExpression(toks, nowDate, true);
  if (parsed) {
    if (metadata.alarm) parsed.alarm = metadata.alarm;
    return parsed;
  }

  // Name the offending (first unconsumed) token when a valid prefix exists.
  for (let end = toks.length - 1; end >= 1; end--) {
    if (tryParseExpression(toks.slice(0, end), nowDate, false)) {
      throw new TimeParseError(
        `Could not parse time expression: "${raw[end]}".`,
        raw[end]
      );
    }
  }

  const offending = raw[0] ?? inputRaw[0];
  throw new TimeParseError(
    `Could not parse time expression: "${offending}".`,
    offending
  );
}

/**
 * When no leading prefix parses, locate a complete time expression *inside* the
 * input and treat the surrounding tokens as the label. A trailing span is
 * preferred (the natural "label first" phrasing, e.g. `gym tomorrow 7am`),
 * falling back to the longest span anywhere. Returns `null` when nothing parses.
 *
 * The selected token range `[start, end)` is returned too, so the caller can
 * judge whether that expression carried an anchor (spec §5.4 stage 3).
 */
function findTimeSpan(
  raw: string[],
  toks: string[],
  now: Date
): { parsed: ParsedTime; rest: string; start: number; end: number } | null {
  // Prefer the longest trailing span: label first, time last. Iterating `start`
  // upward returns the smallest start (i.e. the longest suffix) that parses.
  for (let start = 0; start < toks.length; start++) {
    const parsed = speculative(() => tryParseExpression(toks.slice(start), now, false));
    if (parsed) {
      return { parsed, rest: raw.slice(0, start).join(" "), start, end: toks.length };
    }
  }
  // Otherwise the longest span anywhere; the surrounding tokens form the label.
  for (let len = toks.length; len >= 1; len--) {
    for (let start = 0; start + len <= toks.length; start++) {
      const parsed = speculative(() => tryParseExpression(toks.slice(start, start + len), now, false));
      if (parsed) {
        const label = raw.slice(0, start).concat(raw.slice(start + len));
        return { parsed, rest: label.join(" "), start, end: start + len };
      }
    }
  }
  return null;
}

/**
 * True when the expression at `[start, end)` carries no recurrence, day
 * qualifier, `this`/`next`, or absolute-date anchor — i.e. the ladder selected a
 * bare clock/period. Mirrors the anchor dispatch at the head of
 * `tryParseExpression`; stage 3 overrides only such an unanchored selection.
 */
function spanIsUnanchored(toks: string[], start: number, end: number): boolean {
  let i = start;
  while (i < end && CONNECTORS.has(toks[i])) i++;
  if (i >= end) return true;
  if (matchRecurrencePrefix(toks, i)) return false;
  if (matchNextThis(toks, i)) return false;
  if (matchDayQualifier(toks, i)) return false;
  if (parseAbsoluteDate(toks, i)) return false;
  // Clock → date (`5pm 10/31`): the clock is anchored by the trailing date.
  const clock = parseClock(toks, i);
  if (clock) {
    let j = clock.next;
    while (j < end && CONNECTORS.has(toks[j])) j++;
    if (j < end && parseAbsoluteDate(toks, j)) return false;
  }
  return true;
}

/** True when `[from, to)` holds any token that is not a connector. */
function hasInteriorText(toks: string[], from: number, to: number): boolean {
  for (let k = from; k < to; k++) {
    if (!CONNECTORS.has(toks[k])) return true;
  }
  return false;
}

/**
 * Label for a split-anchor join: every original token except the anchor
 * `[aStart, aEnd)`, the clock `[cStart, cEnd)`, and the connector(s) directly
 * introducing the clock (e.g. the `at` in `at 8pm`), original order preserved.
 */
function splitLabel(
  raw: string[],
  toks: string[],
  aStart: number,
  aEnd: number,
  cStart: number,
  cEnd: number
): string {
  let clockStart = cStart;
  while (clockStart > aEnd && CONNECTORS.has(toks[clockStart - 1])) clockStart--;
  const kept: string[] = [];
  for (let k = 0; k < raw.length; k++) {
    if (k >= aStart && k < aEnd) continue;
    if (k >= clockStart && k < cEnd) continue;
    kept.push(raw[k]);
  }
  return kept.join(" ");
}

/**
 * Stage 3 split-anchor fallback (spec §5.4). When the ladder selected an
 * unanchored clock/period but a recurrence or absolute-date anchor is stranded
 * in the label, join the anchor to the trailing clock and make the intervening
 * tokens part of the label, preserving order. This recovers
 * `dance practice every tuesday in the gym at 8pm` as `every tuesday` + `8pm`
 * with label `dance practice in the gym`. Returns `null` when no split applies.
 *
 * A bare integer is never joined here (§5.4 clock priority: bare is lowest and
 * only ever a clock as the whole expression), and the anchor must be separated
 * from the clock by interior label text — an anchor already adjacent to its
 * clock was consumed by stages 1–2 and is left to them.
 */
function findSplitAnchor(
  raw: string[],
  toks: string[],
  now: Date
): { parsed: ParsedTime; rest: string } | null {
  // The clock stages 1–2 would select: the trailing clock/period.
  let c = -1;
  let clock: Clock | null = null;
  for (let k = 0; k < toks.length; k++) {
    const candidate = parseClock(toks, k) ?? parseDayPeriod(toks, k);
    if (candidate && candidate.next === toks.length && !candidate.bare) {
      c = k;
      clock = candidate;
      break;
    }
  }
  if (!clock) return null;

  // A recurrence anchor before the clock, separated by interior label text.
  for (let a = 0; a < c; a++) {
    const recurrence = matchRecurrencePrefix(toks, a);
    if (recurrence && recurrence.next < c && hasInteriorText(toks, recurrence.next, c)) {
      const joined = toks.slice(a, recurrence.next).concat(toks.slice(c, clock.next));
      const parsed = tryParseExpression(joined, now, false);
      if (parsed) {
        return { parsed, rest: splitLabel(raw, toks, a, recurrence.next, c, clock.next) };
      }
    }
  }

  // An absolute-date anchor before the clock, separated by interior label text.
  for (let a = 0; a < c; a++) {
    const date = parseAbsoluteDate(toks, a);
    if (date && date.next < c && hasInteriorText(toks, date.next, c)) {
      const joined = toks.slice(a, date.next).concat(toks.slice(c, clock.next));
      const parsed = tryParseExpression(joined, now, false);
      if (parsed) {
        return { parsed, rest: splitLabel(raw, toks, a, date.next, c, clock.next) };
      }
    }
  }

  return null;
}

/**
 * Run a speculative parse probe, swallowing an `already_passed` refusal so the
 * caller can keep searching for a valid expression elsewhere in the input. Only
 * exploratory probes (shorter prefixes, the span search) use this; the confident
 * whole-input parse raises `already_passed` directly (spec §10).
 */
function speculative<T>(probe: () => T): T | null {
  try {
    return probe();
  } catch (err) {
    if (err instanceof TimeParseError && err.reason === "already_passed") return null;
    throw err;
  }
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
  const inputRaw = input.trim().split(/\s+/).filter(Boolean);
  if (inputRaw.length === 0) return null;

  const inputToks = inputRaw.map(normalizeToken);
  assertRealDates(inputToks, nowDate);
  const metadata = extractMetadata(inputRaw, inputToks);
  const raw = metadata.raw;
  const toks = metadata.toks;

  // The confident whole-input parse. A passed `this <weekday>` / `this weekend`
  // here is a hard `already_passed` refusal the caller wants to surface, so this
  // throw is deliberately NOT swallowed (spec §10). Only the whole input may
  // carry a bare-integer clock.
  const whole = tryParseExpression(toks, nowDate, true);
  if (whole) {
    if (metadata.alarm) whole.alarm = metadata.alarm;
    return { parsed: whole, rest: "" };
  }

  // Speculative prefix probing: shorter prefixes are slices, so a passed
  // `this <weekday>` inside a longer phrase must not abort the search. Swallow
  // `already_passed` and keep looking, so the documented null contract holds and
  // a valid shorter prefix still wins. Shorter prefixes never carry a
  // bare-integer clock, where a bare integer would swallow part of the label.
  for (let end = toks.length - 1; end >= 1; end--) {
    const parsed = speculative(() => tryParseExpression(toks.slice(0, end), nowDate, false));
    if (parsed) {
      if (metadata.alarm) parsed.alarm = metadata.alarm;
      return { parsed, rest: raw.slice(end).join(" ") };
    }
  }

  // An `every` the grammar cannot read must not fall through to a bare weekday
  // (spec §5.3/§10): fail loudly by resolving nothing.
  if (hasOrphanEvery(toks)) return null;

  // No leading time prefix: fall back to a span anywhere in the input. This too
  // is speculative, so `already_passed` is swallowed here as well.
  const span = findTimeSpan(raw, toks, nowDate);
  if (span) {
    // Stage 3 (spec §5.4): when the span selected an unanchored clock/period but
    // a recurrence/date anchor is stranded in the label, the joined anchor wins.
    if (spanIsUnanchored(toks, span.start, span.end)) {
      const split = findSplitAnchor(raw, toks, nowDate);
      if (split) {
        if (metadata.alarm) split.parsed.alarm = metadata.alarm;
        return split;
      }
    }
    if (metadata.alarm) span.parsed.alarm = metadata.alarm;
    return { parsed: span.parsed, rest: span.rest };
  }

  // Stages 1–2 produced nothing: the literal stage-3 fallback still applies.
  const split = findSplitAnchor(raw, toks, nowDate);
  if (split && metadata.alarm) split.parsed.alarm = metadata.alarm;
  return split;
}
