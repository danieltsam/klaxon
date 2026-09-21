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
