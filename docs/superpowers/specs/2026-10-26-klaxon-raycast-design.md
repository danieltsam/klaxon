# Klaxon — Standalone Raycast Extension Design

> **Date:** 2026-10-26
> **Status:** Draft for owner approval. Nothing is built until this is approved.
> **Target repo:** `/Users/dsam/Documents/raycast-extensions/klaxon` (empty Raycast scaffold, no commits)
> **Source of behaviour:** `clients/raycast` in `remote-alarm` — working and already exercised against the live homelab.
> **Approach chosen:** port the working extension and vendor the shared core (owner decision, 2026-10-26).

---

## 1. Context & intent

The product is being renamed **Klaxon** "for everything" (`docs/agent_context/RELEASE-TODO.md`). The Raycast
extension is the owner's primary way to set alarms, so it needs to live under the Klaxon name and in its own
repo, not as a subdirectory of the backend project.

It cannot move as-is. Today `clients/raycast` depends on `@remotealarm/core` through `file:../core`, which
only resolves inside this checkout. A standalone repo cannot install it, publish it, or hand it to anyone else.

The intent is a first-class Klaxon extension that behaves exactly like the working one, installs from its own
repo, and carries the new name throughout — with one deliberate exception. The port stops the silent drop of
parsed recurrence and metadata described in §6.1. Owner decision, 2026-10-26.

---

## 2. What exists today (verified)

| Fact | Evidence |
|---|---|
| Five commands: List Alarms, Quick Create, Create Alarm, Edit Alarm (id argument), Device Status | `clients/raycast/package.json` |
| 1,313 lines of view code; `lib.tsx` (437) holds the shared view helpers | `wc -l clients/raycast/src/*` |
| All alarm state logic, formatting, and NL parsing live in `@remotealarm/core` | `clients/core/src/index.ts` |
| Core is `private: true`, ESM, exposes `dist/index.js` + `.d.ts` | `clients/core/package.json` |
| Core imports use explicit `.js` specifiers (`./types.js`) | `clients/core/src/index.ts` |
| The parser is pinned by a 179-case corpus; all 63 target cases asserted, 0 remaining | `fixtures/nl-corpus*.json` |
| The backend has no authentication | `backend/src/server.ts` has no `Authorization` check |
| The backend can store only `recurrence_interval_weeks` (1 or 2), not day intervals | `backend/src/db.ts` |
| Live backend: `eb30076`, `delivery_health.ok: true` | `ssh baymax`, `GET /api/health` |
| Scaffold: `@raycast/api ^2.9.0`, `@raycast/utils ^2.2.7`, TypeScript 6, flat ESLint, `src/` empty, `commands: []` | `klaxon/package.json` |
| Toolchain present: `ray` 1.104.21, Node 26.8.2 | `ray --version` |

---

## 3. Goals, non-goals, anti-goals

**Goals**

- Feature parity with `clients/raycast`, running from the new repo with no `file:` dependency.
- Klaxon naming in every user-facing string.
- The same guardrails that make the current extension trustworthy: a missed alarm is never treated as live, a
  dispatch report is shown as "sent", never "delivered", and silence is confirmable.
- The NL parser keeps its corpus guarantee inside the new repo, so a future edit cannot silently break it.
- What the parser resolves is what gets stored: a parsed fortnightly interval, tone, ramp or note reaches the
  backend instead of being discarded by the view (§6.1).

**Non-goals**

- No new commands, no new alarm fields, no UI redesign. The command set and layouts port unchanged.
- No day-interval support. The schema has no column for it; `every 3 days` is refused in the view rather than
  silently stored as a one-time alarm. Adding the column is a separate task (NL spec §7).
- No new metadata UI. Tone, ramp and description already exist as fields; only their carriage from the parse
  changes.
- No authentication preference. The server has none; adding a client-side one would imply a protection that
  does not exist.
- No Raycast Store submission and no changes to the `remote-alarm` repo or the live backend.

**Anti-goals**

- A second, drifting copy of the time parser with no tests.
- An extension that looks like Klaxon but still says "Remote Alarm" in toasts, errors, or help text.
- Widening scope into features the backend cannot back.

---

## 4. Constraints

- Raycast bundles with esbuild and does not run `tsc`'s module resolution; the vendored core must import without
  a build step.
- TypeScript is `strict` with `isolatedModules`; the scaffold's compiler settings win over the old repo's.
- The API contract is `backend/src/server.ts` as deployed at `eb30076`.
- Raycast extensions run on the user's Mac and talk to the backend directly over HTTP.
- No secrets in the repo. The backend URL is a preference, not a checked-in value.

---

## 5. Approach

**Chosen: port + vendor.** Copy the five command files and `lib.tsx` almost verbatim; copy `clients/core/src`
into `src/core/`; rewrite its internal `.js` import specifiers to extensionless; copy the parser and
relative-time fixtures plus the pure tests. Everything becomes one self-contained bundle.

Alternatives rejected:

- **Link to `remote-alarm/clients/core`** (`file:` or workspace). Keeps one source of truth, but the two repos
  must sit side by side and be checked out together. It reproduces today's portability problem.
- **Fresh self-contained client.** Cleanest repo, but re-deriving the API client and the NL grammar is the bulk
  of the work and would either lose the 63-case corpus guarantee or duplicate it anyway.

The cost of vendoring is drift. It is partly contained by copying the fixtures and tests with the code:
a change to the vendored parser that breaks the corpus fails `npm test`. What that cannot catch is
upstream movement — the copied corpus is a snapshot, so if `remote-alarm` evolves, `klaxon` stays
green on an older contract. The copy therefore records its provenance in `VENDORED-FROM.md`: source
paths, the `remote-alarm` commit hash, and the date. Re-vendoring is a documented diff against that
commit, not a guess. `fixtures/nl-corpus.json`'s `canonicalParser` field also names
`clients/core/src/time.ts`; in the copy it is rewritten to `src/core/time.ts` so it does not point at
a file that does not exist.

---

## 6. Layout and mechanics

```
klaxon/
  assets/extension-icon.png      from clients/raycast/assets/icon.png (verify 512×512)
  fixtures/                      nl-corpus.json, nl-corpus-asserted.json,
                                 relative-time-cases.json, time-parse-cases.json
  src/
    core/                        vendored @remotealarm/core
      types.ts errors.ts format.ts time.ts client.ts index.ts
    lib.tsx                      shared view helpers, Klaxon copy
    list-alarms.tsx quick-create.tsx create-alarm.tsx
    edit-alarm.tsx device-status.tsx
  test/
    nl-corpus.test.ts            asserted targets === 0 remaining, traps covered
    relative-time.test.ts        shared prose/compact cases
    time.test.ts format.test.ts
    client.test.ts               wire mapping (injects fetch; no server needed)
  help.md                        backend URL help, Klaxon copy
  README.md                      what it is, install, preferences
  VENDORED-FROM.md               source paths, commit hash, date of the copy
  package.json                   commands, preferences, scripts
```

**Import mechanics**

- `src/core/*.ts`: `./types.js` → `./types`. Only relative specifiers change; no logic changes.
- Views: `from "@remotealarm/core"` → `from "./core"`.
- `tsx` is added as a dev dependency; `"test": "tsx --test test/**/*.test.ts"` sits alongside the scaffold's
  `build`/`dev`/`lint` scripts, which stay as generated.
- The scaffold's `tsconfig.json` includes only `src/**/*`; it gains `test/**/*` so the ported tests are
  type-checked and linted rather than silently outside the project.

**Preferences** (unchanged shape, Klaxon copy)

- `backendUrl` — textfield, required, placeholder `http://klaxon.tailnet:3000`.
- `confirmDestructive` — checkbox, default true, "Confirm before cancel".

**Commands** (same five, same names, Klaxon titles)

| Command | Title | Notes |
|---|---|---|
| `list-alarms` | List Alarms | Grouped Ringing / Missed / Today / Upcoming / Recurring; detail pane |
| `quick-create` | Quick Create Alarm | NL input, live resolved-time preview, reachability hint |
| `create-alarm` | Create Alarm | Full precision form |
| `edit-alarm` | Edit Alarm | `id` text argument |
| `device-status` | Device Status | Battery, charging, last ping age |

### 6.1 Carrying parsed fields (owner decision, 2026-10-26)

The parser resolves more than a time, and the views currently throw the rest away: `quick-create` sends only
`target_time`, `repeat_days`, tone and ramp, so `every 2 weeks 7am Gym` creates a **one-time** alarm and
`chime tomorrow 7am` takes the settings tone. The dashboard's NL create has the same hole. The port fixes
this end to end instead of reproducing it.

| Parsed field | Goes to | Rule |
|---|---|---|
| `interval.count` 1–2, `unit: "weeks"` | `recurrence_interval_weeks` | Sent as-is; the backend anchors the alarm to its first occurrence |
| `interval.unit: "days"`, or weeks > 2 | nothing | **Refused in the view** with a message saying it cannot be stored. Never silently one-time |
| `alarm.sound_tone` | `sound_tone` | Overrides the form's dropdown when the sentence names a tone |
| `alarm.ramp_seconds` | `ramp_seconds` | Same precedence |
| `alarm.description` | `description` (from `note:`) | Used when present; the label keeps the rest of the sentence |

**Scope.** `clients/core` (`createAlarm` payload and types), `clients/cli`, the dashboard's NL payload builder,
and this extension. The new repo vendors the updated core, so the port does not create a fork. The backend
needs no change for weeks 1–2 — it already validates and auto-anchors them (`server.ts:540-562`).

**Precedence, stated once.** An explicit parsed value beats a form default; a form value the user typed beats
nothing else, because the sentence is the more specific statement. Where both are present the preview must
show the parsed value, so the user sees what will be stored.

---

## 7. Naming

"Klaxon" replaces "Remote Alarm" in every user-facing string. The rename is not cosmetic — a half-renamed
extension is the failure mode this section exists to prevent.

| Surface | Becomes |
|---|---|
| `package.json` `name` / `title` / `description` | `klaxon` / `Klaxon` / `Set, inspect, and silence alarms on your Klaxon backend.` |
| Toasts | title `Klaxon` |
| Error copy | "Could not reach the Klaxon backend." |
| Empty views | "No alarms" · "Press ⌘K to create your first alarm." |
| Help and README | Klaxon wording, tailnet examples use `klaxon.tailnet` |
| Type names | keep `RemoteAlarmClient` / `RemoteAlarmError` in the vendored core for this pass (see §10) |

The lowercase `klaxon` wordmark is the product's established casing (`backend/public/index.html`); titles and
sentences use `Klaxon` where a sentence begins.

---

## 8. Preserved behaviour (do not regress)

- `missed` is never treated as live: enable is refused with a reschedule message, and it never falls into
  Today/Upcoming.
- A dispatch with `sent === 0` reports "Saved, but no devices are registered — this alarm won't ring."
- Status colours and icons are ported as-is, including orange `ExclamationMark` for missed.
- Cancel honours `confirmDestructive`; silence does not, because it is the recovery action.
- The detail pane shows missed time and reason, and a reachability warning when no device has pinged in 24h.

---

## 9. Verification

- `npm run lint` clean; `npm run build` succeeds (this is the real test of the vendoring).
- `npm test` — corpus reports 63 asserted, 0 remaining; relative-time cases pass.
- `ray develop`, then against `http://100.72.232.98:8001`: list renders the current five alarms with correct
  groups; device status shows the phone; quick-create previews `tomorrow 6pm`; one throwaway alarm created,
  edited, cancelled; toasts say Klaxon.
- Side-by-side with the old extension: same alarms, same groups, same copy apart from the name.
- §6.1 carriage, on a throwaway alarm: `every 2 weeks 7am Gym` stores `recurrence_interval_weeks: 2` and an
  anchor; `chime tomorrow 7am` stores `sound_tone: chime`; `note:` text lands in `description`; `every 3 days`
  is refused with a message and creates nothing.
- No real alarm is silenced or cancelled during verification.

---

## 10. My calls (correct these if wrong)

1. **Parity of behaviour, not of defects — resolved.** The owner chose to wire parsed fields end to end
   before the port (§6.1) rather than reproduce the silent drop. Weeks 1–2 and tone/ramp/note are carried;
   day intervals are refused because the schema cannot store them. This changes `clients/core` first, and
   the extension vendors the changed copy.
2. **Keep `RemoteAlarmClient` / `RemoteAlarmError` type names** in the vendored core. They are internal; renaming
   them now adds diff noise to a port. A later `@klaxon/core` package rename can do it properly.
3. **Reuse the existing icon** as `extension-icon.png` rather than designing a new mark in this pass. (The
   scaffold's template icon is overwritten; §6 is literal.)
4. **`private: true` stays** for now; the store-submission decision belongs with the public release, not here.
5. **Design docs stay in `remote-alarm/docs/superpowers/specs/`**, not in the extension repo, so the Klaxon
   story is in one place.
6. **Tests port all five core test files, including `client.test.ts`.** It injects `fetch`, needs no server,
   and runs 34 tests in ~190 ms; it is the only guard on the wire mapping that vendoring touches. The
   scaffold's `tsconfig.json` includes only `src/**/*`, so it gains `test/**/*` or the tests are silently
   skipped by every type-check and lint.

---

## 11. Left to the builder

- Exact Raycast API 2.9 adjustments if any construct from 2.4 changed (`useFetch`, `List.Item.Detail`, `Form`).
- Whether `src/core` needs a barrel alias for readability.
- Icon sizing verification and any `package.json` metadata the store would need later.
- Splitting `lib.tsx` if it proves awkward inside the new scaffold; not a goal in itself.
