# Google Calendar Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror active Remote Alarm alarms into a dedicated "Remote Alarms" Google Calendar, outbound-only from the homelab, without ever letting Google break alarm creation.

**Architecture:** A new `gcal` module set in the backend. A pure, network-free payload mapper (`gcal-events.ts`) converts an alarm row into a Google event object; a client (`gcal.ts`) wraps the Google Calendar REST calls behind an injectable `GcalTransport` seam so tests never touch the network; a reconciler (`gcal-reconcile.ts`) repairs drift on a timer. All of it is opt-in via `GCAL_ENABLED` and degrades to a no-op exactly like `fcm.ts` does.

**Tech Stack:** Node 22, TypeScript (ESM, `NodeNext` — relative imports need `.js` extensions), Fastify 4, better-sqlite3, `node:test` + `node:assert/strict` via `tsx --test`, `googleapis` (server-side only).

**Spec:** `docs/superpowers/specs/2026-09-21-google-calendar-mirror-design.md`

## Global Constraints

- Backend is ESM: every relative import needs a `.js` extension (`import { AlarmRepo } from './db.js'`).
- Test command: `cd backend && npm test` → `NODE_ENV=test DB_PATH=:memory: tsx --test test/**/*.test.ts`.
- Tests use `node:test` (`describe`/`it`/`before`/`after`) and `node:assert/strict`; HTTP tests use Fastify's `app.inject()`.
- **Google must never break alarm creation.** Every `gcal` entry point returns or logs; none may throw into a request handler.
- **No credentials, tokens, or device data may appear in any Google event field** (spec §7.1).
- **`GCAL_TIMEZONE` must never be inferred from the server** (spec §7.3). It is required when enabled; a missing or invalid value disables the subsystem loudly.
- OAuth scope is exactly `https://www.googleapis.com/auth/calendar.app.created` — never broaden it (spec §3.1).
- The reconcile scheduler must not run when `NODE_ENV === 'test'` (spec §9.4).
- `googleapis` is backend-only. Never add it to, or import it from, `clients/`.
- Event duration is 15 minutes; `transparency` is `transparent`; `reminders` is `{ useDefault: false }`; `sendUpdates: "none"`.

## Review Focus

Inputs and failure modes the spec implies but no existing test covers, most likely to bite first:

1. **A DST-zone recurrence.** If `timeZone` is wrong or absent, a weekly alarm silently expands at a different wall-clock time. Expected: `recurrence` is only emitted alongside an explicit `timeZone`, and an instant spanning a DST boundary formats with the *correct* offset for its own date.
2. **A non-UUID / malformed alarm id.** Expected: the push is skipped and logged, not thrown — a bad row must not 500 an alarm mutation.
3. **Google returning `409 duplicate` / `404 notFound`.** Expected: `409` on insert falls back to update; `404` on update falls back to insert; neither propagates.
4. **Google unreachable or the refresh token revoked (`invalid_grant`).** Expected: `POST /api/alarms` still returns `201` with an unchanged `fcm_dispatch`.
5. **`repeat_days` containing junk** (`"0"`, `"9"`, `""`, `null`, `"1,1,2"`). Expected: out-of-range values filtered, duplicates collapsed, and no `recurrence` at all when nothing valid remains.

---

## File Structure

| File | Responsibility |
|---|---|
| `backend/src/db.ts` | *modify* — add generic raw settings accessors |
| `backend/src/gcal-events.ts` | *create* — pure alarm→Google event mapping, id derivation, status→action. No I/O. |
| `backend/src/gcal-config.ts` | *create* — env resolution and validation, incl. fail-loud timezone |
| `backend/src/gcal.ts` | *create* — client, injectable transport, idempotent upsert/remove, status bookkeeping. Imports no Google SDK. |
| `backend/src/gcal-google.ts` | *create* — the **only** file that imports `googleapis`; the real transport |
| `backend/src/gcal-reconcile.ts` | *create* — compare active alarms to the calendar and repair |
| `backend/scripts/gcal-auth.ts` | *create* — one-off interactive loopback + PKCE helper |
| `backend/test/gcal-events.test.ts` | *create* — pure mapping tests |
| `backend/test/gcal-config.test.ts` | *create* — config validation tests |
| `backend/test/gcal.test.ts` | *create* — client behaviour with a fake transport |
| `backend/test/gcal-isolation.test.ts` | *create* — proves a hostile Google cannot break alarm creation |
| `backend/src/server.ts` | *modify* — mutation hooks, status endpoint, scheduler |

---

### Task 1: Generic raw settings accessors

The `settings` table already exists, so **no migration** — but `SettingsRepo` only reads/writes the four known `AppSettings` keys (`backend/src/db.ts:228-278`), so it cannot store `gcal_calendar_id`. Add raw accessors.

**Files:**
- Modify: `backend/src/db.ts` (inside the `SettingsRepo` object, after `update`)
- Test: `backend/test/settings-raw.test.ts` (create)

**Interfaces:**
- Consumes: the existing `db` handle from `./db.js`
- Produces: `SettingsRepo.getRaw(key: string): string | null`, `SettingsRepo.setRaw(key: string, value: string): void`, `SettingsRepo.deleteRaw(key: string): void`

- [ ] **Step 1: Write the failing test**

Create `backend/test/settings-raw.test.ts`:

```ts
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { app } from '../src/server.js';
import { db, SettingsRepo } from '../src/db.js';

describe('SettingsRepo raw accessors', () => {
  before(async () => {
    await app.ready();
  });

  after(async () => {
    db.prepare("DELETE FROM settings WHERE key LIKE 'gcal_%'").run();
    await app.close();
  });

  it('returns null for a key that has never been set', () => {
    assert.strictEqual(SettingsRepo.getRaw('gcal_calendar_id'), null);
  });

  it('round-trips a raw value', () => {
    SettingsRepo.setRaw('gcal_calendar_id', 'abc123@group.calendar.google.com');
    assert.strictEqual(
      SettingsRepo.getRaw('gcal_calendar_id'),
      'abc123@group.calendar.google.com'
    );
  });

  it('overwrites an existing key rather than duplicating it', () => {
    SettingsRepo.setRaw('gcal_calendar_id', 'first');
    SettingsRepo.setRaw('gcal_calendar_id', 'second');
    assert.strictEqual(SettingsRepo.getRaw('gcal_calendar_id'), 'second');
    const rows = db.prepare("SELECT COUNT(*) AS n FROM settings WHERE key = 'gcal_calendar_id'").get() as { n: number };
    assert.strictEqual(rows.n, 1);
  });

  it('deletes a key', () => {
    SettingsRepo.setRaw('gcal_calendar_id', 'x');
    SettingsRepo.deleteRaw('gcal_calendar_id');
    assert.strictEqual(SettingsRepo.getRaw('gcal_calendar_id'), null);
  });

  it('does not disturb the typed AppSettings read path', () => {
    SettingsRepo.setRaw('gcal_calendar_id', 'noise');
    const settings = SettingsRepo.getAll();
    assert.deepStrictEqual(Object.keys(settings).sort(), [
      'date_format',
      'ramp_seconds',
      'sound_tone',
      'time_format',
    ]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && npm test 2>&1 | grep -A5 "raw accessors"`
Expected: FAIL — `SettingsRepo.getRaw is not a function`

- [ ] **Step 3: Write minimal implementation**

In `backend/src/db.ts`, add to the `SettingsRepo` object literal, immediately after the `update` method's closing brace and before the object's closing `};`:

```ts
  /**
   * Generic accessor for settings that are not part of AppSettings
   * (e.g. gcal_calendar_id). Kept separate from getAll/update so the typed
   * preferences path is unaffected.
   */
  getRaw(key: string): string | null {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key) as
      | { value: string }
      | undefined;
    return row ? row.value : null;
  },

  setRaw(key: string, value: string): void {
    db.prepare(`
      INSERT INTO settings (key, value, updated_at)
      VALUES (?, ?, datetime('now'))
      ON CONFLICT(key) DO UPDATE SET
        value = excluded.value,
        updated_at = datetime('now')
    `).run(key, value);
  },

  deleteRaw(key: string): void {
    db.prepare('DELETE FROM settings WHERE key = ?').run(key);
  },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && npm test`
Expected: PASS, all suites green (37 pre-existing tests + 5 new).

- [ ] **Step 5: Commit**

```bash
git add backend/src/db.ts backend/test/settings-raw.test.ts
git commit -m "feat(backend): add generic raw settings accessors for non-preference keys"
```

---

### Task 2: Pure event mapping

The highest-risk logic, deliberately isolated so it needs no network and no token.

**Files:**
- Create: `backend/src/gcal-events.ts`
- Test: `backend/test/gcal-events.test.ts`

**Interfaces:**
- Consumes: `AlarmRecord` from `./db.js`
- Produces:
  - `GCAL_EVENT_DURATION_MINUTES = 15`
  - `deriveEventId(alarmId: string): string`
  - `recurrenceRule(repeatDays?: string | null): string[] | undefined`
  - `zonedDateTime(instantIso: string, timeZone: string, addMinutes?: number): { dateTime: string; timeZone: string }`
  - `toGoogleEvent(alarm: AlarmRecord, timeZone: string): GoogleEvent`
  - `actionForStatus(status: AlarmRecord['status']): 'upsert' | 'delete' | 'leave'`
  - types `GoogleEvent`, `GoogleEventDateTime`, `GcalAction`

- [ ] **Step 1: Write the failing test**

Create `backend/test/gcal-events.test.ts`:

```ts
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  actionForStatus,
  deriveEventId,
  recurrenceRule,
  toGoogleEvent,
  zonedDateTime,
} from '../src/gcal-events.js';
import type { AlarmRecord } from '../src/db.js';

const TZ = 'Australia/Brisbane';

function alarm(overrides: Partial<AlarmRecord> = {}): AlarmRecord {
  return {
    id: '550e8400-e29b-41d4-a716-446655440000',
    target_time: '2026-09-21T21:00:00.000Z', // 07:00 Brisbane
    label: 'Standup',
    status: 'pending',
    sound_tone: 'alarm',
    ramp_seconds: 30,
    ...overrides,
  };
}

describe('deriveEventId', () => {
  it('strips hyphens and lowercases', () => {
    assert.strictEqual(
      deriveEventId('550E8400-E29B-41D4-A716-446655440000'),
      '550e8400e29b41d4a716446655440000'
    );
  });

  it('produces a value inside the base32hex alphabet Google accepts', () => {
    const id = deriveEventId('550e8400-e29b-41d4-a716-446655440000');
    assert.match(id, /^[0-9a-v]{5,1024}$/);
    assert.strictEqual(id.length, 32);
  });

  it('is deterministic', () => {
    assert.strictEqual(deriveEventId(alarm().id), deriveEventId(alarm().id));
  });

  it('rejects a malformed id instead of emitting something invalid', () => {
    assert.throws(() => deriveEventId('not a uuid!'), /cannot derive/i);
    assert.throws(() => deriveEventId(''), /cannot derive/i);
    assert.throws(() => deriveEventId('zzz'), /cannot derive/i); // 'z' is outside base32hex
  });
});

describe('recurrenceRule', () => {
  it('maps ISO weekdays to Google day codes', () => {
    assert.deepStrictEqual(recurrenceRule('1,2,3,4,5'), [
      'RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
    ]);
    assert.deepStrictEqual(recurrenceRule('6,7'), ['RRULE:FREQ=WEEKLY;BYDAY=SA,SU']);
  });

  it('sorts and de-duplicates', () => {
    assert.deepStrictEqual(recurrenceRule('5,1,1,3'), [
      'RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR',
    ]);
  });

  it('returns undefined when there is nothing valid', () => {
    assert.strictEqual(recurrenceRule(undefined), undefined);
    assert.strictEqual(recurrenceRule(null), undefined);
    assert.strictEqual(recurrenceRule(''), undefined);
    assert.strictEqual(recurrenceRule('0,9,-1,junk'), undefined);
  });

  it('filters junk but keeps the valid days', () => {
    assert.deepStrictEqual(recurrenceRule('0,2,9'), ['RRULE:FREQ=WEEKLY;BYDAY=TU']);
  });

  it('never emits DTSTART (Google forbids it in recurrence)', () => {
    const rule = recurrenceRule('1')![0];
    assert.ok(!rule.includes('DTSTART'));
  });
});

describe('zonedDateTime', () => {
  it('renders a UTC instant as local wall clock with the right offset', () => {
    assert.deepStrictEqual(zonedDateTime('2026-09-21T21:00:00.000Z', TZ), {
      dateTime: '2026-09-22T07:00:00+10:00',
      timeZone: TZ,
    });
  });

  it('handles an offset that changes across a DST boundary', () => {
    // Europe/London is +01:00 in July and +00:00 in January.
    const summer = zonedDateTime('2026-07-01T12:00:00.000Z', 'Europe/London');
    const winter = zonedDateTime('2026-01-01T12:00:00.000Z', 'Europe/London');
    assert.strictEqual(summer.dateTime, '2026-07-01T13:00:00+01:00');
    assert.strictEqual(winter.dateTime, '2026-01-01T12:00:00+00:00');
  });

  it('uses h23 so midnight is 00, never 24', () => {
    const midnight = zonedDateTime('2026-09-21T14:00:00.000Z', TZ); // 00:00 Brisbane
    assert.strictEqual(midnight.dateTime, '2026-09-22T00:00:00+10:00');
  });

  it('adds minutes for the end time', () => {
    const end = zonedDateTime('2026-09-21T21:00:00.000Z', TZ, 15);
    assert.strictEqual(end.dateTime, '2026-09-22T07:15:00+10:00');
  });
});

describe('actionForStatus', () => {
  it('maps every alarm status exactly as the spec requires', () => {
    assert.strictEqual(actionForStatus('pending'), 'upsert');
    assert.strictEqual(actionForStatus('ringing'), 'upsert');
    assert.strictEqual(actionForStatus('snoozed'), 'upsert');
    assert.strictEqual(actionForStatus('canceled'), 'delete');
    assert.strictEqual(actionForStatus('disabled'), 'delete');
    assert.strictEqual(actionForStatus('dismissed'), 'leave');
  });
});

describe('toGoogleEvent', () => {
  it('builds the documented payload for a one-time alarm', () => {
    const event = toGoogleEvent(alarm(), TZ);
    assert.strictEqual(event.id, '550e8400e29b41d4a716446655440000');
    assert.strictEqual(event.summary, 'Standup');
    assert.deepStrictEqual(event.start, {
      dateTime: '2026-09-22T07:00:00+10:00',
      timeZone: TZ,
    });
    assert.deepStrictEqual(event.end, {
      dateTime: '2026-09-22T07:15:00+10:00',
      timeZone: TZ,
    });
    assert.strictEqual(event.recurrence, undefined);
  });

  it('suppresses reminders so the hardware alarm is not duplicated', () => {
    assert.deepStrictEqual(toGoogleEvent(alarm(), TZ).reminders, { useDefault: false });
  });

  it('is transparent so mirrored alarms never mark you busy', () => {
    assert.strictEqual(toGoogleEvent(alarm(), TZ).transparency, 'transparent');
  });

  it('attaches recurrence and a zone for a recurring alarm', () => {
    const event = toGoogleEvent(alarm({ repeat_days: '1,2,3,4,5' }), TZ);
    assert.deepStrictEqual(event.recurrence, ['RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR']);
    assert.strictEqual(event.start.timeZone, TZ);
  });

  it('never leaks credentials into any field', () => {
    const serialized = JSON.stringify(
      toGoogleEvent(alarm({ description: 'Take minutes' }), TZ)
    ).toLowerCase();
    for (const forbidden of ['token', 'secret', 'refresh', 'client_id', 'password', 'fcm']) {
      assert.ok(!serialized.includes(forbidden), `payload leaked "${forbidden}"`);
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && npx tsx --test test/gcal-events.test.ts`
Expected: FAIL — `Cannot find module '../src/gcal-events.js'`

- [ ] **Step 3: Write minimal implementation**

Create `backend/src/gcal-events.ts`:

```ts
import type { AlarmRecord } from './db.js';

/** Alarms are shown in the calendar as a 15-minute block, matching the ICS feed. */
export const GCAL_EVENT_DURATION_MINUTES = 15;

/** 1=Mon .. 7=Sun, matching the backend's repeat_days encoding. */
const WEEKDAY_CODES = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'] as const;

const EVENT_ID_PATTERN = /^[0-9a-v]{5,1024}$/;

export interface GoogleEventDateTime {
  dateTime: string;
  timeZone: string;
}

export interface GoogleEvent {
  id: string;
  summary: string;
  description?: string;
  start: GoogleEventDateTime;
  end: GoogleEventDateTime;
  recurrence?: string[];
  reminders: { useDefault: boolean };
  transparency: 'transparent' | 'opaque';
  status: 'confirmed';
}

export type GcalAction = 'upsert' | 'delete' | 'leave';

/**
 * Google accepts a client-supplied event id drawn from base32hex ([0-9a-v]).
 * A hyphen-stripped UUID is 32 chars of [0-9a-f], a strict subset, so it is
 * valid without re-encoding. This is what removes the need for a mapping
 * column (spec §3.3).
 */
export function deriveEventId(alarmId: string): string {
  const id = alarmId.toLowerCase().replace(/-/g, '');
  if (!EVENT_ID_PATTERN.test(id)) {
    throw new Error(`cannot derive a Google event id from "${alarmId}"`);
  }
  return id;
}

export function recurrenceRule(repeatDays?: string | null): string[] | undefined {
  if (!repeatDays) return undefined;
  const days = repeatDays
    .split(',')
    .map((part) => parseInt(part.trim(), 10))
    .filter((day) => Number.isInteger(day) && day >= 1 && day <= 7);
  if (days.length === 0) return undefined;
  const unique = [...new Set(days)].sort((a, b) => a - b);
  // DTSTART must not appear here; Google infers it from `start`.
  return [`RRULE:FREQ=WEEKLY;BYDAY=${unique.map((day) => WEEKDAY_CODES[day - 1]).join(',')}`];
}

/**
 * Render a UTC instant as wall-clock time in `timeZone`, with that zone's
 * offset for that specific instant (so DST is handled per-date).
 */
export function zonedDateTime(
  instantIso: string,
  timeZone: string,
  addMinutes = 0
): GoogleEventDateTime {
  const instant = new Date(new Date(instantIso).getTime() + addMinutes * 60_000);
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    timeZoneName: 'longOffset',
  }).formatToParts(instant);
  const value = (type: string) => parts.find((part) => part.type === type)?.value ?? '';
  const rawOffset = parts.find((part) => part.type === 'timeZoneName')?.value ?? 'GMT+00:00';
  const offset = rawOffset === 'GMT' ? '+00:00' : rawOffset.replace('GMT', '');
  return {
    dateTime: `${value('year')}-${value('month')}-${value('day')}T${value('hour')}:${value('minute')}:${value('second')}${offset}`,
    timeZone,
  };
}

function describe(alarm: AlarmRecord): string {
  const lines = [`Alarm ID: ${alarm.id}`];
  if (alarm.sound_tone) lines.push(`Tone: ${alarm.sound_tone}`);
  if (alarm.ramp_seconds !== undefined) lines.push(`Ramp: ${alarm.ramp_seconds}s`);
  if (alarm.repeat_days) lines.push(`Repeat: ${alarm.repeat_days}`);
  return `Managed by Remote Alarm\n${lines.join('\n')}`;
}

export function toGoogleEvent(alarm: AlarmRecord, timeZone: string): GoogleEvent {
  const event: GoogleEvent = {
    id: deriveEventId(alarm.id),
    summary: alarm.label,
    description: describe(alarm),
    start: zonedDateTime(alarm.target_time, timeZone),
    end: zonedDateTime(alarm.target_time, timeZone, GCAL_EVENT_DURATION_MINUTES),
    reminders: { useDefault: false },
    transparency: 'transparent',
    status: 'confirmed',
  };
  const recurrence = recurrenceRule(alarm.repeat_days);
  if (recurrence) event.recurrence = recurrence;
  return event;
}

export function actionForStatus(status: AlarmRecord['status']): GcalAction {
  switch (status) {
    case 'pending':
    case 'ringing':
    case 'snoozed':
      return 'upsert';
    case 'canceled':
    case 'disabled':
      return 'delete';
    case 'dismissed':
      // It already rang. A past calendar entry is history, not an error.
      return 'leave';
    default:
      return 'leave';
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && npx tsx --test test/gcal-events.test.ts`
Expected: PASS — all cases green.

- [ ] **Step 5: Commit**

```bash
git add backend/src/gcal-events.ts backend/test/gcal-events.test.ts
git commit -m "feat(backend): add pure Google Calendar event mapping"
```

---

### Task 3: Config resolution with fail-loud timezone

**Files:**
- Create: `backend/src/gcal-config.ts`
- Test: `backend/test/gcal-config.test.ts`

**Interfaces:**
- Produces: `GCAL_SCOPE: string`, `GcalConfig` interface, `isValidTimeZone(tz: string): boolean`, `resolveGcalConfig(env?: NodeJS.ProcessEnv): { config: GcalConfig | null; reason: string | null }`

- [ ] **Step 1: Write the failing test**

Create `backend/test/gcal-config.test.ts`:

```ts
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { isValidTimeZone, resolveGcalConfig } from '../src/gcal-config.js';

const base = {
  GCAL_ENABLED: 'true',
  GOOGLE_OAUTH_CLIENT_ID: 'client-id',
  GOOGLE_OAUTH_CLIENT_SECRET: 'client-secret',
  GCAL_TIMEZONE: 'Australia/Brisbane',
};

describe('isValidTimeZone', () => {
  it('accepts real IANA zones', () => {
    assert.ok(isValidTimeZone('Australia/Brisbane'));
    assert.ok(isValidTimeZone('UTC'));
  });

  it('rejects nonsense', () => {
    assert.ok(!isValidTimeZone('Mars/Olympus'));
    assert.ok(!isValidTimeZone(''));
  });
});

describe('resolveGcalConfig', () => {
  it('returns a config when everything is present', () => {
    const { config, reason } = resolveGcalConfig({ ...base });
    assert.strictEqual(reason, null);
    assert.strictEqual(config?.timeZone, 'Australia/Brisbane');
    assert.strictEqual(config?.clientId, 'client-id');
  });

  it('is a silent no-op when not enabled', () => {
    const { config, reason } = resolveGcalConfig({});
    assert.strictEqual(config, null);
    assert.strictEqual(reason, null);
  });

  it('refuses to guess the timezone', () => {
    const env = { ...base, GCAL_TIMEZONE: undefined } as NodeJS.ProcessEnv;
    const { config, reason } = resolveGcalConfig(env);
    assert.strictEqual(config, null);
    assert.match(reason ?? '', /GCAL_TIMEZONE is required/i);
  });

  it('rejects an invalid timezone rather than falling back', () => {
    const { config, reason } = resolveGcalConfig({ ...base, GCAL_TIMEZONE: 'Mars/Olympus' });
    assert.strictEqual(config, null);
    assert.match(reason ?? '', /not a valid IANA zone/i);
  });

  it('reports missing credentials', () => {
    const env = { ...base, GOOGLE_OAUTH_CLIENT_ID: undefined } as NodeJS.ProcessEnv;
    const { config, reason } = resolveGcalConfig(env);
    assert.strictEqual(config, null);
    assert.match(reason ?? '', /GOOGLE_OAUTH_CLIENT_ID/);
  });

  it('defaults the token path', () => {
    const { config } = resolveGcalConfig({ ...base });
    assert.strictEqual(config?.tokenPath, './google-oauth-token.json');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && npx tsx --test test/gcal-config.test.ts`
Expected: FAIL — `Cannot find module '../src/gcal-config.js'`

- [ ] **Step 3: Write minimal implementation**

Create `backend/src/gcal-config.ts`:

```ts
/**
 * Config resolution for the Google Calendar mirror.
 *
 * GCAL_TIMEZONE is the PHONE's IANA zone, not the server's. docker-compose
 * sets no TZ, so the container resolves to UTC; inferring would silently pick
 * the wrong recurrence-expansion zone (spec §7.3). We therefore require it
 * and disable the subsystem loudly if it is missing or invalid.
 */

export const GCAL_SCOPE = 'https://www.googleapis.com/auth/calendar.app.created';

export const DEFAULT_TOKEN_PATH = './google-oauth-token.json';
export const DEFAULT_CALENDAR_SUMMARY = 'Remote Alarms';

export interface GcalConfig {
  clientId: string;
  clientSecret: string;
  tokenPath: string;
  timeZone: string;
}

export function isValidTimeZone(timeZone: string): boolean {
  if (!timeZone) return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone });
    return true;
  } catch {
    return false;
  }
}

export function resolveGcalConfig(env: NodeJS.ProcessEnv = process.env): {
  config: GcalConfig | null;
  reason: string | null;
} {
  // Absent/false means "deliberately off" — not an error, and no warning.
  if (env.GCAL_ENABLED !== 'true') {
    return { config: null, reason: null };
  }

  const missing = ['GOOGLE_OAUTH_CLIENT_ID', 'GOOGLE_OAUTH_CLIENT_SECRET'].filter(
    (key) => !env[key]
  );
  if (missing.length > 0) {
    return { config: null, reason: `missing required env: ${missing.join(', ')}` };
  }

  const timeZone = env.GCAL_TIMEZONE ?? '';
  if (!timeZone) {
    return {
      config: null,
      reason: "GCAL_TIMEZONE is required (the phone's IANA zone); refusing to guess",
    };
  }
  if (!isValidTimeZone(timeZone)) {
    return { config: null, reason: `GCAL_TIMEZONE "${timeZone}" is not a valid IANA zone` };
  }

  return {
    config: {
      clientId: env.GOOGLE_OAUTH_CLIENT_ID as string,
      clientSecret: env.GOOGLE_OAUTH_CLIENT_SECRET as string,
      tokenPath: env.GOOGLE_OAUTH_TOKEN_PATH || DEFAULT_TOKEN_PATH,
      timeZone,
    },
    reason: null,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && npx tsx --test test/gcal-config.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/src/gcal-config.ts backend/test/gcal-config.test.ts
git commit -m "feat(backend): add gcal config resolution with required timezone"
```

---

### Task 4: Client with idempotent upsert and error classification

A fake `GcalTransport` is injected in tests, so no network and no token are needed. This task also fixes the error taxonomy that Task 6's isolation test depends on.

**Files:**
- Create: `backend/src/gcal.ts`
- Test: `backend/test/gcal.test.ts`

**Interfaces:**
- Consumes: `toGoogleEvent`, `deriveEventId`, `actionForStatus`, `GoogleEvent` (Task 2); `GcalConfig`, `resolveGcalConfig`, `DEFAULT_CALENDAR_SUMMARY`, `GCAL_SCOPE` (Task 3); `SettingsRepo.getRaw/setRaw` (Task 1)
- Produces:
  - `class GcalApiError extends Error { readonly status: number }`
  - `isStatus(err: unknown, status: number): boolean`
  - `type GcalErrorKind = 'auth' | 'rate_limit' | 'permanent' | 'transient' | 'unknown'`
  - `classifyGcalError(err: unknown): GcalErrorKind`
  - `unconfiguredTransport(): GcalTransport`
  - `interface GcalTransport` (5 methods: `ensureSecondaryCalendar`, `insertEvent`, `updateEvent`, `deleteEvent`, `listEventIds`)
  - `class GcalMirror` with `isConfigured()`, `configReason()`, `timeZone()`, `syncAlarm(alarm)`, `ensureCalendar()`, `listEventIds()`, `deleteEventById(id)`, `status()`

- [ ] **Step 1: Write the failing test**

Create `backend/test/gcal.test.ts`:

```ts
import { describe, it, before, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import { app } from '../src/server.js';
import { db } from '../src/db.js';
import {
  GcalApiError,
  GcalMirror,
  classifyGcalError,
  isStatus,
  type GcalTransport,
} from '../src/gcal.js';
import type { AlarmRecord } from '../src/db.js';

function alarm(overrides: Partial<AlarmRecord> = {}): AlarmRecord {
  return {
    id: '550e8400-e29b-41d4-a716-446655440000',
    target_time: '2026-09-21T21:00:00.000Z',
    label: 'Standup',
    status: 'pending',
    ...overrides,
  };
}

/** Records every call so tests can assert on the sequence. */
class FakeTransport implements GcalTransport {
  calls: string[] = [];
  constructor(private readonly failures: Record<string, Error> = {}) {}

  async ensureSecondaryCalendar(): Promise<string> {
    this.calls.push('ensureCalendar');
    return 'cal-1';
  }
  async insertEvent(_c: string, event: { id: string }): Promise<void> {
    this.calls.push(`insert:${event.id}`);
    if (this.failures.insert) throw this.failures.insert;
  }
  async updateEvent(_c: string, event: { id: string }): Promise<void> {
    this.calls.push(`update:${event.id}`);
    if (this.failures.update) throw this.failures.update;
  }
  async deleteEvent(_c: string, id: string): Promise<void> {
    this.calls.push(`delete:${id}`);
    if (this.failures.delete) throw this.failures.delete;
  }
  async listEventIds(): Promise<string[]> {
    this.calls.push('list');
    return [];
  }
}

const CONFIG = {
  clientId: 'id',
  clientSecret: 'secret',
  tokenPath: '/tmp/nonexistent-token.json',
  timeZone: 'Australia/Brisbane',
};

describe('gcal error classification', () => {
  it('classifies 401/403 invalid_grant as auth', () => {
    assert.strictEqual(classifyGcalError(new GcalApiError('nope', 401)), 'auth');
    assert.strictEqual(classifyGcalError(new Error('invalid_grant')), 'auth');
  });
  it('classifies 429 and 403 rate-limit text as rate_limit', () => {
    assert.strictEqual(classifyGcalError(new GcalApiError('slow down', 429)), 'rate_limit');
    assert.strictEqual(
      classifyGcalError(new GcalApiError('userRateLimitExceeded', 403)),
      'rate_limit'
    );
  });
  it('classifies 400 as permanent, not retryable', () => {
    assert.strictEqual(classifyGcalError(new GcalApiError('bad request', 400)), 'permanent');
  });
  it('classifies 5xx and network failures as transient', () => {
    assert.strictEqual(classifyGcalError(new GcalApiError('boom', 503)), 'transient');
    assert.strictEqual(classifyGcalError(new Error('fetch failed')), 'transient');
  });
});

describe('GcalMirror', () => {
  before(async () => {
    await app.ready();
  });
  beforeEach(() => {
    db.prepare("DELETE FROM settings WHERE key LIKE 'gcal_%'").run();
  });
  after(async () => {
    db.prepare("DELETE FROM settings WHERE key LIKE 'gcal_%'").run();
    await app.close();
  });

  it('is a no-op when not configured', async () => {
    const mirror = new GcalMirror({ config: null, transport: new FakeTransport() });
    assert.strictEqual(mirror.isConfigured(), false);
    await mirror.syncAlarm(alarm()); // must resolve, not throw
    assert.deepStrictEqual(mirror.status().configured, false);
  });

  it('upserts an active alarm via insert', async () => {
    const transport = new FakeTransport();
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm());
    assert.deepStrictEqual(transport.calls, [
      'ensureCalendar',
      'insert:550e8400e29b41d4a716446655440000',
    ]);
  });

  it('falls back to update when insert reports a duplicate', async () => {
    const transport = new FakeTransport({ insert: new GcalApiError('duplicate', 409) });
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm());
    assert.deepStrictEqual(transport.calls, [
      'ensureCalendar',
      'insert:550e8400e29b41d4a716446655440000',
      'update:550e8400e29b41d4a716446655440000',
    ]);
  });

  it('re-inserts when update finds the event was deleted by the user', async () => {
    const transport = new FakeTransport({
      insert: new GcalApiError('duplicate', 409),
      update: new GcalApiError('notFound', 404),
    });
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm());
    assert.deepStrictEqual(transport.calls, [
      'ensureCalendar',
      'insert:550e8400e29b41d4a716446655440000',
      'update:550e8400e29b41d4a716446655440000',
      'insert:550e8400e29b41d4a716446655440000',
    ]);
  });

  it('deletes the event for a cancelled or disabled alarm', async () => {
    const transport = new FakeTransport();
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm({ status: 'canceled' }));
    assert.deepStrictEqual(transport.calls, [
      'ensureCalendar',
      'delete:550e8400e29b41d4a716446655440000',
    ]);
  });

  it('does nothing for a dismissed alarm', async () => {
    const transport = new FakeTransport();
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm({ status: 'dismissed' }));
    assert.deepStrictEqual(transport.calls, []);
  });

  it('treats a 404 on delete as already-gone success', async () => {
    const transport = new FakeTransport({ delete: new GcalApiError('notFound', 404) });
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await mirror.syncAlarm(alarm({ status: 'canceled' })); // must not throw
    assert.deepStrictEqual(transport.calls, [
      'ensureCalendar',
      'delete:550e8400e29b41d4a716446655440000',
    ]);
  });

  it('skips a malformed alarm id rather than throwing', async () => {
    const transport = new FakeTransport();
    const mirror = new GcalMirror({ config: CONFIG, transport });
    // deriveEventId strips hyphens and accepts base32hex, so 'not-a-uuid'
    // would be ACCEPTED (-> 'notauuid'). The input must contain a character
    // outside [0-9a-v]; an underscore qualifies.
    await mirror.syncAlarm(alarm({ id: 'not_a_uuid' }));
    assert.ok(!transport.calls.some((call) => call.startsWith('insert:')));
    assert.match(mirror.status().last_error ?? '', /cannot derive/i);
  });

  it('persists the calendar id so a later run does not create a second calendar', async () => {
    const transport = new FakeTransport();
    await new GcalMirror({ config: CONFIG, transport }).syncAlarm(alarm());
    // A second, fresh mirror (as after a process restart) must reuse the
    // stored id rather than calling calendars.insert a second time.
    await new GcalMirror({ config: CONFIG, transport }).syncAlarm(alarm());
    const ensureCalls = transport.calls.filter((call) => call === 'ensureCalendar').length;
    assert.strictEqual(ensureCalls, 1);
    const stored = db.prepare("SELECT value FROM settings WHERE key = 'gcal_calendar_id'").get() as
      | { value: string }
      | undefined;
    assert.strictEqual(stored?.value, 'cal-1');
  });

  it('records a failure in status instead of propagating it', async () => {
    const transport = new FakeTransport({ insert: new GcalApiError('boom', 500) });
    const mirror = new GcalMirror({ config: CONFIG, transport });
    await assert.rejects(() => mirror.syncAlarm(alarm()));
    assert.strictEqual(mirror.status().ok, false);
    assert.match(mirror.status().last_error ?? '', /boom/);
  });

  it('isStatus only matches GcalApiError', () => {
    assert.ok(isStatus(new GcalApiError('x', 409), 409));
    assert.ok(!isStatus(new Error('409'), 409));
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && npx tsx --test test/gcal.test.ts`
Expected: FAIL — `Cannot find module '../src/gcal.js'`

- [ ] **Step 3: Write minimal implementation**

Create `backend/src/gcal.ts`:

```ts
import { SettingsRepo, type AlarmRecord } from './db.js';
import { actionForStatus, deriveEventId, toGoogleEvent, type GoogleEvent } from './gcal-events.js';
import { DEFAULT_CALENDAR_SUMMARY, type GcalConfig } from './gcal-config.js';

const CALENDAR_ID_KEY = 'gcal_calendar_id';

/** An error carrying an HTTP status from the Calendar API. */
export class GcalApiError extends Error {
  readonly status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = 'GcalApiError';
    this.status = status;
  }
}

export function isStatus(err: unknown, status: number): boolean {
  return err instanceof GcalApiError && err.status === status;
}

export type GcalErrorKind = 'auth' | 'rate_limit' | 'permanent' | 'transient' | 'unknown';

export function classifyGcalError(err: unknown): GcalErrorKind {
  const message = err instanceof Error ? err.message : String(err);
  if (/invalid_grant/i.test(message)) return 'auth';
  if (err instanceof GcalApiError) {
    if (err.status === 401) return 'auth';
    if (err.status === 429) return 'rate_limit';
    if (err.status === 403) return /rate|quota/i.test(message) ? 'rate_limit' : 'auth';
    if (err.status === 400) return 'permanent'; // documented as not retryable
    if (err.status >= 500) return 'transient';
  }
  if (/fetch failed|ECONNRESET|ETIMEDOUT|ENOTFOUND/i.test(message)) return 'transient';
  return 'unknown';
}

/** Low-level Google calls. Injected so tests never touch the network. */
export interface GcalTransport {
  ensureSecondaryCalendar(summary: string, timeZone: string): Promise<string>;
  insertEvent(calendarId: string, event: GoogleEvent): Promise<void>;
  updateEvent(calendarId: string, event: GoogleEvent): Promise<void>;
  deleteEvent(calendarId: string, eventId: string): Promise<void>;
  listEventIds(calendarId: string): Promise<string[]>;
}

/**
 * Transport used while unconfigured. `GcalMirror` returns early whenever
 * `config` is null, so no method here is ever reached — it exists only so the
 * mirror can be constructed in a supported state without a Google client.
 */
export function unconfiguredTransport(): GcalTransport {
  const fail = (): never => {
    throw new Error('gcal transport used while unconfigured');
  };
  return {
    ensureSecondaryCalendar: async () => fail(),
    insertEvent: async () => fail(),
    updateEvent: async () => fail(),
    deleteEvent: async () => fail(),
    listEventIds: async () => fail(),
  };
}

export interface GcalStatus {
  configured: boolean;
  ok: boolean;
  calendar_id: string | null;
  last_sync_at: string | null;
  last_error: string | null;
  last_error_at: string | null;
  reason: string | null;
}

export class GcalMirror {
  private readonly config: GcalConfig | null;
  private readonly transport: GcalTransport;
  /** Field is `reasonText`, not `configReason` — a field and method of the same
   *  name collide (TS2300). The public accessor keeps the documented name. */
  private readonly reasonText: string | null;
  private calendarIdCache: string | null = null;
  private lastSyncAt: string | null = null;
  private lastError: string | null = null;
  private lastErrorAt: string | null = null;

  constructor(options: {
    config: GcalConfig | null;
    transport: GcalTransport;
    reason?: string | null;
  }) {
    this.config = options.config;
    this.transport = options.transport;
    this.reasonText = options.reason ?? null;
  }

  isConfigured(): boolean {
    return this.config !== null;
  }

  configReason(): string | null {
    return this.reasonText;
  }

  timeZone(): string {
    if (!this.config) throw new Error('gcal is not configured');
    return this.config.timeZone;
  }

  clearCalendarCache(): void {
    this.calendarIdCache = null;
    SettingsRepo.deleteRaw(CALENDAR_ID_KEY);
  }

  async ensureCalendar(): Promise<string> {
    if (this.calendarIdCache) return this.calendarIdCache;
    const stored = SettingsRepo.getRaw(CALENDAR_ID_KEY);
    if (stored) {
      this.calendarIdCache = stored;
      return stored;
    }
    if (!this.config) throw new Error('gcal is not configured');
    const created = await this.transport.ensureSecondaryCalendar(
      DEFAULT_CALENDAR_SUMMARY,
      this.config.timeZone
    );
    SettingsRepo.setRaw(CALENDAR_ID_KEY, created);
    this.calendarIdCache = created;
    return created;
  }

  async listEventIds(): Promise<string[]> {
    const calendarId = await this.ensureCalendar();
    return this.transport.listEventIds(calendarId);
  }

  /**
   * Idempotent upsert: insert, and on 409 fall back to update; on 404 from
   * that update, fall back to insert again (the user deleted it in Google).
   */
  private async upsertEvent(calendarId: string, event: GoogleEvent): Promise<void> {
    try {
      await this.transport.insertEvent(calendarId, event);
      return;
    } catch (err) {
      if (!isStatus(err, 409)) throw err;
    }
    try {
      await this.transport.updateEvent(calendarId, event);
    } catch (err) {
      if (!isStatus(err, 404)) throw err;
      // The user deleted the event in Google, so recreate it. A 409 on the
      // retry means a concurrent writer recreated it first: both reach the
      // desired end state (the event exists), so treat that as success.
      try {
        await this.transport.insertEvent(calendarId, event);
      } catch (retryErr) {
        if (!isStatus(retryErr, 409)) throw retryErr;
      }
    }
  }

  private async removeEvent(calendarId: string, eventId: string): Promise<void> {
    try {
      await this.transport.deleteEvent(calendarId, eventId);
    } catch (err) {
      if (isStatus(err, 404) || isStatus(err, 410)) return; // already gone
      throw err;
    }
  }

  /** Delete an event by id. Used by the reconciler for orphans (Task 5). */
  async deleteEventById(eventId: string): Promise<void> {
    if (!this.config) return;
    const calendarId = await this.ensureCalendar();
    await this.removeEvent(calendarId, eventId);
  }

  /**
   * Mirror one alarm. Throws on failure so the caller can time-box and record
   * it; callers in request paths MUST catch (see mirrorSafely in server.ts).
   */
  async syncAlarm(alarm: AlarmRecord): Promise<void> {
    if (!this.config) return;

    let eventId: string;
    try {
      eventId = deriveEventId(alarm.id);
    } catch (err) {
      // A malformed row must never break the caller.
      this.recordError(err);
      return;
    }

    try {
      const action = actionForStatus(alarm.status);
      if (action === 'leave') return;
      const calendarId = await this.ensureCalendar();
      if (action === 'delete') {
        await this.removeEvent(calendarId, eventId);
      } else {
        await this.upsertEvent(calendarId, toGoogleEvent(alarm, this.config.timeZone));
      }
      this.recordSuccess();
    } catch (err) {
      this.recordError(err);
      throw err;
    }
  }

  private recordSuccess(): void {
    this.lastSyncAt = new Date().toISOString();
    this.lastError = null;
    this.lastErrorAt = null;
  }

  private recordError(err: unknown): void {
    this.lastError = err instanceof Error ? err.message : String(err);
    this.lastErrorAt = new Date().toISOString();
  }

  status(): GcalStatus {
    return {
      configured: this.isConfigured(),
      ok: this.isConfigured() && this.lastError === null,
      calendar_id: this.calendarIdCache ?? SettingsRepo.getRaw(CALENDAR_ID_KEY),
      last_sync_at: this.lastSyncAt,
      last_error: this.lastError,
      last_error_at: this.lastErrorAt,
      reason: this.reasonText,
    };
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && npx tsx --test test/gcal.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/src/gcal.ts backend/test/gcal.test.ts
git commit -m "feat(backend): add gcal client with idempotent upsert and error classification"
```

---

### Task 5: Reconciliation

**Files:**
- Create: `backend/src/gcal-reconcile.ts`
- Test: append to `backend/test/gcal.test.ts` (a new `describe` block) or create `backend/test/gcal-reconcile.test.ts` — **create the separate file** to keep `gcal.test.ts` focused.

**Interfaces:**
- Consumes: `GcalMirror` (Task 4), `toGoogleEvent`/`deriveEventId` (Task 2), `AlarmRepo` (existing)
- Produces: `reconcile(mirror: GcalMirror): Promise<{ created: number; deleted: number; failed: number }>`

- [ ] **Step 1: Write the failing test**

Create `backend/test/gcal-reconcile.test.ts`:

```ts
import { describe, it, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { app } from '../src/server.js';
import { db, AlarmRepo } from '../src/db.js';
import { GcalMirror } from '../src/gcal.js';
import { reconcile } from '../src/gcal-reconcile.js';
import type { GcalTransport } from '../src/gcal.js';
import type { GoogleEvent } from '../src/gcal-events.js';

class RecordingTransport implements GcalTransport {
  inserted: string[] = [];
  deleted: string[] = [];
  constructor(private readonly existing: string[] = []) {}
  async ensureSecondaryCalendar(): Promise<string> {
    return 'cal-1';
  }
  async insertEvent(_c: string, event: GoogleEvent): Promise<void> {
    this.inserted.push(event.id);
  }
  async updateEvent(): Promise<void> {}
  async deleteEvent(_c: string, id: string): Promise<void> {
    this.deleted.push(id);
  }
  async listEventIds(): Promise<string[]> {
    return [...this.existing];
  }
}

const CONFIG = {
  clientId: 'id',
  clientSecret: 's',
  tokenPath: '/tmp/none.json',
  timeZone: 'Australia/Brisbane',
};

describe('reconcile', () => {
  before(async () => {
    await app.ready();
  });
  beforeEach(() => {
    db.prepare('DELETE FROM alarms').run();
    db.prepare("DELETE FROM settings WHERE key LIKE 'gcal_%'").run();
  });
  after(async () => {
    db.prepare('DELETE FROM alarms').run();
    db.prepare("DELETE FROM settings WHERE key LIKE 'gcal_%'").run();
    await app.close();
  });

  it('creates events missing from the calendar', async () => {
    AlarmRepo.create({
      id: '550e8400-e29b-41d4-a716-446655440000',
      target_time: '2030-01-01T21:00:00.000Z',
      label: 'Standup',
      status: 'pending',
    });
    const transport = new RecordingTransport([]);
    const result = await reconcile(new GcalMirror({ config: CONFIG, transport }));
    assert.strictEqual(result.created, 1);
    assert.deepStrictEqual(transport.inserted, ['550e8400e29b41d4a716446655440000']);
  });

  it('deletes orphan events with no matching alarm', async () => {
    const transport = new RecordingTransport(['deadbeefdeadbeefdeadbeefdeadbeef']);
    const result = await reconcile(new GcalMirror({ config: CONFIG, transport }));
    assert.strictEqual(result.deleted, 1);
    assert.deepStrictEqual(transport.deleted, ['deadbeefdeadbeefdeadbeefdeadbeef']);
  });

  it('leaves matching events alone', async () => {
    AlarmRepo.create({
      id: '550e8400-e29b-41d4-a716-446655440000',
      target_time: '2030-01-01T21:00:00.000Z',
      label: 'Standup',
      status: 'pending',
    });
    const transport = new RecordingTransport(['550e8400e29b41d4a716446655440000']);
    const result = await reconcile(new GcalMirror({ config: CONFIG, transport }));
    assert.strictEqual(result.created, 0);
    assert.strictEqual(result.deleted, 0);
  });

  it('is a no-op when the mirror is not configured', async () => {
    const transport = new RecordingTransport([]);
    const result = await reconcile(new GcalMirror({ config: null, transport }));
    assert.deepStrictEqual(result, { created: 0, deleted: 0, failed: 0 });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && npx tsx --test test/gcal-reconcile.test.ts`
Expected: FAIL — `Cannot find module '../src/gcal-reconcile.js'`

- [ ] **Step 3: Write minimal implementation**

Create `backend/src/gcal-reconcile.ts`:

```ts
import { AlarmRepo } from './db.js';
import { deriveEventId, toGoogleEvent } from './gcal-events.js';
import type { GcalMirror } from './gcal.js';

export interface ReconcileResult {
  created: number;
  deleted: number;
  failed: number;
}

/**
 * Repair drift between active alarms and the Remote Alarms calendar.
 *
 * Remote Alarm is the single source of truth: events with no matching active
 * alarm are deleted, and active alarms with no event are created (spec §9.3).
 * A full list is used deliberately rather than syncToken — a personal
 * calendar is a single cheap call (spec §9.4).
 */
export async function reconcile(mirror: GcalMirror): Promise<ReconcileResult> {
  const result: ReconcileResult = { created: 0, deleted: 0, failed: 0 };
  if (!mirror.isConfigured()) return result;

  const active = AlarmRepo.getAll('active');

  // Alarms whose id we cannot map are skipped, not fatal.
  const expected = new Map<string, string>(); // eventId -> alarmId
  for (const alarm of active) {
    try {
      expected.set(deriveEventId(alarm.id), alarm.id);
    } catch {
      // Malformed id: nothing to reconcile it against.
    }
  }

  let existing: string[];
  try {
    existing = await mirror.listEventIds();
  } catch {
    result.failed += 1;
    return result;
  }

  const existingSet = new Set(existing);

  for (const alarm of active) {
    let eventId: string;
    try {
      eventId = deriveEventId(alarm.id);
    } catch {
      continue;
    }
    if (existingSet.has(eventId)) continue;
    try {
      await mirror.syncAlarm(alarm);
      result.created += 1;
    } catch {
      result.failed += 1;
    }
  }

  for (const eventId of existing) {
    if (expected.has(eventId)) continue;
    try {
      await mirror.deleteEventById(eventId);
      result.deleted += 1;
    } catch {
      result.failed += 1;
    }
  }

  return result;
}
```

`GcalMirror.deleteEventById` is already present from Task 4 Step 3 — do not re-add it. If it is
missing, the Task 4 implementation was incomplete; add it there rather than here.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && npx tsx --test test/gcal-reconcile.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/src/gcal-reconcile.ts backend/src/gcal.ts backend/test/gcal-reconcile.test.ts
git commit -m "feat(backend): add Google Calendar reconciliation"
```

---

### Task 6: Server wiring, failure isolation, and the status endpoint

The load-bearing task: proves Google cannot break alarm creation.

**Files:**
- Modify: `backend/src/server.ts`
- Test: `backend/test/gcal-isolation.test.ts` (create)

**Interfaces:**
- Consumes: `GcalMirror`, `GcalTransport` (Task 4); `resolveGcalConfig` (Task 3); `reconcile` (Task 5)
- Produces: `export const gcal: GcalMirror`, `export function mirrorSafely(alarm: AlarmRecord): Promise<void>`, `GET /api/calendar/status`

- [ ] **Step 1: Write the failing test**

Create `backend/test/gcal-isolation.test.ts`:

```ts
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { app } from '../src/server.js';
import { db } from '../src/db.js';

describe('Google Calendar failure isolation', () => {
  before(async () => {
    await app.ready();
  });

  after(async () => {
    db.prepare("DELETE FROM alarms WHERE label LIKE 'Isolation%'").run();
    await app.close();
  });

  it('exposes a status endpoint that reports the unconfigured state', async () => {
    const response = await app.inject({ method: 'GET', url: '/api/calendar/status' });
    assert.strictEqual(response.statusCode, 200);
    const body = JSON.parse(response.body);
    assert.strictEqual(typeof body.configured, 'boolean');
    assert.ok('last_error' in body);
    // Never leak credentials.
    const serialized = response.body.toLowerCase();
    for (const forbidden of ['secret', 'refresh_token', 'access_token', 'client_id']) {
      assert.ok(!serialized.includes(forbidden), `status leaked "${forbidden}"`);
    }
  });

  it('creates alarms successfully even though gcal is unconfigured', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: {
        target_time: '2030-01-01T21:00:00.000Z',
        label: 'Isolation Probe',
      },
    });
    assert.strictEqual(response.statusCode, 201);
    const body = JSON.parse(response.body);
    assert.ok(body.fcm_dispatch, 'fcm_dispatch must still be present and unchanged');
    assert.strictEqual(body.fcm_dispatch.sent, 0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && npx tsx --test test/gcal-isolation.test.ts`
Expected: FAIL — `/api/calendar/status` returns 404.

- [ ] **Step 3: Write minimal implementation**

In `backend/src/server.ts`, add imports near the existing ones:

```ts
import { GcalMirror, unconfiguredTransport } from './gcal.js';
import { createGcalTransport } from './gcal-google.js';
import { resolveGcalConfig } from './gcal-config.js';
import { reconcile } from './gcal-reconcile.js';
```

Add, immediately after `initFirebase();`:

```ts
// Google Calendar mirror. Unconfigured is a supported, silent state: it must
// never prevent an alarm from being created or delivered (spec §10).
const gcalResolution = resolveGcalConfig();
const gcal = new GcalMirror({
  config: gcalResolution.config,
  // Build the Google-backed transport ONLY when configured. Constructing it
  // eagerly would throw on a missing token file, but unconfigured is a normal,
  // supported state — so we must not touch the token here.
  transport: gcalResolution.config
    ? createGcalTransport(gcalResolution.config)
    : unconfiguredTransport(),
  reason: gcalResolution.reason,
});

if (!gcal.isConfigured() && gcalResolution.reason) {
  console.error(`[gcal] disabled: ${gcalResolution.reason}`);
} else if (gcal.isConfigured()) {
  console.log(`[gcal] enabled for timezone ${gcal.timeZone()}`);
}

const GCAL_PUSH_TIMEOUT_MS = 3_000;
const GCAL_RECONCILE_INTERVAL_MS = 15 * 60 * 1_000;

/** Time-boxed mirror. Never throws: a Google failure must not affect the caller. */
export async function mirrorSafely(alarm: AlarmRecord): Promise<void> {
  if (!gcal.isConfigured()) return;
  try {
    await Promise.race([
      gcal.syncAlarm(alarm),
      new Promise((_resolve, reject) =>
        setTimeout(() => reject(new Error('gcal push timed out')), GCAL_PUSH_TIMEOUT_MS)
      ),
    ]);
  } catch (err) {
    console.error('[gcal] mirror failed:', err instanceof Error ? err.message : err);
  }
}
```

Add the status route next to the other `GET` routes:

```ts
// 9. GET /api/calendar/status: visibility into the Google Calendar mirror.
app.get('/api/calendar/status', async (_request, reply) => {
  return reply.send(gcal.status());
});
```

Then, in the four mutation handlers, call `await mirrorSafely(<the alarm record>)` **after**
`AlarmRepo` has been written and after the FCM dispatch, immediately before `return reply...`:

- `POST /api/alarms` — `await mirrorSafely(newAlarm);`
- `PATCH /api/alarms/:id` — `await mirrorSafely(updated);`
- `POST /api/alarms/:id/silence` — `await mirrorSafely({ ...existing, status: 'dismissed' });`
- `POST /api/alarms/:id/state` — `await mirrorSafely({ ...existing, status });`
- `DELETE /api/alarms/:id` — `await mirrorSafely({ ...existing, status: 'canceled' });`

Create the real transport in its own file so that `googleapis` is imported in exactly one place
and `gcal.ts` stays free of the SDK (which is what makes the tests offline):

Create `backend/src/gcal-google.ts`:

```ts
import { readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { google } from 'googleapis';
import { GcalApiError, type GcalTransport } from './gcal.js';
import type { GcalConfig } from './gcal-config.js';
import type { GoogleEvent } from './gcal-events.js';

/** googleapis surfaces HTTP failures as an error carrying `response.status`. */
function toApiError(err: unknown, context: string): GcalApiError {
  const status = (err as { response?: { status?: number } })?.response?.status ?? 0;
  const message = err instanceof Error ? err.message : String(err);
  return new GcalApiError(`${context}: ${message}`, status);
}

export function createGcalTransport(config: GcalConfig): GcalTransport {
  const oauth2 = new google.auth.OAuth2(config.clientId, config.clientSecret);
  const tokens = JSON.parse(readFileSync(config.tokenPath, 'utf8'));
  oauth2.setCredentials(tokens);

  // Google rotates access tokens periodically; persist whatever comes back so
  // the refresh token survives a restart.
  oauth2.on('tokens', (fresh) => {
    try {
      writeFileSync(config.tokenPath, JSON.stringify({ ...tokens, ...fresh }, null, 2), 'utf8');
      chmodSync(config.tokenPath, 0o600);
    } catch (err) {
      console.error('[gcal] failed to persist refreshed token:', err);
    }
  });

  const calendar = google.calendar({ version: 'v3', auth: oauth2 });

  return {
    async ensureSecondaryCalendar(summary, timeZone) {
      try {
        const res = await calendar.calendars.insert({ requestBody: { summary, timeZone } });
        const id = res.data.id;
        if (!id) throw new GcalApiError('calendars.insert returned no id', 500);
        return id;
      } catch (err) {
        throw toApiError(err, 'calendars.insert');
      }
    },

    async insertEvent(calendarId, event) {
      try {
        await calendar.events.insert({ calendarId, sendUpdates: 'none', requestBody: event });
      } catch (err) {
        throw toApiError(err, 'events.insert');
      }
    },

    async updateEvent(calendarId, event) {
      try {
        // events.update is a full replace, so `event` must be the complete
        // object — which toGoogleEvent always produces.
        await calendar.events.update({
          calendarId,
          eventId: event.id,
          sendUpdates: 'none',
          requestBody: event,
        });
      } catch (err) {
        throw toApiError(err, 'events.update');
      }
    },

    async deleteEvent(calendarId, eventId) {
      try {
        await calendar.events.delete({ calendarId, eventId, sendUpdates: 'none' });
      } catch (err) {
        throw toApiError(err, 'events.delete');
      }
    },

    async listEventIds(calendarId) {
      try {
        const res = await calendar.events.list({ calendarId, maxResults: 2500 });
        return (res.data.items ?? [])
          .map((item) => item.id)
          .filter((id): id is string => typeof id === 'string');
      } catch (err) {
        throw toApiError(err, 'events.list');
      }
    },
  };
}
```

**Verify the `requestBody` assignments type-check** before moving on:

```bash
cd backend && npx tsc --noEmit
```

The Calendar Events REST resource represents `reminders` as an **object**
(`{ useDefault, overrides }`), but some `googleapis` versions declare it as an array in
`Schema$Event`. If `tsc` rejects the `reminders` field: keep the wire format as an object —
the REST API requires it — and add a single narrow cast at the transport boundary
(`requestBody: event as unknown as Schema$Event`) with a comment naming the googleapis typing
quirk. **Do not change the payload shape to satisfy the type**; the payload is verified against
Google's documentation and a wrong shape silently loses the no-duplicate-notification property.

Because `createGcalTransport` is only reachable from `server.ts`, every test stays offline.
Confirm that by running the full suite with no Google credentials configured.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && npm test`
Expected: PASS — all suites including the new isolation suite, and the pre-existing 37 tests still green.

- [ ] **Step 5: Commit**

```bash
git add backend/src/server.ts backend/src/gcal.ts backend/test/gcal-isolation.test.ts
git commit -m "feat(backend): wire gcal mirror into alarm mutations with failure isolation"
```

---

### Task 7: Scheduler, auth helper, and repo integration

**Files:**
- Modify: `backend/src/server.ts` (scheduler, inside the existing `NODE_ENV !== 'test'` block)
- Create: `backend/scripts/gcal-auth.ts`
- Modify: `backend/package.json`, `backend/.env.example`, `.gitignore`, `README.md`, `docs/ROADMAP.md`

**Interfaces:**
- Produces: `npm run gcal:auth`; new env vars documented; README corrected

- [ ] **Step 1: Add the reconcile scheduler**

In `backend/src/server.ts`, inside the existing `if (process.env.NODE_ENV !== 'test')` block, after `app.listen(...)`:

```ts
  if (gcal.isConfigured()) {
    const runReconcile = () => {
      reconcile(gcal)
        .then((result) => {
          if (result.created || result.deleted || result.failed) {
            console.log('[gcal] reconcile:', result);
          }
        })
        .catch((err) => console.error('[gcal] reconcile failed:', err));
    };
    runReconcile();
    setInterval(runReconcile, GCAL_RECONCILE_INTERVAL_MS);
  }
```

Verify the guard works — this is the check that keeps the existing suite inert:

```bash
cd backend && NODE_ENV=test DB_PATH=:memory: npx tsx --test test/gcal-reconcile.test.ts
```
Expected: completes quickly with no `[gcal] reconcile:` log lines and no outbound requests.

- [ ] **Step 2: Add the auth helper**

Create `backend/scripts/gcal-auth.ts`:

> **Note:** `backend/tsconfig.json` has `rootDir: "src"` and `include: ["src/**/*"]`, so this
> file is deliberately **outside the build** — `npm run build` will not compile it and it will
> not appear in `dist/`. It is executed directly with `tsx` via the `gcal:auth` script. Do not
> try to import it from `src/`, and do not widen the tsconfig `include` to cover it, which
> would break `rootDir`.

```ts
/**
 * One-off interactive OAuth helper. Run on a machine with a browser:
 *   cd backend && npm run gcal:auth
 * then copy the written token file to the homelab's data directory.
 *
 * The OAuth client MUST be type "Desktop app", and the consent screen's
 * publishing status MUST be "In production" — otherwise Google issues a
 * refresh token that expires every 7 days (spec §3.2).
 */
import { createServer } from 'node:http';
import { writeFileSync, chmodSync } from 'node:fs';
import { google } from 'googleapis';
import dotenv from 'dotenv';
import { DEFAULT_TOKEN_PATH, GCAL_SCOPE } from '../src/gcal-config.js';

dotenv.config();

const clientId = process.env.GOOGLE_OAUTH_CLIENT_ID;
const clientSecret = process.env.GOOGLE_OAUTH_CLIENT_SECRET;
const tokenPath = process.env.GOOGLE_OAUTH_TOKEN_PATH || DEFAULT_TOKEN_PATH;

if (!clientId || !clientSecret) {
  console.error('Set GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET in backend/.env first.');
  process.exit(1);
}

const server = createServer();
server.listen(0, '127.0.0.1', async () => {
  const address = server.address();
  if (typeof address === 'string' || address === null) throw new Error('no port');
  const redirectUri = `http://127.0.0.1:${address.port}`;

  const oauth2 = new google.auth.OAuth2(clientId, clientSecret, redirectUri);
  const authUrl = oauth2.generateAuthUrl({
    access_type: 'offline',
    prompt: 'consent',
    scope: [GCAL_SCOPE],
  });

  console.log('\n1. Open this URL and grant access:\n');
  console.log(authUrl + '\n');
  console.log('2. Google will redirect back to 127.0.0.1 automatically.\n');

  server.on('request', async (req, res) => {
    const url = new URL(req.url ?? '/', redirectUri);
    const code = url.searchParams.get('code');
    if (!code) {
      res.writeHead(400).end('No code in callback.');
      return;
    }
    try {
      const { tokens } = await oauth2.getToken(code);
      if (!tokens.refresh_token) {
        res.writeHead(500).end('No refresh token returned. Re-run with prompt=consent.');
        console.error('\nNo refresh token returned. Revoke prior access and re-run.');
        return;
      }
      writeFileSync(tokenPath, JSON.stringify(tokens, null, 2), 'utf8');
      chmodSync(tokenPath, 0o600);
      res.writeHead(200).end('Authorised. You can close this tab.');
      console.log(`\nToken written to ${tokenPath} (mode 600).`);
      console.log('Copy it to the homelab data directory and restart the container.\n');
    } catch (err) {
      res.writeHead(500).end('Token exchange failed.');
      console.error('\nToken exchange failed:', err);
    } finally {
      server.close();
    }
  });
});
```

Add to `backend/package.json` `scripts`:

```json
"gcal:auth": "tsx scripts/gcal-auth.ts"
```

Add `googleapis` to `backend/package.json` `dependencies` (latest published major is **181.x** —
verify with `npm view googleapis version` and pin the range to what resolves):

```json
"googleapis": "^181.0.0"
```

Then run `cd backend && npm install`.

- [ ] **Step 3: Config, ignore rules, and docs**

Append to `backend/.env.example`:

```
# Google Calendar mirror (optional). Requires an OAuth client of type
# "Desktop app" whose consent screen publishing status is "In production" —
# otherwise the refresh token expires every 7 days.
# GCAL_ENABLED=true
# GOOGLE_OAUTH_CLIENT_ID=
# GOOGLE_OAUTH_CLIENT_SECRET=
# GOOGLE_OAUTH_TOKEN_PATH=./google-oauth-token.json
# GCAL_TIMEZONE=Australia/Brisbane
```

Add to the root `.gitignore`, under the Clients section header's sibling backend section:

```
backend/google-oauth-token.json
```

In `README.md`: correct the API table row `| GET | /ical/feed | ... |` to
`| GET | /api/calendar.ics | Live RFC 5545 iCal feed for Google/Apple Calendar |`, and add a
short **Google Calendar sync** section documenting: that alarms mirror into a dedicated
"Remote Alarms" calendar; that Remote Alarm is the single source of truth so edits made in
Google are overwritten; that `GET /api/calendar/status` reports health; and the five manual
setup steps from spec §11.1.

In `docs/ROADMAP.md` §2.1, note that the export direction is implemented and the ingest
direction remains backlog.

- [ ] **Step 4: Verify the full suite and the helper**

```bash
cd backend && npm test
cd backend && npx tsx scripts/gcal-auth.ts   # expect the "set credentials" guard to fire
```
Expected: full suite PASS; the helper exits 1 with the credentials message (proving it does not
crash before validation).

- [ ] **Step 5: Commit**

```bash
git add backend/src/server.ts backend/scripts/gcal-auth.ts backend/package.json backend/.env.example .gitignore README.md docs/ROADMAP.md
git commit -m "feat(backend): add gcal auth helper, reconcile scheduler, and docs"
```

- [ ] **Step 6: Manual live verification (requires the user's credentials)**

This is the **only** end-to-end proof and it cannot be automated (spec §13.2). After the user
completes spec §11.1 and copies the token file:

```bash
# 1. Confirm the mirror reports configured and healthy
curl -s localhost:3000/api/calendar/status

# 2. Create an alarm ~25 minutes out and confirm it appears in Google at the right LOCAL time
cd clients && node cli/dist/index.js 25m "Calendar Mirror Check"

# 3. Move it and confirm the event moves
node cli/dist/index.js edit <id> --at "tomorrow 7am"

# 4. Cancel it and confirm the event disappears
node cli/dist/index.js kill <id> --yes
```

Record the outcome in the PR/commit. If Google and the alarm disagree on wall-clock time, the
first thing to check is `GCAL_TIMEZONE`.

---

## Self-Review

**1. Spec coverage**

| Spec section | Task |
|---|---|
| §3.3 derived event IDs, no migration | Task 2 (`deriveEventId`) |
| §3.4 timezone / recurrence expansion | Task 2 (`zonedDateTime`, `recurrenceRule`), Task 3 |
| §4 file layout | Tasks 2–7 (`gcal-google.ts` in Task 6) |
| §5 auth & credential handling | Task 7 (helper), Task 4 (token path via config) |
| §5.2 `settings` storage | Task 1 |
| §7.1 payload | Task 2 |
| §7.2 status mapping | Task 2 (`actionForStatus`) |
| §7.3 fail-loud timezone | Task 3 |
| §8 dedicated calendar + persisted id | Task 4 (`ensureCalendar`), Task 1 |
| §9.1 push on mutation | Task 6 |
| §9.2 idempotency | Task 4 |
| §9.3 drift policy | Task 5 |
| §9.4 reconcile + test isolation | Task 5, Task 7 Step 1 |
| §10 failure isolation | Task 6 |
| §10.1 status endpoint | Task 6 |
| §11 config | Task 3, Task 7 |
| §11.1 manual prerequisites | Task 7 Step 3 (README) |
| §12 repo integration | Task 7 |
| §13 verification | Tasks 2–6 tests; Task 7 Step 6 manual |

No gaps.

**2. Placeholder scan** — clean. `createGcalTransport` is written out in full in
`backend/src/gcal-google.ts` rather than described, so there is no "implement later" step. The
one open item is a *verification instruction*, not a placeholder: the `googleapis` typings for
`reminders` may disagree with the REST shape, and Task 6 states exactly what to do if `tsc`
objects (keep the documented wire shape, add one narrow documented cast) and what not to do
(change the payload).

**3. Type consistency** — `GcalTransport` has five methods; the fakes in Task 4 and Task 5
implement all five. `GcalMirror.deleteEventById` is defined in Task 4 Step 3 and consumed by
Task 5's reconciler. `GcalStatus` fields match the Task 6 test's assertions. `deriveEventId`,
`toGoogleEvent`, `actionForStatus`, `reconcile`, `mirrorSafely` names are used identically
across tasks.

**4. Review Focus** — each of the five lines has an owning test: (1) Task 2's DST-boundary and
`recurrence` tests; (2) Task 4's malformed-id test; (3) Task 4's 409/404 fallback tests;
(4) Task 6's isolation suite; (5) Task 2's junk-`repeat_days` tests.
