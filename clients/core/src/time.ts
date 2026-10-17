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

type DayQualifier =
  | { kind: "today" }
  | { kind: "tomorrow" }
  | { kind: "weekday"; weekday: Weekday };

interface Clock {
  hours: number;
  minutes: number;
  /** Index into the token array just past the clock. */
  next: number;
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

function makeClock(
  hour: number,
  minute: number,
  meridiem: string | undefined,
  next: number
): Clock | null {
  if (!Number.isInteger(minute) || minute < 0 || minute > 59) return null;
  if (meridiem) {
    // A meridiem implies a 1–12 hour; `13pm` / `0am` are invalid.
    if (hour < 1 || hour > 12) return null;
    let hours = hour % 12;
    if (meridiem === "pm") hours += 12;
    return { hours, minutes: minute, next };
  }
  // Bare / colon times without a meridiem are read as 24-hour.
  if (hour < 0 || hour > 23) return null;
  return { hours: hour, minutes: minute, next };
}

/** Parse a clock token (possibly spread over two tokens, e.g. `7 am`). */
function parseClock(toks: string[], i: number): Clock | null {
  const first = toks[i];
  if (first === undefined) return null;

  // 7am / 12pm / 13pm (invalid)
  let match = /^(\d{1,2})(am|pm)$/.exec(first);
  if (match) {
    return makeClock(parseInt(match[1], 10), 0, match[2], i + 1);
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
    return makeClock(parseInt(match[1], 10), parseInt(match[2], 10), meridiem, next);
  }

  // Bare hour: `7` -> 07:00, `19` -> 19:00, optionally followed by am/pm.
  match = /^(\d{1,2})$/.exec(first);
  if (match) {
    if (i + 1 < toks.length && (toks[i + 1] === "am" || toks[i + 1] === "pm")) {
      return makeClock(parseInt(match[1], 10), 0, toks[i + 1], i + 2);
    }
    return makeClock(parseInt(match[1], 10), 0, undefined, i + 1);
  }

  return null;
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
 */
function tryParseExpression(toks: string[], now: Date): ParsedTime | null {
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
    const day = matchDayQualifier(toks, i);
    if (day) {
      qualifier = day.qualifier;
      i = day.next;
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

  // Duration form: only ever standalone (no day/recurrence qualifier).
  if (!qualifier && repeatDays.length === 0) {
    const duration = parseDuration(toks, i);
    if (duration) {
      const targetTime = new Date(ctx.now.getTime() + duration.ms);
      return finalize(targetTime, [], ctx.now);
    }
  }

  const clock = parseClock(toks, i);
  if (clock && clock.next === toks.length) {
    const targetTime = buildClockTime(ctx, qualifier, repeatDays, clock.hours, clock.minutes);
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
  const parsed = tryParseExpression(toks, nowDate);
  if (parsed) return parsed;

  // Name the offending (first unconsumed) token when a valid prefix exists.
  for (let end = toks.length - 1; end >= 1; end--) {
    if (tryParseExpression(toks.slice(0, end), nowDate)) {
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
    const parsed = tryParseExpression(toks.slice(start), now);
    if (parsed) {
      return { parsed, rest: raw.slice(0, start).join(" ") };
    }
  }
  // Otherwise the longest span anywhere; the surrounding tokens form the label.
  for (let len = toks.length; len >= 1; len--) {
    for (let start = 0; start + len <= toks.length; start++) {
      const parsed = tryParseExpression(toks.slice(start, start + len), now);
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
    const parsed = tryParseExpression(toks.slice(0, end), nowDate);
    if (parsed) {
      return { parsed, rest: raw.slice(end).join(" ") };
    }
  }
  // No leading time prefix: fall back to a span anywhere in the input.
  return findTimeSpan(raw, toks, nowDate);
}
