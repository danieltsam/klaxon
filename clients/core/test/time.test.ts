import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

import {
  parseTime,
  parseLeadingTime,
  formatLocal,
  formatRelative,
  TimeParseError,
} from "../src/index.js";
import type { Weekday } from "../src/index.js";

/**
 * The grammar is pinned once in `fixtures/time-parse-cases.json` and asserted by
 * two implementations: this canonical TypeScript parser and the no-build
 * browser port at `backend/public/nl-time.js`. The fixture is the contract —
 * never edit it to make a test pass, and never let the two implementations
 * diverge from it.
 *
 * `now` in the fixture is a LOCAL wall-clock ISO date-time written without a
 * timezone offset. ECMAScript parses offset-less date-time forms as local time,
 * so `new Date(case.now)` reproduces the old `at(...)` helper in whatever
 * timezone the suite runs, keeping the cases portable.
 */

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

interface ExpectFields {
  y: number;
  mo: number;
  d: number;
  h: number;
  mi: number;
  s: number;
}

interface ValidCase {
  name: string;
  input: string;
  now: string;
  expect: ExpectFields;
  days: Weekday[];
}

interface InvalidCase {
  input: string;
  token: string;
  now: string;
}

interface LeadingCase {
  name: string;
  input: string;
  now: string;
  expect: ExpectFields;
  rest: string;
}

interface InterpretationCase {
  name: string;
  input: string;
  now: string;
  interpretation: string;
}

interface Fixture {
  rule: { grammar: string[]; fields: Record<string, string>; notes: string[] };
  cases: ValidCase[];
  invalid: InvalidCase[];
  leading: LeadingCase[];
  leadingNull: string[];
  interpretation: InterpretationCase[];
}

/**
 * Walk upward from the working directory until `fixtures/time-parse-cases.json`
 * is found, so the suite works whether it runs from `clients/core` or the repo
 * root. A missing fixture is a hard failure, never a silent skip.
 */
function findFixture(startDir: string): string {
  let dir = startDir;
  for (;;) {
    const candidate = join(dir, "fixtures", "time-parse-cases.json");
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) {
      throw new Error(
        `time-parse fixture not found: searched upward from ${startDir} for fixtures/time-parse-cases.json`
      );
    }
    dir = parent;
  }
}

const fixturePath = findFixture(process.cwd());
const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as Fixture;

describe("parseTime — grammar table (shared fixture)", () => {
  for (const testCase of fixture.cases) {
    it(`parses "${testCase.name}"`, () => {
      const parsed = parseTime(testCase.input, new Date(testCase.now));
      assertLocal(
        parsed.targetTime,
        testCase.expect.y,
        testCase.expect.mo,
        testCase.expect.d,
        testCase.expect.h,
        testCase.expect.mi,
        testCase.expect.s
      );
      assert.deepEqual(parsed.repeatDays, testCase.days);
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

describe("parseTime — invalid input (shared fixture)", () => {
  for (const testCase of fixture.invalid) {
    it(`rejects "${testCase.input}" naming the token`, () => {
      assert.throws(
        () => parseTime(testCase.input, new Date(testCase.now)),
        (err: unknown) => {
          assert.ok(err instanceof TimeParseError);
          assert.equal(err.token, testCase.token);
          assert.equal(err.reason, "unparseable");
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

describe("TimeParseError — refusal reason", () => {
  it("carries an already_passed refusal reason", () => {
    const err = new TimeParseError("Already passed.", "this friday", "already_passed");
    assert.equal(err.token, "this friday");
    assert.equal(err.reason, "already_passed");
    assert.equal(new TimeParseError("x", "y").reason, "unparseable");
  });
});

describe("parseLeadingTime — longest leading prefix split (shared fixture)", () => {
  for (const testCase of fixture.leading) {
    it(testCase.name, () => {
      const split = parseLeadingTime(testCase.input, new Date(testCase.now));
      assert.ok(split);
      assertLocal(
        split.parsed.targetTime,
        testCase.expect.y,
        testCase.expect.mo,
        testCase.expect.d,
        testCase.expect.h,
        testCase.expect.mi,
        testCase.expect.s
      );
      assert.equal(split.rest, testCase.rest);
    });
  }

  it("returns null when no prefix parses", () => {
    for (const input of fixture.leadingNull) {
      assert.equal(parseLeadingTime(input, MON_10), null);
    }
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

describe("parseTime — interpretation echo (shared fixture)", () => {
  for (const testCase of fixture.interpretation) {
    it(testCase.name, () => {
      const now = new Date(testCase.now);
      const parsed = parseTime(testCase.input, now);
      assert.equal(parsed.interpretation, testCase.interpretation);
      assert.equal(
        parsed.interpretation,
        `${formatLocal(parsed.targetTime)} (${formatRelative(now, parsed.targetTime)})`
      );
    });
  }
});
