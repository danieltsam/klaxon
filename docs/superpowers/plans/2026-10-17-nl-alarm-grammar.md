# Natural-Language Alarm Grammar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the natural-language time parser so all 169 cases in `fixtures/nl-corpus.json` resolve exactly as the corpus specifies, and every input it cannot resolve confidently fails loudly with a `TimeParseError` that names the offending token and a `reason`.

**Architecture:** Grow the existing longest-leading-prefix → span-fallback ladder (`clients/core/src/time.ts`) with three new stages: a metadata pre-pass (§5.1), new grammar matchers (durations/offsets, absolute dates, day periods, `next`/`this`, intervals) slotted into `tryParseExpression`, and a new split-anchor fallback (§5.4 stage 3). A shared corpus runner asserts the full `expected` shape against **both** implementations — the canonical TypeScript parser and the hand port `backend/public/nl-time.js` — which change in lockstep, task by task.

**Tech Stack:** TypeScript (ESM, `.js` import specifiers) in `clients/core`; `node:test` + `node:assert/strict` via `tsx --test`; the no-build browser port in `backend/public/nl-time.js` loaded through a `vm` shim by `backend/test/*.test.ts`. No new runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-10-17-nl-alarm-grammar-design.md` (§5–§12). This plan covers **the parser only**.

## Out of scope (do not build in this plan)

These are decided in the spec but belong to follow-on plans. Do not touch them here:

- **Backend interval storage** — the general interval column (`recurrence_interval_days`), the migration, `repeat_days` derivation from the anchor, and the `reject a lone integer outside 0–23` server rule (spec §7, §13 `server.ts`/`db.ts`). **The parser may emit `interval` fields; storing them is not this plan's concern.**
- **Google Calendar mirror `FREQ=DAILY;INTERVAL=n`** (spec §7).
- **Mobile `getNextOccurrence` day-interval handling** (spec §7).
- **Dashboard confirm-step layout and metadata chips** (spec §9, §15) — partly a design job; the parser does not emit `ambiguities` in this plan.
- **`ambiguities` emission** (`ParsedTime.ambiguities`, the `Ambiguity` type) — only the confirm step consumes it, and no corpus case asserts it. Deferred to the confirm-step plan.
- CLI / Raycast / README changes (they consume `core`; no new grammar).

## Global Constraints

- **`clients/core` stays dependency-free.** No new runtime dependencies (spec §2, `clients-cli-raycast-design.md` §4.2). No Node-24+ APIs — use `Date`, `Number.isInteger`, `String.prototype.padStart`, `Array.prototype.includes`.
- **Local wall-clock `Date` contract.** The parser produces a local wall-clock `Date`; UTC conversion happens only at the client boundary via `.toISOString()`. Unchanged (spec §2).
- **Both implementations in lockstep.** Every grammar change lands in `clients/core/src/time.ts` **and** `backend/public/nl-time.js` in the same change. `nl-time.js` is a **verbatim** translation (`nl-time.js:1-25`); any behavioural divergence is a bug. Every task's Files list includes the port.
- **Two fixtures, one grammar.** `fixtures/time-parse-cases.json` pins the mechanical grammar (asserted by `clients/core/test/time.test.ts:127-146` and `backend/test/nl-time-port.test.ts:163-222`). `fixtures/nl-corpus.json` is the end-to-end acceptance list (169 cases). Add a case to `time-parse-cases.json` only where the corpus does not cover the mechanical boundary.
- **Never edit a corpus case's `expected` to make a test pass.** If a case is wrong, raise it as a corpus defect (spec §12.2).
- **Corpus `now` is a local wall-clock ISO date-time without an offset** — ECMAScript parses those as local, keeping the corpus timezone-portable. Read it with `new Date(case.now)`.
- **Test runners:** core tests run from `clients/core` (`npm test` → `tsx --test test/**/*.test.ts`); backend tests run from `backend` (`npm test` → `NODE_ENV=test DB_PATH=:memory: GCAL_ENABLED=false tsx --test test/**/*.test.ts`; one file via `npm run test:one test/<file>.test.ts`). `run_tests.sh` runs backend as step [1/3] (`run_tests.sh:11-13`) and clients as step [3/3] (`run_tests.sh:21-23`); CI runs the same two `npm test` commands (`.github/workflows/ci.yml:14-29`, `:51-65`). Both `test/**/*.test.ts` globs already match files placed directly under `test/`, so no new wiring is needed — Task 2 verifies this.
- **The tracked target count.** `fixtures/nl-corpus-asserted.json` lists the corpus `target` ids currently asserted (it grows one task at a time). Each runner asserts the remaining-target count against a constant `EXPECTED_REMAINING_TARGETS`, updated per task. Remaining after each task: T2=63, T3=63, T4=56, T5=41, T6=31, T7=21, T8=14, T9=1, T10=0.

## Review Focus

Input classes the spec implies but **no task's corpus cases cover**. Each names the task that must handle it.

1. **A time token inside `note:` text.** `tomorrow 7am note: call at 6pm` — `note:` consumes to the end of input verbatim (spec §5.1), so the `6pm` must never become the clock; the target is tomorrow 07:00 and the description is `call at 6pm`. No corpus case has a time inside the note. → **Task 9.**
2. **`last <weekday>` / `last week` / `last month`.** `last` is **not** a grammar token (spec §6.3, decision 3): `last friday` resolves forward-only to the next Friday with `last` left in the label, and `last week`/`last month` are not recognized. The old case was removed from the corpus. → **Task 7.**
3. **A metadata keyword used as label text.** `chime practice` — extraction always wins today's design (spec §9/Q1), so the label becomes `practice`; the ambiguity is *not* surfaced in this plan. Must not crash or double-consume. → **Task 9.**
4. **Calendar boundaries for `next month` and `this weekend`.** `next month` from 31 Jan must not overflow into March (spec §6.3: "same wall-clock +1 calendar month"), and `this weekend` when `now` is already Saturday or Sunday must anchor deterministically to the coming Saturday. No corpus case exercises either. → **Task 7.**
5. **An explicit past ISO year.** `2020-01-01` — an explicit year is honoured verbatim including a past year (spec §6.4); the §9 futurity check is deferred, so the parser must **not** silently roll it to next year (the silent-mis-parse failure mode). → **Task 5.**

---

### Task 1: `TimeParseError.reason` — the refusal model

**Files:**
- Modify: `clients/core/src/errors.ts:50-60`
- Modify: `backend/public/nl-time.js:42-49`
- Test: `clients/core/test/time.test.ts` (invalid loop at `:169-188`)
- Test: `backend/test/nl-time-port.test.ts` (invalid loop at `:174-196`)

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `export type RefusalReason = "unparseable" | "already_passed"` (in `errors.ts`, re-exported via `index.ts`'s `export * from "./errors.js"`).
  - `TimeParseError` constructor becomes `constructor(message: string, token?: string, reason: RefusalReason = "unparseable")`, with a public `reason: RefusalReason` property. The default keeps every existing `new TimeParseError(msg, token)` call working unchanged.
- The corpus `invalid` cases (including their `reason`) are asserted by the runner built in **Task 2**; this task pins the field against `fixtures/time-parse-cases.json` and a direct construction.

- [ ] **Step 1: Write the failing test**

Add to `clients/core/test/time.test.ts` (inside the existing `describe("parseTime — invalid input (shared fixture)")` loop, after the `err.token` assertion at `:176`):

```ts
assert.equal(err.reason, "unparseable");
```

Add a new test below that describe:

```ts
it("carries an already_passed refusal reason", () => {
  const err = new TimeParseError("Already passed.", "this friday", "already_passed");
  assert.equal(err.token, "this friday");
  assert.equal(err.reason, "already_passed");
  assert.equal(new TimeParseError("x", "y").reason, "unparseable");
});
```

Mirror the loop assertion in `backend/test/nl-time-port.test.ts:174-196` (`assert.equal((err as { reason?: string }).reason, "unparseable")`) and add the same construction test against `NLTime.TimeParseError`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/core && npx tsx --test test/time.test.ts`
Expected: FAIL — `err.reason` is `undefined` (property not yet declared).

- [ ] **Step 3: Implement**

In `clients/core/src/errors.ts`, add `export type RefusalReason = "unparseable" | "already_passed";` and change the class to:

```ts
export class TimeParseError extends Error {
  token?: string;
  reason: RefusalReason;
  constructor(message: string, token?: string, reason: RefusalReason = "unparseable") {
    super(message);
    this.name = "TimeParseError";
    this.token = token;
    this.reason = reason;
    Object.setPrototypeOf(this, new.target.prototype);
  }
}
```

In `backend/public/nl-time.js:43-49`, mirror verbatim: `constructor(message, token, reason) { ...; this.reason = reason === undefined ? "unparseable" : reason; }`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd clients/core && npm test` then `cd backend && npm run test:one test/nl-time-port.test.ts`
Expected: PASS — all existing invalid cases now also assert `.reason === "unparseable"`.

- [ ] **Step 5: Commit**

```bash
git add clients/core/src/errors.ts backend/public/nl-time.js clients/core/test/time.test.ts backend/test/nl-time-port.test.ts
git commit -m "feat(core): add TimeParseError.reason refusal model"
```

---

### Task 2: The corpus runner (both implementations) + tracked target count

**Files:**
- Create: `fixtures/nl-corpus-asserted.json`
- Create: `clients/core/test/nl-corpus.test.ts`
- Create: `backend/test/nl-corpus-port.test.ts`
- Modify: `clients/core/src/time.ts:22-29` (extend `ParsedTime`)
- Modify: `backend/public/nl-time.js` (no behavioural change; the port's returned objects already tolerate the new optional fields)

**Interfaces:**
- Consumes: `parseTime`, `parseLeadingTime`, `TimeParseError` (core, `../src/index.js`); `NLTime.parseTime` / `NLTime.parseLeadingTime` / `NLTime.TimeParseError` (port, via the `vm` shim copied from `nl-time-port.test.ts:113-126`); `RefusalReason` (Task 1).
- Produces:
  - `export type AlarmMetadata = { sound_tone?: SoundTone; ramp_seconds?: number; description?: string }` (in `time.ts`; `SoundTone` from `./types.js`).
  - `export interface IntervalSpec { count: number; unit: "days" | "weeks" }` (in `time.ts`).
  - `ParsedTime` gains `alarm?: AlarmMetadata; interval?: IntervalSpec` (spec §9). `ambiguities` is deliberately **not** added (out of scope).
  - `fixtures/nl-corpus-asserted.json` with shape `{ "assertedTargetIds": string[] }` — the single source of truth for which `target` ids are asserted; read by both runners.
  - The runner assertion helper (below), used by every later task to flip ids.

- [ ] **Step 1: Write the runner asserting the whole corpus (will be red)**

Create `clients/core/test/nl-corpus.test.ts`. It loads `fixtures/nl-corpus.json` by walking upward from `process.cwd()` (copy the `findFixture` pattern from `time.test.ts:112-125`; a missing fixture is a hard failure). Define:

```ts
interface LocalFields { y: number; mo: number; d: number; h: number; mi: number; s: number }
interface Expected {
  local: LocalFields | null; repeatDays: number[] | null; label: string | null;
  invalid?: true; rejectedToken?: string; reason?: string;
  intervalWeeks?: number; intervalDays?: number; alarm?: AlarmMetadata;
}
interface CorpusCase { id: string; category: string; input: string; now: string; status: "supported" | "target"; trap?: boolean; expected: Expected }
```

The full-shape assertion (map the parser's structured output onto the corpus's flat keys):

```ts
function assertExpected(parsed: ParsedTime, rest: string, expected: Expected): void {
  assertLocal(parsed.targetTime, expected.local!);
  assert.deepEqual([...parsed.repeatDays], expected.repeatDays);
  assert.equal(rest, expected.label);
  if (expected.intervalWeeks !== undefined) assert.deepEqual(parsed.interval, { count: expected.intervalWeeks, unit: "weeks" });
  else if (expected.intervalDays !== undefined) assert.deepEqual(parsed.interval, { count: expected.intervalDays, unit: "days" });
  else assert.equal(parsed.interval, undefined);
  if (expected.alarm) assert.deepEqual(parsed.alarm, expected.alarm);
  else assert.equal(parsed.alarm, undefined);
}
```

The routing, one `it` per case (name it `` `${c.id} — ${c.input}` ``):

- `expected.invalid === true` → `assert.throws(() => parseTime(c.input, new Date(c.now)), (err) => { assert.ok(err instanceof TimeParseError); assert.equal(err.token, c.expected.rejectedToken); assert.equal(err.reason, c.expected.reason); return true; })`.
- otherwise → `const split = parseLeadingTime(c.input, new Date(c.now)); assert.ok(split); assertExpected(split.parsed, split.rest, c.expected)`.

Selection (the tracked count): assert `supported` cases always; assert `target` cases only when their `id` is in `assertedTargetIds`; count the rest. Add:

```ts
it("tracks the remaining target count", () => {
  const remaining = corpus.cases.filter((c) => c.status === "target" && !assertedTargetIds.includes(c.id)).length;
  assert.equal(remaining, EXPECTED_REMAINING_TARGETS);
});
```

with `const EXPECTED_REMAINING_TARGETS = 63;` at the top (updated by each later task).

Create `fixtures/nl-corpus-asserted.json`:

```json
{ "assertedTargetIds": [] }
```

Mirror the runner in `backend/test/nl-corpus-port.test.ts` using `NLTime.parseLeadingTime` / `NLTime.parseTime` / `NLTime.TimeParseError` and the same `assertExpected` logic (`[...parsed.repeatDays]` re-homes the vm-realm array, as at `nl-time-port.test.ts:168-169`); it reads the **same** `fixtures/nl-corpus.json` and `fixtures/nl-corpus-asserted.json`, and carries the same `EXPECTED_REMAINING_TARGETS`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/core && npx tsx --test test/nl-corpus.test.ts`
Expected: FAIL — 63 `target` cases fail their `expected` shape (the expansion is not built yet); the 106 `supported` and 6 `inv-*` cases pass.

- [ ] **Step 3: Implement the tracked-count mechanism**

Introduce the manifest read (walk upward for `fixtures/nl-corpus-asserted.json`, same pattern) and gate `target` cases on `assertedTargetIds`. Extend `ParsedTime` in `clients/core/src/time.ts:22-29`:

Extend the existing `import type { Weekday } from "./types.js";` (`time.ts:20`) to also import `SoundTone`, then in `clients/core/src/time.ts:22-29`:

```ts
export type AlarmMetadata = { sound_tone?: SoundTone; ramp_seconds?: number; description?: string };
export interface IntervalSpec { count: number; unit: "days" | "weeks" }
export interface ParsedTime {
  targetTime: Date; repeatDays: Weekday[]; interpretation: string;
  alarm?: AlarmMetadata; interval?: IntervalSpec;
}
```

(Keep `IntervalSpec` exactly `{ count: number; unit: "days" | "weeks" }`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd clients/core && npx tsx --test test/nl-corpus.test.ts` then `cd backend && npm run test:one test/nl-corpus-port.test.ts`
Expected: PASS — 106 supported + 6 `inv-*` asserted, `remaining === 63`, both implementations agree.

Then verify discovery/wiring: `cd /Users/dsam/Documents/remote-alarm && ./run_tests.sh` — the new suites run inside steps [1/3] and [3/3] (no script edit needed).

- [ ] **Step 5: Commit**

```bash
git add fixtures/nl-corpus-asserted.json clients/core/test/nl-corpus.test.ts backend/test/nl-corpus-port.test.ts clients/core/src/time.ts
git commit -m "test(core): add nl-corpus runner for both implementations with tracked target count"
```

---

### Task 3: Bare-integer clock guard (trap guards)

**Files:**
- Modify: `clients/core/src/time.ts:63-68` (`Clock`), `:215-247` (`parseClock`), `:337-390` (`tryParseExpression`), `:429-453` (`findTimeSpan`), `:462-479` (`parseLeadingTime`), `:396-421` (`parseTime`)
- Modify: `backend/public/nl-time.js:220-252`, `:325-378`, `:414-434`, `:443-459`, `:384-405`
- Test: `clients/core/test/time.test.ts` (new `describe`)
- Test: `backend/test/nl-time-port.test.ts` (mirror)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `interface Clock { hours: number; minutes: number; next: number; bare: boolean }` — `bare` is true only for the bare-integer form (`7`, no meridiem, no colon).
  - `function tryParseExpression(toks: string[], now: Date, allowBareIntegerClock: boolean): ParsedTime | null` (new third parameter).
- **Rule (spec §5.4/§11 #6):** a bare-integer clock is a valid expression **only** when the token slice is the entire input. Top-level `parseTime`/`parseLeadingTime` calls on the full token array pass `allowBareIntegerClock = true`; every prefix slice and every span-search call passes `false`.

- [ ] **Step 1: Write the failing test**

Add to `clients/core/test/time.test.ts`:

```ts
describe("bare-integer clock guard", () => {
  it("allows a lone integer as the whole expression", () => {
    assertLocal(parseTime("7", MON_10).targetTime, 2026, 9, 22, 7, 0);
  });
  it("never selects a bare integer inside a phrase", () => {
    assert.equal(parseLeadingTime("foo 5 bar", MON_10), null);
    assert.equal(parseLeadingTime("call at 5", MON_10), null);
  });
});
```

Mirror both in `backend/test/nl-time-port.test.ts` with `NLTime.parseTime` / `NLTime.parseLeadingTime`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/core && npx tsx --test test/time.test.ts`
Expected: FAIL — `foo 5 bar` / `call at 5` currently resolve to a bare-integer clock (03:00/05:00 with a label).

- [ ] **Step 3: Implement**

In `parseClock`, set `bare: true` on the bare-integer branch (`time.ts:238-244`) and `bare: false` on the meridiem and colon branches. Thread `allowBareIntegerClock` through `tryParseExpression` and accept a clock only when `clock.next === toks.length && (!clock.bare || allowBareIntegerClock)`. Update the four call sites: `parseTime`/`parseLeadingTime` pass `true` for the full-token call and `false` for slices; `findTimeSpan` passes `false` for every span. Mirror verbatim in the port.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd clients/core && npm test` then `cd backend && npm run test:one test/nl-time-port.test.ts`
Expected: PASS — new guards green, all 106 supported corpus cases and both fixture suites still green.

- [ ] **Step 5: Commit**

```bash
git add clients/core/src/time.ts backend/public/nl-time.js clients/core/test/time.test.ts backend/test/nl-time-port.test.ts
git commit -m "fix(core): a bare integer is a clock only as the whole expression"
```

---

### Task 4: Durations and day/week offsets

**Files:**
- Modify: `clients/core/src/time.ts:249-263` (`parseDuration` area), `:337-390` (`tryParseExpression`)
- Modify: `backend/public/nl-time.js:254-270`, `:325-378`
- Test: `clients/core/test/nl-corpus.test.ts` + `fixtures/nl-corpus-asserted.json` (append ids, update `EXPECTED_REMAINING_TARGETS` to `56`)
- Test: `backend/test/nl-corpus-port.test.ts` (same)

**Interfaces:**
- Consumes: the bare-integer guard (Task 3), `IntervalSpec`/`AlarmMetadata`/`ParsedTime` (Task 2).
- Produces: `function parseDayWeekOffset(toks: string[], i: number): { days: number; next: number } | null` — reads `<n> days|day`, `<n> weeks|week`, `<n>w`, `<n>d`, concatenated (`1w 2d`, `1w2d`), optionally led by the `in` connector and optionally followed by `from now`. `days = weeks*7 + days`. Resolution preserves wall-clock via `candidate.setDate(candidate.getDate() + days)` (spec §6.6), **never** ms arithmetic.
- Flips 7 target cases: `dur-in-3-days`, `dur-in-1-day`, `dur-in-2-weeks`, `dur-2-weeks-from-now`, `dur-in-1w-2d`, `dur-3-days-bare`, `dur-2-weeks-bare`.

- [ ] **Step 1: Write the failing test (flip the corpus ids)**

Add to `fixtures/nl-corpus-asserted.json`:

```json
{ "assertedTargetIds": ["dur-in-3-days","dur-in-1-day","dur-in-2-weeks","dur-2-weeks-from-now","dur-in-1w-2d","dur-3-days-bare","dur-2-weeks-bare"] }
```

These assert the corpus `expected`; e.g. `dur-in-3-days` from `2026-09-21T10:00:00` → `{ local: {y:2026,mo:9,d:24,h:10,mi:0,s:0}, repeatDays: [], label: "" }` (and the trap cases must **not** read the number as a clock: `dur-2-weeks-bare` → 2026-10-05 10:00, label `""`, not 02:00 with label `weeks`). Update `EXPECTED_REMAINING_TARGETS` to `56` in both runners.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/core && npx tsx --test test/nl-corpus.test.ts`
Expected: FAIL — the 7 new ids fail (`in 3 days` currently resolves to tomorrow 03:00 label `days`).

- [ ] **Step 3: Implement**

Add `parseDayWeekOffset` (above) and, in `tryParseExpression`, before the clock branch, try the offset when there is no day qualifier and no recurrence (mirroring the existing duration branch at `time.ts:374-381`). Day/week units must **not** be added to `parseDuration`'s h/m/s regex. Mirror verbatim in the port.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd clients/core && npm test` then `cd backend && npm test`
Expected: PASS — 113 of 169 asserted, `remaining === 56`.

- [ ] **Step 5: Commit**

```bash
git add clients/core/src/time.ts backend/public/nl-time.js clients/core/test/nl-corpus.test.ts backend/test/nl-corpus-port.test.ts fixtures/nl-corpus-asserted.json
git commit -m "feat(core): parse day/week durations and offsets"
```

---

### Task 5: Absolute dates (and clock↔date joining)

**Files:**
- Modify: `clients/core/src/time.ts` (new matcher + `tryParseExpression:337-390`)
- Modify: `backend/public/nl-time.js` (new matcher + `tryParseExpression:325-378`)
- Test: `clients/core/test/nl-corpus.test.ts` + `fixtures/nl-corpus-asserted.json` (append 15 ids, `EXPECTED_REMAINING_TARGETS` → `41`)
- Test: `backend/test/nl-corpus-port.test.ts` (same)

**Interfaces:**
- Consumes: `Clock` (Task 3), `ParsedTime` (Task 2).
- Produces:
  - `interface AbsoluteDate { month: number; day: number; year?: number }`
  - `function parseAbsoluteDate(toks: string[], i: number): { date: AbsoluteDate; next: number } | null` — `<month> <day>` (`dec 25`), `<day> <month>` (`25 dec`, `25th december`), `<month> <ordinal>` (`jan 4th`), `<d>/<m>` numeric, ISO `YYYY-MM-DD`. Month table includes short and full names; ordinals strip `st|nd|rd|th`.
  - `function parseNumericDate(token: string): { month: number; day: number } | null` — `25/12` → first field > 12 ⇒ day/month; `31/12` → day/month; `10/31` → second field > 12 ⇒ month/day; both ≤ 12 ⇒ default **day/month** (`03/04` = 3 Apr) (spec §6.5).
  - `function resolveAbsoluteDate(now: Date, date: AbsoluteDate, hours: number, minutes: number): Date` — explicit year honoured verbatim (including a **past** year; do not roll it); no year ⇒ if the resolved instant `<= now`, roll to the next year (spec §6.4).
- **Ordering is not fixed** (spec §5.4): a clock and a date may appear in either order. `tryParseExpression` must accept date→clock and clock→date, stripping `at`/`in` connectors between them.
- Flips 15 target cases: `abs-dec25-7am`, `abs-dec25`, `abs-25-dec`, `abs-25-12`, `abs-31-12`, `abs-03-04`, `abs-iso-date`, `abs-iso-9am`, `abs-jan-4th`, `abs-25th-december`, `abs-december-25`, `abs-dec25-upcoming`, `abs-dec25-passed-year`, `abs-jan1-from-dec`, `trap-5pm-date`.

- [ ] **Step 1: Write the failing test (flip the corpus ids)**

Add the 15 ids above to `fixtures/nl-corpus-asserted.json`. Headline assertions from the corpus: `abs-dec25-7am` → 2026-12-25 07:00, label `""`; `trap-5pm-date` (`5pm 10/31`) → 2026-10-31 17:00, label `""` (the date is **not** demoted to label); `abs-03-04` (`03/04`) → 2027-04-03 00:00; `abs-jan1-from-dec` (`1 jan`, now 2026-12-28) → 2027-01-01 00:00. Update `EXPECTED_REMAINING_TARGETS` to `41` in both runners.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/core && npx tsx --test test/nl-corpus.test.ts`
Expected: FAIL — the 15 new ids fail (`dec 25 7am` currently resolves to tomorrow 07:00 with label `dec 25`).

- [ ] **Step 3: Implement**

Add `parseAbsoluteDate` / `parseNumericDate` / `resolveAbsoluteDate` and slot date+clock joining into `tryParseExpression` (after qualifiers/recurrence, try date→clock, then clock→date, before the duration branch). A lone date with no clock resolves to 00:00 on that day. Mirror verbatim in the port.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd clients/core && npm test` then `cd backend && npm test`
Expected: PASS — 128 of 169 asserted, `remaining === 41`.

- [ ] **Step 5: Commit**

```bash
git add clients/core/src/time.ts backend/public/nl-time.js clients/core/test/nl-corpus.test.ts backend/test/nl-time-port.test.ts fixtures/nl-corpus-asserted.json
git commit -m "feat(core): parse absolute dates and join them to a clock"
```

---

### Task 6: Day periods

**Files:**
- Modify: `clients/core/src/time.ts` (new table + `tryParseExpression:337-390`)
- Modify: `backend/public/nl-time.js` (new table + `tryParseExpression:325-378`)
- Test: `clients/core/test/nl-corpus.test.ts` + `fixtures/nl-corpus-asserted.json` (append 10 ids, `EXPECTED_REMAINING_TARGETS` → `31`)
- Test: `backend/test/nl-time-port.test.ts` (same)

**Interfaces:**
- Consumes: `Clock` (Task 3), `DayQualifier`/`buildClockTime` (`time.ts:58-61`, `:290-319`).
- Produces:
  - `const DAY_PERIODS: Record<string, { hours: number; minutes: number }>` — `morning` 09:00, `afternoon` 15:00, `evening` 19:00, `tonight` 21:00, `noon` 12:00, `midnight` 00:00 (spec §6.2).
  - `function parseDayPeriod(toks: string[], i: number): Clock | null` — a period **is a clock** (`bare: false`), optionally prefixed `this`; a passed period rolls forward exactly like a passed clock.
- Flips 10 target cases: `per-this-afternoon`, `per-afternoon`, `per-morning`, `per-this-morning`, `per-tonight`, `per-this-evening`, `per-noon`, `per-midnight`, `day-tomorrow-morning`, `day-tomorrow-noon`.

- [ ] **Step 1: Write the failing test (flip the corpus ids)**

Add the 10 ids above to `fixtures/nl-corpus-asserted.json`. Headline assertions from the corpus: `per-morning` (`morning`, now 10:00) → 2026-09-22 09:00 (passed → next day); `per-afternoon` → 2026-09-21 15:00; `per-midnight` → 2026-09-22 00:00; `day-tomorrow-noon` → 2026-09-22 12:00. Update `EXPECTED_REMAINING_TARGETS` to `31` in both runners.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/core && npx tsx --test test/nl-corpus.test.ts`
Expected: FAIL — the 10 new ids fail (`tomorrow morning` currently resolves to tomorrow 00:00 with label `morning`).

- [ ] **Step 3: Implement**

Add `DAY_PERIODS` and `parseDayPeriod`; in `tryParseExpression`, treat a period as a clock candidate (after the explicit clock attempt), and allow `this <period>` (consume `this`, resolve as the bare period) and `tomorrow <period>` / `<date> <period>` (anchor to that day). Mirror verbatim in the port.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd clients/core && npm test` then `cd backend && npm test`
Expected: PASS — 138 of 169 asserted, `remaining === 31`.

- [ ] **Step 5: Commit**

```bash
git add clients/core/src/time.ts backend/public/nl-time.js clients/core/test/nl-corpus.test.ts backend/test/nl-time-port.test.ts fixtures/nl-corpus-asserted.json
git commit -m "feat(core): parse day periods as clock anchors"
```

---

### Task 7: `next` / `this` quantifiers and the `already_passed` refusal

**Files:**
- Modify: `clients/core/src/time.ts:58-61` (`DayQualifier`), `:180-193` (`matchDayQualifier`), `:290-319` (`buildClockTime`), `:337-390` (`tryParseExpression`)
- Modify: `backend/public/nl-time.js:190-203`, `:288-311`, `:325-378`
- Test: `clients/core/test/nl-corpus.test.ts` + `fixtures/nl-corpus-asserted.json` (append 10 ids, `EXPECTED_REMAINING_TARGETS` → `21`)
- Test: `backend/test/nl-time-port.test.ts` (same)

**Interfaces:**
- Consumes: `TimeParseError` + `RefusalReason` (Task 1), `Weekday`/`isoWeekday` (`time.ts:74-78`).
- Produces:
  - Extend `DayQualifier` with `{ kind: "this-weekday"; weekday: Weekday; token: string }`, `{ kind: "next-weekday"; weekday: Weekday }`, `{ kind: "this-weekend" }`, `{ kind: "next-week" }`, `{ kind: "next-month" }`.
  - `function matchNextThis(toks: string[], i: number): { qualifier: DayQualifier; next: number } | null` — matches `this <weekday>`, `next <weekday>`, `this weekend`, `next week`, `next month`. `last` is **not** a token (Review Focus 2).
  - `buildClockTime` handles the new kinds: `this-weekday` = that weekday in the **current Monday-start ISO week**; if the resolved instant `<= now` (including equality) throw `new TimeParseError('...', qualifier.token, "already_passed")` — never roll forward. `next-weekday` = the **next** ISO week. `this-weekend` = coming Saturday 00:00. `next-week` = `now` +7 days same wall-clock. `next-month` = `now` +1 calendar month via `setMonth(getMonth()+1)` (must not overflow month-end — Review Focus 4).
- Flips 10 target cases: `day-next-monday`, `day-next-week`, `day-next-month`, `day-this-weekend`, `wd-this-friday-future`, `wd-this-friday-passed`, `wd-this-friday-today-ahead`, `wd-this-friday-today-passed`, `wd-this-monday-passed`, `trap-next-monday-7am`.

- [ ] **Step 1: Write the failing test (flip the corpus ids)**

Add the 10 ids above to `fixtures/nl-corpus-asserted.json`. The three `already_passed` cases are `invalid: true` and route through `parseTime` (Task 2), asserting `rejectedToken === "this friday"`/`"this monday"` and `reason === "already_passed"`; e.g. `wd-this-monday-passed` (`this monday`, now Mon 21 Sep 10:00) → throws token `this monday`, reason `already_passed`. Valid headline: `day-next-monday` → 2026-09-28 00:00; `day-next-month` → 2026-10-21 10:00; `trap-next-monday-7am` → 2026-09-28 07:00, label `""`; `wd-this-friday-today-ahead` (`this friday 7pm`, now Fri 25 Sep 08:00) → 2026-09-25 19:00. Update `EXPECTED_REMAINING_TARGETS` to `21` in both runners.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/core && npx tsx --test test/nl-corpus.test.ts`
Expected: FAIL — the 10 new ids fail (`next monday 7am` currently leaves `next` in the label; `this monday` currently rolls forward instead of throwing).

- [ ] **Step 3: Implement**

Add `matchNextThis` and the new `DayQualifier` kinds; call `matchNextThis` in `tryParseExpression` before `matchDayQualifier`. In `buildClockTime`, resolve each kind and throw the `already_passed` refusal for a passed `this-weekday`. Mirror verbatim in the port.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd clients/core && npm test` then `cd backend && npm test`
Expected: PASS — 148 of 169 asserted, `remaining === 21`.

- [ ] **Step 5: Commit**

```bash
git add clients/core/src/time.ts backend/public/nl-time.js clients/core/test/nl-corpus.test.ts backend/test/nl-time-port.test.ts fixtures/nl-corpus-asserted.json
git commit -m "feat(core): consume next/this quantifiers with already_passed refusal"
```

---

### Task 8: Intervals (week and day)

**Files:**
- Modify: `clients/core/src/time.ts:155-178` (`matchRecurrencePrefix`), `:337-390` (`tryParseExpression`)
- Modify: `backend/public/nl-time.js:168-188`, `:325-378`
- Test: `clients/core/test/nl-corpus.test.ts` + `fixtures/nl-corpus-asserted.json` (append 7 ids, `EXPECTED_REMAINING_TARGETS` → `14`)
- Test: `backend/test/nl-time-port.test.ts` (same)

**Interfaces:**
- Consumes: `IntervalSpec` (Task 2), `Weekday`/`ALL_DAYS`/`WEEKDAYS`/`WEEKENDS`/`readWeekdayGroup` (`time.ts:31-33`, `:110-153`).
- Produces:
  - `matchRecurrencePrefix` return type becomes `{ repeatDays: Weekday[]; interval?: IntervalSpec; next: number }`.
  - `function parseInterval(toks: string[], i: number): { interval: IntervalSpec; repeatDays: Weekday[]; next: number } | null` — dispatch order after `every` (spec §5.3): `<n> weeks` → `{ count: n, unit: "weeks" }`; `<n> days` → `{ count: n, unit: "days" }`; `other <weekday>` and `<n>nd <weekday>` → `repeatDays: [d]`, `{ count: 2, unit: "weeks" }`; then fall through to `day` → all-days, `<weekday-group>` → set (existing behaviour).
  - Anchoring (spec §6.6): a weekday-less interval with **no clock** anchors to `now + interval` preserving wall-clock (`repeatDays: []`); with a clock, it anchors to the clock's next occurrence; a weekday interval anchors to the weekday's next occurrence.
- Flips 7 target cases: `int-every-2-weeks`, `int-every-2-weeks-7am`, `int-every-other-monday`, `int-every-other-monday-7am`, `int-every-2nd-tuesday`, `int-every-2nd-tuesday-7am`, `int-every-3-days`.

- [ ] **Step 1: Write the failing test (flip the corpus ids)**

Add the 7 ids above to `fixtures/nl-corpus-asserted.json`. Headline assertions from the corpus: `int-every-2-weeks` → 2026-10-05 10:00, `repeatDays: []`, `interval: { count: 2, unit: "weeks" }`; `int-every-2-weeks-7am` → 2026-09-22 07:00, `repeatDays: []`, `interval: { count: 2, unit: "weeks" }`, label `""` (the `2` is **never** a clock); `int-every-other-monday` → 2026-09-28 00:00, `repeatDays: [1]`, `interval: { count: 2, unit: "weeks" }`; `int-every-3-days` → 2026-09-24 10:00, `repeatDays: []`, `interval: { count: 3, unit: "days" }`. Update `EXPECTED_REMAINING_TARGETS` to `14` in both runners.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/core && npx tsx --test test/nl-corpus.test.ts`
Expected: FAIL — the 7 new ids fail (`every 2 weeks 7am` currently resolves to tomorrow 07:00 with label `every 2 weeks` and no `interval`).

- [ ] **Step 3: Implement**

Add `parseInterval` and call it inside `matchRecurrencePrefix`'s `every` branch before the weekday-group fallback (spec §5.3 order). Carry `interval` out of `matchRecurrencePrefix` into `tryParseExpression` and set it on the result; anchor per §6.6. Mirror verbatim in the port.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd clients/core && npm test` then `cd backend && npm test`
Expected: PASS — 155 of 169 asserted, `remaining === 14`.

- [ ] **Step 5: Commit**

```bash
git add clients/core/src/time.ts backend/public/nl-time.js clients/core/test/nl-corpus.test.ts backend/test/nl-time-port.test.ts fixtures/nl-corpus-asserted.json
git commit -m "feat(core): parse week and day intervals, emitting interval fields"
```

---

### Task 9: Metadata extraction (a pre-pass)

**Files:**
- Modify: `clients/core/src/time.ts:396-421` (`parseTime`), `:462-479` (`parseLeadingTime`) — a pre-pass before tokenising
- Modify: `backend/public/nl-time.js:384-405`, `:443-459`
- Test: `clients/core/test/nl-corpus.test.ts` + `fixtures/nl-corpus-asserted.json` (append 13 ids, `EXPECTED_REMAINING_TARGETS` → `1`)
- Test: `backend/test/nl-time-port.test.ts` (same)

**Interfaces:**
- Consumes: `AlarmMetadata` (Task 2).
- Produces:
  - `function extractMetadata(raw: string[], toks: string[]): { alarm: AlarmMetadata | undefined; raw: string[]; toks: string[] }` — a pre-pass run by `parseTime`/`parseLeadingTime` before the grammar. Recognizes standalone tokens anywhere and removes them from the stream (spec §5.1, §8): `chime` → `sound_tone: "chime"`; `digital` (alias `digital pulse`) → `"digital"`; `no ramp` → `ramp_seconds: 0`; `quick ramp` → `15`; `gentle ramp` → `30`; `deep ramp` → `60`; `<n>s ramp` → `n`; `note:` consumes **everything to end of input verbatim** as `description` (original casing preserved; tokens after `note:` are never parsed as time).
  - The `30s` trap (spec §8): a bare `<n>s` stays a **duration**; only `<n>s ramp` is a ramp.
- Flips 13 target cases: `meta-chime-lead`, `meta-chime-trail`, `meta-digital`, `meta-gentle-ramp`, `meta-30s-ramp`, `meta-15s-ramp`, `meta-no-ramp`, `meta-quick-ramp`, `meta-deep-ramp`, `meta-note`, `meta-combined`, `meta-note-with-label`, `trap-30s-ramp`.

- [ ] **Step 1: Write the failing test (flip the corpus ids)**

Add the 13 ids above to `fixtures/nl-corpus-asserted.json`. Headline assertions from the corpus: `meta-combined` (`chime 30s ramp tomorrow 7am note: gym`) → 2026-09-22 07:00, label `""`, `alarm: { sound_tone: "chime", ramp_seconds: 30, description: "gym" }`; `trap-30s-ramp` (`30s ramp 7am`) → 2026-09-22 07:00, label `""`, `alarm: { ramp_seconds: 30 }` (a bare `30s` would be a duration); `meta-note-with-label` (`uni meeting tomorrow 7am note: bring towel`) → label `uni meeting`, `alarm: { description: "bring towel" }`. Update `EXPECTED_REMAINING_TARGETS` to `1` in both runners.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/core && npx tsx --test test/nl-corpus.test.ts`
Expected: FAIL — the 13 new ids fail (metadata currently collapses into the label; `meta-combined` label is `chime 30s ramp note: gym`).

- [ ] **Step 3: Implement**

Add `extractMetadata` and call it at the top of `parseTime`/`parseLeadingTime`, then run the grammar on the returned `raw`/`toks` and attach `alarm` to the result (including the empty-input check ordering). `note:` must split on the literal token `note:` and take the rest verbatim. Mirror verbatim in the port.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd clients/core && npm test` then `cd backend && npm test`
Expected: PASS — 168 of 169 asserted, `remaining === 1`.

- [ ] **Step 5: Commit**

```bash
git add clients/core/src/time.ts backend/public/nl-time.js clients/core/test/nl-corpus.test.ts backend/test/nl-time-port.test.ts fixtures/nl-corpus-asserted.json
git commit -m "feat(core): extract alarm metadata as a keyed pre-pass"
```

---

### Task 10: The split-anchor precedence fallback

**Files:**
- Modify: `clients/core/src/time.ts:429-479` (`findTimeSpan`, `parseLeadingTime`)
- Modify: `backend/public/nl-time.js:414-459` (`findTimeSpan`, `parseLeadingTime`)
- Test: `clients/core/test/nl-corpus.test.ts` + `fixtures/nl-corpus-asserted.json` (append 1 id, `EXPECTED_REMAINING_TARGETS` → `0`)
- Test: `backend/test/nl-time-port.test.ts` (same)

**Interfaces:**
- Consumes: `matchRecurrencePrefix`/`parseInterval` (Task 8), `parseAbsoluteDate` (Task 5), `parseDayPeriod` (Task 6), `tryParseExpression` (Task 3).
- Produces: `function findSplitAnchor(raw: string[], toks: string[], now: Date): { parsed: ParsedTime; rest: string } | null` — the new **stage 3** of the ladder (spec §5.4). When stages 1–2 would select a bare clock/period with no recurrence/date/day-period anchor, but a recurrence/date/period anchor exists elsewhere in the input, join the anchor to the clock and make the intervening tokens part of the label, preserving order. `parseLeadingTime` calls it only after the leading-prefix and span fallbacks return `null`.
- Flips 1 target case: `trap-dance-practice`.

- [ ] **Step 1: Write the failing test (flip the corpus id)**

Add `"trap-dance-practice"` to `fixtures/nl-corpus-asserted.json`. Assertion from the corpus: `dance practice every tuesday in the gym at 8pm` → 2026-09-22 20:00, `repeatDays: [2]`, label `dance practice in the gym` (both anchors removed, order preserved). Update `EXPECTED_REMAINING_TARGETS` to `0` in both runners.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/core && npx tsx --test test/nl-corpus.test.ts`
Expected: FAIL — `trap-dance-practice` currently resolves to today 20:00 with the whole phrase as the label (recurrence lost).

- [ ] **Step 3: Implement**

Add `findSplitAnchor` and call it in `parseLeadingTime` after `findTimeSpan` (spec §5.4 stage 3). Select the clock by the §5.4 priority (an anchored clock outranks a bare one), then remove the anchor and the clock from the label tokens in order. Mirror verbatim in the port.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd clients/core && npm test` then `cd backend && npm test`
Expected: PASS — all 169 corpus cases asserted, `remaining === 0`.

- [ ] **Step 5: Commit**

```bash
git add clients/core/src/time.ts backend/public/nl-time.js clients/core/test/nl-corpus.test.ts backend/test/nl-time-port.test.ts fixtures/nl-corpus-asserted.json
git commit -m "feat(core): join a recurrence anchor to its clock across interior label text"
```

---

## Verification (end to end)

- `cd clients/core && npm test` — every core suite passes, including `nl-corpus.test.ts` with `remaining === 0`.
- `cd backend && npm test` — every backend suite passes, including `nl-corpus-port.test.ts` with `remaining === 0` (the port and the TypeScript parser agree on all 169 cases).
- `./run_tests.sh` — ends "All Automated Test Suites Passed Successfully!" (steps [1/3] and [3/3] run the new suites).
- CI `backend` and `clients` jobs are green (`.github/workflows/ci.yml`).
- Spot-check the 17 trap cases: `fixtures/nl-corpus.json` `cases.filter(c => c.trap)` all assert (as `supported` or as manifest-listed `target`s) — none silently mis-parses.

## Self-Review notes

- **Spec coverage:** §5.1 → Task 9; §5.2 token inventory → Tasks 4–9; §5.3 interval-vs-set → Task 8; §5.4 ladder → Tasks 3, 10; §6.1 forward-only → unchanged (Task 2 asserts it); §6.2 periods → Task 6; §6.3 `next`/`this` + refusal → Task 7; §6.4 dates → Task 5; §6.5 numeric dates → Task 5; §6.6 offsets/intervals → Tasks 4, 8; §6.7 casing → preserved (Tasks 9, 10 keep original-cased label text); §8 metadata → Task 9; §10 error model → Tasks 1, 7; §11 traps → Tasks 3–10; §12.2 runner → Task 2.
- **Deferred (not in this plan):** §7 backend storage, GCal `FREQ`, mobile `getNextOccurrence`; §9 `ambiguities` + dashboard confirm step. See **Out of scope**.
- **Type consistency:** `AlarmMetadata` and `IntervalSpec` are defined once in Task 2 and consumed by Tasks 8 and 9; `RefusalReason`/`TimeParseError` are defined in Task 1 and consumed by Task 7; `Clock.bare` and `allowBareIntegerClock` are defined in Task 3 and relied on by Tasks 4–10.
