# Alarm Delivery Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make alarm delivery reliable and make any delivery failure loud, instead of the silent no-op that let a real alarm be missed.

**Architecture:** Keep FCM as the wake channel but fix its hygiene (TTL, collapse key, retry, correct token pruning, payload guard); keep the ring local-first (already true — the `alarm` package arms natively and survives reboot); add a *due-aware* delivery-health monitor so a dead token, a failed dispatch, or an alarm that went `missed` surfaces instead of going quiet; and make FCM receipts trigger an authoritative pull.

**Tech Stack:** Node/TypeScript backend (Fastify, `node:test`, `tsx`, `firebase-admin`); Flutter/Dart Android app (`firebase_messaging` 16.7.0, `alarm` 5.13.1).

**Spec:** `docs/superpowers/specs/2026-10-16-alarm-delivery-reliability-design.md` (§5.1, §5.3, §5.4, §5.5). This plan covers the **reliability core only**. Auth/token and public exposure (§5.2, §5.6, §5.7) are a separate plan.

## Global Constraints

- Backend tests: `npm test` from `backend/` (sets `NODE_ENV=test DB_PATH=:memory: GCAL_ENABLED=false`, runs `tsx --test test/**/*.test.ts`). One file: `npm run test:one test/<file>.test.ts`. Runner is `node:test` + `node:assert/strict`; ESM imports use the `.js` extension (`../src/fcm.js`).
- Mobile tests: `flutter test`; lints: `flutter analyze lib/ test/`.
- Real timers in the backend are guarded by `isTestRun` (`server.ts:126`); any new timer must be too, and a test must assert it does not start under test.
- FCM data payload values are strings; the data payload must stay under **4096 bytes**.
- `sent > 0` is **never** proof of delivery. No user-facing or audit string may imply delivery from a `sent` count.
- The `alarm` package (5.13.1) uses `AlarmManager.setExactAndAllowWhileIdle` and ships a native `BootReceiver`; the ring is already local-first and reboot-safe. **No `setAlarmClock` / native work in this plan.**
- **No auth, token, or exposure changes in this plan** (that is Plan 2). Do not touch request headers here.

## Review Focus

Input/condition → behavior a reasonable person expects. Each is pinned by a test in the task named.

1. **Zero registered devices.** An alarm is created, nothing is delivered, and the system stays silent. Expected: it is recorded and surfaced as unhealthy. → Task 3.
2. **A healthy token removed by a payload error.** A malformed/oversized message returns `messaging/invalid-argument` and the device is pruned. Expected: only a genuinely dead token is pruned. → Task 2.
3. **App terminated.** A data-only message lands in the background isolate. Expected: the alarm arms with **no** network call. → Task 8.
4. **A quiet interval with no alarms.** No dispatch happens for days. Expected: the monitor stays healthy — it must not false-alert. → Task 3.
5. **An oversized payload** (e.g. a very long label) is sent. Expected: it fails at send with a visible error, not silently dropped by FCM. → Task 1.

---

### Task 1: FCM message hygiene — TTL, collapse key, payload guard

**Files:**
- Modify: `backend/src/fcm.ts`
- Test: `backend/test/fcm_hygiene.test.ts` (create)

**Interfaces:**
- Consumes: `FcmPayload` (fcm.ts:57-68), `DeviceRepo.getAllTokens()`.
- Produces:
  - `export const FCM_TTL_MS = 60 * 60 * 1000`
  - `export function buildFcmMessage(action: FcmAction, payload: FcmPayload, token: string): Record<string, unknown>`
  - `export function validateFcmPayload(payload: FcmPayload): { ok: true } | { ok: false; error: string }`
  - `export type FcmAction = 'CREATE' | 'CANCEL' | 'DISMISS' | 'DISABLE'`

- [ ] **Step 1: Write the failing test**

```ts
// backend/test/fcm_hygiene.test.ts
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { buildFcmMessage, validateFcmPayload, FCM_TTL_MS } from '../src/fcm.js';

describe('buildFcmMessage', () => {
  it('sets high priority, a 1h TTL, and a per-alarm collapse key', () => {
    const msg: any = buildFcmMessage('CREATE', { id: 'abc', label: 'gym' }, 'tok-1');
    assert.equal(msg.token, 'tok-1');
    assert.equal(msg.android.priority, 'high');
    assert.equal(msg.android.ttl, FCM_TTL_MS);
    assert.equal(msg.android.collapseKey, 'alarm:abc');
    assert.equal(msg.data.action, 'CREATE');
    assert.equal(msg.data.id, 'abc');
  });

  it('rejects a payload whose JSON exceeds 4096 bytes', () => {
    const big = validateFcmPayload({ id: 'abc', label: 'x'.repeat(5000) });
    assert.equal(big.ok, false);
    assert.match((big as any).error, /4096/);
  });

  it('accepts a normal payload', () => {
    assert.deepEqual(validateFcmPayload({ id: 'abc', label: 'gym' }), { ok: true });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:one test/fcm_hygiene.test.ts`
Expected: FAIL — `buildFcmMessage` is not exported.

- [ ] **Step 3: Implement in `backend/src/fcm.ts`**

Add `FcmAction`, `FCM_TTL_MS`, and `validateFcmPayload` (JSON.stringify the data map; `ok:false` when `Buffer.byteLength(...) > 4096`). Add `buildFcmMessage(action, payload, token)` returning `{ token, android: { priority: 'high', ttl: FCM_TTL_MS, collapseKey: \`alarm:${payload.id}\` }, data: { action, ...stringified payload } }`. Rewrite the per-token send loop (fcm.ts:117-142) to build the message with `buildFcmMessage` and to call `validateFcmPayload` first, logging an `error` and counting it in `failed` when invalid.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test`
Expected: PASS (all suites), including the new file.

- [ ] **Step 5: Commit**

```bash
git add backend/src/fcm.ts backend/test/fcm_hygiene.test.ts
git commit -m "fix: set FCM ttl and collapse key, guard payload size"
```

---

### Task 2: FCM send behaviour — retry/backoff and correct token pruning

**Files:**
- Modify: `backend/src/fcm.ts`
- Test: `backend/test/fcm_hygiene.test.ts`

**Interfaces:**
- Produces:
  - `export function shouldPruneToken(code: string | undefined): boolean`
  - `export async function withRetry<T>(fn: () => Promise<T>, opts?: { attempts?: number; baseDelayMs?: number; isRetryable?: (e: unknown) => boolean; sleep?: (ms: number) => Promise<void> }): Promise<T>`
- Consumes: `DeviceRepo.remove(token)`.

- [ ] **Step 1: Write the failing test**

```ts
it('prunes only a genuinely dead token, not a payload error', () => {
  assert.equal(shouldPruneToken('messaging/registration-token-not-registered'), true);
  assert.equal(shouldPruneToken('messaging/invalid-argument'), false);
  assert.equal(shouldPruneToken(undefined), false);
});

it('retries a transient error and eventually succeeds', async () => {
  let calls = 0;
  const slept: number[] = [];
  const out = await withRetry(
    async () => { calls++; if (calls < 3) throw Object.assign(new Error('boom'), { code: 'messaging/internal-error' }); return 'ok'; },
    { attempts: 3, baseDelayMs: 10, sleep: async (ms) => { slept.push(ms); } },
  );
  assert.equal(out, 'ok');
  assert.equal(calls, 3);
  assert.deepEqual(slept, [10, 20]);
});

it('does not retry a permanent error', async () => {
  let calls = 0;
  await assert.rejects(() => withRetry(
    async () => { calls++; throw Object.assign(new Error('x'), { code: 'messaging/registration-token-not-registered' }); },
    { attempts: 3, sleep: async () => {} },
  ));
  assert.equal(calls, 1);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:one test/fcm_hygiene.test.ts`
Expected: FAIL — `shouldPruneToken` / `withRetry` not exported.

- [ ] **Step 3: Implement in `backend/src/fcm.ts`**

`shouldPruneToken` returns true only for `'messaging/registration-token-not-registered'`. `withRetry` loops up to `attempts` (default 3), sleeping `baseDelayMs * 2**n` between tries, rethrowing immediately when `isRetryable` (default: not a prune code) is false. Change the error handling at fcm.ts:134-140 to prune via `shouldPruneToken(err.code)` and to send through `withRetry`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/src/fcm.ts backend/test/fcm_hygiene.test.ts
git commit -m "fix: retry transient FCM sends and stop pruning healthy tokens"
```

---

### Task 3: Delivery-health evaluation (pure)

**Files:**
- Create: `backend/src/alerts.ts`
- Test: `backend/test/delivery_health.test.ts` (create)

**Interfaces:**
- Consumes: `AlarmRecord` (db.ts).
- Produces:
  - `export type DeliveryHealthReason = 'no_registered_devices' | 'last_dispatch_failed' | 'alarm_due_without_report'`
  - `export interface DeliveryHealth { ok: boolean; reasons: DeliveryHealthReason[] }`
  - `export const DUE_WITHIN_MS = 15 * 60 * 1000`
  - `export function evaluateDeliveryHealth(input: { deviceCount: number; alarms: AlarmRecord[]; now: Date; dueWithinMs?: number }): DeliveryHealth`

- [ ] **Step 1: Write the failing test**

```ts
// backend/test/delivery_health.test.ts
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { evaluateDeliveryHealth } from '../src/alerts.js';

const base = { deviceCount: 1, now: new Date('2026-10-16T00:00:00Z'), dueWithinMs: 900000 };

describe('evaluateDeliveryHealth', () => {
  it('flags zero registered devices', () => {
    const h = evaluateDeliveryHealth({ ...base, deviceCount: 0, alarms: [] });
    assert.equal(h.ok, false);
    assert.deepEqual(h.reasons, ['no_registered_devices']);
  });

  it('flags a failed last dispatch', () => {
    const h = evaluateDeliveryHealth({ ...base, alarms: [{ id: 'a', status: 'pending', target_time: '2026-10-17T00:00:00Z', last_dispatch_failed: 1 } as any] });
    assert.ok(h.reasons.includes('last_dispatch_failed'));
  });

  it('flags a due alarm the phone never reported on', () => {
    const h = evaluateDeliveryHealth({ ...base, alarms: [{ id: 'a', status: 'pending', target_time: '2026-10-16T00:05:00Z', last_dispatch_failed: 0 } as any] });
    assert.ok(h.reasons.includes('alarm_due_without_report'));
  });

  it('stays healthy through a quiet interval with no alarms', () => {
    assert.deepEqual(evaluateDeliveryHealth({ ...base, alarms: [] }), { ok: true, reasons: [] });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:one test/delivery_health.test.ts`
Expected: FAIL — cannot find module `../src/alerts.js`.

- [ ] **Step 3: Implement `backend/src/alerts.ts`**

Pure function. `no_registered_devices` when `deviceCount === 0`; `last_dispatch_failed` when any alarm has `last_dispatch_failed > 0`; `alarm_due_without_report` when an alarm is `pending`/`snoozed` with `target_time` between `now` and `now + dueWithinMs` and `last_dispatch_sent` falsy. `ok` is `reasons.length === 0`. **Do not** add any time-since-last-dispatch rule — quiet intervals are normal.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/src/alerts.ts backend/test/delivery_health.test.ts
git commit -m "feat: add due-aware delivery health evaluation"
```

---

### Task 4: Wire the monitor into the sweep and `/api/health`

**Files:**
- Modify: `backend/src/server.ts` (import from `./alerts.js`; extend the sweep at server.ts:1036-1045; extend the `GET /api/health` handler at server.ts:252)
- Test: `backend/test/delivery_health.test.ts`

**Interfaces:**
- Consumes: `evaluateDeliveryHealth`, `DeviceRepo.getAllDevices()`, `AlarmRepo.getAll('all')`.
- Produces: `GET /api/health` response gains `delivery_health: DeliveryHealth`.

- [ ] **Step 1: Write the failing test**

```ts
import { app } from '../src/server.js';
// (add to delivery_health.test.ts)
it('reports delivery health on /api/health', async () => {
  await app.ready();
  const res = await app.inject({ method: 'GET', url: '/api/health' });
  const body = res.json();
  assert.equal(typeof body.delivery_health.ok, 'boolean');
  assert.ok(Array.isArray(body.delivery_health.reasons));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:one test/delivery_health.test.ts`
Expected: FAIL — `delivery_health` undefined.

- [ ] **Step 3: Implement**

In the existing 60s sweep body, after `sweepMissedAlarms()`, compute `evaluateDeliveryHealth({ deviceCount: DeviceRepo.getAllDevices().length, alarms: AlarmRepo.getAll('all'), now: new Date() })` and `console.error('[alerts] delivery unhealthy:', health.reasons)` when `!health.ok`. Extend the `/api/health` handler to include the same `delivery_health` object. Keep everything inside the existing `if (!isTestRun)` timer.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test` — Expected: PASS; confirm the existing hermeticity assertion (`missedSweepStarted === false`) still holds.

- [ ] **Step 5: Commit**

```bash
git add backend/src/server.ts backend/test/delivery_health.test.ts
git commit -m "feat: surface delivery health in sweep logs and /api/health"
```

---

### Task 5: Webhook alert delivery (provider adapter)

**Files:**
- Modify: `backend/src/alerts.ts`
- Test: `backend/test/alerts_webhook.test.ts` (create)

**Interfaces:**
- Produces:
  - `export type WebhookKind = 'generic' | 'discord' | 'slack' | 'healthchecks'`
  - `export function formatWebhookAlert(kind: WebhookKind, alert: { title: string; body: string }): { method: 'POST' | 'GET'; headers: Record<string, string>; body?: string }`
  - `export async function sendWebhookAlert(url: string, kind: WebhookKind, alert: { title: string; body: string }): Promise<boolean>`

- [ ] **Step 1: Write the failing test**

```ts
// backend/test/alerts_webhook.test.ts
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { formatWebhookAlert, sendWebhookAlert } from '../src/alerts.js';

describe('formatWebhookAlert', () => {
  const alert = { title: 'Delivery unhealthy', body: 'no_registered_devices' };
  it('shapes a Discord payload', () => {
    assert.deepEqual(JSON.parse(formatWebhookAlert('discord', alert).body!), { content: 'Delivery unhealthy\nno_registered_devices' });
  });
  it('shapes a Slack payload', () => {
    assert.deepEqual(JSON.parse(formatWebhookAlert('slack', alert).body!), { text: 'Delivery unhealthy\nno_registered_devices' });
  });
  it('shapes a plain JSON payload', () => {
    assert.deepEqual(JSON.parse(formatWebhookAlert('generic', alert).body!), alert);
  });
  it('uses a GET heartbeat for Healthchecks', () => {
    const r = formatWebhookAlert('healthchecks', alert);
    assert.equal(r.method, 'GET');
    assert.equal(r.body, undefined);
  });
});

describe('sendWebhookAlert', () => {
  it('no-ops and returns false when no URL is configured', async () => {
    assert.equal(await sendWebhookAlert('', 'generic', { title: 't', body: 'b' }), false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:one test/alerts_webhook.test.ts`
Expected: FAIL — exports missing.

- [ ] **Step 3: Implement in `backend/src/alerts.ts`**

`formatWebhookAlert` returns the shapes above (Discord `{content}`, Slack `{text}`, generic `{title, body}`, Healthchecks a `GET` with no body). `sendWebhookAlert` returns `false` immediately for an empty URL, else `fetch`es the formatted request with a 5s timeout and returns whether the response was ok. Telegram is intentionally out of scope in the adapter (its API needs a bot token + `chat_id`); the README notes it can be reached via `generic` plus a relay.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/src/alerts.ts backend/test/alerts_webhook.test.ts
git commit -m "feat: add provider-shaped webhook alert delivery"
```

---

### Task 6: Call the webhook when health turns bad (throttled)

**Files:**
- Modify: `backend/src/server.ts` (sweep body only)
- Test: `backend/test/delivery_health.test.ts`

**Interfaces:**
- Consumes: `sendWebhookAlert`, `evaluateDeliveryHealth`, env `ALERT_WEBHOOK_URL` and optional `ALERT_WEBHOOK_KIND` (default `generic`).
- Produces: no new public surface.

- [ ] **Step 1: Write the failing test**

```ts
// delivery_health.test.ts
import { shouldSendAlert } from '../src/alerts.js';
it('throttles repeated identical alerts', () => {
  const first = shouldSendAlert('no_registered_devices', new Date('2026-10-16T00:00:00Z'), null);
  assert.equal(first.send, true);
  const soon = shouldSendAlert('no_registered_devices', new Date('2026-10-16T00:05:00Z'), first.sentAt);
  assert.equal(soon.send, false);
  const later = shouldSendAlert('no_registered_devices', new Date('2026-10-16T01:00:00Z'), first.sentAt);
  assert.equal(later.send, true);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:one test/delivery_health.test.ts`
Expected: FAIL — `shouldSendAlert` not exported.

- [ ] **Step 3: Implement**

Add `export function shouldSendAlert(reason: DeliveryHealthReason, now: Date, lastSentAt: Date | null, cooldownMs = 30 * 60 * 1000): { send: boolean; sentAt: Date }` to `alerts.ts` — sends when there is no `lastSentAt` or the cooldown has elapsed. In the sweep, keep a module-level `lastAlertAt`, and when `!health.ok` and `shouldSendAlert(...)` fires, `void sendWebhookAlert(process.env.ALERT_WEBHOOK_URL ?? '', (process.env.ALERT_WEBHOOK_KIND as WebhookKind) ?? 'generic', { title: 'Remote Alarm delivery unhealthy', body: health.reasons.join(', ') })`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/src/alerts.ts backend/src/server.ts backend/test/delivery_health.test.ts
git commit -m "feat: send throttled webhook alerts when delivery health is bad"
```

---

### Task 7: Mobile — re-register the FCM token on refresh

**Files:**
- Modify: `mobile/lib/main.dart` (`_initFCM` at 2113-2200)
- Test: `mobile/test/fcm_token_refresh_test.dart` (create)

**Interfaces:**
- Consumes: `BackendClient.registerDeviceToken` (backend_client.dart:45).
- Produces: a top-level `@visibleForTesting Future<void> Function(String token)? registerTokenForTest;` seam in `main.dart` (mirroring `AlarmService.missedReportSenderForTest`, alarm_service.dart:22).

- [ ] **Step 1: Write the failing test**

```dart
// mobile/test/fcm_token_refresh_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_alarm/main.dart' as app;

void main() {
  test('registerToken forwards the token to the registrar seam', () async {
    String? seen;
    app.registerTokenForTest = (t) async { seen = t; };
    await app.registerToken('tok-123');
    expect(seen, 'tok-123');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/fcm_token_refresh_test.dart`
Expected: FAIL — `registerToken` / `registerTokenForTest` undefined.

- [ ] **Step 3: Implement in `mobile/lib/main.dart`**

Add top-level `registerTokenForTest` and `Future<void> registerToken(String token)` which calls `registerTokenForTest ?? (t) => BackendClient.registerDeviceToken(t)`. In `_initFCM`, after the existing `getToken()` call, add `FirebaseMessaging.instance.onTokenRefresh.listen(registerToken);` and `if (_fcmToken != null) registerToken(_fcmToken!);` so a rotated token is re-registered without a cold start.

- [ ] **Step 4: Run tests and analyze**

Run: `flutter test` then `flutter analyze lib/ test/` — Expected: PASS, no new lints.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/main.dart mobile/test/fcm_token_refresh_test.dart
git commit -m "fix: re-register the FCM token on refresh instead of cold start only"
```

---

### Task 8: Mobile — refresh state on FCM receipt

**Files:**
- Modify: `mobile/lib/services/alarm_service.dart` (`handleAlarmPayload` at 137)
- Test: `mobile/test/payload_refresh_test.dart` (create)

**Interfaces:**
- Produces: `static Future<void> Function()? onPayloadHandledForTest;` in `AlarmService`, invoked at the end of every `handleAlarmPayload` branch.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test**

```dart
// mobile/test/payload_refresh_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_alarm/services/alarm_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a payload triggers the post-handle hook even for an unknown action', () async {
    var fired = 0;
    AlarmService.onPayloadHandledForTest = () async { fired++; };
    await AlarmService.handleAlarmPayload({'action': 'UNKNOWN'});
    expect(fired, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/payload_refresh_test.dart`
Expected: FAIL — `onPayloadHandledForTest` undefined.

- [ ] **Step 3: Implement**

Declare the static hook and call it once at the end of `handleAlarmPayload`. In `mobile/lib/main.dart`, set `AlarmService.onPayloadHandledForTest = null` by default and instead pass the real refresher where the handlers live: after each `handleAlarmPayload(message.data)` call in `_initFCM` (2165, 2171, 2180) and in `_firebaseMessagingBackgroundHandler` (43-52), the foreground handlers also call `unawaited(_syncWithBackend(silent: true))`. The background isolate keeps applying the payload directly and does **not** fetch (Review Focus 3).

- [ ] **Step 4: Run tests and analyze**

Run: `flutter test` then `flutter analyze lib/ test/` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/services/alarm_service.dart mobile/lib/main.dart mobile/test/payload_refresh_test.dart
git commit -m "feat: pull authoritative state after an FCM receipt"
```

---

### Task 9: Dashboard delivery-health banner

**Files:**
- Modify: `backend/public/index.html`

**Interfaces:**
- Consumes: `GET /api/health` → `{ ..., delivery_health: { ok: boolean; reasons: string[] } }` (Task 4).
- Produces: no API change.

The dashboard has **no test harness** (a known gap), so this task is verified manually.

- [ ] **Step 1: Add the health fetch and banner**

On the dashboard's existing refresh cycle, add a `fetch('/api/health')` and render a prominent banner when `delivery_health.ok === false`, listing `reasons`. Keep ASD-STE100 wording: the banner says delivery is unverified — it must not claim the phone received or missed anything.

- [ ] **Step 2: Verify manually**

Run the backend locally with no registered device. Open `/`, confirm the banner appears and lists `no_registered_devices`. Register a device, confirm the banner clears.

- [ ] **Step 3: Commit**

```bash
git add backend/public/index.html
git commit -m "feat: show delivery health on the dashboard"
```

---

### Task 10: Best-effort phone push alert

**Files:**
- Modify: `backend/src/fcm.ts` (add a notification sender), `backend/src/server.ts` (call it in the alert branch from Task 6)
- Test: `backend/test/alerts_webhook.test.ts`

**Interfaces:**
- Produces:
  - `export function buildFcmNotification(title: string, body: string, token: string): Record<string, unknown>`
  - `export async function sendFcmNotification(title: string, body: string): Promise<{ sent: number; failed: number }>`
- Consumes: `DeviceRepo.getAllTokens()`, the throttled alert branch from Task 6.

- [ ] **Step 1: Write the failing test**

```ts
// alerts_webhook.test.ts
import { buildFcmNotification } from '../src/fcm.js';
it('builds a user-visible notification with high priority', () => {
  const m: any = buildFcmNotification('Delivery unhealthy', 'no_registered_devices', 'tok');
  assert.equal(m.android.priority, 'high');
  assert.deepEqual(m.notification, { title: 'Delivery unhealthy', body: 'no_registered_devices' });
  assert.equal(m.data, undefined);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:one test/alerts_webhook.test.ts`
Expected: FAIL — `buildFcmNotification` not exported.

- [ ] **Step 3: Implement**

`buildFcmNotification` returns `{ token, notification: { title, body }, android: { priority: 'high' } }` — a **notification** message, so Android displays it with no app code and high priority is legitimate. `sendFcmNotification` loops `DeviceRepo.getAllTokens()` like `sendFcmDataMessage`. In the Task 6 alert branch, call `void sendFcmNotification('Remote Alarm delivery unhealthy', health.reasons.join(', '))` alongside the webhook. This is best-effort: it cannot reach a phone that is force-stopped or offline, and that limitation is exactly why the dashboard and webhook exist too.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/src/fcm.ts backend/src/server.ts backend/test/alerts_webhook.test.ts
git commit -m "feat: send a best-effort phone notification when delivery health is bad"
```

---

### Task 11: Docs and decision record

**Files:**
- Modify: `README.md` (add a delivery-health note and the `ALERT_WEBHOOK_URL` setting; ASD-STE100)
- Modify: `docs/superpowers/specs/2026-10-16-alarm-delivery-reliability-design.md` (§11 open items → resolved)

**Interfaces:** none.

- [ ] **Step 1: Update `README.md`**

Add a short subsection: delivery health is monitored and surfaced on `/api/health` and the dashboard; an optional `ALERT_WEBHOOK_URL` (with `ALERT_WEBHOOK_KIND` = `generic|discord|slack|healthchecks`) forwards alerts; a dead-man's switch is recommended. Keep ASD-STE100 style.

- [ ] **Step 2: Record the resolved open items in the spec**

Update the spec's §11: the `alarm` package uses `setExactAndAllowWhileIdle` (no `setAlarmClock`; boot re-arm is native via `BootReceiver`), so §5.1 needs no code; note the schedule-version item is deferred (the pull runs on every receipt; a version guard is YAGNI until proven needed).

- [ ] **Step 3: Commit**

```bash
git add README.md docs/superpowers/specs/2026-10-16-alarm-delivery-reliability-design.md
git commit -m "docs: describe delivery health monitoring and alert webhook"
```

---

## Verification (end to end)

- `cd backend && npm test` — all suites pass, including `fcm_hygiene`, `delivery_health`, `alerts_webhook`.
- `cd mobile && flutter test && flutter analyze lib/ test/` — pass, no new lints.
- `./run_tests.sh` — ends "All Automated Test Suites Passed Successfully!".
- **Manual, on device (cannot be automated here):** with Wi-Fi and Tailscale **off**, an already-armed one-time alarm still rings; a token refresh re-registers without a cold start; a push with the app killed still arms the alarm.
- **Manual, live:** create a one-time alarm ~1 minute out with no registered device — the sweep logs `delivery unhealthy: no_registered_devices`, `/api/health` reports it, the dashboard banner shows it, and a phone (if any token is registered) gets the notification.
