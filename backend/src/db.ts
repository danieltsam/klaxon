import Database from 'better-sqlite3';
import path from 'path';
import fs from 'fs';

/**
 * `missed_reason` values that are evidence of *silence*, not of failure.
 *
 * The sweep derives a reason from the dispatch counters, but `sent > 0` does
 * not prove the alarm rang (see `deriveMissedReason`). A row carrying one of
 * these is not a failure the user can act on or trust, so the sweep resolves it
 * quietly to `dismissed` instead of recording a `missed` the owner reported as
 * wrong. Every other reason is a fact: nothing could be sent, FCM rejected it,
 * or the phone itself said it could not ring.
 */
export const UNCONFIRMED_MISSED_REASONS: readonly string[] = [
  'dispatched_not_reported',
  'unknown',
];

/** True when `reason` is evidence of failure rather than evidence of silence. */
export function isKnownMissedReason(reason: string | null | undefined): boolean {
  if (!reason) return false;
  return !UNCONFIRMED_MISSED_REASONS.includes(reason);
}

export interface AlarmRecord {
  id: string;
  target_time: string;
  label: string;
  description?: string;
  status: 'pending' | 'ringing' | 'dismissed' | 'snoozed' | 'canceled' | 'disabled' | 'missed';
  repeat_days?: string; // e.g. '1,2,3,4,5'
  recurrence_interval_weeks?: number; // 1 (default, weekly) or 2 (fortnightly)
  recurrence_anchor_date?: string;    // ISO date "YYYY-MM-DD", required if interval > 1
  sound_tone?: string; // e.g. 'alarm', 'chime', 'digital'
  ramp_seconds?: number; // e.g. 0, 15, 30, 60
  created_at?: string;
  missed_at?: string | null;            // ISO instant the alarm was declared missed
  missed_reason?: string | null;        // one of the closed reason set (spec §7)
  last_dispatch_sent?: number | null;   // outcome of the most recent FCM dispatch
  last_dispatch_failed?: number | null; // outcome of the most recent FCM dispatch
  last_dispatch_at?: string | null;     // when that dispatch happened
  skipped_from?: string | null;         // occurrence consumed by a skip; earlier than target_time
}

export interface DeviceRecord {  token: string;
  battery_level?: number | null;
  is_charging?: number | boolean | null;
  device_name?: string | null;
  updated_at?: string;
}

export interface AppSettings {
  sound_tone: 'alarm' | 'chime' | 'digital';
  ramp_seconds: number;
  date_format: 'dd/mm/yyyy' | 'mm/dd/yyyy' | 'yyyy-mm-dd';
  time_format: '24h' | '12h';
}

// A test run must never open a real database.
//
// Only the npm test script sets DB_PATH=:memory:, so a bare
// `tsx --test <file>` would otherwise create and delete rows in the real
// alarms.db -- which happened once and hung for seven minutes. Defaulting to
// :memory: under a test run makes the isolation structural rather than a
// property of how the tests were invoked. An explicit DB_PATH is respected.
const isTestRun =
  process.env.NODE_ENV === 'test' || process.env.NODE_TEST_CONTEXT !== undefined;

const configuredDbPath = process.env.DB_PATH;
if (isTestRun && !configuredDbPath) {
  console.log('[DB] Test run without DB_PATH: using :memory: so it cannot touch a real database.');
}
const dbPath =
  configuredDbPath ?? (isTestRun ? ':memory:' : path.resolve(process.cwd(), 'alarms.db'));
if (dbPath !== ':memory:') {
  try {
    fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  } catch (_) {}
}
console.log(`[DB] Opening SQLite database at ${dbPath}...`);
export const db = new Database(dbPath);

// Enable WAL mode for high concurrency
console.log(`[DB] Setting journal_mode = WAL...`);
db.pragma('journal_mode = WAL');
console.log(`[DB] SQLite database initialized successfully.`);

// Initialize tables
db.exec(`
  CREATE TABLE IF NOT EXISTS alarms (
    id TEXT PRIMARY KEY,
    target_time TEXT NOT NULL,
    label TEXT NOT NULL,
    description TEXT DEFAULT NULL,
    status TEXT DEFAULT 'pending',
    repeat_days TEXT DEFAULT NULL,
    recurrence_interval_weeks INTEGER DEFAULT 1,
    recurrence_anchor_date TEXT DEFAULT NULL,
    sound_tone TEXT DEFAULT 'alarm',
    ramp_seconds INTEGER DEFAULT 30,
    created_at TEXT DEFAULT (datetime('now')),
    skipped_from TEXT DEFAULT NULL
  );

  CREATE TABLE IF NOT EXISTS devices (
    token TEXT PRIMARY KEY,
    battery_level INTEGER DEFAULT NULL,
    is_charging INTEGER DEFAULT NULL,
    device_name TEXT DEFAULT NULL,
    updated_at TEXT DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT DEFAULT (datetime('now'))
  );
`);

// Migrations for existing databases
const migrations = [
  'ALTER TABLE alarms ADD COLUMN description TEXT DEFAULT NULL;',
  'ALTER TABLE alarms ADD COLUMN repeat_days TEXT DEFAULT NULL;',
  "ALTER TABLE alarms ADD COLUMN sound_tone TEXT DEFAULT 'alarm';",
  'ALTER TABLE alarms ADD COLUMN ramp_seconds INTEGER DEFAULT 30;',
  'ALTER TABLE devices ADD COLUMN battery_level INTEGER DEFAULT NULL;',
  'ALTER TABLE devices ADD COLUMN is_charging INTEGER DEFAULT NULL;',
  'ALTER TABLE devices ADD COLUMN device_name TEXT DEFAULT NULL;',
  { name: 'add_recurrence_interval_weeks', sql: 'ALTER TABLE alarms ADD COLUMN recurrence_interval_weeks INTEGER DEFAULT 1' },
  { name: 'add_recurrence_anchor_date',     sql: 'ALTER TABLE alarms ADD COLUMN recurrence_anchor_date TEXT DEFAULT NULL' },
  { name: 'add_missed_at',                  sql: 'ALTER TABLE alarms ADD COLUMN missed_at TEXT DEFAULT NULL' },
  { name: 'add_missed_reason',              sql: 'ALTER TABLE alarms ADD COLUMN missed_reason TEXT DEFAULT NULL' },
  { name: 'add_last_dispatch_sent',         sql: 'ALTER TABLE alarms ADD COLUMN last_dispatch_sent INTEGER DEFAULT NULL' },
  { name: 'add_last_dispatch_failed',       sql: 'ALTER TABLE alarms ADD COLUMN last_dispatch_failed INTEGER DEFAULT NULL' },
  { name: 'add_last_dispatch_at',           sql: 'ALTER TABLE alarms ADD COLUMN last_dispatch_at TEXT DEFAULT NULL' },
  { name: 'add_skipped_from',               sql: 'ALTER TABLE alarms ADD COLUMN skipped_from TEXT DEFAULT NULL' }
];

for (const migration of migrations) {
  try {
    if (typeof migration === 'string') {
      db.exec(migration);
    } else {
      db.exec(migration.sql);
    }
  } catch {
    // Column already exists
  }
}

export const AlarmRepo = {
  getAll(view: 'active' | 'history' | 'all' = 'active'): AlarmRecord[] {
    if (view === 'history') {
      return db.prepare(`
        SELECT * FROM alarms 
        WHERE status IN ('dismissed', 'canceled', 'missed') 
        ORDER BY target_time DESC 
        LIMIT 50
      `).all() as AlarmRecord[];
    }
    if (view === 'all') {
      return db.prepare("SELECT * FROM alarms WHERE status != 'canceled' ORDER BY target_time ASC").all() as AlarmRecord[];
    }
    // Default: active only
    return db.prepare(`
      SELECT * FROM alarms 
      WHERE status IN ('pending', 'snoozed', 'ringing') 
      ORDER BY target_time ASC
    `).all() as AlarmRecord[];
  },

  getById(id: string): AlarmRecord | undefined {
    return db.prepare('SELECT * FROM alarms WHERE id = ?').get(id) as AlarmRecord | undefined;
  },

  create(alarm: AlarmRecord): AlarmRecord {
    db.prepare(`
      INSERT INTO alarms (id, target_time, label, description, status, repeat_days, sound_tone, ramp_seconds, recurrence_interval_weeks, recurrence_anchor_date)
      VALUES (@id, @target_time, @label, @description, @status, @repeat_days, @sound_tone, @ramp_seconds, @recurrence_interval_weeks, @recurrence_anchor_date)
    `).run({
      ...alarm,
      description: alarm.description || null,
      repeat_days: alarm.repeat_days || null,
      sound_tone: alarm.sound_tone || 'alarm',
      ramp_seconds: alarm.ramp_seconds ?? 30,
      recurrence_interval_weeks: alarm.recurrence_interval_weeks ?? 1,
      recurrence_anchor_date: alarm.recurrence_anchor_date || null
    });
    return alarm;
  },

  updateStatus(id: string, status: string): boolean {
    // A status change away from `missed` corrects the record: a late report can
    // prove the sweep's guess wrong, so the failure fields must not linger on a
    // row that is no longer a failure. `missed` is never set through this path —
    // `markMissed` is its only writer — so clearing here is always safe.
    // `cancel` is terminal. A delayed phone report for an alarm the owner
    // cancelled must not resurrect it as ringing/snoozed/pending.
    const result = db.prepare(`
      UPDATE alarms
      SET status = ?, missed_at = NULL, missed_reason = NULL
      WHERE id = ? AND status != 'canceled'
    `).run(status, id);
    return result.changes > 0;
  },

  updateTargetTime(id: string, targetTime: string): boolean {
    // Moving the target consumes any pending skip: the marker names an
    // occurrence that is no longer the one being moved past (design §5.1).
    const result = db.prepare(`
      UPDATE alarms
      SET target_time = ?,
          skipped_from = NULL
      WHERE id = ?
    `).run(targetTime, id);
    return result.changes > 0;
  },

  /**
   * Move the alarm to `targetTime` and record (or clear) the occurrence a skip
   * consumed, in one statement so the pair can never drift (design §5.2).
   * This is the only writer that sets `skipped_from`.
   */
  /**
   * Write a skip (or undo one) only if the row still carries the target the
   * caller read. Two surfaces pressing skip within the same second both read
   * the same pre-skip target and both dispatch; without this guard both would
   * report success and the loser would overwrite a row it no longer matches.
   * Returns false when the row moved, so the caller can tell the user to reload.
   */
  setSkip(
    id: string,
    expectedTargetTime: string,
    skippedFrom: string | null,
    targetTime: string
  ): boolean {
    const result = db.prepare(`
      UPDATE alarms
      SET target_time = @target_time,
          skipped_from = @skipped_from
      WHERE id = @id AND target_time = @expected_target_time
    `).run({
      id,
      expected_target_time: expectedTargetTime,
      skipped_from: skippedFrom,
      target_time: targetTime,
    });
    return result.changes > 0;
  },

  /**
   * Persist the outcome of the most recent FCM dispatch. This is the only
   * evidence the system has about why a phone never rang, so the missed-alarm
   * reason is derived from it (spec §5.1, §7).
   */
  recordDispatch(id: string, sent: number, failed: number, at: string = new Date().toISOString()): boolean {
    const result = db.prepare(`
      UPDATE alarms
      SET last_dispatch_sent = ?,
          last_dispatch_failed = ?,
          last_dispatch_at = ?
      WHERE id = ?
    `).run(sent, failed, at, id);
    return result.changes > 0;
  },

  /**
   * System-set transition to `missed`. Never reachable through the client
   * state endpoint (spec §5); the sweep and the device report are its only
   * callers.
   *
   * Defense in depth: only an alarm that could still be live (`pending` or
   * `snoozed`) may be declared missed. A row already ringing, dismissed,
   * canceled, disabled, or missed is left untouched.
   */
  markMissed(id: string, reason: string, at: string = new Date().toISOString()): boolean {
    const result = db.prepare(`
      UPDATE alarms
      SET status = 'missed',
          missed_at = ?,
          missed_reason = ?
      WHERE id = ? AND status IN ('pending', 'snoozed')
    `).run(at, reason, id);
    return result.changes > 0;
  },

  /**
   * Repair a lost dismissal report: transition an alarm that is still
   * `ringing` to `dismissed`. Called only by the abandoned-ring sweep, which
   * decides the alarm has rung unacknowledged long enough that the phone is not
   * coming back with a report.
   *
   * Guarded on `status = 'ringing'` so it is atomic and can never overwrite a
   * state the phone (or the missed sweep) set in the meantime. It is deliberately
   * NOT `markMissed`: the alarm fired, so calling it missed would be dishonest
   * (and is the exact confusion the owner reported). No `missed_*` field is set.
   */
  markDismissed(id: string): boolean {
    const result = db.prepare(`
      UPDATE alarms
      SET status = 'dismissed'
      WHERE id = ? AND status = 'ringing'
    `).run(id);
    return result.changes > 0;
  },

  /**
   * Quietly resolve an alarm that passed its target with **no evidence of
   * failure**.
   *
   * The sweep only records `missed` when it has evidence (see
   * `isKnownMissedReason`). When all it has is silence, that is not a failure
   * and must not be recorded as one — the reported symptom was a `missed` row
   * for an alarm that had rung. It still needs a terminal state, so it resolves
   * to `dismissed`: the same assumption the abandoned-ring sweep makes, and
   * consistent with those alarms having rung. No `missed_*` field is set, so
   * nothing presents it to the user as a failure.
   *
   * Guarded on `pending`/`snoozed` so it is atomic and cannot overwrite a state
   * the phone set in the meantime.
   */
  update(id: string, updates: Partial<AlarmRecord>): boolean {
    const existing = this.getById(id);
    if (!existing) return false;
    const merged = { ...existing, ...updates };
    const result = db.prepare(`
      UPDATE alarms
      SET target_time = @target_time,
          label = @label,
          description = @description,
          status = @status,
          repeat_days = @repeat_days,
          sound_tone = @sound_tone,
          ramp_seconds = @ramp_seconds,
          recurrence_interval_weeks = @recurrence_interval_weeks,
          recurrence_anchor_date = @recurrence_anchor_date,
          skipped_from = @skipped_from
      WHERE id = @id
    `).run({
      id,
      target_time: merged.target_time,
      label: merged.label,
      description: merged.description || null,
      status: merged.status,
      repeat_days: merged.repeat_days || null,
      sound_tone: merged.sound_tone || 'alarm',
      ramp_seconds: merged.ramp_seconds ?? 30,
      recurrence_interval_weeks: merged.recurrence_interval_weeks ?? 1,
      recurrence_anchor_date: merged.recurrence_anchor_date || null,
      skipped_from: merged.skipped_from ?? null
    });
    return result.changes > 0;
  },

  cancel(id: string): boolean {
    return this.updateStatus(id, 'canceled');
  }
};

export const DeviceRepo = {
  getAllTokens(): string[] {
    const rows = db.prepare('SELECT token FROM devices').all() as { token: string }[];
    return rows.map(r => r.token);
  },

  getAllDevices(): DeviceRecord[] {
    return db.prepare(`
      SELECT token, battery_level, is_charging, device_name, updated_at
      FROM devices
      ORDER BY updated_at DESC
    `).all() as DeviceRecord[];
  },

  upsert(
    token: string,
    metadata?: { battery_level?: number | null; is_charging?: number | boolean | null; device_name?: string | null }
  ): void {
    const batteryLevel = typeof metadata?.battery_level === 'number' ? metadata.battery_level : null;
    const isCharging = metadata?.is_charging === true || metadata?.is_charging === 1 ? 1 : metadata?.is_charging === false || metadata?.is_charging === 0 ? 0 : null;
    const deviceName = metadata?.device_name?.trim() || null;

    db.prepare(`
      INSERT INTO devices (token, battery_level, is_charging, device_name, updated_at)
      VALUES (?, ?, ?, ?, datetime('now'))
      ON CONFLICT(token) DO UPDATE SET 
        battery_level = COALESCE(excluded.battery_level, devices.battery_level),
        is_charging = COALESCE(excluded.is_charging, devices.is_charging),
        device_name = COALESCE(excluded.device_name, devices.device_name),
        updated_at = datetime('now')
    `).run(token, batteryLevel, isCharging, deviceName);
  },

  remove(token: string): void {
    db.prepare('DELETE FROM devices WHERE token = ?').run(token);
  }
};

export const DEFAULT_SETTINGS: AppSettings = {
  sound_tone: 'alarm',
  ramp_seconds: 15,
  date_format: 'dd/mm/yyyy',
  time_format: '24h'
};

export const SettingsRepo = {
  getAll(): AppSettings {
    const rows = db.prepare('SELECT key, value FROM settings').all() as { key: string; value: string }[];
    const map: Record<string, string> = {};
    for (const r of rows) {
      map[r.key] = r.value;
    }
    return {
      sound_tone: (map['sound_tone'] && ['alarm', 'chime', 'digital'].includes(map['sound_tone']))
        ? (map['sound_tone'] as 'alarm' | 'chime' | 'digital')
        : DEFAULT_SETTINGS.sound_tone,
      ramp_seconds: (map['ramp_seconds'] && !isNaN(parseInt(map['ramp_seconds'], 10)))
        ? parseInt(map['ramp_seconds'], 10)
        : DEFAULT_SETTINGS.ramp_seconds,
      date_format: (map['date_format'] && ['dd/mm/yyyy', 'mm/dd/yyyy', 'yyyy-mm-dd'].includes(map['date_format']))
        ? (map['date_format'] as 'dd/mm/yyyy' | 'mm/dd/yyyy' | 'yyyy-mm-dd')
        : DEFAULT_SETTINGS.date_format,
      time_format: (map['time_format'] && ['24h', '12h'].includes(map['time_format']))
        ? (map['time_format'] as '24h' | '12h')
        : DEFAULT_SETTINGS.time_format
    };
  },

  update(settings: Partial<AppSettings>): AppSettings {
    const upsertStmt = db.prepare(`
      INSERT INTO settings (key, value, updated_at)
      VALUES (?, ?, datetime('now'))
      ON CONFLICT(key) DO UPDATE SET
        value = excluded.value,
        updated_at = datetime('now')
    `);

    const tx = db.transaction((updates: Partial<AppSettings>) => {
      if (updates.sound_tone !== undefined) {
        upsertStmt.run('sound_tone', updates.sound_tone);
      }
      if (updates.ramp_seconds !== undefined) {
        upsertStmt.run('ramp_seconds', String(updates.ramp_seconds));
      }
      if (updates.date_format !== undefined) {
        upsertStmt.run('date_format', updates.date_format);
      }
      if (updates.time_format !== undefined) {
        upsertStmt.run('time_format', updates.time_format);
      }
    });

    tx(settings);
    return this.getAll();
  },

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
};
