# Skip next occurrence — design

> **Date:** 2026-10-30
> **Status:** awaiting owner approval
> **Touches:** `backend/`, `mobile/`, `backend/public/` (dashboard), `clients/core`, `clients/cli`, `clients/raycast`

## 1. Why

The owner runs a Mon–Fri 9am recurring alarm. Some nights they know the next morning is a
write-off. Today the only options are: disable the alarm (which drops every weekday until it is
re-enabled), delete it, or be woken at 9am and dismiss it. They want to skip exactly the upcoming
occurrence, usually from bed the night before, and have the schedule carry on the morning after.

The request: one action on a recurring alarm, available from the phone, the dashboard, the API,
the CLI and Raycast.

## 2. Goals, non-goals, anti-goals

**Goals**

- Skip the next occurrence of a recurring alarm; the one after it rings as normal.
- Reachable from every surface the app already has: HTTP API, dashboard, phone, CLI, Raycast.
- Undoable until the skipped instant passes.
- Honest about failure: if the phone cannot be reached, the skip is refused, not recorded as done.

**Non-goals**

- Skipping more than one upcoming occurrence at a time.
- Skipping from the ring screen. Dismissing a recurring alarm already consumes that occurrence.
- A per-occurrence history view. The alarm stays one row.
- Multi-device reasoning. There is one phone.

**Anti-goals**

- Anything that turns "skip one" into "disable the schedule".
- A skip the backend records but the phone never hears about.
- Any client reimplementing the recurrence arithmetic.
- A skipped morning appearing as a missed alarm or a delivery-health failure.

## 3. Constraints the code imposes

1. **One row per alarm.** Recurrence is `repeat_days` + `recurrence_interval_weeks` +
   `recurrence_anchor_date`. There is no per-occurrence record to flag.
2. **The backend never fires alarms.** The phone arms a real OS alarm and re-arms itself on
   dismissal; the backend sends CREATE/CANCEL/DISABLE/DISMISS pushes and the phone reconciles on
   push and on app start (`mobile/lib/services/alarm_service.dart`). A backend-only change does not
   stop the phone ringing.
3. **The phone re-derives the target on every CREATE.** `_applyAlarmPayload` runs
   `computeArmTarget` → `getNextOccurrence`, whose weekday branch computes from **now**, not from
   the payload's `target_time`. A CREATE carrying "Wednesday 9am" at 1am Monday is re-armed as
   **Monday 9am** — the occurrence just skipped. This is the main hazard in the whole feature
   (§5.4).
4. **The backend's weekday maths is UTC.** `rollTargetTimeToFuture` reads `getUTCDay()` and the
   stored `repeat_days`. For the owner (Australia/Brisbane, UTC+10) a 9am alarm is 23:00Z the
   previous day, so the UTC weekday is one behind the local weekday. It also ignores interval and
   anchor, so it would move a fortnightly alarm onto the wrong week. Skip must not reuse it.
5. **Rows carrying `repeat_days` are never swept as missed** (`sweepMissedAlarms` filters
   `repeat_days IS NULL OR TRIM(repeat_days) = ''`, `backend/src/server.ts:184`). A fortnightly
   alarm stored as interval + anchor with no `repeat_days` is skip-eligible and *is* swept, so skip
   must leave every row's `target_time` on an occurrence that will actually be armed.
6. **No dashboard JS test harness.** Backend routes are tested with `app.inject`; the phone has
   widget/unit tests under `mobile/test/`.
7. Long-press on the phone list is already multi-select, so it is not available as the gesture for
   this.

## 4. Approaches considered

**Placement.** A: inside the alarm's detail sheet, next to delete. B: a row-level quick action.
C: attached to the next-alarm hero card. The owner picked A and ruled out B and C; the sheet is
where you go to change what an alarm does, and the row already changes its displayed time after a
skip, so no extra badge is needed.

**Storage.** A nullable `skipped_from` column on the alarm row versus a separate skips table.
The column was chosen: a skip is a single pending decision, the phone only ever holds one armed
alarm, and a table would force every reconcile to subtract a set of skipped instants for a
capability the UI cannot reach. Keeping one column keeps the row self-describing.

**Where the arithmetic lives.** A dedicated `POST /api/alarms/:id/skip` versus clients sending
`target_time` to the existing state endpoint. The dedicated endpoint was chosen: one
implementation of "advance exactly one occurrence", one place to test, and the CLI and Raycast do
not need the recurrence rules at all.

## 5. Design

### 5.1 Behaviour

Skip is available when the alarm is recurring (`repeat_days` non-empty, or interval > 1 with an
anchor), `status = 'pending'`, and no skip is currently pending.

- `S`, the skipped instant, is the upcoming occurrence: `target_time` when it is in the future,
  otherwise the next occurrence after now.
- `N`, the new target, is the occurrence strictly after `S` in the pattern.
- Skip sets `skipped_from = S` and `target_time = N`, then pushes the phone a CREATE for `N`.
- The alarm rings at `N`; dismissing it advances to the following occurrence exactly as today.
- Undo is available while `S` is still in the future. It restores `target_time = S`, clears
  `skipped_from`, and pushes a CREATE for `S`.

`skipped_from` is cleared by any write that moves `target_time`: the device reporting the next
advance after `N` fires (`POST /api/alarms/:id/state` with `pending`), and `PATCH` (an edit).
`AlarmRepo.updateTargetTime` (`backend/src/db.ts:205`) is currently a bare `target_time`
assignment and must be extended to clear it; `setSkip` is the only writer that sets it. Undo
clears it too. If no write happens, it simply expires: it is in the past and the UI stops showing
it, with no background job needed.

### 5.2 State

- Migration: `ALTER TABLE alarms ADD COLUMN skipped_from TEXT DEFAULT NULL`
  (`backend/src/db.ts`, same pattern as `add_missed_at`).
- `AlarmRecord` gains `skipped_from?: string | null`. It is exposed by every endpoint that returns
  an alarm, as a UTC ISO instant like `target_time`.
- One repo write, `setSkip(id, skippedFrom | null, targetTime)`, so the pair can never drift.
- Invariant: `skipped_from` is only set to the occurrence that was consumed, and is always earlier
  than `target_time`.

### 5.3 API

**`POST /api/alarms/:id/skip`**

Body: `{ "utc_offset_minutes": 600 }` (optional; omitted means the server's own offset, then UTC).

- `404` unknown id.
- `409` when: not recurring; `status` is not `pending`; a skip is already pending. Each gets a
  distinct message saying why.
- Otherwise compute `S` and `N` (§5.5) and dispatch CREATE. Build the payload with the **create
  path's** field set (`backend/src/server.ts:627-646`): `id`, `target_time`, `label`,
  `description`, `sound_tone`, `ramp_seconds`, `repeat_days`, `recurrence_interval_weeks`,
  `recurrence_anchor_date`. Do not copy the `pending` transition's builder
  (`server.ts:989-1001`): it omits interval and anchor, `buildFcmData` then sends
  `recurrence_anchor_date: ''` (`backend/src/fcm.ts:123`), and the phone clears its stored anchor
  (`alarm_service.dart:314-331`), silently turning a skipped fortnightly alarm weekly.
- If `sent === 0 && failed > 0`, reply `502` and leave `target_time` and `skipped_from` untouched,
  with the same wording as the cancel path: the phone was not reached, so the alarm was not
  skipped. Record the dispatch outcome anyway, as cancel does (`server.ts:671`), so `/api/health`
  sees the failed attempt.
- `sent === 0 && failed === 0` (no device registered) applies the skip; there is nothing to ring.
- On success: write the row, `recordDispatch`, `mirrorSafely` the updated row, reply
  `200 { success, id, status, target_time, skipped_from, fcm_dispatch }`.

**`POST /api/alarms/:id/unskip`**

- `409` when nothing is pending, when `skipped_from` has already passed, or when the alarm is no
  longer `pending` (disabled, ringing, or cancelled since the skip was set).
- Otherwise dispatch CREATE for `S` first, then restore the row; same `502` rule.
- Reply the same shape with `skipped_from: null`.

POST verbs rather than `DELETE /skip` because the existing mutation endpoints are POST verbs
(`/silence`, `/state`), and "unskip" names the action in every client.

### 5.4 Phone

Two changes, the second larger than it looks.

**UI.** In the alarm edit sheet (`mobile/lib/main.dart`, the sheet that currently ends in
`save adjustments` / `delete`), a separate subdued line above that button row:

- eligible: `skip next occurrence`
- skipped: `skipped tue 30 oct, 9:00am · back wed 9:00am` with `undo` beside it

Hidden entirely for one-time alarms, disabled, snoozed and ringing alarms. Tapping it calls the
endpoint, then applies the returned alarm locally through the same path reconcile uses, so the OS
alarm moves immediately instead of waiting for the echo push. Failure shows a toast and leaves the
sheet as it was.

**Arming rule.** `computeArmTarget` must return `targetTime` unchanged when it is already in the
future, before it delegates to `getNextOccurrence`. That is the narrowest place: every remote arm
path goes through it (`_applyAlarmPayload` at `alarm_service.dart:335`, `scheduleLocalAlarm` at
`:657`), while `dismissAlarm` calls `getNextOccurrence` directly with a just-rung time in the past
and keeps today's behaviour. Without the guard, the CREATE that reports the skip is re-armed on the
phone as the skipped morning (constraint 3) and the feature does nothing. With it, a server target
is authoritative, which also closes a latent reconcile bug where the phone could arm an earlier
occurrence than the one the backend holds. This is the riskiest edit in the change: the recurrence
tests in `mobile/test/recurrence_test.dart` all pass past targets so they survive, but the exposure
is future recurring CREATEs in `arm_dedup_test.dart`, `payload_refresh_test.dart` and
`sync_reconnection_test.dart`.

### 5.5 Occurrence arithmetic

A new backend helper, used only by skip. It steps forward from the row's own `target_time`, which
is already a valid occurrence, rather than from `recurrence_anchor_date`: the anchor is written as
a UTC date on create (`server.ts:573` slices the ISO string) but as a local date by the phone
(`mobile/lib/main.dart:2611`), so it is not a reliable phase source. `target_time` is.

1. Convert to the local wall clock with `utc_offset_minutes`.
2. Step forward in the pattern until the candidate is strictly after now: one local day at a time
   for a weekly pattern, skipping days whose local weekday is not in `repeat_days`; `7 ×
   recurrence_interval_weeks` local days for an interval pattern. That candidate is `S`.
3. Step once more, the same way, for `N`.
4. Convert back to UTC.

`utc_offset_minutes` is **minutes east of UTC** (Brisbane = `+600`), matching
`-new Date().getTimezoneOffset()` in JS and `DateTime.now().timeZoneOffset.inMinutes` in Dart.
Accept integers within ±840; a missing or out-of-range value falls back to the server's own
offset, then UTC. A fixed offset means no DST handling, which is fine for Brisbane and is stated
rather than guessed at.

`rollTargetTimeToFuture` is left alone. Its UTC weekday assumption is a pre-existing mismatch and
fixing it here would change create/roll behaviour unrelated to this feature; note it as a
follow-up.

### 5.6 Dashboard

In `#alarm-detail-modal` (`backend/public/index.html`), a text action in the footer beside
`delete alarm`, with the same two states as the phone and the same eligibility rule. Handler posts
the endpoint, then `loadAlarms()`. `openAlarmDetail` reads the cached `allAlarms` array
(`index.html:1211`), so refresh that cached row and re-render the modal's skip line before closing
or reloading; otherwise a successful skip leaves the modal still offering "skip next occurrence".
The row and hero card need no change: the displayed next ring is already the signal.

### 5.7 Phone client, CLI and Raycast

- `mobile/lib/services/backend_client.dart`: `skipAlarm(id)` and `unskipAlarm(id)` alongside
  `updateRemoteAlarm`, sending the phone's `timeZoneOffset.inMinutes`.
- `clients/core`: `skipAlarm(id)` and `unskipAlarm(id)` returning `AlarmMutationResult`; alarm
  normalisation carries `skipped_from`.
- `clients/cli`: `alarm skip <id>` and `alarm unskip <id>` in `COMMAND_NAMES`, the help text,
  `commands/mutate.ts`, and the dispatch switch in `clients/cli/src/index.ts:103`. No confirmation
  prompt: it is reversible.
- `clients/raycast`: a `skip next occurrence` action on `list-alarms`, hidden for non-recurring
  alarms, and an undo action when a skip is pending.
- `clients/README.md` and `raycast/help.md` updated.
- `clients/core/dist` is not tracked in git but is what the CLI and Raycast import, so run
  `npm run build` in `clients/core` before testing either of them.

## 6. Edge cases

| Case | Expected |
|---|---|
| Fri 9am skipped | lands on Mon 9am, not Sat |
| Sun night, Mon–Fri alarm | `S` = Mon 9am, `N` = Tue 9am |
| Fortnightly alarm | steps `7 × interval` days from `target_time`, never the next weekday |
| `target_time` already past (phone offline a day) | `S` = next occurrence after now, `N` = the one after |
| Snoozed alarm | `409`. A snooze target is an instant, not a pattern occurrence; dismiss or disable first |
| Ringing | `409`; use silence |
| Second skip before the first passes | `409`. After `S` passes, the next skip is allowed |
| Edit while a skip is pending | edit wins, `skipped_from` cleared |
| One-time alarm | no action in any UI, `409` from the API |
| Phone unreachable | `502`, row untouched, message says so |
| Calendar mirror | event moves to `N` via `mirrorSafely`; mirror is currently paused, covered by unit tests |

## 7. Testing

- **Backend** (`backend/test/skip.test.ts`): the advance rules above including Fri→Mon, a
  fortnightly row, and an interval-plus-anchor row with no `repeat_days`; offset handling with a
  UTC+10 target; the CREATE payload carrying interval and anchor intact; every `409`; double-skip;
  undo before and after `S`; dispatch failure leaves `target_time` untouched and returns `502`;
  no-device applies; PATCH clears `skipped_from`; `sweepMissedAlarms` leaves the row alone
  throughout.
- **Phone** (`mobile/test/skip_test.dart`): eligibility in the sheet; a CREATE whose target is
  future is armed as given, not rolled back to today; reconcile cannot re-arm the skipped morning;
  undo. Existing recurrence, dedup and reconcile suites must stay green.
- **Clients** (`clients/core/test/client.test.ts`): `skipAlarm`/`unskipAlarm` request shape and
  error mapping. There is no CLI test harness (`clients/cli` has no `test/` directory or script),
  so the verbs are verified by hand against a running backend after `clients/core` is rebuilt.
- **Dashboard**: no harness. Verify by hand against a running backend, including the modal's
  post-skip state; the endpoints themselves are covered by the backend tests.

## 8. Left to the builder

- Exact wording of the two lines and the toasts, matched to the existing lowercase copy.
- Whether the sheet action sits above or below the save/delete row.
- Whether Raycast's undo is a second action or a toggle on the same one.
- Response field order and any shared type additions in `clients/core/src/types.ts`.

## 9. Calls made on the owner's behalf

- POST `/skip` and `/unskip` rather than `DELETE /skip`.
- Skip payload carries the caller's UTC offset, because the backend has no per-alarm timezone and
  its weekday maths is UTC.
- The pattern is stepped forward from `target_time`, not from `recurrence_anchor_date`, because the
  anchor is written as a UTC date by the backend and a local date by the phone.
- The "a future target wins" guard goes in `computeArmTarget`, not `getNextOccurrence`, so
  `dismissAlarm` keeps its current behaviour.
- No row-level badge after a skip; the changed next-ring time is the signal, the detail sheet
  explains it.
- `skipped_from` is exposed by the API but only shown while it is in the future.
- Copying the `pending` transition's CREATE payload is a trap (it drops interval and anchor); the
  create path's field set is the one to copy.
