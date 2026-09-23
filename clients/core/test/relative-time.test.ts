import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { formatRelative } from "../src/index.js";

/**
 * The relative-time rule is pinned once in `fixtures/relative-time-cases.json`
 * and shared by four implementations. This suite asserts the `compact` strings
 * the CLI and Raycast consume; the `prose` column belongs to the phone and
 * dashboard. The fixture is the contract — never edit it to make a test pass.
 */
interface FixtureCase {
  seconds: number;
  prose: string;
  compact: string;
}

interface Fixture {
  rule: { tiers: string[]; notes: string[] };
  cases: FixtureCase[];
}

/**
 * Walk upward from the working directory until `fixtures/relative-time-cases.json`
 * is found, so the suite works whether it runs from `clients/core` or the repo
 * root. A missing fixture is a hard failure, never a silent skip.
 */
function findFixture(startDir: string): string {
  let dir = startDir;
  for (;;) {
    const candidate = join(dir, "fixtures", "relative-time-cases.json");
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) {
      throw new Error(
        `relative-time fixture not found: searched upward from ${startDir} for fixtures/relative-time-cases.json`
      );
    }
    dir = parent;
  }
}

const fixturePath = findFixture(process.cwd());
const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as Fixture;

const EPOCH = new Date(0);
const atSeconds = (seconds: number): Date => new Date(seconds * 1000);

describe("relative time — shared fixture (compact)", () => {
  it("loads a non-empty case list from the fixture", () => {
    assert.ok(fixture.cases.length > 0, `no cases in ${fixturePath}`);
  });

  for (const { seconds, compact } of fixture.cases) {
    it(`${seconds}s renders "in ${compact}"`, () => {
      assert.equal(formatRelative(EPOCH, atSeconds(seconds)), `in ${compact}`);
    });
  }
});

describe("relative time — compact boundaries", () => {
  it("59 seconds is under a minute", () => {
    assert.equal(formatRelative(EPOCH, atSeconds(59)), "in less than a minute");
  });

  it("exactly 60 seconds is one minute", () => {
    assert.equal(formatRelative(EPOCH, atSeconds(60)), "in 1m");
  });

  it("exactly 24 hours is one day", () => {
    assert.equal(formatRelative(EPOCH, atSeconds(24 * 60 * 60)), "in 1d");
  });

  it("exactly 30 days is one month", () => {
    assert.equal(formatRelative(EPOCH, atSeconds(30 * 24 * 60 * 60)), "in 1mo");
  });

  it("exactly 365 days is one year", () => {
    assert.equal(formatRelative(EPOCH, atSeconds(365 * 24 * 60 * 60)), "in 1y");
  });

  it("a negative duration keeps its magnitude and gains 'ago'", () => {
    assert.equal(formatRelative(atSeconds(3660), EPOCH), "1h 1m ago");
  });
});
