import Database from 'better-sqlite3';
import path from 'path';

export interface AlarmRecord {
  id: string;
  target_time: string;
  label: string;
  status: 'pending' | 'ringing' | 'dismissed' | 'snoozed' | 'canceled';
  repeat_days?: string; // e.g. '1,2,3,4,5'
  created_at?: string;
}

export interface DeviceRecord {
  token: string;
  updated_at?: string;
}

const dbPath = path.resolve(process.cwd(), 'alarms.db');
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
    created_at TEXT DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS devices (
    token TEXT PRIMARY KEY,
    updated_at TEXT DEFAULT (datetime('now'))
  );
`);

// Migration: add repeat_days column if not present
try {
  db.exec('ALTER TABLE alarms ADD COLUMN repeat_days TEXT DEFAULT NULL;');
} catch {
  // Column already exists
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
      return db.prepare('SELECT * FROM alarms ORDER BY target_time ASC').all() as AlarmRecord[];
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
      INSERT INTO alarms (id, target_time, label, status, repeat_days)
      VALUES (@id, @target_time, @label, @status, @repeat_days)
    `).run({
      ...alarm,
      repeat_days: alarm.repeat_days || null
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

  upsert(token: string): void {
    db.prepare(`
      INSERT INTO devices (token, updated_at)
      VALUES (?, datetime('now'))
      ON CONFLICT(token) DO UPDATE SET updated_at = datetime('now')
    `).run(token);
  },

  remove(token: string): void {
    db.prepare('DELETE FROM devices WHERE token = ?').run(token);
  }
};
