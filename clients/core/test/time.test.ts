import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  parseTime,
  parseLeadingTime,
  formatLocal,
  formatRelative,
  TimeParseError,
} from "../src/index.js";
import type { Weekday } from "../src/index.js";

/** Local wall-clock constructor (month is 1-based here for readability). */
function at(
  year: number,
  month: number,
  day: number,
  hours: number,
  minutes: number,
  seconds = 0,
  ms = 0
): Date {
  return new Date(year, month - 1, day, hours, minutes, seconds, ms);
}

const MON_10 = at(2026, 9, 21, 10, 0); // Monday 21 Sep 2026, 10:00 local
const ALL: Weekday[] = [1, 2, 3, 4, 5, 6, 7];

function assertLocal(
  date: Date,
  y: number,
  mo: number,
  d: number,
  h: number,
  mi: number,
  s = 0
): void {
  assert.equal(date.getFullYear(), y, `year of ${date.toISOString()}`);
  assert.equal(date.getMonth() + 1, mo, `month of ${date.toISOString()}`);
  assert.equal(date.getDate(), d, `day of ${date.toISOString()}`);
  assert.equal(date.getHours(), h, `hours of ${date.toISOString()}`);
  assert.equal(date.getMinutes(), mi, `minutes of ${date.toISOString()}`);
  assert.equal(date.getSeconds(), s, `seconds of ${date.toISOString()}`);
}

interface ValidCase {
  name: string;
  input: string;
  now: Date;
  y: number;
  mo: number;
  d: number;
  h: number;
  mi: number;
  s?: number;
  days?: Weekday[];
}

const VALID: ValidCase[] = [
  // ── Duration ──────────────────────────────────────────────────────────
  { name: "25m", input: "25m", now: MON_10, y: 2026, mo: 9, d: 21, h: 10, mi: 25 },
  { name: "25 min", input: "25 min", now: MON_10, y: 2026, mo: 9, d: 21, h: 10, mi: 25 },
  { name: "in 25m", input: "in 25m", now: MON_10, y: 2026, mo: 9, d: 21, h: 10, mi: 25 },
  { name: "1h", input: "1h", now: MON_10, y: 2026, mo: 9, d: 21, h: 11, mi: 0 },
  { name: "1h30m", input: "1h30m", now: MON_10, y: 2026, mo: 9, d: 21, h: 11, mi: 30 },
  { name: "2h15m", input: "2h15m", now: MON_10, y: 2026, mo: 9, d: 21, h: 12, mi: 15 },
  { name: "90s", input: "90s", now: MON_10, y: 2026, mo: 9, d: 21, h: 10, mi: 1, s: 30 },
  {
    name: "45 seconds",
    input: "45 seconds",
    now: MON_10,
    y: 2026,
    mo: 9,
    d: 21,
    h: 10,
    mi: 0,
    s: 45,
  },
  { name: "99m (valid large duration)", input: "99m", now: MON_10, y: 2026, mo: 9, d: 21, h: 11, mi: 39 },
  {
    name: "in 1h 30m (multi-token)",
    input: "in 1h 30m",
    now: MON_10,
    y: 2026,
    mo: 9,
    d: 21,
    h: 11,
    mi: 30,
  },

  // ── Clock ─────────────────────────────────────────────────────────────
  { name: "bare 7 (passed -> tomorrow 07:00)", input: "7", now: MON_10, y: 2026, mo: 9, d: 22, h: 7, mi: 0 },
  {
    name: "bare 7 (future -> today 07:00)",
    input: "7",
    now: at(2026, 9, 21, 6, 0),
    y: 2026,
    mo: 9,
    d: 21,
    h: 7,
    mi: 0,
  },
  { name: "bare 19 is 24-hour", input: "19", now: MON_10, y: 2026, mo: 9, d: 21, h: 19, mi: 0 },
  {
    name: "7:30 without meridiem is 24-hour (future)",
    input: "7:30",
    now: at(2026, 9, 21, 6, 0),
    y: 2026,
    mo: 9,
    d: 21,
    h: 7,
    mi: 30,
  },
  {
    name: "7:30 without meridiem (passed -> tomorrow)",
    input: "7:30",
    now: MON_10,
    y: 2026,
    mo: 9,
    d: 22,
    h: 7,
    mi: 30,
  },
  { name: "19:00", input: "19:00", now: MON_10, y: 2026, mo: 9, d: 21, h: 19, mi: 0 },
  {
    name: "07:00",
    input: "07:00",
    now: at(2026, 9, 21, 6, 0),
    y: 2026,
    mo: 9,
    d: 21,
    h: 7,
    mi: 0,
  },
  { name: "7am", input: "7am", now: at(2026, 9, 21, 6, 0), y: 2026, mo: 9, d: 21, h: 7, mi: 0 },
  {
    name: "7:30am",
    input: "7:30am",
    now: at(2026, 9, 21, 6, 0),
    y: 2026,
    mo: 9,
    d: 21,
    h: 7,
    mi: 30,
  },
  { name: "12am is midnight", input: "12am", now: at(2026, 9, 20, 23, 0), y: 2026, mo: 9, d: 21, h: 0, mi: 0 },
  { name: "12pm is noon", input: "12pm", now: MON_10, y: 2026, mo: 9, d: 21, h: 12, mi: 0 },
  { name: "bare 0 (passed -> tomorrow midnight)", input: "0", now: MON_10, y: 2026, mo: 9, d: 22, h: 0, mi: 0 },
  { name: "23:59", input: "23:59", now: MON_10, y: 2026, mo: 9, d: 21, h: 23, mi: 59 },
  {
    name: "23:59 boundary rolls at exact equality",
    input: "23:59",
    now: at(2026, 9, 21, 23, 59),
    y: 2026,
    mo: 9,
    d: 22,
    h: 23,
    mi: 59,
  },
  { name: "at 7am (connector stripped)", input: "at 7am", now: at(2026, 9, 21, 6, 0), y: 2026, mo: 9, d: 21, h: 7, mi: 0 },
  { name: "7 pm (split meridiem)", input: "7 pm", now: MON_10, y: 2026, mo: 9, d: 21, h: 19, mi: 0 },
  {
    name: "7:30 pm (split meridiem)",
    input: "7:30 pm",
    now: MON_10,
    y: 2026,
    mo: 9,
    d: 21,
    h: 19,
    mi: 30,
  },

  // ── Day-qualified ─────────────────────────────────────────────────────
  { name: "tomorrow", input: "tomorrow", now: MON_10, y: 2026, mo: 9, d: 22, h: 0, mi: 0 },
  { name: "tmr", input: "tmr", now: MON_10, y: 2026, mo: 9, d: 22, h: 0, mi: 0 },
  { name: "tomorrow 6pm", input: "tomorrow 6pm", now: MON_10, y: 2026, mo: 9, d: 22, h: 18, mi: 0 },
  { name: "tomorrow at 7am", input: "tomorrow at 7am", now: MON_10, y: 2026, mo: 9, d: 22, h: 7, mi: 0 },
  { name: "today 6pm (future)", input: "today 6pm", now: MON_10, y: 2026, mo: 9, d: 21, h: 18, mi: 0 },
  { name: "today 9am (passed rolls +1)", input: "today 9am", now: MON_10, y: 2026, mo: 9, d: 22, h: 9, mi: 0 },
  { name: "mon 8:30am (passed -> next Monday)", input: "mon 8:30am", now: MON_10, y: 2026, mo: 9, d: 28, h: 8, mi: 30 },
  {
    name: "monday 8:30am (today counts if not passed)",
    input: "monday 8:30am",
    now: at(2026, 9, 21, 8, 0),
    y: 2026,
    mo: 9,
    d: 21,
    h: 8,
    mi: 30,
  },
  { name: "tue 8:30am", input: "tue 8:30am", now: MON_10, y: 2026, mo: 9, d: 22, h: 8, mi: 30 },
  { name: "wed 7am", input: "wed 7am", now: MON_10, y: 2026, mo: 9, d: 23, h: 7, mi: 0 },
  { name: "thu 7am", input: "thu 7am", now: MON_10, y: 2026, mo: 9, d: 24, h: 7, mi: 0 },
  { name: "fri 7am", input: "fri 7am", now: MON_10, y: 2026, mo: 9, d: 25, h: 7, mi: 0 },
  { name: "sat 7am", input: "sat 7am", now: MON_10, y: 2026, mo: 9, d: 26, h: 7, mi: 0 },
  { name: "sun 7am", input: "sun 7am", now: MON_10, y: 2026, mo: 9, d: 27, h: 7, mi: 0 },
  { name: "friday 7:30pm", input: "friday 7:30pm", now: MON_10, y: 2026, mo: 9, d: 25, h: 19, mi: 30 },

  // ── Recurrence ────────────────────────────────────────────────────────
  { name: "daily 7am (passed)", input: "daily 7am", now: MON_10, y: 2026, mo: 9, d: 22, h: 7, mi: 0, days: ALL },
  {
    name: "daily 7am (today)",
    input: "daily 7am",
    now: at(2026, 9, 21, 6, 0),
    y: 2026,
    mo: 9,
    d: 21,
    h: 7,
    mi: 0,
    days: ALL,
  },
  { name: "every day 7am", input: "every day 7am", now: MON_10, y: 2026, mo: 9, d: 22, h: 7, mi: 0, days: ALL },
  { name: "weekdays 7am", input: "weekdays 7am", now: MON_10, y: 2026, mo: 9, d: 22, h: 7, mi: 0, days: [1, 2, 3, 4, 5] },
  { name: "weekends 7am", input: "weekends 7am", now: MON_10, y: 2026, mo: 9, d: 26, h: 7, mi: 0, days: [6, 7] },
  { name: "mon-fri 7am", input: "mon-fri 7am", now: MON_10, y: 2026, mo: 9, d: 22, h: 7, mi: 0, days: [1, 2, 3, 4, 5] },
  { name: "mon,wed,fri 7am", input: "mon,wed,fri 7am", now: MON_10, y: 2026, mo: 9, d: 23, h: 7, mi: 0, days: [1, 3, 5] },
  { name: "mon, wed, fri 7am (spaced list)", input: "mon, wed, fri 7am", now: MON_10, y: 2026, mo: 9, d: 23, h: 7, mi: 0, days: [1, 3, 5] },
  { name: "every mon 7am (passed -> next)", input: "every mon 7am", now: MON_10, y: 2026, mo: 9, d: 28, h: 7, mi: 0, days: [1] },
  {
    name: "every mon 7am (today)",
    input: "every mon 7am",
    now: at(2026, 9, 21, 6, 0),
    y: 2026,
    mo: 9,
    d: 21,
    h: 7,
    mi: 0,
    days: [1],
  },
  { name: "every day at 10pm", input: "every day at 10pm", now: MON_10, y: 2026, mo: 9, d: 21, h: 22, mi: 0, days: ALL },
  { name: "daily 6am", input: "daily 6am", now: MON_10, y: 2026, mo: 9, d: 22, h: 6, mi: 0, days: ALL },
];

describe("parseTime — grammar table", () => {
  for (const testCase of VALID) {
    it(`parses "${testCase.name}"`, () => {
      const parsed = parseTime(testCase.input, testCase.now);
      assertLocal(
        parsed.targetTime,
        testCase.y,
        testCase.mo,
        testCase.d,
        testCase.h,
        testCase.mi,
        testCase.s ?? 0
      );
      assert.deepEqual(parsed.repeatDays, testCase.days ?? []);
    });
  }
});

describe("parseTime — weekday mapping for all seven days", () => {
  const nowMonday = MON_10;
  const expected: Record<string, number> = {
    mon: 28, // passed today -> next Monday
    tue: 22,
    wed: 23,
    thu: 24,
    fri: 25,
    sat: 26,
    sun: 27,
  };
  for (const [name, day] of Object.entries(expected)) {
    it(`"${name} 7am" resolves to Sep ${day}`, () => {
      const parsed = parseTime(`${name} 7am`, nowMonday);
      assert.equal(parsed.targetTime.getDate(), day);
      assert.equal(parsed.targetTime.getHours(), 7);
      assert.ok(parsed.targetTime.getTime() > nowMonday.getTime());
    });
  }
});

interface InvalidCase {
  input: string;
  token: string;
}

const INVALID: InvalidCase[] = [
  { input: "25:00", token: "25:00" },
  { input: "13pm", token: "13pm" },
  { input: "1x30m", token: "1x30m" },
  { input: "-5m", token: "-5m" },
  { input: "25", token: "25" },
  { input: "24", token: "24" },
  { input: "7:60", token: "7:60" },
  { input: "0am", token: "0am" },
  { input: "tomorrow 13pm", token: "13pm" },
  { input: "banana", token: "banana" },
];

describe("parseTime — invalid input", () => {
  for (const testCase of INVALID) {
    it(`rejects "${testCase.input}" naming the token`, () => {
      assert.throws(
        () => parseTime(testCase.input, MON_10),
        (err: unknown) => {
          assert.ok(err instanceof TimeParseError);
          assert.equal(err.token, testCase.token);
          assert.match(err.message, new RegExp(testCase.token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
          return true;
        }
      );
    });
  }

  it("rejects empty input", () => {
    assert.throws(() => parseTime("", MON_10), TimeParseError);
    assert.throws(() => parseTime("   ", MON_10), TimeParseError);
  });
});

describe("parseLeadingTime — longest leading prefix split", () => {
  it("splits '25m Oven'", () => {
    const split = parseLeadingTime("25m Oven", MON_10);
    assert.ok(split);
    assertLocal(split.parsed.targetTime, 2026, 9, 21, 10, 25);
    assert.equal(split.rest, "Oven");
  });

  it("splits 'tomorrow 6pm Call mum'", () => {
    const split = parseLeadingTime("tomorrow 6pm Call mum", MON_10);
    assert.ok(split);
    assertLocal(split.parsed.targetTime, 2026, 9, 22, 18, 0);
    assert.equal(split.rest, "Call mum");
  });

  it("splits '8am 5 minute warning' (not a concatenation)", () => {
    const split = parseLeadingTime("8am 5 minute warning", MON_10);
    assert.ok(split);
    assertLocal(split.parsed.targetTime, 2026, 9, 22, 8, 0);
    assert.equal(split.rest, "5 minute warning");
  });

  it("strips the 'in' connector but preserves the label", () => {
    const split = parseLeadingTime("in 25m Oven", MON_10);
    assert.ok(split);
    assertLocal(split.parsed.targetTime, 2026, 9, 21, 10, 25);
    assert.equal(split.rest, "Oven");
  });

  it("preserves the label's original casing", () => {
    const split = parseLeadingTime("tomorrow 6pm Call Mum", MON_10);
    assert.ok(split);
    assert.equal(split.rest, "Call Mum");
  });

  it("returns null when no prefix parses", () => {
    assert.equal(parseLeadingTime("Oven", MON_10), null);
    assert.equal(parseLeadingTime("", MON_10), null);
  });
});

describe("parseTime — timezone round trip (spec §6.5)", () => {
  it("requested wall clock survives targetTime -> toISOString -> local Date", () => {
    const parsed = parseTime("7:30am", at(2026, 9, 21, 6, 0));
    assertLocal(parsed.targetTime, 2026, 9, 21, 7, 30);

    const iso = parsed.targetTime.toISOString();
    const reDerived = new Date(iso);
    assert.equal(reDerived.getTime(), parsed.targetTime.getTime());
    assert.equal(reDerived.getHours(), 7);
    assert.equal(reDerived.getMinutes(), 30);
  });

  it("round-trips a day-qualified time", () => {
    const parsed = parseTime("tomorrow 6pm", MON_10);
    const reDerived = new Date(parsed.targetTime.toISOString());
    assert.equal(reDerived.getHours(), 18);
    assert.equal(reDerived.getMinutes(), 0);
    assert.equal(reDerived.getDate(), 22);
  });

  it("round-trips a recurring time", () => {
    const parsed = parseTime("mon-fri 7am", MON_10);
    const reDerived = new Date(parsed.targetTime.toISOString());
    assert.equal(reDerived.getHours(), 7);
    assert.equal(reDerived.getMinutes(), 0);
    assert.deepEqual(parsed.repeatDays, [1, 2, 3, 4, 5]);
  });

  it("round-trips a duration as an instant offset", () => {
    const now = MON_10;
    const parsed = parseTime("25m", now);
    assert.equal(parsed.targetTime.getTime() - now.getTime(), 25 * 60 * 1000);
    const reDerived = new Date(parsed.targetTime.toISOString());
    assert.equal(reDerived.getTime(), parsed.targetTime.getTime());
  });
});

describe("parseTime — interpretation echo", () => {
  it("echoes the absolute local time and the relative offset", () => {
    const now = at(2026, 9, 21, 17, 20);
    const expected = at(2026, 9, 22, 7, 0);
    const parsed = parseTime("tomorrow 7am", now);
    assert.equal(parsed.interpretation, "Tue 22 Sep, 7:00am (in 13h 40m)");
    assert.equal(
      parsed.interpretation,
      `${formatLocal(expected)} (${formatRelative(now, expected)})`
    );
  });
});
