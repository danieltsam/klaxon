# Skip Next Occurrence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a recurring alarm skip exactly its next occurrence, from the API, dashboard, phone, CLI and Raycast, and resume the morning after.

**Architecture:** A nullable `skipped_from` column records the consumed occurrence; the skip endpoint advances `target_time` by one occurrence and pushes the phone a CREATE. A pure arithmetic module owns the stepping. The phone's `computeArmTarget` learns to trust a future target, which is what makes the pushed skip stick.

**Tech Stack:** Fastify + better-sqlite3 (TypeScript, `node:test`), Flutter/Dart, vanilla JS dashboard, `@remotealarm/core` + oclif-less CLI + Raycast React extension.

**Spec:** `docs/superpowers/specs/2026-10-30-skip-next-occurrence-design.md`

## Global Constraints

- Skip is only for recurring alarms: `repeat_days` non-empty, or `interval > 1` with an anchor.
- `utc_offset_minutes` means **minutes east of UTC** (Brisbane `+600`); accept ±840, fall back to the server offset, then UTC.
- Never build the skip's CREATE payload from the `pending` transition's builder (`server.ts:989-1001`); it drops interval and anchor and silently makes a fortnightly alarm weekly. Use `buildCreatePayload`.
- Never send `skipped_from` in an FCM payload; the phone learns it on reconcile.
- Copy is lowercase, matching the existing UI.
- No new dependencies in any package.
- Suite commands: `cd backend && npm test`, `cd mobile && flutter test`, `cd clients/core && npm test`, and `./run_tests.sh` at the end.
- Commit after every task.

## Review Focus

1. Skip pressed while the alarm is already ringing or its target is seconds past: must not stop the ring and must not skip zero occurrences.
2. Two surfaces skipping within seconds: the second must 409 and the alarm must advance exactly once.
3. Alarm edited between the skip and the skipped morning: the edit wins and the phone arms the edit, not the old pattern.
4. Phone offline during the skip and reconnecting after the skipped morning: the skipped instant must not come back.
5. Skipping the last weekday of the week: Friday must land on Monday, never Saturday.

---

### Task 1: Occurrence arithmetic

**Files:**
- Create: `backend/src/recurrence.ts`
- Test: `backend/test/skip_arithmetic.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `interface Pattern { repeatDays: number[]; intervalWeeks: number }`
  - `isRecurring(repeatDays: number[], intervalWeeks: number, anchorDate?: string | null): boolean`
  - `stepOccurrence(occurrence: Date, pattern: Pattern, utcOffsetMinutes: number): Date`
  - `firstOccurrenceAfter(occurrence: Date, pattern: Pattern, utcOffsetMinutes: number, after: Date): Date`

- [ ] **Step 1: Write the failing test**

```ts
// backend/test/skip_arithmetic.test.ts
import { describe, it } from 'node:test';
import assert from 'node:assert';
import { isRecurring, stepOccurrence, firstOccurrenceAfter } from '../src/recurrence.js';

const BRISBANE = 600;

describe('skip arithmetic', () => {
  it('steps Friday to Monday on a weekday pattern, in Brisbane local time', () => {
    // Fri 30 Oct 2026, 09:00 Brisbane == Thu 29 Oct 23:00Z
    const friday = new Date('2026-10-29T23:00:00.000Z');
    const next = stepOccurrence(friday, { repeatDays: [1, 2, 3, 4, 5], intervalWeeks: 1 }, BRISBANE);
    assert.strictEqual(next.toISOString(), '2026-11-01T23:00:00.000Z'); // Mon 2 Nov 09:00 Brisbane
  });

  it('steps the same instant a day later when the offset is ignored', () => {
    const thursdayUtc = new Date('2026-10-29T23:00:00.000Z');
    const next = stepOccurrence(thursdayUtc, { repeatDays: [1, 2, 3, 4, 5], intervalWeeks: 1 }, 0);
    assert.strictEqual(next.toISOString(), '2026-10-30T23:00:00.000Z');
  });

  it('steps an interval pattern by 7 x interval days', () => {
    const base = new Date('2026-10-30T09:00:00.000Z');
    const next = stepOccurrence(base, { repeatDays: [5], intervalWeeks: 2 }, 0);
    assert.strictEqual(next.toISOString(), '2026-11-13T09:00:00.000Z');
  });

  it('rolls a past occurrence forward to the first one after now', () => {
    const monday = new Date('2026-10-26T09:00:00.000Z');
    const now = new Date('2026-10-28T12:00:00.000Z');
    const s = firstOccurrenceAfter(monday, { repeatDays: [1, 2, 3, 4, 5], intervalWeeks: 1 }, 0, now);
    assert.strictEqual(s.toISOString(), '2026-10-29T09:00:00.000Z');
  });

  it('keeps a future occurrence unchanged', () => {
    const tomorrow = new Date('2026-10-29T09:00:00.000Z');
    const now = new Date('2026-10-28T12:00:00.000Z');
    const s = firstOccurrenceAfter(tomorrow, { repeatDays: [1, 2, 3, 4, 5], intervalWeeks: 1 }, 0, now);
    assert.strictEqual(s.getTime(), tomorrow.getTime());
  });

  it('treats interval-with-anchor and repeat_days as recurring', () => {
    assert.strictEqual(isRecurring([1, 2], 1), true);
    assert.strictEqual(isRecurring([], 2, '2026-10-30'), true);
    assert.strictEqual(isRecurring([], 1, null), false);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && npm run test:one -- test/skip_arithmetic.test.ts`
Expected: FAIL, cannot find module `../src/recurrence.js`.

- [ ] **Step 3: Implement `backend/src/recurrence.ts`**

Exact signatures as in Interfaces. Implementation notes: convert to local by adding `utcOffsetMinutes * 60_000` to the epoch and reading the UTC components of that shifted `Date` as the wall clock; shift back by subtracting. For `intervalWeeks > 1` step `7 * intervalWeeks` local days. Otherwise advance one local day at a time (at most 7) until the local ISO weekday is in `repeatDays`. `firstOccurrenceAfter` returns `occurrence` when it is already strictly after `after`, else keeps calling `stepOccurrence` (cap 400 steps) until it is.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd backend && npm run test:one -- test/skip_arithmetic.test.ts`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add backend/src/recurrence.ts backend/test/skip_arithmetic.test.ts
git commit -m "feat(backend): occurrence arithmetic for skipping one instance"
```

---

### Task 2: `POST /api/alarms/:id/skip`

**Files:**
- Modify: `backend/src/db.ts` (schema, migrations, `AlarmRecord`, `setSkip`)
- Modify: `backend/src/server.ts` (`buildCreatePayload`, the route)
- Test: `backend/test/skip.test.ts`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `AlarmRecord.skipped_from?: string | null`
  - `AlarmRepo.setSkip(id: string, skippedFrom: string | null, targetTime: string): boolean`
  - `buildCreatePayload(alarm: AlarmRecord): FcmPayload` (exported from `server.ts`)
  - `POST /api/alarms/:id/skip` body `{ utc_offset_minutes?: number }` → `200 { success, id, status, target_time, skipped_from, fcm_dispatch }`

- [ ] **Step 1: Write the failing tests**

`backend/test/skip.test.ts`, with `before` registering `DeviceRepo.upsert('skip-test-token')` and `after` deleting every alarm whose label starts with `SkipTest` and the token. Include a local helper:

```ts
async function createAlarm(payload: Record<string, unknown>) {
  const res = await app.inject({
    method: 'POST',
    url: '/api/alarms',
    payload: { label: 'SkipTest alarm', ...payload },
  });
  return JSON.parse(res.body);
}
```

Then:

```ts
it('advances exactly one occurrence and records what was skipped', async () => {
  const target = new Date(Date.now() + 60 * 60 * 1000);
  const created = await createAlarm({ target_time: target.toISOString(), repeat_days: '1,2,3,4,5,6,7' });
  const res = await app.inject({ method: 'POST', url: `/api/alarms/${created.id}/skip`, payload: { utc_offset_minutes: 0 } });
  assert.strictEqual(res.statusCode, 200);
  const data = JSON.parse(res.body);
  assert.strictEqual(new Date(data.target_time).getTime(), target.getTime() + 86_400_000);
  assert.strictEqual(new Date(data.skipped_from).getTime(), target.getTime());
  const row = AlarmRepo.getById(created.id)!;
  assert.strictEqual(row.target_time, data.target_time);
  assert.strictEqual(row.skipped_from, data.skipped_from);
  assert.strictEqual(data.fcm_dispatch.sent, 1);
});
```

Plus: 404 unknown id; 409 for a one-time alarm (create without `repeat_days`, assert `error` matches `/not recurring|recurring/i`); 409 for each of `disabled`, `snoozed` and `ringing`; 409 for a second skip while one is pending (target unchanged); a `target_time` 30s in the past with all seven days advances to the next future occurrence and leaves today's row alone; a no-device skip (delete all tokens first) succeeds with `sent: 0, failed: 0`; and `buildCreatePayload` returns `recurrence_interval_weeks === 2` and the anchor for a fortnightly row.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd backend && npm run test:one -- test/skip.test.ts`
Expected: FAIL, 404 from the unknown route.

- [ ] **Step 3: Add the column and the repo write**

`db.ts`: add `skipped_from TEXT DEFAULT NULL` to the `CREATE TABLE` and `{ name: 'add_skipped_from', sql: 'ALTER TABLE alarms ADD COLUMN skipped_from TEXT DEFAULT NULL' }` to `migrations`; add `skipped_from?: string | null` to `AlarmRecord`; add

```ts
setSkip(id: string, skippedFrom: string | null, targetTime: string): boolean
```

writing both columns in one statement. Leave `updateTargetTime` alone; Task 4 changes it.

- [ ] **Step 4: Implement `buildCreatePayload` and the route**

`buildCreatePayload(alarm)` returns the create path's field set (`server.ts:627-646`): id, target_time, label, sound_tone, ramp_seconds, recurrence_interval_weeks, recurrence_anchor_date, plus description and repeat_days when present. Replace the inline builder in `POST /api/alarms` with it, so the two cannot drift.

The route resolves `utc_offset_minutes` (integer, |v| ≤ 840, else the server offset, else 0), rejects the three 409 cases, computes `S = firstOccurrenceAfter(new Date(existing.target_time), pattern, offset, new Date())` and `N = stepOccurrence(S, pattern, offset)`, sends CREATE for `{ ...existing, target_time: N.toISOString() }`, then: on `sent === 0 && failed > 0` → `recordDispatch`, reply `502` with `{ error: 'The phone was not reached, so the alarm was not skipped. Try again.' }` and write nothing; otherwise `setSkip(id, S.toISOString(), N.toISOString())`, `recordDispatch`, `mirrorSafely(updated)`, and reply 200.

- [ ] **Step 5: Run them to verify they pass**

Run: `cd backend && npm run test:one -- test/skip.test.ts`
Expected: PASS.

- [ ] **Step 6: Run the full backend suite**

Run: `cd backend && npm test`
Expected: PASS. The 479-test baseline is unchanged except for the new file.

- [ ] **Step 7: Commit**

```bash
git add backend/src/db.ts backend/src/server.ts backend/test/skip.test.ts
git commit -m "feat(backend): skip the next occurrence of a recurring alarm"
```

---

### Task 3: `POST /api/alarms/:id/unskip`

**Files:**
- Modify: `backend/src/server.ts`
- Test: `backend/test/skip.test.ts`

**Interfaces:**
- Consumes: Task 2's `setSkip`, `buildCreatePayload`, `AlarmRepo`.
- Produces: `POST /api/alarms/:id/unskip` → same response shape with `skipped_from: null`.

- [ ] **Step 1: Write the failing tests**

Add to `backend/test/skip.test.ts`: (a) after a skip, unskip restores `target_time` to the skipped instant and nulls `skipped_from`; (b) 409 with a distinct message when nothing is pending; (c) 409 when the alarm was disabled after the skip; (d) 409 once `skipped_from` is in the past — set it directly with `db.prepare('UPDATE alarms SET skipped_from = ? WHERE id = ?')` to `new Date(Date.now() - 60_000).toISOString()`; (e) `502` and an unchanged row when the phone is unreachable (reuse the long-label trick: a label of 5000 `x`s makes the FCM payload exceed 4096 bytes, so dispatch returns `sent: 0, failed: 1`).

- [ ] **Step 2: Run to verify they fail**

Run: `cd backend && npm run test:one -- test/skip.test.ts`
Expected: FAIL, 404 from the unknown route.

- [ ] **Step 3: Implement the route**

Same dispatch-first ordering as skip: compute `S` from `existing.skipped_from`, send CREATE for `S`, then on success `setSkip(id, null, S)`, `recordDispatch`, `mirrorSafely`. On `sent === 0 && failed > 0`, reply 502 and write nothing.

- [ ] **Step 4: Run to verify they pass**

Run: `cd backend && npm run test:one -- test/skip.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/src/server.ts backend/test/skip.test.ts
git commit -m "feat(backend): undo a skipped occurrence"
```

---

### Task 4: Clear the marker when the alarm moves or is edited

**Files:**
- Modify: `backend/src/db.ts` (`updateTargetTime`, `update`)
- Modify: `backend/src/server.ts` (PATCH handler)
- Test: `backend/test/skip.test.ts`

**Interfaces:**
- Consumes: Task 2's column.
- Produces: no new signatures; `updateTargetTime` and PATCH now null `skipped_from`.

- [ ] **Step 1: Write the failing tests**

Add to `backend/test/skip.test.ts`: (a) after a skip, `PATCH { label: 'renamed' }` returns `skipped_from: null` and keeps `target_time`; (b) after a skip, `POST /state { status: 'pending', target_time: <N + 1 day> }` returns `skipped_from: null`; (c) `GET /api/alarms?view=all` exposes `skipped_from` on a skipped row.

- [ ] **Step 2: Run to verify they fail**

Run: `cd backend && npm run test:one -- test/skip.test.ts`
Expected: FAIL on the `skipped_from` assertions.

- [ ] **Step 3: Implement**

`updateTargetTime`: `SET target_time = ?, skipped_from = NULL`. `update`: add `skipped_from = @skipped_from` to the SET list and the bound object (defaulting to the merged value). In PATCH, set `updates.skipped_from = null` before `AlarmRepo.update`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd backend && npm run test:one -- test/skip.test.ts`
Expected: PASS.

- [ ] **Step 5: Run the full backend suite**

Run: `cd backend && npm test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/src/db.ts backend/src/server.ts backend/test/skip.test.ts
git commit -m "feat(backend): drop a pending skip when the alarm changes"
```

---

### Task 5: Phone arms a future target as given

**Files:**
- Modify: `mobile/lib/services/alarm_service.dart` (`computeArmTarget`)
- Test: `mobile/test/skip_arming_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `AlarmService.computeArmTarget` returns `targetTime` unchanged when it is strictly after `now`, for both one-time and recurring alarms.

- [ ] **Step 1: Write the failing test**

```dart
// mobile/test/skip_arming_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

void main() {
  test('a future recurring target is armed as given, not rolled back to today', () {
    final now = DateTime(2026, 10, 29, 1, 0); // Thursday 1am
    final target = DateTime(2026, 10, 30, 9, 0); // Friday 9am, the morning after a skip
    final armed = AlarmService.computeArmTarget(
      target,
      repeatDays: [1, 2, 3, 4, 5],
      mockNow: now,
    );
    expect(armed, equals(target));
  });

  test('a past recurring target still advances', () {
    final now = DateTime(2026, 10, 30, 10, 0); // Friday, after the ring
    final target = DateTime(2026, 10, 30, 9, 0);
    final armed = AlarmService.computeArmTarget(
      target,
      repeatDays: [1, 2, 3, 4, 5],
      mockNow: now,
    );
    expect(armed, equals(DateTime(2026, 11, 2, 9, 0))); // Monday
  });

  test('a target that already passed advances past it, never back to an earlier skip', () {
    final now = DateTime(2026, 11, 4, 12, 0); // Wednesday midday, phone was offline
    final target = DateTime(2026, 11, 3, 9, 0); // the Tuesday the alarm was meant to ring
    final armed = AlarmService.computeArmTarget(
      target,
      repeatDays: [1, 2, 3, 4, 5],
      mockNow: now,
    );
    expect(armed!.isAfter(target), isTrue);
    expect(armed, equals(DateTime(2026, 11, 5, 9, 0))); // Thursday, never the Monday before
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd mobile && flutter test test/skip_arming_test.dart`
Expected: FAIL on the first test, `armed` is 2026-10-29 09:00.

- [ ] **Step 3: Implement**

In `computeArmTarget`, before the `isRecurring` branch: `if (targetTime.isAfter(now)) return targetTime;`. Leave `getNextOccurrence` untouched; `dismissAlarm` calls it directly with a just-rung time.

- [ ] **Step 4: Run to verify it passes**

Run: `cd mobile && flutter test test/skip_arming_test.dart`
Expected: PASS, 3 tests.

- [ ] **Step 5: Run the full mobile suite**

Run: `cd mobile && flutter test`
Expected: PASS. If `arm_dedup_test.dart`, `payload_refresh_test.dart` or `sync_reconnection_test.dart` fail, the guard is in the wrong place: it must sit in `computeArmTarget`, not `getNextOccurrence`.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/services/alarm_service.dart mobile/test/skip_arming_test.dart
git commit -m "fix(mobile): arm a future target as given so a pushed skip sticks"
```

---

### Task 6: Phone skip control

**Files:**
- Modify: `mobile/lib/services/alarm_service.dart` (eligibility + label helpers)
- Modify: `mobile/lib/services/backend_client.dart` (`skipRemoteAlarm`, `unskipRemoteAlarm`)
- Modify: `mobile/lib/main.dart` (`_AlarmItem.skippedFrom`, `_loadAllAlarms`, the edit sheet)
- Test: `mobile/test/skip_ui_helpers_test.dart`

**Interfaces:**
- Consumes: Tasks 2, 3 and 5.
- Produces:
  - `AlarmService.isSkipEligible({required bool isEnabled, required bool isSnoozed, required List<int> repeatDays, required int intervalWeeks, String? anchorDate, required String status, String? skippedFrom, DateTime? mockNow})` → `bool`
  - `AlarmService.skipLineLabel(DateTime skippedFrom, DateTime next)` → `String`
  - `BackendClient.skipRemoteAlarm(String uuid, int utcOffsetMinutes)` → `Future<Map<String, dynamic>?>`
  - `BackendClient.unskipRemoteAlarm(String uuid)` → `Future<Map<String, dynamic>?>`

- [ ] **Step 1: Write the failing tests**

```dart
// mobile/test/skip_ui_helpers_test.dart
test('eligible only for an enabled, unsnoozed, pending recurring alarm', () {
  final now = DateTime(2026, 10, 29, 1, 0);
  bool at({bool enabled = true, bool snoozed = false, List<int> days = const [1, 2, 3, 4, 5], int weeks = 1, String? anchor, String status = 'pending', String? skipped}) =>
      AlarmService.isSkipEligible(isEnabled: enabled, isSnoozed: snoozed, repeatDays: days,
        intervalWeeks: weeks, anchorDate: anchor, status: status, skippedFrom: skipped, mockNow: now);

  expect(at(), isTrue);
  expect(at(enabled: false), isFalse);
  expect(at(snoozed: true), isFalse);
  expect(at(days: const []), isFalse);
  expect(at(days: const [], weeks: 2, anchor: '2026-10-30'), isTrue);
  expect(at(status: 'ringing'), isFalse);
  expect(at(status: 'disabled'), isFalse);
  expect(at(skipped: '2026-10-30T00:00:00.000Z'), isFalse);
});

test('the skip line names what was skipped and when it is back', () {
  final label = AlarmService.skipLineLabel(DateTime(2026, 10, 30, 9), DateTime(2026, 11, 2, 9));
  expect(label, 'skipped fri 30 oct, 9:00am · back mon 2 nov, 9:00am');
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd mobile && flutter test test/skip_ui_helpers_test.dart`
Expected: FAIL, `isSkipEligible` is not defined.

- [ ] **Step 3: Implement the helpers and the client methods**

`isSkipEligible`: status must be `pending`, `isEnabled`, not `isSnoozed`, no `skippedFrom` still in the future (`DateTime.tryParse`), and the recurrence test from the spec (`repeatDays.isNotEmpty || (intervalWeeks > 1 && anchorDate != null)`).

`skipLineLabel`: a pure function using the existing relative-day helpers if they fit, else `toLowerCase()` on `'EEE d MMM'` output; exact shape `skipped <day> <d> <mon>, <h>:<mm><am|pm> · back <day> <d> <mon>, <h>:<mm><am|pm>`.

`skipRemoteAlarm`/`unskipRemoteAlarm`: mirror `updateRemoteAlarm`'s error handling, POST to `/api/alarms/$uuid/skip` with `{ 'utc_offset_minutes': DateTime.now().timeZoneOffset.inMinutes }` and `/api/alarms/$uuid/unskip`, return the decoded body or null.

- [ ] **Step 4: Run to verify they pass**

Run: `cd mobile && flutter test test/skip_ui_helpers_test.dart`
Expected: PASS.

- [ ] **Step 5: Carry `skipped_from` into the phone's model**

Add `String? skippedFrom;` to `_AlarmItem` and set it in `_loadAllAlarms` from the fetched row's `skipped_from`.

- [ ] **Step 6: Wire the sheet**

In the edit sheet, add one line above the `save adjustments` / `delete` row: when eligible, a subdued `skip next occurrence` text button; when a skip is pending, `skipLineLabel(...)` plus an `undo` button. Handlers call the client method; on success update the in-memory item (`dateTime`, `skippedFrom`) and rebuild the sheet, and fire `AlarmService.syncWithBackend()` in the background so the OS alarm is re-armed. On failure, `_showToast('could not skip: backend unreachable')` and leave the sheet untouched. Both controls are absent for one-time, disabled, snoozed and ringing alarms.

- [ ] **Step 7: Run analyze and the full suite**

Run: `cd mobile && flutter analyze && flutter test`
Expected: clean analyze, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add mobile/lib/services/alarm_service.dart mobile/lib/services/backend_client.dart mobile/lib/main.dart mobile/test/skip_ui_helpers_test.dart
git commit -m "feat(mobile): skip the next occurrence from the alarm sheet"
```

---

### Task 7: Dashboard control

**Files:**
- Modify: `backend/public/index.html`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: `skipCurrentAlarm()`, `unskipCurrentAlarm()`, and a `renderSkipLine(alarm)` helper.

- [ ] **Step 1: Add the markup and handlers**

In `#alarm-detail-modal`, above the footer's `delete alarm` button, add `<div id="skip-state-line"></div>` and a text button `id="skip-next-btn"` with lowercase copy matching the phone. `renderSkipLine(alarm)` shows either the eligible action (recurring, `pending`) or the skipped line plus undo, and runs from `openAlarmDetail`. Handlers POST `/api/alarms/${id}/skip` with `{ utc_offset_minutes: -new Date().getTimezoneOffset() }` or `/unskip`, update the matching entry in `allAlarms`, call `renderSkipLine`, then `loadAlarms()`. On a non-2xx, `alert('could not skip: ' + (err.error || res.status))`.

Does not close the modal, so the undo stays reachable.

- [ ] **Step 2: Verify by hand**

Run: `cd backend && npm run dev`, open `http://localhost:3000`, create a weekday alarm, open it, skip, confirm the line flips and the row time moves; reload the page and confirm the line persists; unskip and confirm it reverts. Also open a one-time alarm and confirm the control is absent.

- [ ] **Step 3: Commit**

```bash
git add backend/public/index.html
git commit -m "feat(dashboard): skip the next occurrence from the alarm modal"
```

---

### Task 8: `clients/core`

**Files:**
- Modify: `clients/core/src/client.ts`, `clients/core/src/types.ts`
- Test: `clients/core/test/client.test.ts`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces:
  - `RemoteAlarmClient.skipAlarm(id: string): Promise<AlarmMutationResult>`
  - `RemoteAlarmClient.unskipAlarm(id: string): Promise<AlarmMutationResult>`
  - `Alarm.skipped_from?: string | null`

- [ ] **Step 1: Write the failing tests**

Follow the existing `silenceAlarm` test: assert the method POSTs `/api/alarms/<id>/skip` (and `/unskip`) with a body carrying `utc_offset_minutes`, maps the response through `toMutationResult`, and turns a 409 into `RemoteAlarmError` with the server message. assert `skipped_from` survives `normalizeAlarm`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd clients/core && npm test`
Expected: FAIL, `skipAlarm` is not a function.

- [ ] **Step 3: Implement**

Mirror `silenceAlarm`. Send `utc_offset_minutes: -new Date().getTimezoneOffset()`; `build` copies `skipped_from` when present.

- [ ] **Step 4: Run to verify they pass, then build**

Run: `cd clients/core && npm test && npm run build`
Expected: PASS, and `dist/` regenerated. `dist` is untracked but is what the CLI and Raycast import.

- [ ] **Step 5: Commit**

```bash
git add clients/core/src/client.ts clients/core/src/types.ts clients/core/test/client.test.ts
git commit -m "feat(core): skip and unskip client methods"
```

---

### Task 9: CLI verbs

**Files:**
- Modify: `clients/cli/src/args.ts`, `clients/cli/src/commands/mutate.ts`, `clients/cli/src/index.ts`

**Interfaces:**
- Consumes: Task 8.
- Produces: `alarm skip <id>` and `alarm unskip <id>`.

- [ ] **Step 1: Add the verbs**

`COMMAND_NAMES` gains `skip` and `unskip`; the top help and per-command help describe them in the existing style. `mutate.ts` gains `skipCommand` and `unskipCommand` using `rejectFlags(ctx.values, MUTATION_FLAGS, '<verb>')`, `requireId`, `confirmAlarm`, `emitMutation(ctx, 'skipped', ...)` / `'unskipped'`. `index.ts` adds both to the dispatch switch. No confirmation prompt: the action is reversible.

- [ ] **Step 2: Verify by hand**

Run: `cd backend && npm run dev` in one shell, then `cd clients/cli && npx tsx src/index.ts skip <id>` for a recurring alarm (expect the new time printed), `npx tsx src/index.ts unskip <id>`, and `npx tsx src/index.ts skip <one-time-id>` (expect the server's 409 message and a non-zero exit). Also `npx tsx src/index.ts --help` lists both verbs.

- [ ] **Step 3: Type-check**

Run: `cd clients/cli && npx tsc -p tsconfig.json --noEmit`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add clients/cli/src/args.ts clients/cli/src/commands/mutate.ts clients/cli/src/index.ts
git commit -m "feat(cli): skip and unskip verbs"
```

---

### Task 10: Raycast actions

**Files:**
- Modify: `clients/raycast/src/list-alarms.tsx`
- Modify: `clients/raycast/help.md`

**Interfaces:**
- Consumes: Task 8.
- Produces: `skip next occurrence` and `undo skip` actions.

- [ ] **Step 1: Add the actions**

In the alarm action panel: `skip next occurrence`, shown only when the alarm is recurring (`repeat_days` non-empty, or interval > 1 with an anchor) and `status === 'pending'` and no `skipped_from` in the future; `undo skip`, shown when `skipped_from` is in the future. Call `client.skipAlarm` / `client.unskipAlarm`, toast the new time, then revalidate. Refresh `help.md`.

- [ ] **Step 2: Verify**

Run: `cd clients/raycast && npm run typecheck && npm run lint`
Expected: both clean. Then `npm run dev` against a running backend and exercise both actions on a weekday alarm.

- [ ] **Step 3: Commit**

```bash
git add clients/raycast/src/list-alarms.tsx clients/raycast/help.md
git commit -m "feat(raycast): skip next occurrence action"
```

---

### Task 11: Documentation and full verification

**Files:**
- Modify: `README.md`, `clients/README.md`, `docs/ROADMAP.md`

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Document the feature**

README: one short subsection under what the app does, plus the two endpoints with the `utc_offset_minutes` rule and the 502 behaviour. `clients/README.md`: the two CLI verbs and the Raycast actions. `docs/ROADMAP.md`: move the item to implemented.

- [ ] **Step 2: Run every suite**

Run: `./run_tests.sh`
Expected: ends with `All Automated Test Suites Passed Successfully!`.

- [ ] **Step 3: Commit**

```bash
git add README.md clients/README.md docs/ROADMAP.md
git commit -m "docs: record skip-next-occurrence"
```
