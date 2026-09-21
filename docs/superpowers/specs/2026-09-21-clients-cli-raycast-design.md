# Remote Alarm — Clients (Core, CLI, Raycast Extension) Design

> **Date:** 2026-09-21
> **Status:** Approved design — pending written-spec review, then implementation plan
> **Scope:** New `clients/` tree in this repository. Zero backend changes.
> **Roadmap reference:** `docs/ROADMAP.md` §2.4 "CLI Companion & Raycast Extension"

---

## 1. Context & Intent

Remote Alarm today has two ways to interact with it: a web dashboard and the Android app.
Both require leaving the current context — a browser tab or the phone itself.

This design adds two headless clients that share one logic core:

- **`alarm`** — a terminal command for scripting and fast ad-hoc scheduling.
- **A Raycast extension** — the daily driver, driven by a global hotkey.

**Intended outcome.** Create, inspect, edit, silence, and cancel hardware alarms from the
laptop, over the existing Tailscale mesh, without opening a browser.

**Success criterion.** From a Raycast hotkey, `Oven, 25 minutes` is committed in under five
seconds, and a ringing alarm is silenced in one keystroke.

**Why a shared core rather than two independent clients.** The two surfaces need
identical, subtle behaviour — timezone conversion, `repeat_days` encoding, error mapping.
Duplicating that logic would guarantee drift in exactly the places where a mistake means an
alarm fires at the wrong hour or not at all.

---

## 2. Scope

### In scope

| Capability | Endpoint |
|---|---|
| List alarms (`active` / `history` / `all`) | `GET /api/alarms?view=` |
| Create alarm | `POST /api/alarms` |
| Edit alarm | `PATCH /api/alarms/:id` |
| Cancel alarm | `DELETE /api/alarms/:id` |
| Silence a ringing alarm | `POST /api/alarms/:id/silence` |
| Enable / disable / snooze | `POST /api/alarms/:id/state` |
| Recurrence (once / daily / weekdays / weekends / custom) | `repeat_days` field |
| Tone + volume ramp | `sound_tone`, `ramp_seconds` fields |
| Device battery / charging / last-ping | `GET /api/devices` |
| Default tone + ramp for new alarms | `GET /api/settings` |

### Explicitly out of scope

- **Global settings editing** (`POST /api/settings`). Read-only use of defaults only.
- **Google Calendar / Tailscale calendar subscription.** This is the second half of the
  original request and is a separate subsystem deserving its own design. It is *not*
  designed or estimated here.
- **Authentication.** See §12.1 — a deliberate accepted risk.
- **Monthly / yearly recurrence.** The backend only expresses weekly `BYDAY`; anything else
  would be a capability we cannot honour.
- **Raycast store publishing**, menu-bar commands, AI tools.
- **Any backend change.** Every operation maps to an existing route.

---

## 3. Verified Constraints

These are not assumptions. Each was verified during reconnaissance, and the toolchain
claims were verified by a throwaway spike (`/var/folders/.../T/opencode/raycast-spike`).

### 3.1 Toolchain — spike-verified

| Claim | Verification | Result |
|---|---|---|
| Raycast extension can consume a sibling TS package via `file:` | `npm install` in spike | Symlink `node_modules/@remotealarm/core -> ../../../core` |
| The package is **bundled**, not required at runtime | Inspected `dist/spike.js` | `// ../core/dist/index.js` inlined at line 28; only `@raycast/api` and `react/jsx-runtime` remain `require`d |
| ESM core + CJS extension tsconfig coexist | `ray build` type-check | Passes — resolution via `node_modules/@remotealarm/core/*.d.ts`, no TS6059 |
| Missing `core/dist` fails loudly | Deleted `dist`, rebuilt | `Could not resolve "@remotealarm/core"` |
| `ray lint --relaxed` skips author validation | Ran it | **FALSE** — relaxed still calls `GET /users/<author>`, rejected a placeholder |
| `-e` is the output flag | Ran it | **FALSE** — `-e` is `--exit-on-error`; output needs `-o <dir>` |

**Pinned versions:** `@raycast/api@2.4.1`, `@raycast/utils@2.3.1`, React 19.0.0,
Node target 22.22.2. Local Node v26 runs the CLI but extension code executes on Raycast's
own bundled Node 22 — core must not depend on Node-24+ APIs.

**Author handle:** `danieltsam` — verified `HTTP 200` against the Raycast users API, so
`ray lint` is viable and is part of the verification gate.

### 3.2 Backend contract — recon-verified

- `GET /api/alarms` returns a **bare JSON array**, not a wrapper.
- `repeat_days` accepts `string | number[]` on input but **always returns a comma-joined
  string**. Encoding is `1=Mon … 7=Sun` (`server.ts:61-69`, `:360`, `:377`).
- `target_time` is an ISO-8601 UTC string; the server zeroes seconds/ms (`server.ts:150`).
- **Local→UTC conversion is the client's job.** The mobile client does
  `.toUtc().toIso8601String()` before sending (`backend_client.dart:116-127`).
- `sound_tone` **fails open** on create/edit — an invalid value silently becomes `alarm`.
  Only `POST /api/settings` returns 400.
- `ramp_seconds` accepts any non-negative integer per-alarm (default 30), but `/api/settings`
  accepts only `0|15|30|60`. Two different valid sets.
- `fcm_dispatch` (`{sent, failed}`) is **omitted entirely** for state transitions to
  `ringing`/`dismissed`/`snoozed`. In Firebase mock mode it reports
  `sent = deviceCount` **while delivering nothing** (`fcm.ts:105-108`).
- `400` validation errors are `{ error: string }`. **`404` has two different shapes**, verified
  live: an unknown alarm id returns `{ "error": "Alarm not found" }`, but an unmatched route
  returns Fastify's default
  `{ "message": "Route GET:/x not found", "error": "Not Found", "statusCode": 404 }`.
  Error mapping must therefore read `body.error ?? body.message`, or the useful message is
  replaced by the useless string `"Not Found"`.
- Absent optional fields are returned as **explicit `null`**, not omitted — verified:
  `repeat_days: null`, `description: null`. Null-coercion is mandatory; a
  `Weekday[] | undefined` type silently receives `null`.
- `sound_tone` fails open **silently** on create/edit — verified: `"BOGUS"` was stored as
  `"alarm"` with no error. Client-side validation is the only real guard; the server will
  not reject a bad tone.
- `created_at` is SQLite `datetime('now')` format (`"2026-09-21 09:56:15"`), not ISO — do
  not `Date.parse` it blindly.
- **No authentication of any kind.** CORS is `origin: true`.
- `GET /api/devices` returns masked tokens, battery, charging, and a SQLite
  `datetime('now')` timestamp (not ISO).

### 3.3 Repo state

- No root `package.json`, no workspaces, no root TypeScript. `clients/` inherits nothing.
- `npm registry` reachable; Node v26.8.2 / npm 11.19.1.
- `.gitignore` covers `node_modules/` (unanchored, so it works) but **not** `clients/**/dist/`.
- `run_tests.sh` runs backend then mobile under `set -e`; no slot for new packages.
- `docs/agent_context/backlog.md:78` specifies `extensions/remotealarm` — **stale**; this
  design uses `clients/raycast` and will correct that reference.
- Backend is **not currently running**. Docker maps host `8001`→container `3000`; native dev
  binds `3000`.

---

## 4. Architecture

```
clients/
├── package.json            # npm workspaces root; aggregate scripts
├── README.md               # setup, dev loop, verification commands
├── core/                   # @remotealarm/core — ALL logic lives here
│   ├── src/
│   │   ├── index.ts        # public surface (types + client + parser)
│   │   ├── types.ts        # wire + domain types
│   │   ├── client.ts       # RemoteAlarmClient (fetch-based)
│   │   ├── time.ts         # natural-language time parser
│   │   ├── errors.ts       # RemoteAlarmError hierarchy
│   │   └── format.ts       # shared display formatters
│   ├── test/
│   │   ├── time.test.ts
│   │   ├── client.test.ts
│   │   └── format.test.ts
│   ├── package.json        # main: dist/index.js, types: dist/index.d.ts
│   └── tsconfig.json
├── cli/                    # bin: alarm
│   ├── src/index.ts
│   └── package.json
├── raycast/                # Raycast extension
│   ├── src/{list-alarms,quick-create,create-alarm,edit-alarm,device-status}.tsx
│   ├── assets/icon.png
│   ├── help.md
│   ├── package.json
│   └── tsconfig.json
└── scripts/
    └── smoke.sh            # live end-to-end proof
```

### 4.1 The one structural rule

**`core` is the only package with logic.** `cli` and `raycast` are presentation shells:
they parse input, call core, and render results. If either shell starts making decisions
about timezones, encodings, or error semantics, that logic belongs in core.

### 4.2 Hard constraints on `core`

- **Zero runtime dependencies.** Pure TypeScript over the global `fetch`.
  Rationale: Raycast's esbuild explicitly rejects native `.node` modules, and a transitive
  dependency is a permanent liability. Any future dependency must be justified against this.
- Must not use Node-24+ APIs — the Raycast host runs Node 22.22.2.
- Must not import React.

### 4.3 Build topology

```
core  --(tsc)-->  dist/index.js + index.d.ts
                      |
        +-------------+-------------+
        |                           |
   cli (tsx/tsc)            raycast (file:../core, esbuild inlines it)
```

`ray develop` **does not watch `../core`** (verified: removing `dist` hard-fails the build).
Therefore the dev loop **must** run a core watcher concurrently. This is a correctness
requirement, not a convenience: a stale-but-present `dist` would ship old logic silently.

Root scripts (`npm-run-all` is the only root devDependency; `core` itself stays
dependency-free per §4.2):
```jsonc
{
  "build":     "npm run build -w @remotealarm/core",
  "dev":       "npm-run-all -p watch:core dev:raycast",
  "watch:core":"npm run build -w @remotealarm/core -- --watch",
  "dev:raycast":"npm --prefix raycast run dev",
  "test":      "npm run test -w @remotealarm/core"
}
```

---

## 5. Core — Types & Client

### 5.1 Types

```ts
export type AlarmStatus =
  | "pending" | "ringing" | "dismissed" | "snoozed" | "canceled" | "disabled";

export type SoundTone = "alarm" | "chime" | "digital";
export type Weekday = 1 | 2 | 3 | 4 | 5 | 6 | 7;   // 1=Mon … 7=Sun

export interface Alarm {
  id: string;
  target_time: string;          // ISO-8601 UTC, as returned by the server
  label: string;
  description?: string;
  status: AlarmStatus;
  repeat_days?: Weekday[];      // DECODED — never the raw comma-string
  sound_tone?: SoundTone;
  ramp_seconds?: number;
  created_at?: string;
}

export type CreateAlarmInput = {
  label: string;
  description?: string;
  repeat_days?: Weekday[];
  sound_tone?: SoundTone;
  ramp_seconds?: number;
} & (
  | { when: string; targetTime?: never }   // natural language, parsed by core
  | { targetTime: Date; when?: never }     // absolute local instant, no parsing
);

export interface FcmDispatch { sent: number; failed: number }

export interface AlarmMutationResult {
  alarm: Alarm;
  dispatch?: FcmDispatch;       // absent for some transitions — see 5.4
}

/** `POST /api/alarms/:id/state` accepts a strict subset — `canceled` is rejected (400). */
export type SetStateStatus = Exclude<AlarmStatus, "canceled">;

export interface UpdateAlarmInput {
  when?: string;                // natural language; re-parsed by core
  label?: string;
  description?: string;
  repeat_days?: Weekday[];
  sound_tone?: SoundTone;
  ramp_seconds?: number;
  status?: SetStateStatus;
}

export interface Health { status: "ok"; timestamp: string }

export interface DeviceStatus {
  token_masked: string;
  device_name: string;
  battery_level: number | null;
  is_charging: boolean;
  updated_at: string;           // SQLite datetime('now'), NOT ISO — do not Date.parse blindly
}

export interface Settings {
  sound_tone: SoundTone;
  ramp_seconds: number;         // narrowed to 0|15|30|60 on write only
  date_format: "dd/mm/yyyy" | "mm/dd/yyyy" | "yyyy-mm-dd";
  time_format: "24h" | "12h";
}

/** Injectable clock/transport seam so contract tests need no network. */
export type FetchLike = typeof fetch;

export interface TimeoutConfig { health: number; read: number; write: number }
```

### 5.2 Client surface

```ts
class RemoteAlarmClient {
  constructor(config: { baseUrl: string; timeouts?: Partial<TimeoutConfig>; fetch?: FetchLike });

  health(): Promise<Health>;
  listAlarms(view?: "active" | "history" | "all"): Promise<Alarm[]>;
  createAlarm(input: CreateAlarmInput): Promise<AlarmMutationResult>;
  updateAlarm(id: string, patch: UpdateAlarmInput): Promise<AlarmMutationResult>;
  cancelAlarm(id: string): Promise<AlarmMutationResult>;
  silenceAlarm(id: string): Promise<AlarmMutationResult>;
  setState(id: string, status: SetStateStatus, targetTime?: Date): Promise<AlarmMutationResult>;
  listDevices(): Promise<DeviceStatus[]>;
  getSettings(): Promise<Settings>;
}
```

`fetch` is injectable so contract tests need no network and no server.

### 5.3 Normalization rules (all at the boundary)

1. **`repeat_days` in:** `Weekday[]` → `"1,2,3,4,5"`. **Out:** comma-string → `Weekday[]`,
   discarding out-of-range entries. The wire type is overloaded (`string | number[]`) and
   **also uses `null` for absent values** — coerce `null` → `undefined` so `null` never
   reaches the domain type. This is the easiest place to ship a silent bug.
2. **`target_time` out:** zero seconds and milliseconds before send, mirroring
   `server.ts:150`, so the value we echo to the user is byte-identical to what is stored.
3. **`target_time` in:** `Alarm.target_time` stays the raw UTC string exactly as returned.
   Local-time derivation is a named helper (`toLocalDate(alarm)`) in `format.ts`, so callers
   never hand-roll a conversion and there is exactly one place it can go wrong.
4. **`baseUrl`:** strip a trailing slash once at construction. A double slash produces a 404
   that looks like a missing route rather than a typo.
5. **Timeouts:** `AbortSignal.timeout()` on every request (health 4s, writes 8s, reads 10s —
   matching the mobile client). undici's defaults are far too long to fail fast behind a
   hotkey.
6. **Absolute time input:** `createAlarm`/`updateAlarm` accept either `when` (natural
   language) or `targetTime` (an absolute local instant). `targetTime` bypasses parsing but
   goes through the *same* conversion point as parsed times — it must never introduce a
   second timezone path (§6.5). For create the two are mutually exclusive at compile time
   (discriminated union); for update, at most one, rejected at runtime. **An empty
   `repeatDays` must be sent as `undefined`, never `[]`** — sending `[]` turns a one-time
   alarm into a recurrence. The form-based clients (§8.4) depend on this path, since a
   `DatePicker` cannot express an arbitrary date as natural language.

### 5.4 Error handling

```ts
class RemoteAlarmError extends Error {
  status?: number;          // HTTP status, if the request reached the server
  serverMessage?: string;   // the { error } body, verbatim
}
class RemoteAlarmNetworkError extends RemoteAlarmError {}  // unreachable / DNS / timeout
class RemoteAlarmNotFoundError extends RemoteAlarmError {} // 404
```

The client **always** surfaces the server's own message rather than replacing it with a
generic one — the backend's validation messages are specific and useful
(e.g. `"Missing required fields: target_time and label are required."`). Because `404`
arrives in two shapes (§3.2), the extractor is `body.error ?? body.message ?? fallback`.

`fcm_dispatch` is carried as a **separate, explicitly-untrusted** field. It is never folded
into a boolean `success`. See §9.

---

## 6. Core — Time Parser

### 6.1 Contract

```ts
interface ParsedTime {
  targetTime: Date;         // local wall-clock instant
  repeatDays: Weekday[];    // empty = one-time
  interpretation: string;   // human-readable echo, e.g. "Tue 22 Sep, 7:00am (in 13h 40m)"
}
parseTime(input: string, now?: Date): ParsedTime;   // throws TimeParseError
```

`now` is injectable for deterministic tests.

### 6.2 Grammar

Single expression, matched as the **longest leading prefix**. Case- and
whitespace-insensitive. This same rule powers the CLI's time/label split (§7.1).

| Form | Examples | Semantics |
|---|---|---|
| Duration | `25m`, `25 min`, `1h`, `1h30m`, `2h15m`, `90s`, `45 seconds`, `in 25m` | now + duration. No recurrence. |
| Clock | `7am`, `7:30am`, `07:00`, `19:00`, `at 7am`, `7` | Next occurrence. If already passed → +1 day. |
| Day-qualified | `tomorrow`, `tmr`, `tomorrow 6pm`, `today 6pm`, `mon 8:30am`, `friday 7:30pm` | Weekday resolves to the next matching day; today counts if the time has not passed. |
| Recurrence | `daily 7am`, `every day 7am`, `weekdays 7am`, `weekends 7am`, `mon-fri 7am`, `mon,wed,fri 7am`, `every mon 7am` | Sets `repeatDays`; `targetTime` is the next matching occurrence. |

Optional connectors `at` and `in` are stripped: `tomorrow at 7am`, `in 25m`.

### 6.3 Determinism rules (documented, not guessed)

- Bare `7` (no am/pm, no colon) → **07:00**. Bare numbers are read as a 24-hour hour, valid
  `0–23`, so `19` → 19:00.
- `7:30` without am/pm → **24-hour**, i.e. 07:30. `19:30` → 19:30.
- `12am` → **00:00**; `12pm` → **12:00** (conventional reading; `13pm` is invalid because a
  meridiem implies a 1–12 hour).
- `25:00`, `13pm`, `1x30m`, `-5m` → `TimeParseError` with a message naming the offending
  token. Note `99m` is **valid** (1h39m) — a large duration is not an error.
- Duration suffix disambiguates from hour: `25m` is 25 minutes; `25` is an invalid hour.
- A passed clock time with no day qualifier → **+1 day** (mirrors the backend's one-time
  roll semantics in `rollTargetTimeToFuture`).
- `mon-fri` expands to `[1,2,3,4,5]`; `weekdays` → same; `weekends` → `[6,7]`;
  `daily`/`every day` → `[1,2,3,4,5,6,7]`.

### 6.4 Explicit non-goals

Monthly/yearly recurrence, ordinal dates ("second Tuesday"), timezone-qualified input
("7am PST"), and date arithmetic beyond "next matching weekday". The backend can only
express weekly `BYDAY`; offering more would be a promise we cannot keep.

### 6.5 The timezone contract — highest-risk item

**Rule:** the parser produces a *local wall-clock* `Date`. The client converts to UTC via
`.toISOString()` **immediately before sending**. Nothing else in the system converts
timezones.

This mirrors the mobile client (`alignedTarget.toUtc().toIso8601String()`) and is the
behaviour the backend is built against.

**Mitigation against silent wrong-hour bugs:** both surfaces **echo the resolved absolute
local time** before committing (`→ Tue 22 Sep, 7:00am`). A timezone error is then visible
at creation time rather than at 3am. This echo is a hard requirement, not a nicety.

**Inherited limitation (documented, not fixed):** the backend stores UTC instants and never
re-derives local time, so a recurring alarm set during one DST offset would drift by an hour
after a DST transition. **This already affects the existing mobile app and dashboard** — it
is not introduced here. Fixing it would require a backend change and is out of scope. In a
no-DST zone the limitation is moot.

---

## 7. CLI

Binary name `alarm`, matching `ROADMAP.md:52` verbatim.

### 7.1 Time / label split

Positional arguments are joined into one string. The **longest leading prefix that parses
as a single time expression** becomes the time; the remainder is the label.

```
alarm 25m Oven              -> when="25m",        label="Oven"
alarm tomorrow 6pm Call mum -> when="tomorrow 6pm", label="Call mum"
alarm 8am 5 minute warning  -> when="8am",        label="5 minute warning"
```

Because the parser matches a single expression (not a concatenation), `"8am 5"` does not
parse as one unit and the split stays unambiguous. `--at` and `--label` override for the
rare case where it is not.

If **no** leading prefix parses as a time expression (e.g. `alarm Oven`), the command exits
`1` with a usage message showing the accepted forms. It never silently guesses a time.

### 7.2 Commands

```
alarm <when> <label> [flags]        Create
alarm list [--all|--history|--json] List (default view: active)
alarm silence <id>                  Silence a ringing alarm
alarm kill <id>                     Cancel (DELETE)
alarm enable <id> | disable <id>    State transitions
alarm edit <id> [flags]             Edit fields
alarm status                        Device battery / charging / last ping
alarm config [--url <base>]         Show or set the backend URL
```

Create flags: `-d/--days <spec>`, `--tone <alarm|chime|digital>`, `--ramp <0|15|30|60>`,
`--desc <text>`, `--json`.

### 7.3 Configuration

- File: `~/.config/remotealarm/config.json` (XDG-respecting).
- Environment override: `REMOTEALARM_URL`.
- Precedence: flag → env → config → default.
- Default `http://localhost:3000`, **but** on connection-refused the error explicitly names
  `:8001` (the docker mapping) and the Tailscale hostname pattern. A bare "ECONNREFUSED"
  would leave the user guessing between two valid ports.

### 7.4 Scriptability

- **Exit codes:** `0` ok · `1` usage/parse error · `2` network error · `3` API error ·
  `4` not found. These map onto the error hierarchy in §5.4.
- `--json` on every command for piping.
- `--no-color` honoured; colour auto-disabled when not a TTY.
- `kill` prompts interactively but requires `--yes` when stdin is not a TTY, so a script can
  never delete an alarm by accident.
- Every mutating command prints the server-confirmed alarm with its resolved local time.

---

## 8. Raycast Extension

Manifest: author `danieltsam`, `platforms: ["macOS"]`, icon `assets/icon.png`.

### 8.1 Commands

| Command | Mode | Purpose |
|---|---|---|
| `list-alarms` | view | Default. Browse, search, act. |
| `quick-create` | view | Frictionless: natural-language text + live preview. |
| `create-alarm` | view | Full form for precision. |
| `edit-alarm` | view | Full form prefilled; `id` argument, pushed from the list. |
| `device-status` | view | Battery, charging, last ping, masked token. |

### 8.2 `list-alarms`

`List` with `isShowingDetail`, grouped into **Ringing / Today / Upcoming / Recurring**.
Header accessory shows phone battery and last-ping age so reachability is visible without
opening another command.

Actions, in priority order:

1. **Silence** — rendered *only* when an alarm is actually `ringing`. Primary action.
2. Enable / Disable.
3. Edit — `Action.Push` to `edit-alarm`.
4. Cancel — behind `confirmAlert` with `Alert.ActionStyle.Destructive`.
5. Copy ID.
6. Refresh.

Refreshes on a 10-second interval while open (`setInterval` + `revalidate`, cleaned up on
unmount — `useFetch` has no built-in polling).

### 8.3 `quick-create`

The zero-friction path: a single natural-language text field with a **live resolved-time
preview** rendered as the user types, plus tone and ramp dropdowns. The preview is the
user-facing half of the §6.5 mitigation — it makes a timezone error obvious before commit.

### 8.4 `create-alarm` / `edit-alarm`

`Form` with `Form.TextField`, `Form.DatePicker` (`Type.DateTime` — there is no time-only
mode), `Form.Dropdown` for recurrence and tone, `Form.TextField` for ramp. Validation via
`useForm` + `FormValidation.Required`.

The `DatePicker` feeds the client's absolute `targetTime` path (§5.3 rule 6), so **any**
date is selectable. An earlier implementation converted the picked `Date` back into a
natural-language string and was therefore limited to the next 7 days; that workaround is
gone. `Quick Create` likewise passes `leading.parsed.targetTime` directly rather than
re-parsing a re-derived string, and **must forward `parseLeadingTime(...).parsed.repeatDays`
explicitly** — because `targetTime` bypasses parsing, omitting it would silently downgrade
`weekdays 7am Walk` to a one-time alarm.

### 8.5 Preferences

| Preference | Type | Required | Notes |
|---|---|---|---|
| `backendUrl` | textfield | yes | `help.md` explains homelab/Tailscale setup. |
| `confirmDestructive` | checkbox | no | Default `true`. |

**No tone/ramp preferences.** `GET /api/settings` already holds those defaults; duplicating
them into preferences would create two sources of truth. The extension reads the server.

---

## 9. Trust & Delivery Messaging

This section exists because the backend's delivery reporting is **misleading**, and a user
who believes a delivered alarm when it was not delivered will miss something important.

**The problem:** `fcm_dispatch` reports `sent = deviceCount` in Firebase mock mode while
delivering nothing (`fcm.ts:105-108`), and is omitted entirely for `ringing`/`dismissed`/
`snoozed` transitions.

**Rules, applied in both surfaces:**

1. Never say **"delivered"**. Say **"command sent"**.
2. `sent === 0` → explicit warning: *"Saved, but no devices are registered — this alarm
   won't ring."* This is a real, actionable condition (the phone has never registered).
3. Device last-ping older than ~24h → amber indicator in the list header, and a warning on
   create. Reachability is asserted from `/api/devices`, **never** inferred from
   `fcm_dispatch`.
4. A missing `fcm_dispatch` is rendered as "no dispatch report", not as failure or success.

---

## 10. Repo Integration

| File | Change |
|---|---|
| `.gitignore` | Add `clients/**/dist/`, `clients/**/*.tsbuildinfo`, `clients/raycast/.raycast/`. (`node_modules/` already matches unanchored.) |
| `run_tests.sh` | Add step 3 `npm test` under `clients/`; relabel steps `[1/3]`, `[2/3]`, `[3/3]`. Keep `set -e`. |
| `docs/agent_context/backlog.md:78` | Correct stale `extensions/remotealarm` → `clients/raycast`. |
| `docs/ROADMAP.md` §2.4 | Mark in progress; link this spec. |
| `clients/README.md` | New: setup, dev loop (including the mandatory core watcher), verification. |

**No backend files change.**

---

## 11. Verification

### 11.1 Core unit tests — `node:test` + `node:assert/strict`

Matches the existing backend convention (`backend/package.json:11`, `tsx --test`).

- **Parser, table-driven (~40 cases):** every grammar form in §6.2; boundaries — midnight
  rollover, `23:59`, bare `7`, `7:30` 24-hour reading, `25:00` and `13pm` rejection,
  weekday mapping for all seven days, range and list expansion, `in`/`at` connectors.
- **Parser round-trip:** requested wall clock → `targetTime` → `.toISOString()` →
  re-derived local time equals the requested wall clock. This is the direct test of §6.5.
- **Client contract, stubbed `fetch`:** exact request bodies — `repeat_days` array encoded
  to a comma-string, seconds/ms zeroed, headers; and responses with a comma-string
  `repeat_days` decoded to `Weekday[]`.
- **Error mapping:** `400`/`404` → correct subclass, server `error` string preserved.
- **`now`-injected determinism:** no test depends on wall-clock time.

### 11.2 Live end-to-end — `clients/scripts/smoke.sh`

The real proof, against a running backend (docker `:8001` or native `:3000`):

```
create → list → assert resolved time matches intent → silence → cancel → confirm in history
```

**Skips cleanly (exit 0) with a SKIP notice if the server is unreachable**, so
`run_tests.sh` remains green offline and in CI.

### 11.3 Raycast

- Gate: `ray build` (type-checks and bundles) **and** `ray lint` — viable because `danieltsam`
  was verified to resolve.
- Manual `ray develop` smoke: create via `quick-create`, confirm the resolved-time preview,
  see it in the list, silence it.
- Requires the core watcher running (§4.3).

### 11.4 What is NOT verified

**Actual phone ringing.** No automated test can confirm the Android device alarms and
sounds; the smoke script proves *server state* only. This is stated plainly rather than
implied, per the deliverability caveats in §9.

### 11.5 Ordering

Each unit of work ends in a check (§ core tests → CLI smoke → Raycast build/lint), so a
failure is attributed to the unit that introduced it.

---

## 12. Risks

### 12.1 No authentication — accepted

The backend has no auth and permissive CORS. **Anything on the tailnet can read, cancel, or
silence alarms.** For a single-user personal homelab this is an accepted risk, and it
matches the existing dashboard and mobile app.

Documented, not silently fixed: adding a shared-secret header would require a backend
change, which is out of scope for this design.

### 12.2 Stale `core/dist` ships silently

Verified hazard. Mitigated by making the core watcher a required part of the dev loop
(§4.3) and by documenting it in `clients/README.md`. A missing `dist` fails loudly; a stale
one does not, which is why the watcher is mandatory rather than advisory.

### 12.3 Raycast toolchain changes

The sibling-package pattern is **not officially documented by Raycast** — it is verified
working at `@raycast/api@2.4.1`, but nothing guarantees it across major versions. If it
breaks, the fallback is a build-time copy of `core/dist` into `clients/raycast/src/lib/`
(option C from the design discussion), which trades duplication for immunity.

### 12.4 Timezone / wrong-hour alarms

The most damaging possible bug. Mitigated by: a single conversion point (§6.5), the
round-trip unit test (§11.1), and the mandatory resolved-time echo in both surfaces.

### 12.5 `alarm` binary name collision

`alarm` is not taken by any default macOS binary, but it is generic. Mitigated by install
via `npm link` from `clients/cli` (explicit, reversible) rather than a global install.

### 12.6 Duration inputs fire up to 59s early — accepted, inherited

Discovered during implementation verification. `server.ts:150` unconditionally truncates
seconds (`dateObj.setSeconds(0, 0)`), and the client mirrors it per §5.3 rule 2. For
**clock** times this is a no-op, but for **duration** inputs it shortens the interval:

```
alarm 25m  at 10:00:45  ->  10:25:45  ->  truncated to 10:25:00   (45s early)
alarm 1m   at 10:00:45  ->  10:01:45  ->  truncated to 10:01:00   (15s, not 60s)
```

The worst case is a short timer firing in a fraction of the requested interval.

**Accepted as-is, deliberately.** No client-side change can fix it — the server truncates
the value regardless of what is sent. More importantly, the existing mobile app and web
dashboard have identical behaviour, so patching only the CLI and Raycast would make the
phone's alarms disagree with the laptop's.

**The correct fix is a backend change:** skip the seconds truncation when `target_time` is
duration-derived rather than clock-derived. That requires distinguishing the two at the API
boundary, which is out of scope for this design (§2). Recorded here so the behaviour is a
known, documented property rather than a silent surprise.

---

## 13. Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Delivery surface | Shared core + CLI + Raycast | Avoids drift in timezone/encoding logic; CLI ships value immediately. |
| Core consumption by Raycast | Prebuilt `dist` + `file:` dep | **Spike-verified** to inline correctly; preserves type-checking. |
| Time input | Natural-language, deterministic grammar | The "zero friction" premise; matches the pre-existing backlog spec. |
| Repo location | `clients/` | Single history, stays in sync with API changes. Supersedes `backlog.md`'s `extensions/`. |
| CLI binary name | `alarm` | Matches `ROADMAP.md:52` verbatim. |
| `ray lint` in gate | Yes | `danieltsam` verified to resolve; corrected the assumption that `--relaxed` skips this. |
| Backend changes | None | Every operation maps to an existing route — zero regression risk. |
| Tone/ramp preferences | Not duplicated | `GET /api/settings` is already the source of truth. |
| Auth | Out of scope | Needs a backend change; accepted risk documented in §12.1. |

---

## 14. Open Items

None blocking. Deferred to their own design cycle: Google Calendar / Tailscale calendar
subscription (§2), and backend auth (§12.1).
