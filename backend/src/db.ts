import Database from 'better-sqlite3';
import path from 'path';

export interface AlarmRecord {
  id: string;
  target_time: string;
  label: string;
  status: 'pending' | 'ringing' | 'dismissed' | 'snoozed' | 'canceled' | 'disabled';
  repeat_days?: string; // e.g. '1,2,3,4,5'
  sound_tone?: string; // e.g. 'alarm', 'chime', 'digital'
  ramp_seconds?: number; // e.g. 0, 15, 30, 60
  created_at?: string;
}

export interface DeviceRecord {
  token: string;
  battery_level?: number | null;
  is_charging?: number | boolean | null;
  device_name?: string | null;
  updated_at?: string;
}

const dbPath = process.env.DB_PATH || path.resolve(process.cwd(), 'alarms.db');
export const db = new Database(dbPath);

// Enable WAL mode for high concurrency
db.pragma('journal_mode = WAL');

// Initialize tables
db.exec(`
  CREATE TABLE IF NOT EXISTS alarms (
    id TEXT PRIMARY KEY,
    target_time TEXT NOT NULL,
    label TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    repeat_days TEXT DEFAULT NULL,
    sound_tone TEXT DEFAULT 'alarm',
    ramp_seconds INTEGER DEFAULT 30,
    created_at TEXT DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS devices (
    token TEXT PRIMARY KEY,
    battery_level INTEGER DEFAULT NULL,
    is_charging INTEGER DEFAULT NULL,
    device_name TEXT DEFAULT NULL,
    updated_at TEXT DEFAULT (datetime('now'))
  );
`);

// Migrations for existing databases
const migrations = [
  'ALTER TABLE alarms ADD COLUMN repeat_days TEXT DEFAULT NULL;',
  "ALTER TABLE alarms ADD COLUMN sound_tone TEXT DEFAULT 'alarm';",
  'ALTER TABLE alarms ADD COLUMN ramp_seconds INTEGER DEFAULT 30;',
  'ALTER TABLE devices ADD COLUMN battery_level INTEGER DEFAULT NULL;',
  'ALTER TABLE devices ADD COLUMN is_charging INTEGER DEFAULT NULL;',
  'ALTER TABLE devices ADD COLUMN device_name TEXT DEFAULT NULL;'
];

for (const migration of migrations) {
  try {
    db.exec(migration);
  } catch {
    // Column already exists
  }
}

export const AlarmRepo = {
  getAll(view: 'active' | 'history' | 'all' = 'active'): AlarmRecord[] {
    if (view === 'history') {
      return db.prepare(`
        SELECT * FROM alarms 
        WHERE status IN ('dismissed', 'canceled') 
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
      INSERT INTO alarms (id, target_time, label, status, repeat_days, sound_tone, ramp_seconds)
      VALUES (@id, @target_time, @label, @status, @repeat_days, @sound_tone, @ramp_seconds)
    `).run({
      ...alarm,
      repeat_days: alarm.repeat_days || null,
      sound_tone: alarm.sound_tone || 'alarm',
      ramp_seconds: alarm.ramp_seconds ?? 30
    });
    return alarm;
  },

  updateStatus(id: string, status: string): boolean {
    const result = db.prepare(`
      UPDATE alarms
      SET status = ?
      WHERE id = ?
    `).run(status, id);
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
