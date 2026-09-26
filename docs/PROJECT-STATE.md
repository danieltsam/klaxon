# Remote Alarm — Project State

> **Last updated:** 2026-09-26
> **Working directory:** `/Users/dsam/Documents/remotealarm`
> **Purpose:** the whole-system state. What is deployed, what is committed, what is in flight, and
> what a fresh session must know before touching anything.

Companion documents:

| Document | Covers |
|---|---|
| `docs/agent_context/WORKING_STATE.md` | The mobile/UI session's live state. Most detailed on the app. **Untracked.** |
| `AGENT_HANDOFF.md` | Original onboarding (2026-09-21). Its §8 items are now done. **Untracked.** |
| `docs/ROADMAP.md` | Implemented features + future backlog |
| `docs/agent_context/backlog.md` | Creative + UI backlog |
| `docs/superpowers/specs/` | Written specs: clients/CLI/Raycast, calendar mirror, missed alarms |
| `docs/superpowers/plans/` | The calendar mirror implementation plan |
| `fixtures/relative-time-cases.json` | The shared relative-time contract (see §3.4) |

---

## 1. What is live

**Homelab** (`baymax`, `100.72.232.98`, repo at `/home/dsam/projects/remotealarm`):

- Container `remotealarm`, `0.0.0.0:8001 -> 3000`, running commit **`7cb9ba4`**
- `GET /api/health` returns ok; `GET /api/calendar/status` reports `configured: true, ok: true, needs_reauth: false`
- Alarm set: 5 visible in `view=all` (`dismissed 1`, `disabled 3`, `missed 1`) plus 3 `canceled` rows
- Deploys: `git pull --ff-only` then `docker compose up -d --build`. Confirm with `docker compose ps`
  and `docker compose logs --tail=50`.

**Database:** `/app/data/alarms.db` inside the container. The host's `./data` directory is
**root-owned and `dsam` cannot write to it**, so use `docker cp` or `docker compose exec` rather
than a plain copy. Backups taken this session:

- `alarms.db.bak-20260923-081110`
- `alarms.db.bak-20260923-104230`

**Google Calendar mirror:** live, writing to its own generated calendar. The OAuth client is on a
**Testing consent screen, so the refresh token expires after 7 days**. The fix and the exact
re-auth commands are in `README.md` (gcal credential-expiry section). During this session
`refresh_token_expires_in` was measuring roughly 5 days out, so a re-consent is due about
**2026-09-28**. When it lapses, only the mirror stops, and `needs_reauth: true` plus
`last_error_kind: "auth"` reports it. Alarms keep working.

**Test counts (verified by running them):**

| Suite | Command | Count |
|---|---|---|
| Backend | `cd backend && npm test` | 152 tests / 40 suites |
| Mobile | `cd mobile && flutter test` | 122 tests |
| Clients | `cd clients/core && npm test` | 160 tests / 22 suites |
| All three | `./run_tests.sh` | must end "All Automated Test Suites Passed Successfully!" |

---

## 2. Repo state

- `HEAD` is **`7cb9ba4`**, 0 ahead / 0 behind `origin/master`
- The tree carries **in-flight work from a second agent**: uncommitted changes across `mobile/`
  (notably `main.dart`, `alarm_service.dart`, the recurrence widgets and the calendar picker) and,
  at times, `backend/public/index.html`. **Run `git status` for the current list**; do not rely on
  this snapshot, which is dated above.
- Untracked context artifacts: `AGENT_HANDOFF.md` and all of `docs/agent_context/`
  (41 files, 6.4 MB, of which 6.1 MB is `screenshots/`)

**Concurrency hazard, and it is real.** Two writers have repeatedly collided on `mobile/lib/main.dart`
and `backend/public/index.html`, silently costing commits. Before editing either, check
`git status` and the file's mtime. When a lane is in flight, do not touch its files; commit another
agent's work only when asked, and commit it in its own commit.

---

## 3. Features that landed (recent work)

### 3.1 Missed alarms — DONE, DEPLOYED

A failed alarm is recorded rather than left silently overdue. Spec:
`docs/superpowers/specs/2026-09-23-missed-alarms-design.md`.

- New `missed` status. **System-set only**; rejected by `/state` and by `PATCH`.
- Backend sweep every 60s over one-time alarms past a **5-minute grace window**.
- The phone also refuses to arm a stale alarm and reports it, batched, via
  `POST /api/alarms/report-missed`.
- `missed_reason` is a closed set of six. The dashboard, mobile app, CLI and Raycast all surface it.
- The calendar keeps and annotates the event rather than deleting it.

Live confirmation: the stale `church` alarm became `missed` with `device_reported_stale`.

### 3.2 Snoozed alarms — gap CLOSED

An overdue `snoozed` alarm used to sit stuck indefinitely, exactly as `pending` did, and the phone's
reconcile could report a healthy snooze as missed. Now a snooze writes its next-ring time into the
existing **`target_time`** column:

- `/state` accepts `target_time` for `snoozed`, and computes `floor(now to the minute) + 9min` when
  a client omits it, so an older app cannot leave a stale time.
- The sweep covers `pending` **and** `snoozed` under the same grace rule.
- No FCM and no dispatch are recorded for a snooze.
- `PATCH` now **rejects** a bare `snoozed` with a 400 pointing at `/state`.

Spec §15 item 3 is retired.

### 3.3 Other hardening

- `markMissed` gained a status guard, so only a row that could still be live can be declared missed.
- The calendar mirror is now handed the **updated** row, not the one read before the update.
- Test hermeticity is structural: `NODE_ENV === 'test'` guards the timers in `server.ts`, and the
  test script sets `DB_PATH=:memory:` and `GCAL_ENABLED=false`. A bare `tsx --test` defaults to
  in-memory. This follows an incident where the suite created 20 real Google calendars.

### 3.4 Relative times — DONE

An alarm a fortnight away read `331 hours 23 mins`. The rule now picks the largest unit and shows up
to three components: **`13 days 19 hours 23 mins`**.

| Span | Output (prose) | Compact |
|---|---|---|
| < 1 min | `less than a minute` | same |
| < 1 hour | `25 mins` | `25m` |
| < 24 hours | `13 hours 40 mins` | `13h 40m` |
| < 30 days | `13 days 19 hours 23 mins` | `13d 19h 23m` |
| < 1 year | `3 months 12 days 5 hours` | `3mo 12d 5h` |
| >= 1 year | `1 year 2 months 3 days` | `1y 2mo 3d` |

Months are a fixed 30 days and years a fixed 365, so the rule stays pure arithmetic. Zeros are
omitted and singulars are used for exactly one unit. **Weeks were deliberately excluded** from
countdowns; the calendar ribbon keeps its `in N wks`.

Because the rule is reimplemented in Dart, TypeScript and inline JavaScript, it is pinned by
**one shared case table**: `fixtures/relative-time-cases.json`. Both test suites assert against it.
It caught a real year-tier bug during implementation (365 days rendered as `1y 5d`).

| Surface | Where |
|---|---|
| Phone hero | `mobile/lib/utils/relative_time.dart` (`formatRelativeDuration`) |
| Dashboard | `backend/public/index.html` inline `formatRelative` |
| CLI + Raycast | `clients/core/src/format.ts` `formatRelative` |
| Calendar ribbon | `mobile/lib/widgets/calendar_picker.dart` — **left alone, in weeks** |

Verified on device: the alarm sheet rendered `in 13 days 18 hours 42 mins`.

### 3.5 Clients, CLI and Raycast — DONE

`clients/` holds a shared dependency-free core plus an `alarm` CLI and a Raycast extension. No
backend changes required. Confirmed working end-to-end against the live homelab with
`npm start --silent -- --url http://100.72.232.98:8001 list --all`.

---

## 4. In progress right now

**The mobile/UI session is active.** Read `docs/agent_context/WORKING_STATE.md` for its detail.
As of this writing:

- Recurrence chip-row **variant lab** is live (9 variants, long-press the `repeats` label), persisted
  via the `recurrence_chip_variant` preference
- The user is choosing a variant; **hybrid segmented variants are spec'd but not built**
- Mass-select / bulk duplicate + delete is implemented
- A large refactor of `recurrence_lab.dart` is mid-flight (12 files uncommitted)

**Treat `mobile/` as owned by that session.** This session held off it entirely and committed its
own work in a way that left the other agent's changes intact.

---

## 5. Outstanding / next

| Item | Notes |
|---|---|
| **gcal re-consent due ~2026-09-28** | 7-day Testing clock. Exact commands in `README.md`. |
| **Chip variant final selection** | User deciding. See `WORKING_STATE.md` §3.2 for the removal checklist. |
| **ICS feed `INTERVAL` gap** | `/api/calendar.ics` omits `INTERVAL` for fortnightly alarms; the Google mirror includes it. |
| **Dashboard has no test harness** | Its `formatRelative` was verified by extracting the function from the HTML and evaluating it against the fixture in node. Worth making permanent. |
| **Screenshots deliberately untracked** | `docs/agent_context/screenshots/` (6.1 MB, 25 files) stays on disk rather than in git, to keep the repo small. The rest of `docs/agent_context/` and `AGENT_HANDOFF.md` are committed. A clean working tree loses them. |
| **`AGENT_HANDOFF.md` is stale** | Dated 2026-09-21; its §8 items are all done. `WORKING_STATE.md` supersedes it. |

---

## 6. Environment and how to verify

```bash
# All suites
./run_tests.sh

# Individually
cd backend && npm test                        # 152
cd mobile && flutter test                     # 122
cd clients/core && npm test                   # 160

# Type-check the backend and clients
cd backend && npx tsc -p tsconfig.json --noEmit
cd clients/core && npx tsc -p tsconfig.json --noEmit

# Deploy the backend
ssh <homelab> 'cd <path-to-remotealarm> && git pull --ff-only && docker compose up -d --build'

# Build and install the app
cd mobile && flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

**Build the matching variant.** The installed app is a **debug** build. A release APK has a different
signing key, so `adb install -r` fails across the two. Build `--debug` to match.

**Gradle takes 70-300s.** Timeouts under 120s will fail; allow longer.

**Device automation is risky.** See §7.4.

---

## 7. Traps and lessons

### 7.1 Clocks disagree

The host reports **2026-09-26**; the device and homelab both reported **2026-09-23** during this
session. The backend's sweep and the client timestamps derive from their own clocks, so stored
timestamps and "overdue" judgements may be skewed relative to each other. Worth checking before
trusting a timing-sensitive result.

### 7.2 `DELETE /api/alarms/:id` is a soft delete

It returns 200 but only sets `status='canceled'`; the row remains. Use
`docker compose exec` plus SQL to remove a row for real.

### 7.3 An app update cancels the app's AlarmManager entries

Normal Android behaviour. The app re-arms only **enabled** alarms on launch, so a disabled alarm
correctly stays unarmed after an update.

### 7.4 Driving the device UI can create things

In this session, a tap intended for an enable switch hit a **duplicate** affordance instead, creating
two stray alarms (one local, one pushed to the backend). Cleaning them up also deleted the original
local alarm. Safeguards learned:

- Take a `uiautomator dump` and tap **exact bounds**, never guessed coordinates
- Guard destructive taps: verify the sheet's own label field before tapping Delete
- Prefer the tap-outside **Scrim** for dismissals; it cannot hit "Save"
- A Flutter sheet may ignore BACK and resist drag; the scrim is the reliable dismiss
- `local_` alarms are **protected from pruning** by both reconcile loops
  (`alarm_service.dart` `:367` and `:383`), so they need explicit deletion

### 7.5 Concurrent writers

See §2. This has cost real work more than once.

---

## 8. Verification log

What was checked and how, so it need not be redone blindly:

| Claim | Evidence |
|---|---|
| Missed alarms work live | `church` became `missed` with `device_reported_stale` on the deployed backend |
| Snooze fallback works live | Throwaway alarm: no-time snooze returned `floor(now to minute)+9min`, future; explicit time stored exactly; no FCM |
| Overdue snooze no longer sticks | Throwaway alarm with a past snooze time became `missed` (the phone's guard won the race) |
| Relative-times on device | Alarm sheet rendered `in 13 days 18 hours 42 mins` |
| Relative-times in the terminal | CLI `list --all` rendered `2d 2h 58m ago`, `in 18h 46m` |
| Dashboard formatter | Extracted `formatRelative` from the HTML, evaluated it against all 16 prose cases with a pinned clock: 16/16 |
| Dashboard deployed | Served HTML contains `MONTH = 30 * DAY` and zero occurrences of the old `in ${hours} hours` |
| Backend redeploy clean | `view=all` returns 5, zero labels matching `(copy)`, baseline statuses |
| Relative-time fixture | Caught a real year-tier bug (365d rendered `1y 5d`) before it landed |
