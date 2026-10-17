import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { parseTime, parseLeadingTime, TimeParseError } from "../src/index.js";
import type { AlarmMetadata, ParsedTime } from "../src/index.js";

/**
 * The natural-language alarm corpus (`fixtures/nl-corpus.json`) is the
 * acceptance contract for the grammar expansion. This runner asserts every
 * case's *whole* structured resolution — the wall-clock instant, the repeat-day
 * set, the unconsumed label, the interval anchor, and any inline alarm metadata
 * — against both implementations of the parser (this canonical TypeScript one
 * and the hand-written browser port pinned by `backend/test/nl-corpus-port.test.ts`).
 *
 * `supported` cases are asserted unconditionally. `target` cases (behaviour the
 * expansion is meant to add) are asserted only once their id is listed in
 * `fixtures/nl-corpus-asserted.json`; the number still outstanding is tracked by
 * `EXPECTED_REMAINING_TARGETS` so a later task cannot silently drop one. Both
 * files are the single source of truth, read by both runners.
 *
 * `now` in the corpus is a LOCAL wall-clock ISO date-time written without a
 * timezone offset, exactly as in `fixtures/time-parse-cases.json`, so the cases
 * stay portable across whatever timezone the suite runs in.
 */

interface LocalFields {
  y: number;
  mo: number;
  d: number;
  h: number;
  mi: number;
  s: number;
}

interface Expected {
  local: LocalFields | null;
  repeatDays: number[] | null;
  label: string | null;
  invalid?: true;
  rejectedToken?: string;
  reason?: string;
  intervalWeeks?: number;
  intervalDays?: number;
  alarm?: AlarmMetadata;
}

interface CorpusCase {
  id: string;
  category: string;
  input: string;
  now: string;
  status: "supported" | "target";
  trap?: boolean;
  expected: Expected;
}

interface Corpus {
  cases: CorpusCase[];
}

/** Which `target` ids are asserted today; the rest are tracked as outstanding. */
interface AssertedManifest {
  assertedTargetIds: string[];
}

/** Updated by each task as it flips `target` ids into `fixtures/nl-corpus-asserted.json`. */
const EXPECTED_REMAINING_TARGETS = 14;

/**
 * Walk upward from the working directory until `relativePath` is found, so the
 * suite works whether it runs from `clients/core` or the repo root. A missing
 * fixture is a hard failure, never a silent skip.
 */
function findFixture(relativePath: string, startDir: string): string {
  let dir = startDir;
  for (;;) {
    const candidate = join(dir, relativePath);
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) {
      throw new Error(
        `fixture not found: searched upward from ${startDir} for ${relativePath}`
      );
    }
    dir = parent;
  }
}

const corpusPath = findFixture(join("fixtures", "nl-corpus.json"), process.cwd());
const corpus = JSON.parse(readFileSync(corpusPath, "utf8")) as Corpus;

const manifestPath = findFixture(join("fixtures", "nl-corpus-asserted.json"), process.cwd());
const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as AssertedManifest;
const assertedTargetIds = manifest.assertedTargetIds;

function assertLocal(date: Date, expected: LocalFields): void {
  assert.equal(date.getFullYear(), expected.y, `year of ${date.toISOString()}`);
  assert.equal(date.getMonth() + 1, expected.mo, `month of ${date.toISOString()}`);
  assert.equal(date.getDate(), expected.d, `day of ${date.toISOString()}`);
  assert.equal(date.getHours(), expected.h, `hours of ${date.toISOString()}`);
  assert.equal(date.getMinutes(), expected.mi, `minutes of ${date.toISOString()}`);
  assert.equal(date.getSeconds(), expected.s, `seconds of ${date.toISOString()}`);
}

/**
 * Map the parser's structured output onto the corpus's flat expectation keys.
 * `intervalWeeks`/`intervalDays` are mutually exclusive encodings of the same
 * optional `interval` field; when neither is present the parser must report none.
 */
function assertExpected(parsed: ParsedTime, rest: string, expected: Expected): void {
  assertLocal(parsed.targetTime, expected.local!);
  assert.deepEqual([...parsed.repeatDays], expected.repeatDays);
  assert.equal(rest, expected.label);
  if (expected.intervalWeeks !== undefined) {
    assert.deepEqual(parsed.interval, { count: expected.intervalWeeks, unit: "weeks" });
  } else if (expected.intervalDays !== undefined) {
    assert.deepEqual(parsed.interval, { count: expected.intervalDays, unit: "days" });
  } else {
    assert.equal(parsed.interval, undefined);
  }
  if (expected.alarm) {
    assert.deepEqual(parsed.alarm, expected.alarm);
  } else {
    assert.equal(parsed.alarm, undefined);
  }
}

describe("nl-corpus — full resolution (shared fixture)", () => {
  for (const testCase of corpus.cases) {
    const asserted =
      testCase.status === "supported" || assertedTargetIds.includes(testCase.id);
    if (!asserted) continue;

    it(`${testCase.id} — ${testCase.input}`, () => {
      if (testCase.expected.invalid === true) {
        assert.throws(
          () => parseTime(testCase.input, new Date(testCase.now)),
          (err: unknown) => {
            assert.ok(err instanceof TimeParseError);
            assert.equal(err.token, testCase.expected.rejectedToken);
            assert.equal(err.reason, testCase.expected.reason);
            return true;
          }
        );
        return;
      }

      const split = parseLeadingTime(testCase.input, new Date(testCase.now));
      assert.ok(split, `expected a resolution for "${testCase.input}"`);
      assertExpected(split.parsed, split.rest, testCase.expected);
    });
  }
});

describe("nl-corpus — tracked coverage", () => {
  it("tracks the remaining target count", () => {
    const remaining = corpus.cases.filter(
      (c) => c.status === "target" && !assertedTargetIds.includes(c.id)
    ).length;
    assert.equal(remaining, EXPECTED_REMAINING_TARGETS);
  });
});
