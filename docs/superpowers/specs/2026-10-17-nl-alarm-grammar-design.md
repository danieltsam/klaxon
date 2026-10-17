# Remote Alarm — Natural-Language Alarm Grammar Expansion Design

> **Date:** 2026-10-17
> **Status:** Decided design — the owner decisions and settled calls are encoded below (§6.3, §7,
> §10, §12.2, §15, §17). Next: written-spec review, then an implementation plan.
> **Scope:** The `clients/core` time parser, its browser port, the two shared fixtures, the
> web dashboard create modal, and a backend schema change for day-intervals (decided, §7).
> No CLI or Raycast behaviour change is required beyond consuming new optional fields; mobile
> gains day-interval handling in `getNextOccurrence` (§7).
> **Contract:** `fixtures/nl-corpus.json` — 169 cases. This document is the *why* and *how*;
> the corpus is the *what*. Where the two disagree, the corpus wins and this document is wrong.
> **Guiding principle:** a silent mis-parse is the enemy. An alarm that resolves to a
> plausible-but-wrong time is worse than one that refuses to resolve, because the owner
> discovers it only when it fails to ring. **Fail loudly over guessing.**
> **Related:** `docs/superpowers/specs/2026-09-21-clients-cli-raycast-design.md` (§6 defines the
> current grammar and the timezone contract), `docs/superpowers/specs/2026-09-23-missed-alarms-design.md`
> (the status model the parser's output feeds), `docs/superpowers/specs/2026-09-21-google-calendar-mirror-design.md`
> (recurrence → calendar).

---

## 1. Context & Intent

The natural-language time parser (`clients/core/src/time.ts`) is the front door to every alarm
created from the CLI, the Raycast extension, and the dashboard. Its current grammar is small and
deliberate: durations, clocks, `today`/`tomorrow`/weekdays, and weekday sets. It is matched as the
**longest leading prefix** of a single expression, with a fallback that finds the longest parseable
**span** anywhere in the input (trailing spans preferred) when no prefix parses.

That grammar has been measured, not assumed. `fixtures/nl-corpus.json` is a 169-case corpus of real
phrasings and their expected resolution. **106 cases pass today; 63 fail.** The 63 failures are the
expansion. Each failing case records the parser's *real current output* (`actual_today`), and it is
that output — not a hypothetical — that shows how the current parser goes wrong:

- `in 3 days` → resolves to **tomorrow 03:00** with label `days`. The `3` was eaten as a bare hour.
- `every 2 weeks 7am` → resolves to **tomorrow 07:00** with label `every 2 weeks`. The interval was
  silently discarded.
- `dec 25 7am` → resolves to **tomorrow 07:00** with label `dec 25`. The date was silently demoted
  to label text.
- `next monday 7am` → label `next`. The quantifier leaked into the label.
- `5pm 10/31` → **today 17:00** with label `10/31`. The date was silently dropped.
- `dance practice every tuesday in the gym at 8pm` → a **one-time today 20:00**; the recurrence was
  lost entirely.

Every one of these is a *silent* mis-parse: the parser returns a valid-looking time, the alarm is
created, and it rings at the wrong moment (or does not repeat) with no warning. That is the failure
mode this design exists to eliminate.

**Intended outcome.** A competent builder can extend the grammar so that all 169 corpus cases
resolve as the corpus says, and every input the parser cannot resolve confidently **fails loudly**
rather than returning a plausible-but-wrong time. The parser continues to produce a *local
wall-clock* `Date`; timezone handling is unchanged (§2).

**Success criterion.** The corpus is the test. 106 supported cases stay green, 63 target cases go
green, and the 17 flagged traps never silently mis-parse — they either resolve exactly as specified
or refuse.

---

## 2. Scope

### In scope

| Area | Change |
|---|---|
| Grammar tokens | Absolute dates, day periods, `next`/`this`, intervals, metadata keywords |
| Resolution | Forward-only weekdays, day-period anchors, year-rollover dates, interval anchoring |
| Precedence | The leading-prefix → span-fallback ladder, plus a new split-anchor fallback (§5.4) |
| Metadata | Tone / ramp / note keyword extraction (§8) |
| Ambiguity | A confirm step in the dashboard around the existing parse echo (§9) |
| Rejection | Loud failure for unresolvable input; trap guards (§10, §11) |
| Contract | Both fixtures and both implementations kept in lockstep (§12) |
| Backend | **Decided**: a general interval column so day- and week-intervals both store (§7) |

### Out of scope

- **Timezone behaviour.** The parser still produces a local wall-clock `Date`; conversion to UTC
  still happens only at the client boundary (`clients-cli-raycast-design.md` §6.5). Nothing here
  changes that contract.
- **Monthly / yearly recurrence.** The backend expresses weekly `BYDAY` and day-intervals only;
  `every 2nd tuesday` means *fortnightly on Tuesday*, not *the second Tuesday of the month*.
- **Ordinal-of-month semantics** ("the second Tuesday of the month"). Not expressible downstream.
- **Free-text / ML parsing.** No fuzzy matching, no language model, no "understand anything". The
  grammar is deterministic and enumerable.
- **New runtime dependencies.** `core` stays dependency-free (`clients-cli-raycast-design.md` §4.2);
  the browser port stays a hand-written no-build file.
- **Mobile / CLI / Raycast UI.** They consume `core`; new optional output fields are additive.
  Mobile additionally gains day-interval handling in `getNextOccurrence` (§7).
- **Dashboard visual design.** The confirm step's *layout* is a designer's job (§15).

---

## 3. Verified Constraints

Measured or read, not assumed.

| Fact | Where |
|---|---|
| The grammar is a contiguous single expression, matched as the longest leading prefix | `clients/core/src/time.ts:337-390` (`tryParseExpression`), `:462-479` (`parseLeadingTime`) |
| When no prefix parses, the fallback prefers the longest **trailing** span, then the longest span anywhere | `time.ts:429-453` (`findTimeSpan`) |
| Matching lowercases tokens; the label is rebuilt from the **original-cased** raw tokens | `time.ts:403`, `:474`, `:439`, `:447` |
| There is no absolute-date, day-period, interval, `next`/`this`, or metadata grammar | `time.ts` token tables (`WEEKDAY_NAMES`, `CONNECTORS`, `parseDuration`, `matchRecurrencePrefix`) |
| A passed clock/`today` rolls forward; a passed weekday rolls to next week | `time.ts:274-319` (`buildAbsolute`, `buildClockTime`) |
| The browser port `backend/public/nl-time.js` is a **verbatim** translation of `time.ts` + the echo formatter | `nl-time.js:1-25`, `:443-459` |
| The dashboard loads the port and calls `parseLeadingTime` on input and on submit | `index.html:585`, `:1416`, `:1444`, `:1523` |
| The parse echo already renders interpretation + label + weekday chips | `index.html:378-383`, `:1390-1399` |
| `repeat_days` is a comma ISO-weekday string; `recurrence_interval_weeks` is `1` or `2`; `recurrence_anchor_date` is `YYYY-MM-DD` | `db.ts:11-13`, `:77-78`, `:108-109`; `server.ts:432-461` |
| The API rejects `recurrence_interval_weeks` outside `1..2` | `server.ts:435`, `:666` |
| The missed sweep treats an empty/absent `repeat_days` as a **one-time** alarm | `server.ts:175-179` |
| The create path zeroes seconds and rolls a past target forward (one-time, beyond grace) | `server.ts:403`, `:417-424` |
| `fixtures/time-parse-cases.json` is asserted by the TS suite and the port | `time.test.ts:127-128`, `:130-146` |
| `fixtures/nl-corpus.json` currently has **no test harness** — it is a measurement artifact | repo-wide search: the file references itself only |
| `core` has zero runtime dependencies and must not use Node-24+ APIs | `clients-cli-raycast-design.md` §4.2 |

The last-but-one row matters for §12: the corpus is the contract but nothing runs it. This design
adds a runner.

---

## 4. The Corpus — the Contract

`fixtures/nl-corpus.json` (`schemaVersion: 1`) is the specification of *what* must resolve.
`resolution` defines a case's answer as `parseLeadingTime(input, now)` → `local` (wall-clock),
`repeatDays` (ISO weekdays, `[]` = one-time), `label` (the unconsumed remainder). An invalid case
has `local`/`repeatDays`/`label` null.

| Status | Count | Meaning |
|---|---|---|
| `supported` | 106 | Verified green today (`machineVerified: true`). **Must stay green.** |
| `target` | 63 | Should resolve this way after expansion; fails today. `actual_today` is the live output. |
| `traps` | 17 | Flagged `trap: true`. The acceptance list for "never silently mis-parse" (§11). |
| **total** | **169** | |

By category (from the corpus `summary`):

| Category | Cases | Category | Cases |
|---|---|---|---|
| durations | 25 | day-periods | 8 |
| clocks | 18 | label-placement | 10 |
| day-qualified | 14 | alarm-metadata | 12 |
| weekdays | 19 | traps | 6 |
| weekday-sets | 30 | invalid | 6 |
| absolute-dates | 14 | | |
| intervals | 7 | | |

`now` is a local wall-clock ISO date-time **without** an offset (ECMAScript parses those as local),
so the corpus is timezone-portable. Default `now` is Monday 21 Sep 2026 10:00 local; cases that need
a passed/future boundary, a Monday-is-today view, or a Jan/Dec rollover vary it.

**How to read the corpus.** `expected` is the target answer. `actual_today` on a `target` case is
*evidence of the defect*, never a thing to preserve. `status` says whether the case is green today.
`trap` says the case is a guard. The corpus's own `grammarNotes` and `semantics` blocks are the
authoritative short statements of intent; §6 restates and extends them.

---

## 5. Grammar

The grammar is defined as an ordered pipeline. Each stage is deterministic; there is no scoring by
heuristic and no randomness.

### 5.1 Stage 0 — Metadata extraction (a pre-pass)

Metadata keywords are **keyed**: they are recognized as standalone tokens anywhere in the input and
removed from the token stream *before* the time grammar runs. This is what lets `chime 30s ramp
tomorrow 7am note: gym` yield a tone, a ramp, a note, and a clean time expression, regardless of
where each keyword sits. The full keyword table is §8.

The `note:` keyword is special: it consumes **everything to the end of the input** as the
description, verbatim. Tokens after `note:` are never parsed as time. This is why
`tomorrow 7am note: bring towel` yields `description: "bring towel"` and label `""`.

Extraction is one-way: once a keyword is recognized it is gone. A label that legitimately contains a
keyword word (e.g. `chime practice`) therefore loses that word — see the ambiguity in §9 and open
question Q1.

### 5.2 Stage 1 — Token inventory

Surface forms, case-insensitively matched (the label keeps original case, §6.7).

**Clocks** (unchanged): `7am`, `7:30am`, `07:00`, `19:00`, `7`, `19`, `7 pm`, `7:30 pm`.

**Durations**: `<n>m|min|minute(s)`, `<n>h|hr|hour(s)`, `<n>s|sec|second(s)`, concatenated
(`1h30m`), optionally led by `in`. Seconds/hours/minutes only — **never** days or weeks (§5.3).

**Day qualifiers**

| Form | Meaning |
|---|---|
| `today` | today; a passed clock rolls to +1 day |
| `tomorrow` / `tmr` | +1 day |
| `<weekday>` | next occurrence, **forward-only** (§6.1) |
| `next <weekday>` | that weekday in the **next** ISO week (§6.3) |
| `this <weekday>` | that weekday in the **current** ISO week; an **`already_passed` refusal** when gone (§6.3) |
| `this weekend` | coming Saturday 00:00 |
| `next week` | same wall-clock +7 days |
| `next month` | same wall-clock +1 calendar month |

`last` is **not** a grammar token (owner decision 3): `last friday` is parsed as the weekday `friday`
(forward-only) with `last` left in the label, and `last week` / `last month` are not recognized.
`this` is a token for `this weekend`, `this <period>` (§6.2), and `this <weekday>` (§6.3). `next
month` is pinned by the corpus (`day-next-month`).

**Recurrence / weekday sets**

| Form | `repeatDays` | Interval |
|---|---|---|
| `daily`, `every day` | `1..7` | 1 |
| `weekdays` | `1..5` | 1 |
| `weekends` | `6,7` | 1 |
| `mon-fri` (inclusive, wrapping) | `1..5` | 1 |
| `mon,wed,fri`, `mon, wed, fri` | `1,3,5` | 1 |
| `every <weekday>` | `[d]` | 1 |
| `every other <weekday>` | `[d]` | **2** |
| `every <n>nd <weekday>` (e.g. `2nd`) | `[d]` | **2** |

**Absolute dates** (§6.4)

| Form | Example | Reading |
|---|---|---|
| `<month> <day>` | `dec 25`, `december 25` | month, day |
| `<day> <month>` | `25 dec`, `25th december` | day, month |
| `<month> <ordinal>` | `jan 4th` | month, day |
| `<d>/<m>` numeric | `25/12`, `31/12`, `10/31` | see §6.5 |
| ISO | `2026-12-31` | year-month-day |

**Day periods** (§6.2): `morning`, `afternoon`, `evening`, `tonight`, `noon`, `midnight`,
optionally prefixed `this`.

**Intervals / day-week offsets** (§6.6)

| Form | Meaning |
|---|---|
| `<n> days`, `in <n> days` | one-time offset: now + n days |
| `<n> weeks`, `in <n> weeks`, `<n> weeks from now`, `in 1w 2d` | one-time offset: now + span |
| `every <n> weeks` | interval recurrence, `intervalWeeks = n`, no clock → anchor now + n weeks |
| `every <n> days` | interval recurrence, `intervalDays = n`, no clock → anchor now + n days (§7) |

**Metadata**: see §8.

### 5.3 The interval-versus-weekday-set distinction (owner decision 3)

A number **with a unit** is an interval. A **named day** is a weekday set. The two must never
collapse into each other. This single rule fixes the worst trap:

```
"every 2 weeks 7am"
  WRONG (today):  "2" is eaten as a bare hour 02:00; "every 2 weeks" becomes the label.
  RIGHT:          intervalWeeks = 2; clock = 7am → tomorrow 07:00; label = "".
```

So after `every`, dispatch in this order: `<n> <day|week>` → interval; `other <weekday>` or
`<n>nd <weekday>` → weekday set + interval 2; `day` → all-days set; `<weekday-group>` → weekday set.
Only if none matches does the token stream fall through to the ordinary clock grammar.

### 5.4 Stage 2 — Precedence: leading prefix, span fallback, split anchor

This is the rule the prompt calls out, extended. The ladder is applied in order; the first stage that
produces an expression wins.

1. **Leading prefix (unchanged).** The longest leading token prefix that is a complete single
   expression. Remainder = label. This preserves every `supported` case that relies on a leading time
   (`25m Oven`, `tomorrow 6pm Call mum`).
2. **Contiguous span fallback (unchanged).** When no prefix parses, the longest **trailing** span
   that parses wins; failing that, the longest span anywhere. Surrounding tokens = label. This
   preserves label-first phrasing (`gym tomorrow 7am`, `uni meeting tomorrow at 8pm`) and keeps stray
   integers out of the time (`call at 5 tomorrow 7am`).
3. **Split-anchor fallback (new).** When stages 1–2 would select a **bare clock/period with no
   recurrence or date anchor**, but a recurrence/date/day-period anchor exists elsewhere in the
   input, the anchor is joined to the clock and the intervening tokens become part of the label. This
   is what recovers `dance practice every tuesday in the gym at 8pm`:

   ```
   tokens:   dance practice | every tuesday | in the gym | at 8pm
   anchor:   every tuesday        (repeatDays = [2])
   clock:    8pm
   label:    dance practice in the gym        (both anchors removed, order preserved)
   ```

**Selection among candidate clocks.** When several clocks/periods are present, prefer, in order:
(a) a clock accompanied by a recurrence/date/day-period anchor; (b) a clock with a meridiem or a day
qualifier; (c) a bare integer — **lowest priority**, and a bare integer is only ever a clock when it
is the entire expression (this is the `clk-bare-7` trap guard). This rule is why `call at 5 tomorrow
7am` keeps `call at 5` as the label and `5pm 10/31` binds the date to the clock.

**Ordering is not fixed.** A date and a clock may appear in either order (`dec 25 7am` and `5pm
10/31` both resolve to date + time). A recurrence precedes its clock. Connectors `at`/`in` are
stripped between components.

---

## 6. Resolution Semantics

### 6.1 Forward-only weekdays (owner decision 1)

A bare weekday always resolves to the **next** occurrence strictly in the future. `mon 8:30am` on a
Monday at 10:00 is *next* Monday; on a Monday at 08:00 it is *today*. A bare weekday with no clock is
midnight of that day. This is unchanged behaviour and is the default for the **bare** weekday form;
`this <weekday>` and `next <weekday>` are ISO-week anchored instead (§6.3).

### 6.2 Day periods

| Period | Anchor |
|---|---|
| `morning` | 09:00 |
| `afternoon` | 15:00 |
| `evening` | 19:00 |
| `tonight` | 21:00 |
| `noon` | 12:00 |
| `midnight` | 00:00 |

A period is a clock. A passed period rolls forward to the next day, exactly like a passed clock
(`this morning` at 10:00 → tomorrow 09:00). `this <period>` is equivalent to the bare period.
`tomorrow <period>` and `<date> <period>` anchor the period to that day.

### 6.3 `next` / `this`

The three weekday forms are a deliberate, unambiguous three-way contrast. All of them use the app's
weekday numbering **`mon = 1 … sun = 7`** and a **Monday-start ISO week** (the week runs Mon → Sun):

| Form | Week it anchors to | Passed → |
|---|---|---|
| `<weekday>` (bare) | forward-only: the next occurrence strictly in the future (§6.1) | rolls to the next week |
| `this <weekday>` | the **current** ISO week (Mon–Sun containing `now`) | **`already_passed` refusal** (§10) |
| `next <weekday>` | the **next** ISO week | n/a — always ahead |

- **bare `<weekday>`** — unchanged (§6.1): the next occurrence strictly in the future. It may be
  *today* (when the resolved time has not passed) or the same weekday next week (when it has). It
  never refuses and never lands in the past.
- **`this <weekday>`** — that weekday **within the current ISO week** (Monday-start). With no clock
  the resolved instant is that weekday's midnight; with a clock it is that weekday at the clock time.
  Same-day is valid while the resolved time is still ahead. **If that instant has already passed —
  including exact equality, matching the passed-clock rule — the parse is a hard `already_passed`
  refusal (§10), not a roll-forward.** `this friday` from Mon 21 Sep 2026 10:00 → Fri 25 Sep 00:00
  (still ahead); from Sat 26 Sep 2026 10:00 → refusal, because that week's Friday (25 Sep) has gone;
  `this friday 7pm` on Fri 25 Sep at 08:00 → 19:00 (ahead, valid), but at 20:00 → refusal.
- **`next <weekday>`** — that weekday in the **next** ISO week (the week after the current one):
  `next monday` from Mon 21 Sep → Mon 28 Sep, pinned by `day-next-monday`.

Because bare and `this` coincide whenever the day is still ahead, the distinction only shows once the
day has passed: bare rolls forward, `this` refuses. `next` is always a full week beyond the current
week's occurrence. This three-way split is pinned by the corpus (`wd-this-friday-future`,
`wd-this-friday-passed`, `wd-this-friday-today-ahead`, `wd-this-friday-today-passed`,
`wd-this-monday-passed`).

Other `next` / `this` forms (unchanged):

- `this weekend` — coming Saturday 00:00.
- `this <period>` — the bare day period (§6.2).
- `next week` — the same wall-clock time +7 days (`next week` from Mon 21 Sep 10:00 → Mon 28 Sep
  10:00); pinned by `day-next-week`.
- `next month` — the same wall-clock time +1 calendar month (Mon 21 Sep 10:00 → Wed 21 Oct 10:00);
  pinned by `day-next-month`.

`last` is **dropped from the grammar** (owner decision 3): there is no `last <weekday>`, `last week`,
or `last month`. `last friday` is therefore just the weekday `friday` (forward-only) with `last` left
in the label, and the old backwards-resolution case is removed from the corpus. `this` is a token for
`this <weekday>`, `this weekend`, and `this <period>` — see the token table (§5.2).

### 6.4 Absolute dates

- `<month> <day>` (`dec 25`), `<day> <month>` (`25 dec`), `<month> <ordinal>` (`jan 4th`), and ISO
  (`2026-12-31`) all resolve to that calendar day at 00:00 unless a clock is present.
- **No year → next occurrence.** A date that has already passed this year rolls to next year:
  `jan 4th` from Sep 2026 → 2027-01-04; `1 jan` from late Dec 2026 → 2027-01-01; `dec 25` from Jan
  2026 → 2026-12-25.
- An explicit ISO year is honoured verbatim, including a past year (then §9's futurity check
  applies).
- An absolute-date anchor **outranks** a bare trailing clock: `dec 25 7am` → 25 Dec 07:00, not
  tomorrow 07:00 with `dec 25` as label.

### 6.5 Numeric dates — `25/12` is day/month

The reading is **day/month** when unambiguous, with a fallback that makes every corpus case
deterministic:

| Input | Reading | Rule |
|---|---|---|
| `25/12` | 25 Dec | first field > 12 ⇒ it is the day |
| `31/12` | 31 Dec | first field > 12 ⇒ it is the day |
| `10/31` | 31 Oct | second field > 12 ⇒ first field is the month |
| `03/04` | 3 Apr (default) | both ≤ 12 ⇒ **ambiguous**: default day/month, confirm (§9) |

The default matches the app's `dd/mm/yyyy` preference (`db.ts:35`). The ambiguous case is the only
place a numeric date is guessed, and the guess is surfaced, not hidden. It is pinned by the corpus
case `abs-03-04`: `03/04` from 21 Sep 2026 → 2027-04-03 (3 Apr 2026 has passed, so it rolls a year).

### 6.6 Intervals and day/week offsets

- `<n> days`, `in <n> days`, `<n> weeks`, `in <n> weeks`, `2 weeks from now`, `in 1w 2d` are
  **one-time offsets** from `now` preserving wall-clock: `in 3 days` from Mon 21 Sep 10:00 → Thu 24
  Sep 10:00. They are durations with day/week units; the number is never a clock.
- `every <n> weeks` with no clock anchors to `now + n weeks` preserving wall-clock and reports
  `intervalWeeks = n`.
- `every <n> weeks <clock>` anchors to the clock's next occurrence and reports `intervalWeeks = n`.
- `every other <weekday>` and `every <n>nd <weekday>` anchor to the weekday's next occurrence and
  report `repeatDays = [d]`, `intervalWeeks = 2`.
- `every <n> days` with no clock anchors to `now + n days` preserving wall-clock and reports
  `intervalDays = n`; `every <n> days <clock>` anchors to the clock's next occurrence. Day-intervals
  store in the general interval column (§7).

### 6.7 Casing

The parser lowercases tokens for matching only. **The label and the `note:` text are never
re-cased.** `tomorrow 6pm Call Mum` → label `Call Mum`; `Uni Meeting tomorrow at 8pm` → label
`Uni Meeting`. This is already true (`time.ts:474`) and must remain true for every new form,
including label text that sits between a split anchor and its clock.

---

## 7. Interval Storage — **Decided: the general interval column**

The grammar recognizes two kinds of recurrence interval: week-intervals (`every 2 weeks`) and
day-intervals (`every 3 days`). The owner has decided that both are first-class and both store
(owner decision 1 — previously "Option A"). The grammar is honoured end-to-end; there is no
"unresolved storage" gap.

**What the grammar produces.** `every 2 weeks` → `intervalWeeks = 2`; `every 3 days` →
`intervalDays = 3`. Either may carry `repeatDays = []` when no weekday is named (the corpus pins
`repeatDays: []` for `int-every-2-weeks` and `int-every-3-days`).

**The schema change** (`db.ts`, `server.ts`):

| Field | Type | Constraint |
|---|---|---|
| `repeat_days` | comma ISO-weekday string | unchanged; the `BYDAY` anchor |
| `recurrence_interval_weeks` | INTEGER | existing; `1` or `2` |
| `recurrence_interval_days` | INTEGER | **new**; `>= 1`, the day-interval count |
| `recurrence_anchor_date` | `YYYY-MM-DD` | required when an interval is anchored |

Generalising to `recurrence_interval` + `recurrence_interval_unit` is an acceptable equivalent, as
long as day- and week-intervals both round-trip. A migration adds the column; existing rows default
to no day-interval.

**The parser/server split (owner decision 2).** The parser reports a weekday-less interval with
`repeatDays: []` — that is what the corpus pins. The **server/create path** is what derives
`repeat_days`: when an interval arrives with no weekday, the server sets
`repeat_days = [isoWeekday(recurrence_anchor_date)]` so the backend has a `BYDAY` anchor. This split
is deliberate, and it fixes the latent bug where a weekday-less interval had no `repeat_days` and the
missed sweep treated it as **one-time** (`server.ts:175-179`). The fix lives on the create/update
path, not in the parser.

**Downstream.**

- **Google Calendar mirror.** The RRULE must match the interval unit: day-intervals emit
  `RRULE:FREQ=DAILY;INTERVAL=n`, week-intervals emit `RRULE:FREQ=WEEKLY;INTERVAL=n` (plus the derived
  `BYDAY`). The mirror today only emits `FREQ=WEEKLY;BYDAY=…` (`server.ts:349-356`); it gains the
  `DAILY` branch.
- **Phone (`getNextOccurrence`).** The mobile scheduler learns day-intervals: a `DAILY;INTERVAL=n`
  recurrence advances the target by `n` days from the anchor, exactly as the `WEEKLY;INTERVAL=n`
  branch advances by `n * 7` days (`mobile/lib/services/alarm_service.dart`).

**Rejected alternative (for history).** "Option B" — map weeks onto the existing columns and reject
`every <n> days` loudly — was not chosen: it discarded a first-class interval the grammar can
represent. No `UnsupportedIntervalError` is added.

---

## 8. Metadata Keyword Table

Metadata rides as **keyed keywords in the text**, extracted by Stage 0 (§5.1). The mapping is fixed
by the corpus.

| Keyword | Field | Value |
|---|---|---|
| `chime` | `sound_tone` | `chime` |
| `digital` (alias `digital pulse`) | `sound_tone` | `digital` |
| `no ramp` | `ramp_seconds` | `0` (Instant) |
| `quick ramp` | `ramp_seconds` | `15` |
| `gentle ramp` | `ramp_seconds` | `30` (Gradual, the app default) |
| `deep ramp` | `ramp_seconds` | `60` (Deep Sleep) |
| `<n>s ramp` | `ramp_seconds` | `n` |
| `note: <text>` | `description` | `<text>` verbatim, to end of input |

**The `30s` trap.** A bare `<n>s` is a **duration** (`30s` = now + 30 seconds), never a ramp. Only
`<n>s ramp` — the number immediately followed by the literal word `ramp` — is a ramp. This is the
`dur-30s` guard and it must not be relaxed. `30s ramp 7am` is therefore ramp 30 at 07:00 (settled
call 6); `trap-30s-ramp` and `meta-30s-ramp` agree on this reading.

Metadata is removed before the time grammar, so it may appear before, after, or between the time
components. `chime 30s ramp tomorrow 7am note: gym` yields tone `chime`, ramp `30`, description
`gym`, target tomorrow 07:00, label `""`.

---

## 9. Ambiguity → Confirm (owner decision 2)

**Ambiguity is confirmed, not guessed.** The parse echo already exists in the dashboard
(`#nl-interpretation`, `#nl-label`, `#nl-days-container`, `index.html:378-383`, `:1390-1399`). The
confirm step is designed around it, not beside it.

The parser gains a structured result — `ParsedTime` extended with optional, additive fields:

```ts
interface ParsedTime {
  targetTime: Date;              // unchanged: local wall-clock
  repeatDays: Weekday[];         // unchanged
  interpretation: string;        // unchanged echo
  alarm?: {                      // NEW — metadata (§8)
    sound_tone?: "alarm" | "chime" | "digital";
    ramp_seconds?: number;
    description?: string;
  };
  interval?: { count: number; unit: "days" | "weeks" };   // NEW (§7)
  ambiguities?: Ambiguity[];     // NEW — empty/absent = unambiguous
}

interface Ambiguity {
  kind: "numeric_date" | "metadata_word" | "past_time" | "interval_no_clock";
  chosen: string;                // what the parser picked
  alternatives: string[];        // what else it could have been
}
```

Behaviour:

- **Unambiguous** (`ambiguities` empty): the dashboard keeps the current one-click add. The echo
  still shows interpretation + label + metadata chips.
- **Ambiguous**: the add button becomes **confirm**. The dashboard shows the chosen interpretation
  ("I'll set: …"), the alternatives as selectable chips, and the metadata that was extracted. Nothing
  is created until the user confirms. The interpretation echo is never suppressed.

Ambiguity is *not* an error. It is a first-class, visible state. Triggers:

| Trigger | Example | Surfaced as |
|---|---|---|
| Ambiguous numeric date (§6.5) | `03/04` | "3 Apr" vs "4 Mar" |
| A metadata word that could be label text | `chime practice` | tone `chime` vs label `chime practice` |
| A time that resolves into the past | an explicit past date, e.g. `2020-01-01` | past time, futurity warning |
| An interval with no clock | `every 2 weeks` | "anchored to now" |

A lone integer outside 0–23 is a **hard rejection**, not an ambiguity (settled call 5): `25` and `24`
throw and name the token (`inv-25` / `inv-24`), and there is no `bare_integer` ambiguity kind.
`10/31` is a numeric date (§6.5), not a bare integer.

---

## 10. Error & Rejection Behaviour

Every refusal is a thrown `TimeParseError` carrying **both** the offending token and a **reason** (the
refusal kind), so a caller can distinguish "I don't understand this" from "I understood it and it is
in the past":

```ts
type RefusalReason = "unparseable" | "already_passed";

class TimeParseError extends Error {
  token?: string;          // the offending token / phrase, where applicable
  reason: RefusalReason;   // defaults to "unparseable"
}
```

- **`unparseable`** (default) — no grammar form matches. `.token` names the first token that could not
  be consumed (existing behaviour, `time.ts:407-420`). The dashboard renders `could not parse
  "<token>"` (`index.html:1525`).
- **`already_passed`** — a *recognized* `this <weekday>` (§6.3) whose resolved instant is in the past
  (including exact equality, matching the passed-clock rule). `.token` names the `this <weekday>`
  phrase (e.g. `this friday`). This is a **hard error**: never a roll-forward, never an offered
  ambiguity. The owner's words: *"if it's already passed, just throw an error stating it's already
  passed."*

Other rules:

- **Never return a plausible-but-wrong time.** If the parser cannot confidently resolve an
  expression, it must throw rather than emit a time. This is the acceptance criterion the 17 traps
  test (§11).
- **A lone integer outside 0–23 is a hard rejection** (`inv-24`, `inv-25`), never an offered
  ambiguity (§9).
- **Empty input** throws (`time.ts:399-401`), unchanged.
- Error messages name the *token*, not the whole input, so the user can see which word failed.

**How the corpus asserts it (§12.2).** Every `invalid: true` corpus case carries
`expected.rejectedToken` and `expected.reason`; the runner calls `parseTime(input, now)` and asserts it
throws a `TimeParseError` with `error.token === expected.rejectedToken` **and**
`error.reason === expected.reason`. The existing `inv-*` cases carry `reason: "unparseable"`; the new
`this <weekday>` refusal cases (`wd-this-friday-passed`, `wd-this-friday-today-passed`,
`wd-this-monday-passed`) carry `reason: "already_passed"`. The create API surfaces both fields (e.g.
`{ error, rejectedToken, reason }`) so a caller learns *why* the input failed, not just that it did.

---

## 11. Trap Guards — Concrete Rules

The 17 flagged traps, each with the rule that keeps it honest. A trap either resolves exactly as the
corpus says or refuses; it never silently mis-parses.

| # | Case | Input | Guard |
|---|---|---|---|
| 1 | `dur-30s` | `30s` | Bare `<n>s` is a duration; only `<n>s ramp` is a ramp. |
| 2 | `dur-in-3-days` | `in 3 days` | `<n> day(s)` is a day offset; `3` is never a clock. |
| 3 | `dur-2-weeks-from-now` | `2 weeks from now` | `<n> weeks from now` is an offset; `2` is never a clock. |
| 4 | `dur-3-days-bare` | `3 days` | Same as #2. |
| 5 | `dur-2-weeks-bare` | `2 weeks` | Same as #3. |
| 6 | `clk-bare-7` | `7` | A lone integer is a valid hour **only** as the entire expression. |
| 7 | `abs-dec25-7am` | `dec 25 7am` | A date anchor outranks a bare trailing clock. |
| 8 | `int-every-2-weeks-7am` | `every 2 weeks 7am` | `every <n> weeks` is an interval; `2` is never a clock (§5.3). |
| 9 | `lab-5-min-warning` | `8am 5 minute warning` | `5 minute` must not join `8am` as a duration; the trailing span wins. |
| 10 | `lab-call-at-5` | `call at 5 tomorrow 7am` | A stray bare `5` stays in the label when a later qualified clock exists. |
| 11 | `lab-walk-at-5` | `walk at 5 tomorrow 7am` | Same as #10. |
| 12 | `trap-5pm-date` | `5pm 10/31` | Clock-then-date joins; the date is not demoted to label. |
| 13 | `trap-dance-practice` | `dance practice every tuesday in the gym at 8pm` | A recurrence anchor joins its clock across interior label text (§5.4 stage 3). |
| 14 | `trap-buy-2-loaves` | `buy 2 loaves tomorrow 8am` | A bare integer stays in the label when a qualified clock exists. |
| 15 | `trap-meeting-3` | `meeting 3 tomorrow 7am` | Same as #14. |
| 16 | `trap-next-monday-7am` | `next monday 7am` | `next` is consumed as a quantifier, never label text. |
| 17 | `trap-30s-ramp` | `30s ramp 7am` | `<n>s ramp` is a ramp (30) and `7am` is the clock → tomorrow 07:00. |

---

## 12. The Shared Contract & Lockstep

Two fixtures, one grammar, two implementations.

| Fixture | Role |
|---|---|
| `fixtures/time-parse-cases.json` | The **existing** lockstep pin. The TS suite (`time.test.ts`) and the browser port both assert its `cases` / `invalid` / `leading` / `leadingNull` / `interpretation`. Extended with new grammar cases. |
| `fixtures/nl-corpus.json` | The **expansion contract** — 169 cases, the acceptance list. Gains a machine-checked runner (§12.2). |

Two implementations must not drift:

1. `clients/core/src/time.ts` — the canonical parser.
2. `backend/public/nl-time.js` — the no-build browser port, loaded by the dashboard
   (`index.html:585`). It is a **verbatim** translation (`nl-time.js:1-25`); any behavioural
   divergence is a bug.

**Rule:** a grammar change lands in both files in the same change, and both are asserted against
`fixtures/time-parse-cases.json`. The corpus runner (§12.2) runs against both.

### 12.2 The corpus runner (new)

The corpus is currently a measurement artifact with no test. Add a runner that, for every case,
calls `parseLeadingTime(input, new Date(now))` and asserts the **full** `expected` shape — `local`,
`repeatDays`, `label`, and, when present, `intervalWeeks`, `intervalDays`, and every `alarm.*` field
(settled call 4). Asserting only `local`/`repeatDays`/`label` is not enough: the interval and metadata
fields are part of the contract, and a case that silently drops them is a false green. Run the runner
against **both** implementations. After expansion, `target` cases become ordinary passing tests and
the `trap` flag becomes a named regression set.

**Invalid cases (`invalid: true`) use a different entry point.** `parseLeadingTime` returns `null`
rather than throwing when nothing parses, so for every `invalid: true` case (the `inv-*` cases and the
`already_passed` `this <weekday>` cases) the runner calls `parseTime(input, new Date(now))` and asserts
it throws a `TimeParseError` whose `.token` equals `expected.rejectedToken` **and** whose `.reason`
equals `expected.reason` (`"unparseable"` | `"already_passed"`, §10) — this is the null-vs-throw
resolution and the reason assertion. Every other case calls `parseLeadingTime`.

The corpus is the contract: **never edit a case's `expected` to make a test pass.** If a case is
wrong, that is a corpus defect to raise, not to paper over.

---

## 13. Repo Integration

| File | Change |
|---|---|
| `clients/core/src/time.ts` | Grammar stages, resolution, metadata pre-pass, interval output, split-anchor fallback |
| `clients/core/src/types.ts` | Extend `ParsedTime` (optional `alarm`, `interval`, `ambiguities`) |
| `clients/core/src/errors.ts` | `TimeParseError` keeps `.token` and gains `.reason` (`"unparseable" \| "already_passed"`, §10) |
| `clients/core/src/format.ts` | Echo for dates, periods, and intervals (unchanged for existing forms) |
| `clients/core/test/time.test.ts` | Extended shared-fixture cases + trap regression set |
| `fixtures/time-parse-cases.json` | New grammar cases |
| `fixtures/nl-corpus.json` | Content updated per the owner decisions (`last` removed; `30s ramp`, `next month`, `03/04`, `every 3 days`, and `this <weekday>` pinned; counts updated); add the runner that asserts it |
| `backend/public/nl-time.js` | Verbatim port of every change |
| `backend/public/index.html` | Confirm step + metadata chips around the existing echo |
| `backend/src/server.ts` | General interval: derive `repeat_days` from the anchor for a weekday-less interval; store/emit the interval; ICS gains `FREQ=DAILY;INTERVAL=n`; reject a lone integer outside 0–23 |
| `backend/src/db.ts` | Add the general interval column (`recurrence_interval_days`) + migration (§7) |
| `clients/cli`, `clients/raycast` | Consume the new optional fields through `core`; no new grammar |
| `README.md` | Document the expanded grammar (ASD-STE100, as the file now requires) |

**Mobile change (decided, §7):** `getNextOccurrence` learns day-intervals so a `DAILY;INTERVAL=n`
recurrence schedules correctly.

---

## 14. Goals, Non-Goals, Anti-Goals

### Goals

- Resolve all 169 corpus cases as the corpus specifies (106 already green, 63 to gain).
- Keep every one of the 106 `supported` cases green — no regression.
- Distinguish intervals from weekday sets, so `every 2 weeks 7am` no longer eats the `2` (§5.3).
- Forward-only bare weekdays; day periods with fixed anchors; year-rollover dates.
- Metadata as keyed keywords, extracted anywhere (§8).
- Ambiguity is surfaced and confirmed, never guessed (§9).
- Unresolvable input fails loudly (§10).
- Both implementations stay in lockstep with both fixtures (§12).

### Non-goals

- Timezone behaviour (unchanged, §2).
- Monthly / yearly recurrence or ordinal-of-month semantics.
- Free-text / ML parsing or fuzzy matching.
- New runtime dependencies in `core`.
- New grammar in the CLI/Raycast shells — they consume `core`.
- Dashboard visual design.

### Anti-goals

- **Silently guessing.** A plausible-but-wrong time is the failure this design exists to remove.
- **Resolving a bare weekday into the past.**
- **Resolving a passed `this <weekday>` forward instead of refusing** — it must throw `already_passed` (§6.3, §10).
- **Consuming a bare integer as a clock inside a phrase.**
- **Letting `every <n> <unit>` collapse into a clock.**
- **Demoting an absolute date or `next`/`this` into label text.**
- **Returning a time when the input is unresolvable.**
- **Letting the two implementations diverge**, or editing the corpus to make a test pass.
- **Sweeping a stored interval as one-time** because it has no `repeat_days` (§7).

---

## 15. Open Questions

The blocking questions are resolved and encoded (§6.3, §7, §10, §12.2, §17); the corpus conflicts
are fixed, including whether `this <weekday>` is a token (it is, with a hard `already_passed`
refusal). What genuinely remains:

1. **Metadata keywords versus label words.** Is a label allowed to contain `chime` / `ramp` /
   `note:`? Extraction always wins today's design; is the detailed form the only escape hatch, or
   should the confirm step offer "keep as label"?
2. **Confirm-step scope.** Does the confirm step apply only to genuinely ambiguous input, or also to
   high-consequence forms (intervals, `next month`)? Recommended: only genuine ambiguity.
3. **Corpus in CI.** Should the runner be wired into `run_tests.sh` as a gate, and should the 63
   `target` cases become failing tests immediately (red until implemented) or be enabled case by
   case?

---

## 16. Deliberately Left to the Builder

- The exact internal representation of grammar stages (a single pass with lookahead, a tokeniser +
  parser, or a table of matchers) — as long as it is deterministic and satisfies §5.
- The precise shape of `Ambiguity` and the candidate list, beyond the fields in §9.
- The dashboard confirm-step markup, copy, and interaction details (layout is the designer's job).
- The corpus runner's harness details and where it lives.
- The exact wording of the new `TimeParseError` messages.
- Whether new grammar cases go into `time-parse-cases.json`, the corpus, or both — recommended:
  both, with `time-parse-cases.json` covering the mechanical grammar and the corpus covering
  end-to-end phrasing.
- The internal ordering of the trap regression set.

---

## 17. Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Forward-only weekdays | Always the next occurrence | Owner decision 1; a bare weekday never lands in the past |
| `next`/`this` | Consumed as quantifiers | Fixes the `next monday 7am` label leak |
| `this <weekday>` | The **current ISO week** (Monday-start, `mon=1…sun=7`); a hard **`already_passed` refusal** once that instant has gone | Owner correction; `this` is a weekday token, distinct from bare (forward-only) and `next` (next week) |
| `last` | **Dropped from the grammar** | Owner decision 3; no backwards resolution, no past-time case |
| Intervals vs weekday sets | Number+unit = interval; named day = set | Owner decision 3; fixes `every 2 weeks 7am` |
| Metadata | Keyed keywords, pre-pass, removed anywhere | Owner decision 4; corpus mapping |
| `30s ramp` | Metadata (ramp 30); a bare `30s` stays a duration | Settled call 6; `trap-30s-ramp` and `meta-30s-ramp` agree |
| Ambiguity | Confirmed around the existing echo, never guessed | Owner decision 2 |
| Lone integer > 23 | **Hard rejection**, not an ambiguity | Settled call 5; `inv-24`/`inv-25`; no `bare_integer` kind |
| Unresolvable input | Fail loudly, name the token; the reason (`unparseable` \| `already_passed`) is exposed | Owner decision 5; `TimeParseError.token` / `.reason`; API `rejectedToken` / `reason` |
| Precedence | Leading prefix → trailing/anywhere span → split anchor | Preserves all `supported` cases; recovers interior recurrence |
| Bare integer | A clock only as the entire expression | `clk-bare-7`; keeps stray integers in labels |
| Numeric dates | day/month, with a month-first fallback when unambiguous | `25/12` and `10/31` resolve deterministically; `03/04` pinned by `abs-03-04` |
| Interval storage | **General interval column (Option A)** (§7) | Owner decision 1; `every 3 days` works like `every 2 weeks` |
| Weekday-less interval | Parser keeps `repeatDays: []`; server derives `repeat_days` from the anchor | Owner decision 2; fixes the swept-as-one-time bug |
| Corpus runner | Asserts the **full** `expected` shape; invalid cases asserted via `parseTime` (token + reason) | Settled calls 4 and 7 |
| Unpinned tokens | `next month`, `03/04`, and `this <weekday>` pinned with cases; `last week`, `last month` removed | Settled call 8; no unnamed, untested tokens |
| Contract | Both fixtures, both implementations in lockstep | `time-parse-cases.json` pins; the corpus is the acceptance list |
