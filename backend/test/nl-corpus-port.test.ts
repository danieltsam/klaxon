import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

/**
 * Browser-port contract for the natural-language alarm corpus.
 *
 * `backend/public/nl-time.js` is a hand port of `clients/core/src/time.ts`
 * (the dashboard has no build step) and the two must not drift, so this suite is
 * a deliberate mirror of `clients/core/test/nl-corpus.test.ts`: it reads the
 * SAME `fixtures/nl-corpus.json` and the SAME `fixtures/nl-corpus-asserted.json`
 * and asserts the SAME full resolution shape. If this suite and clients/core's
 * disagree, the port is wrong.
 *
 * The file is loaded exactly as the browser ships it — evaluated as a classic
 * script in a fresh VM global — but with a CommonJS `module.exports` shim in
 * that global so the UMD wrapper's node branch runs and the suite can drive the
 * exported API.
 */

interface LocalFields {
  y: number;
  mo: number;
  d: number;
  h: number;
  mi: number;
  s: number;
}

type SoundTone = 'alarm' | 'chime' | 'digital';

interface AlarmMetadata {
  sound_tone?: SoundTone;
  ramp_seconds?: number;
  description?: string;
}

interface IntervalSpec {
  count: number;
  unit: 'days' | 'weeks';
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
  status: 'supported' | 'target';
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

interface ParsedTime {
  targetTime: Date;
  repeatDays: number[];
  interpretation: string;
  alarm?: AlarmMetadata;
  interval?: IntervalSpec;
}

interface NLTimeApi {
  parseTime(input: string, now?: Date): ParsedTime;
  parseLeadingTime(input: string, now?: Date): { parsed: ParsedTime; rest: string } | null;
  TimeParseError: new (
    message?: string,
    token?: string,
    reason?: string
  ) => Error & { token?: string; reason?: string };
}

/** Updated by each task as it flips `target` ids into `fixtures/nl-corpus-asserted.json`. */
const EXPECTED_REMAINING_TARGETS = 41;

/**
 * Walk upward from the working directory until `relativePath` is found, so the
 * suite works whether it runs from `backend` or the repo root. A missing fixture
 * is a hard failure, never a silent skip.
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

/** Absolute path to the shipped port; this suite never modifies the file. */
const nlTimePath = fileURLToPath(new URL('../public/nl-time.js', import.meta.url));
const source = readFileSync(nlTimePath, 'utf8');

/**
 * Evaluate `nl-time.js` as a classic script in a fresh VM global carrying both a
 * `window` (its browser root) and a `module.exports` shim (the UMD node branch),
 * then hand back the exported API.
 */
function loadNLTime(): NLTimeApi {
  const sandbox: { module: { exports: unknown }; window: unknown } = {
    module: { exports: {} },
    window: {},
  };
  // In a browser `window` is the global object; mirror that here.
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return sandbox.module.exports as NLTimeApi;
}

const NLTime = loadNLTime();

const corpusPath = findFixture(join('fixtures', 'nl-corpus.json'), process.cwd());
const corpus = JSON.parse(readFileSync(corpusPath, 'utf8')) as Corpus;

const manifestPath = findFixture(join('fixtures', 'nl-corpus-asserted.json'), process.cwd());
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as AssertedManifest;
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
 * Map the port's structured output onto the corpus's flat expectation keys.
 * `[...parsed.repeatDays]` re-homes the vm-realm array onto the host Array
 * prototype so `deepEqual` compares values, not realms.
 */
function assertExpected(parsed: ParsedTime, rest: string, expected: Expected): void {
  assertLocal(parsed.targetTime, expected.local!);
  assert.deepEqual([...parsed.repeatDays], expected.repeatDays);
  assert.equal(rest, expected.label);
  if (expected.intervalWeeks !== undefined) {
    assert.deepEqual(parsed.interval, { count: expected.intervalWeeks, unit: 'weeks' });
  } else if (expected.intervalDays !== undefined) {
    assert.deepEqual(parsed.interval, { count: expected.intervalDays, unit: 'days' });
  } else {
    assert.equal(parsed.interval, undefined);
  }
  if (expected.alarm) {
    assert.deepEqual(parsed.alarm, expected.alarm);
  } else {
    assert.equal(parsed.alarm, undefined);
  }
}

describe('nl-time.js — nl-corpus full resolution (shared fixture)', () => {
  for (const testCase of corpus.cases) {
    const asserted =
      testCase.status === 'supported' || assertedTargetIds.includes(testCase.id);
    if (!asserted) continue;

    it(`${testCase.id} — ${testCase.input}`, () => {
      if (testCase.expected.invalid === true) {
        assert.throws(
          () => NLTime.parseTime(testCase.input, new Date(testCase.now)),
          (err: unknown) => {
            assert.ok(err instanceof NLTime.TimeParseError);
            assert.equal((err as { token?: string }).token, testCase.expected.rejectedToken);
            assert.equal((err as { reason?: string }).reason, testCase.expected.reason);
            return true;
          }
        );
        return;
      }

      const split = NLTime.parseLeadingTime(testCase.input, new Date(testCase.now));
      assert.ok(split, `expected a resolution for "${testCase.input}"`);
      assertExpected(split.parsed, split.rest, testCase.expected);
    });
  }
});

describe('nl-time.js — nl-corpus tracked coverage', () => {
  it('tracks the remaining target count', () => {
    const remaining = corpus.cases.filter(
      (c) => c.status === 'target' && !assertedTargetIds.includes(c.id)
    ).length;
    assert.equal(remaining, EXPECTED_REMAINING_TARGETS);
  });
});
