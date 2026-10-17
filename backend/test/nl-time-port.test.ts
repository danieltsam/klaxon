import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

/**
 * Browser-port contract.
 *
 * `backend/public/nl-time.js` is a hand port of `clients/core/src/time.ts`
 * (the dashboard has no build step). The two must not drift, so the same
 * fixture that pins the TypeScript suite — `fixtures/time-parse-cases.json` —
 * pins this port. If this suite and clients/core's disagree, the port is wrong.
 *
 * The file is loaded exactly as the browser ships it — evaluated as a classic
 * script in a fresh VM global — but with a CommonJS `module.exports` shim in
 * that global so the UMD wrapper's node branch runs and the suite can drive the
 * exported API. This needs no `public/package.json` marker (which would
 * otherwise be publicly served at `/package.json`), and leaves `nl-time.js`
 * itself untouched.
 */

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
  days: number[];
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
  cases: ValidCase[];
  invalid: InvalidCase[];
  leading: LeadingCase[];
  leadingNull: string[];
  interpretation: InterpretationCase[];
}

interface ParsedTime {
  targetTime: Date;
  repeatDays: number[];
  interpretation: string;
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

/**
 * Walk upward from the working directory until the fixture is found, so the
 * suite works whether it runs from `backend` or the repo root. A missing fixture
 * is a hard failure, never a silent skip.
 */
function findFixture(startDir: string): string {
  let dir = startDir;
  for (;;) {
    const candidate = join(dir, 'fixtures', 'time-parse-cases.json');
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

/** Absolute path to the shipped port; this suite never modifies the file. */
const nlTimePath = fileURLToPath(new URL('../public/nl-time.js', import.meta.url));
const source = readFileSync(nlTimePath, 'utf8');

/**
 * Evaluate `nl-time.js` as a classic script in a fresh VM global carrying both a
 * `window` (its browser root) and a `module.exports` shim (the UMD node branch),
 * then hand back the exported API. Unlike `require()` this never consults a
 * `public/package.json`, so that marker stays deleted and `/package.json` is no
 * longer served.
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

// The same vm path the shape test below exercises, used to drive every case.
const NLTime = loadNLTime();

const fixturePath = findFixture(process.cwd());
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as Fixture;

function assertLocal(date: Date, expect: ExpectFields): void {
  assert.equal(date.getFullYear(), expect.y, `year of ${date.toISOString()}`);
  assert.equal(date.getMonth() + 1, expect.mo, `month of ${date.toISOString()}`);
  assert.equal(date.getDate(), expect.d, `day of ${date.toISOString()}`);
  assert.equal(date.getHours(), expect.h, `hours of ${date.toISOString()}`);
  assert.equal(date.getMinutes(), expect.mi, `minutes of ${date.toISOString()}`);
  assert.equal(date.getSeconds(), expect.s, `seconds of ${date.toISOString()}`);
}

describe('nl-time.js — exported shape', () => {
  it('exposes parseTime, parseLeadingTime and TimeParseError via the vm module shim', () => {
    assert.equal(typeof NLTime.parseTime, 'function');
    assert.equal(typeof NLTime.parseLeadingTime, 'function');
    assert.equal(typeof NLTime.TimeParseError, 'function');
  });

  it('exposes window.NLTime when evaluated as a classic browser script', () => {
    const window: Record<string, unknown> = {};
    const sandbox = { window };
    vm.runInNewContext(source, sandbox);
    const browserApi = window.NLTime as NLTimeApi;
    assert.equal(typeof browserApi.parseTime, 'function');
    assert.equal(typeof browserApi.parseLeadingTime, 'function');
    assert.equal(typeof browserApi.TimeParseError, 'function');
    const parsed = browserApi.parseTime('25m', new Date('2026-09-21T10:00:00'));
    // `Array.from` re-homes the vm-realm array onto the host Array prototype.
    assert.deepEqual(Array.from(parsed.repeatDays), []);
    assert.equal(parsed.targetTime.getHours(), 10);
    assert.equal(parsed.targetTime.getMinutes(), 25);
  });
});

describe('nl-time.js — grammar table (shared fixture)', () => {
  for (const testCase of fixture.cases) {
    it(`parses "${testCase.name}"`, () => {
      const parsed = NLTime.parseTime(testCase.input, new Date(testCase.now));
      assertLocal(parsed.targetTime, testCase.expect);
      // `Array.from` re-homes the vm-realm array onto the host Array prototype.
      assert.deepEqual(Array.from(parsed.repeatDays), testCase.days);
    });
  }
});

describe('nl-time.js — invalid input (shared fixture)', () => {
  for (const testCase of fixture.invalid) {
    it(`rejects "${testCase.input}" naming the token`, () => {
      assert.throws(
        () => NLTime.parseTime(testCase.input, new Date(testCase.now)),
        (err: unknown) => {
          assert.ok(err instanceof NLTime.TimeParseError);
          assert.equal((err as { token?: string }).token, testCase.token);
          assert.equal((err as { reason?: string }).reason, 'unparseable');
          assert.match(
            (err as Error).message,
            new RegExp(testCase.token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
          );
          return true;
        }
      );
    });
  }

  it('rejects empty input', () => {
    assert.throws(() => NLTime.parseTime('', new Date('2026-09-21T10:00:00')), NLTime.TimeParseError);
    assert.throws(() => NLTime.parseTime('   ', new Date('2026-09-21T10:00:00')), NLTime.TimeParseError);
  });
});

describe('nl-time.js — TimeParseError refusal reason', () => {
  it('carries an already_passed refusal reason', () => {
    const err = new NLTime.TimeParseError('Already passed.', 'this friday', 'already_passed');
    assert.equal(err.token, 'this friday');
    assert.equal(err.reason, 'already_passed');
    assert.equal(new NLTime.TimeParseError('x', 'y').reason, 'unparseable');
  });
});

describe('nl-time.js — parseLeadingTime (shared fixture)', () => {
  for (const testCase of fixture.leading) {
    it(testCase.name, () => {
      const split = NLTime.parseLeadingTime(testCase.input, new Date(testCase.now));
      assert.ok(split);
      assertLocal(split.parsed.targetTime, testCase.expect);
      assert.equal(split.rest, testCase.rest);
    });
  }

  it('returns null when no prefix parses', () => {
    for (const input of fixture.leadingNull) {
      assert.equal(NLTime.parseLeadingTime(input, new Date('2026-09-21T10:00:00')), null);
    }
  });
});

describe('nl-time.js — interpretation echo (shared fixture)', () => {
  for (const testCase of fixture.interpretation) {
    it(testCase.name, () => {
      const parsed = NLTime.parseTime(testCase.input, new Date(testCase.now));
      assert.equal(parsed.interpretation, testCase.interpretation);
    });
  }
});

describe('nl-time.js — bare-integer clock guard', () => {
  it('allows a lone integer as the whole expression', () => {
    const parsed = NLTime.parseTime('7', new Date('2026-09-21T10:00:00'));
    assertLocal(parsed.targetTime, { y: 2026, mo: 9, d: 22, h: 7, mi: 0, s: 0 });
  });
  it('never selects a bare integer inside a phrase', () => {
    assert.equal(NLTime.parseLeadingTime('foo 5 bar', new Date('2026-09-21T10:00:00')), null);
    assert.equal(NLTime.parseLeadingTime('call at 5', new Date('2026-09-21T10:00:00')), null);
  });
});
