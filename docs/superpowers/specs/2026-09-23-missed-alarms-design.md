# Remote Alarm — Missed Alarms Design

> **Date:** 2026-09-23
> **Status:** Approved design — pending written-spec review, then implementation plan
> **Scope:** Backend, mobile, and the web dashboard. Touches the alarm state model.
> **Guiding principle:** a missed alarm is a **failure**, and a failure must leave an audit
> trail rather than be tidied away. Auditability outranks state-model tidiness here.
> **Related:** `docs/superpowers/specs/2026-09-21-clients-cli-raycast-design.md` (the clients
> consume `AlarmStatus`), `docs/superpowers/specs/2026-09-21-google-calendar-mirror-design.md`
> (the mirror maps `AlarmStatus` to calendar actions).

---

## 1. Context & Intent

An alarm whose moment passed without ringing does not currently resolve. It sits `pending` in
the past forever, and the phone quietly rolls it forward.

This was found live, not theorised. The homelab held a one-time alarm ("church", target
`2026-09-21T20:15:00Z`) that was still `pending` two days later. `adb shell dumpsys alarm`
showed it **armed for 06:15 the next morning** — the phone had rolled a stale alarm forward and
would have rung it.

**How it got there.** Alarms are dispatched over FCM, and the phone's token had died
(`NotRegistered`, which `fcm.ts` correctly prunes). Alarms sent during that window never reached
the phone, so it never scheduled them and never reported back. Only the *phone reporting*
`ringing`/`dismissed`/`snoozed` moves an alarm out of `pending`, and the backend has no way to age
one out, so it stayed `pending` in the past indefinitely.

**Why it matters beyond one stale row.** A reconnect is the dangerous moment. On reconnect the
phone pulls the active list and arms each overdue alarm at its **next clock-time occurrence**.
At 12:00am that means an alarm set for 00:01 rings **one minute later**, and several accumulated
overdue alarms produce a burst of surprises in the small hours. This is the strongest argument
for the change, not a reason against it.

**Intended outcome.** An alarm that could not be delivered never rings at a startling hour, is
recorded as failed with enough detail to audit afterwards, and is only re-armed when the owner
explicitly reschedules it.

---

## 2. Scope

### In scope
- A grace window after which a one-time alarm is declared missed.
- A dedicated `missed` status.
- Backend detection, and a phone-side guard that closes the reconnect race.
- Audit fields: when it was missed, and the reason that can be determined.
- Calendar: **keep** the event and annotate it as missed.
- Web dashboard: surface missed alarms.
- Client support so the CLI and Raycast render the new status.

### Out of scope
- **Recurring alarms keep advancing.** Daily, weekdays, and fortnightly alarms continue through
  `getNextOccurrence` unchanged. A daily alarm whose stored time is stale is still a *live*
  schedule, not a spent one, so it is not "missed".
- **No auto-rescheduling.** Nothing re-arms itself.
- No per-attempt delivery log. Audit is one record per alarm, not a history of every dispatch.
- No change to the existing calendar mirror mechanics beyond the status mapping and description.

---

## 3. Verified Constraints

Measured or read, not assumed.

| Fact | Where |
|---|---|
| A past one-time alarm rolls to today at the same clock time, else tomorrow | `mobile/lib/services/alarm_service.dart:400-412` (`computeFutureOccurrence`) |
| Only the phone reporting moves an alarm out of `pending` | `server.ts` `/api/alarms/:id/state` |
| The backend accepts a past `target_time` on create (parses, no futurity check) | `server.ts:232-235` |
| `rollTargetTimeToFuture` runs **only** on a transition to `pending` | `server.ts:601` |
| No overdue reconciliation exists anywhere | confirmed by reading the codebase |
| `canceled` is already not settable through `/state` | `server.ts` accepted-status list |
| Mock-mode FCM reports `sent = deviceCount` while delivering nothing | `fcm.ts:105-108` |
| `backend/public/index.html` has uncommitted local changes (+130/−6) | working tree |

The mock-mode row matters for §7: `sent > 0` is **not** proof of delivery, so audit copy must not
claim it.

---

## 4. Policy

**Grace window: 5 minutes, fixed.** Not configurable. A one-time alarm still rings if the phone
arms it within 5 minutes of its time; beyond that it is missed and never rings late. Five minutes
absorbs a brief hiccup at the alarm moment without permitting an alarm to surface hours later.

The window applies to **one-time alarms only**. Recurring alarms are unaffected (§2).

### 4.1 Any failure, not only an FCM disconnect

**The policy is cause-agnostic.** The FCM-disconnect case is how the defect was *found*, not what
the defect is *about*. The sweep is purely time-based: it never asks why an alarm did not ring,
only that it did not. An alarm that failed because the token was dead, because the device never
reported, because Android suppressed it, or for a cause the system cannot observe, is treated
identically.

"Fail gracefully" therefore means three things, for every cause:

- the alarm is **recorded as a failure**, rather than left silently overdue;
- it is **never revived automatically**, so a failure cannot surprise the owner later;
- **nothing else is affected** — one failed alarm does not disturb another, and the daemon keeps
  running.

The last point is the one that must not be lost: a failure path that itself throws, or that stalls
the sweep, would turn one missed alarm into a broken system.

---

## 5. State Model

`missed` joins the `AlarmStatus` union:

```ts
type AlarmStatus =
  | "pending" | "ringing" | "dismissed" | "snoozed"
  | "canceled" | "disabled"
  | "missed";                       // NEW — set by the system, never by a client command
```

**System-set only.** `missed` is deliberately excluded from the statuses `/api/alarms/:id/state`
accepts, exactly as `canceled` already is. A client cannot declare its own alarm missed through
the ordinary state endpoint; the dedicated report path in §6.2 is the only way.

**View membership:** excluded from `view=active` (so the phone never treats it as something to
arm), and included in `view=all`.

### 5.1 New columns on `alarms`

Added through the existing `migrations` array in `db.ts`, which already tolerates re-runs.

| Column | Purpose |
|---|---|
| `missed_at TEXT` | when the alarm was declared missed |
| `missed_reason TEXT` | the reason that could be determined, from §7 |
| `last_dispatch_sent INTEGER` | outcome of the most recent FCM dispatch |
| `last_dispatch_failed INTEGER` | outcome of the most recent FCM dispatch |
| `last_dispatch_at TEXT` | when that dispatch happened |

The three `last_dispatch_*` columns are what make the reason possible. They are written wherever
`sendFcmDataMessage` is called, so the record reflects the last thing the system actually tried to
do — which is the only evidence available about why a phone never rang.

---

## 6. Detection

### 6.1 Backend sweep

A timer in `server.ts`, alongside the existing calendar reconcile and **guarded the same way**
(`NODE_ENV !== 'test'`), runs every **60 seconds**:

> Any `pending` alarm with **no `repeat_days`** whose `target_time + 5 minutes < now` becomes
> `missed`, with `missed_at = now` and `missed_reason` computed per §7.

Fortnightly alarms carry `repeat_days` as well as an interval, so "no `repeat_days`" excludes them
along with daily and weekday alarms. `ringing` and `snoozed` are not swept — see §15.

Only the backend can do this. The phone is, by definition, the thing that is unreachable, and an
alarm missed because the token died would never be marked if detection lived there.

Test hermeticity is mandatory here for the reason learned from the calendar mirror: guarding only
one code path was not enough. The sweep gets the same `NODE_ENV !== 'test'` guard as the reconcile
timer, and the test script's `GCAL_ENABLED=false` pattern (§11) is the precedent for making
hermeticity explicit rather than a property of absent configuration.

### 6.2 Phone reports on reconnect

The phone declines to arm a stale alarm (§8.1) and **tells the backend**, so the missed state
converges the moment the device returns rather than up to a sweep later.

New endpoint, batched deliberately:

```
POST /api/alarms/report-missed
  { "ids": ["<uuid>", ...], "reason": "device_reported_stale" }
→ 200 { "updated": <count> }
```

Named `report-missed` rather than `/missed` so the path segment can never be read as an `:id`;
`PATCH` and `DELETE /api/alarms/:id` already own that shape, and a future `POST /api/alarms/:id`
would otherwise make `missed` ambiguous.

One call per reconnect for all stale alarms, rather than one `/state` call each. It also keeps
`/state`'s semantics tight: `missed` remains system-set, and this endpoint is explicitly a device
report.

The sweep and the report are independent. Either alone produces a correct result; together, the
state converges quickly **and** survives a phone that never comes back.

---

## 7. The Reason, and Its Limits

`missed_reason` is derived from the persisted dispatch outcome at the moment of marking:

| Condition | Reason |
|---|---|
| `last_dispatch_sent = 0 AND last_dispatch_failed = 0` | `no_device_registered` |
| `last_dispatch_failed > 0` | `delivery_failed` |
| `last_dispatch_sent > 0` | `dispatched_not_reported` |
| no dispatch recorded | `unknown` |
| the device says it never got to the alarm (§6.2) | `device_reported_stale` |
| the device says it tried and could not fire it | `device_reported_failed` |

The first four come from the sweep, the last two from the device report. **`missed_reason` is a
closed set.** Both producers must use one of these six values, so the vocabulary cannot drift apart.

The two device-reported values are what make the reason set cause-agnostic: they exist so a
device-side failure — Android suppressing an alarm, a force-stop, a permission lost — can be
recorded honestly rather than being flattened into the FCM-framed `dispatched_not_reported`.

**Copy must not overclaim.** Mock mode reports `sent = deviceCount` while delivering nothing
(§3), so `dispatched_not_reported` means exactly what it says: the system sent it and the phone
never said what happened. It does **not** mean the phone received it. All user-facing strings must
be phrased that way.

---

## 8. Phone Behaviour

### 8.1 Refuse to arm a stale one-time alarm

The guard sits with the scheduling decision (`computeFutureOccurrence` or its call site). For a
one-time alarm more than the grace window past, the phone **does not arm it**. This is the change
that closes the 12am race.

Both sides enforce the window independently, which is the point: the phone cannot arm a stale
alarm even if the backend has not swept it yet, and the backend marks it missed even if the phone
never returns.

Within the window, behaviour is unchanged: the alarm arms and may ring a few minutes late, which
is the intended grace.

### 8.2 Report, then show

Declined stale alarms are reported in one batched call (§6.2) and rendered as **Missed** in the
app, with the reason and the time.

### 8.3 Re-enable means reschedule

A missed alarm's time is in the past, so "re-enable" cannot mean "arm it". The action becomes
**Reschedule** and asks for a new date and time. Nothing moves without an explicit choice.

Rationale for distinguishing this from the rejected automatic forward-roll: a silent
forward-roll surprises you; an explicit reschedule is an instruction.

---

## 9. Calendar

**Keep the event and annotate it.** A missed alarm's event is *not* deleted, reversing the
mapping used for `disabled`. The calendar is where the owner looks, so a failure that happened
should be visible there rather than tidied away.

- `actionForStatus('missed')` → **`upsert`** (not `delete`).
- `describe()` in `gcal-events.ts` gains a missed annotation carrying the status, the timestamp,
  and the reason, e.g.:

  ```
  Managed by Remote Alarm
  Alarm ID: <uuid>
  ⚠️ MISSED — this alarm did not fire.
  Missed at: <iso>
  Reason: dispatched_not_reported
  ```

`syncAlarm` already upserts, so this is a mapping change and a description change, with no new
mechanism.

---

## 10. Web Dashboard

`backend/public/index.html` must surface missed alarms with the same audit detail as the calendar:
status, when, and the reason. The dashboard already branches on status (`pending`, `ringing`,
`snoozed`, `disabled`), so this is a new branch plus a section.

**Sequencing note:** that file has uncommitted local changes and is also modified by a concurrent
agent. It must be free before this work starts, or the changes will be silently lost — a collision
already observed twice on this project.

---

## 11. Repo Integration

| File | Change |
|---|---|
| `backend/src/db.ts` | status union, view filters, five new columns via the migrations array |
| `backend/src/server.ts` | sweep timer (test-guarded), the report endpoint, persist dispatch outcomes |
| `backend/src/fcm.ts` | no change to behaviour; callers persist the outcome it already returns |
| `backend/src/gcal-events.ts` | `actionForStatus('missed') → 'upsert'`, missed annotation in `describe()` |
| `backend/src/gcal-reconcile.ts` | no change |
| `backend/public/index.html` | Missed section with audit detail |
| `mobile/lib/services/alarm_service.dart` | refuse to arm stale one-time alarms |
| `mobile/lib/services/backend_client.dart` | batched missed-report call |
| `mobile/lib/main.dart` | Missed rendering, reason and time, Reschedule action |
| `clients/core/src/types.ts` | `AlarmStatus` union gains `missed` |
| `clients/core/src/format.ts`, CLI, Raycast | a status label and badge |
| `README.md` | document the policy and the new status (ASD-STE100, as the file now requires) |

The clients are in scope because they consume `AlarmStatus`; without the union change the CLI and
Raycast would render an unknown status.

---

## 12. Verification

### 12.1 Unit tests
- Sweep: marks a past one-time alarm; **does not** mark a recurring one; does not mark one inside
  the grace window; does not mark a future one; `missed_at` and `missed_reason` are set.
- Reason derivation: all four branches of §7, including the mock-mode case where `sent > 0` must
  **not** be reported as delivered.
- `/state` still rejects `missed`; the report endpoint accepts it.
- `view=active` excludes missed; `view=all` includes it.
- `actionForStatus('missed') === 'upsert'`; the generated event description contains the
  timestamp and reason.
- The sweep timer does not run under `NODE_ENV=test` (mirroring the existing reconcile guard).
- Mobile: `computeFutureOccurrence` refuses a past one-time alarm beyond grace; still rolls a
  recurring one; still arms one inside the window.

### 12.2 End-to-end, against a live backend
The failure being fixed was found live, so it should be verified live:
1. Create a one-time alarm ~1 minute out on a throwaway database.
2. Do not let it be delivered (no registered device reproduces the original condition).
3. Confirm the sweep marks it `missed` with `no_device_registered`, and that `view=active` no
   longer returns it.
4. Confirm the calendar event survives and carries the missed annotation.
5. Reconnect scenario: with a stale alarm present, confirm the phone does **not** arm it, and that
   `dumpsys alarm` shows nothing scheduled for it. This is the 12am case, checked directly.

### 12.3 What cannot be verified here
**The phone cannot be driven end-to-end from this environment.** The guard and the report can be
tested in Dart and by inspection, but "a reconnect at 12am does not wake me" is only truly
confirmed upstream by observing `dumpsys alarm` after a real reconnect. That step is stated as
manual rather than implied to be covered.

---

## 13. Risks

### 13.1 A late alarm is lost where it previously rang
The grace window is a deliberate trade: alarms are no longer silently revived, so a genuine
delivery failure costs the alarm. Mitigated by making it *visible* (Missed in the app, the
calendar, and the dashboard) and reschedulable in one action. This is the owner's stated
preference — the failure mode being fixed is worse.

### 13.2 The reason could be read as certainty
`dispatched_not_reported` and mock-mode `sent` counts can imply delivery that did not happen.
Mitigated by wording (§7) and by a test asserting the mock-mode case is not labelled as delivered.

### 13.3 Test hermeticity
A new timer that touches the database is a new opportunity for the suite to reach outside itself —
the exact failure that created 20 stray calendars. Mitigated by the same `NODE_ENV !== 'test'`
guard as the reconcile timer, plus a test that asserts the sweep does not run under test.

### 13.4 Concurrent edits to `main.dart` and `index.html`
Both files have concurrent writers on this project and collisions have already occurred. This work
must be sequenced behind them, and the spec records that rather than assuming a free file.

---

## 14. Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Grace window | 5 minutes, fixed | Absorbs a brief hiccup; forbids an alarm surfacing hours later. Not configurable (YAGNI) |
| Representation | Dedicated `missed` status | First-class: filterable, badgeable, and the UI cannot confuse "missed" with "I disabled this" |
| Who sets it | System only, never a client command | Consistent with `canceled`; `/state` stays a user-intent endpoint |
| Detection | Backend sweep, 60s | Only the backend can see "overdue *and* unreachable" |
| Race closure | Phone refuses to arm stale alarms too | Neither side depends on the other being timely; this is what fixes the 12am case |
| Convergence | Phone reports on reconnect, batched | Immediate accuracy, and still correct if the phone never returns |
| Re-enable | Becomes Reschedule | The old time has passed; an explicit choice replaces a silent roll |
| Calendar | Keep and annotate | Owner's call: auditability outranks mirror tidiness |
| Audit depth | Status + timestamp + derivable reason | Enough to audit a failure without a full delivery log |
| Recurring alarms | Unaffected | A stale stored time is normal for a repeating schedule |
| Dashboard | In scope | Same auditability requirement as the calendar |

---

## 15. Open Items

1. **`backend/public/index.html` must be free of concurrent edits** before §10 starts (§13.4).
2. **Deployment.** The homelab runs a commit that predates both this change and the fortnightly
   work; it will need a redeploy once this lands.
3. **The same gap exists for `snoozed` alarms, and this design does not fix it.** A `snoozed` alarm
   whose snooze time passes without the phone ringing would sit `snoozed` indefinitely, exactly as
   `pending` did. The sweep deliberately covers `pending` only, to keep this change bounded.
   Recorded rather than forgotten: it is a candidate for the same treatment in a follow-up.
