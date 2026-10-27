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
  alarm?: AlarmMetadata;
}

interface AlarmMetadata {
  sound_tone?: string;
  ramp_seconds?: number;
  description?: string;
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

describe('nl-time.js — metadata pre-pass (spec §5.1/§8)', () => {
  it('never parses a time token that follows note:', () => {
    const split = NLTime.parseLeadingTime(
      'tomorrow 7am note: call at 6pm',
      new Date('2026-09-21T10:00:00')
    );
    assert.ok(split);
    // The `6pm` is note text, not the clock: the alarm stays at 07:00.
    assertLocal(split.parsed.targetTime, { y: 2026, mo: 9, d: 22, h: 7, mi: 0, s: 0 });
    assert.equal(split.rest, '');
    // `{ ...parsed.alarm }` re-homes the vm-realm object onto the host prototype.
    assert.deepEqual({ ...split.parsed.alarm }, { description: 'call at 6pm' });

    const parsed = NLTime.parseTime(
      'tomorrow 7am note: call at 6pm',
      new Date('2026-09-21T10:00:00')
    );
    assertLocal(parsed.targetTime, { y: 2026, mo: 9, d: 22, h: 7, mi: 0, s: 0 });
    assert.deepEqual({ ...parsed.alarm }, { description: 'call at 6pm' });
  });

  it('keeps note: text verbatim (original casing)', () => {
    const parsed = NLTime.parseTime(
      'tomorrow 7am note: Call Mom at 6PM',
      new Date('2026-09-21T10:00:00')
    );
    assert.deepEqual({ ...parsed.alarm }, { description: 'Call Mom at 6PM' });
  });

  it('extracts a metadata keyword used as label text', () => {
    const split = NLTime.parseLeadingTime(
      'chime practice tomorrow 7am',
      new Date('2026-09-21T10:00:00')
    );
    assert.ok(split);
    assertLocal(split.parsed.targetTime, { y: 2026, mo: 9, d: 22, h: 7, mi: 0, s: 0 });
    assert.equal(split.rest, 'practice');
    assert.deepEqual({ ...split.parsed.alarm }, { sound_tone: 'chime' });
    // No time at all: extraction wins and nothing crashes.
    assert.equal(NLTime.parseLeadingTime('chime practice', new Date('2026-09-21T10:00:00')), null);
  });
});

/**
 * Regression locks from the final whole-branch review. Deliberate mirror of the
 * matching block in `clients/core/test/time.test.ts`: the same behaviour is also
 * pinned end-to-end by the added `fixtures/nl-corpus.json` cases, so the port and
 * the canonical TypeScript parser stay in lockstep.
 */
describe('nl-time.js — final-review regression locks', () => {
  const MON = new Date('2026-09-21T10:00:00');
  const SAT = new Date('2026-09-26T10:00:00'); // Saturday: this week's Friday has passed

  it('keeps the bare-integer guard in the clock -> date branch', () => {
    const meeting = NLTime.parseLeadingTime('meeting 5 10/31', MON);
    assert.ok(meeting);
    assertLocal(meeting.parsed.targetTime, { y: 2026, mo: 10, d: 31, h: 0, mi: 0, s: 0 });
    assert.equal(meeting.rest, 'meeting 5');

    const buy = NLTime.parseLeadingTime('buy 2 10/31', MON);
    assert.ok(buy);
    assertLocal(buy.parsed.targetTime, { y: 2026, mo: 10, d: 31, h: 0, mi: 0, s: 0 });
    assert.equal(buy.rest, 'buy 2');

    const foo = NLTime.parseLeadingTime('foo 5 dec 25', MON);
    assert.ok(foo);
    assertLocal(foo.parsed.targetTime, { y: 2026, mo: 12, d: 25, h: 0, mi: 0, s: 0 });
    assert.equal(foo.rest, 'foo 5');
  });

  it('still accepts a bare integer as the whole clock -> date expression', () => {
    const split = NLTime.parseLeadingTime('2 10/31', MON);
    assert.ok(split);
    assertLocal(split.parsed.targetTime, { y: 2026, mo: 10, d: 31, h: 2, mi: 0, s: 0 });
    assert.equal(split.rest, '');
  });

  it('fails loudly on an unreadable `every` instead of a bare weekday', () => {
    assert.equal(NLTime.parseLeadingTime('every 3rd monday', MON), null);
    assert.throws(
      () => NLTime.parseTime('every 3rd monday', MON),
      (err: unknown) => {
        assert.ok(err instanceof NLTime.TimeParseError);
        assert.equal((err as { token?: string }).token, 'every');
        return true;
      }
    );
  });

  it("refuses `this weekend` once the current week's Saturday has gone", () => {
    const sunday = new Date('2026-09-27T10:00:00');
    for (const now of [SAT, sunday]) {
      assert.throws(
        () => NLTime.parseTime('this weekend', now),
        (err: unknown) => {
          assert.ok(err instanceof NLTime.TimeParseError);
          assert.equal((err as { reason?: string }).reason, 'already_passed');
          assert.equal((err as { token?: string }).token, 'this weekend');
          return true;
        }
      );
    }
  });

  it('resolves a passed `this <weekday>` via a valid trailing time', () => {
    const split = NLTime.parseLeadingTime('this friday gym tomorrow 7am', SAT);
    assert.ok(split);
    assertLocal(split.parsed.targetTime, { y: 2026, mo: 9, d: 27, h: 7, mi: 0, s: 0 });
    assert.equal(split.rest, 'this friday gym');
  });

  it('still throws already_passed for a confident bare `this <weekday>`', () => {
    assert.throws(
      () => NLTime.parseLeadingTime('this friday', SAT),
      (err: unknown) => {
        assert.ok(err instanceof NLTime.TimeParseError);
        assert.equal((err as { reason?: string }).reason, 'already_passed');
        assert.equal((err as { token?: string }).token, 'this friday');
        return true;
      }
    );
  });

  it('honours an explicit past ISO year and anchors a date + period', () => {
    const past = NLTime.parseLeadingTime('2020-01-01', MON);
    assert.ok(past);
    assertLocal(past.parsed.targetTime, { y: 2020, mo: 1, d: 1, h: 0, mi: 0, s: 0 });

    const period = NLTime.parseLeadingTime('dec 25 noon', MON);
    assert.ok(period);
    assertLocal(period.parsed.targetTime, { y: 2026, mo: 12, d: 25, h: 12, mi: 0, s: 0 });
  });
});

describe('browser port — clock followed by a day qualifier', () => {
  const now = new Date(2026, 9, 27, 22, 0, 0, 0);

  it('joins `1:45 p.m. tomorrow` and leaves no label', () => {
    const split = NLTime.parseLeadingTime('1:45 p.m. tomorrow', now);
    assert.ok(split);
    assert.equal(split.rest, '');
    assert.equal(split.parsed.targetTime.getDate(), 28);
    assert.equal(split.parsed.targetTime.getHours(), 13);
    assert.equal(split.parsed.targetTime.getMinutes(), 45);
  });

  it('understands `day after tomorrow`', () => {
    const split = NLTime.parseLeadingTime('day after tomorrow 6:30am', now);
    assert.ok(split);
    assert.equal(split.parsed.targetTime.getDate(), 29);
    assert.equal(split.parsed.targetTime.getHours(), 6);
  });

  it('understands a spoken offset', () => {
    const split = NLTime.parseLeadingTime('in two days gym', now);
    assert.ok(split);
    assert.equal(split.rest, 'gym');
    assert.equal(split.parsed.targetTime.getDate(), 29);
  });
});
