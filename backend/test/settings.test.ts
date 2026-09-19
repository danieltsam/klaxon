import { describe, it, before, after } from 'node:test';
import assert from 'node:assert';
import { app } from '../src/server.js';
import { db, SettingsRepo, DEFAULT_SETTINGS } from '../src/db.js';

describe('Settings API & Persistence Regression Test Suite', () => {
  before(async () => {
    await app.ready();
  });

  after(async () => {
    // Reset settings table to clean state after tests
    db.prepare('DELETE FROM settings').run();
  });

  it('GET /api/settings should return default configuration when database is fresh', async () => {
    db.prepare('DELETE FROM settings').run();
    const response = await app.inject({
      method: 'GET',
      url: '/api/settings'
    });

    assert.strictEqual(response.statusCode, 200);
    const body = JSON.parse(response.body);
    assert.strictEqual(body.sound_tone, DEFAULT_SETTINGS.sound_tone);
    assert.strictEqual(body.ramp_seconds, DEFAULT_SETTINGS.ramp_seconds);
    assert.strictEqual(body.date_format, DEFAULT_SETTINGS.date_format);
    assert.strictEqual(body.time_format, DEFAULT_SETTINGS.time_format);
  });

  it('POST /api/settings should update sound_tone, ramp_seconds, date_format, and time_format', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/settings',
      payload: {
        sound_tone: 'chime',
        ramp_seconds: 30,
        date_format: 'mm/dd/yyyy',
        time_format: '12h'
      }
    });

    assert.strictEqual(response.statusCode, 200);
    const body = JSON.parse(response.body);
    assert.strictEqual(body.success, true);
    assert.strictEqual(body.settings.sound_tone, 'chime');
    assert.strictEqual(body.settings.ramp_seconds, 30);
    assert.strictEqual(body.settings.date_format, 'mm/dd/yyyy');
    assert.strictEqual(body.settings.time_format, '12h');

    // Verify persistence via GET
    const getRes = await app.inject({
      method: 'GET',
      url: '/api/settings'
    });
    const fetched = JSON.parse(getRes.body);
    assert.strictEqual(fetched.sound_tone, 'chime');
    assert.strictEqual(fetched.ramp_seconds, 30);
    assert.strictEqual(fetched.date_format, 'mm/dd/yyyy');
    assert.strictEqual(fetched.time_format, '12h');
  });

  it('POST /api/settings should support partial updates and preserve untouched fields', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/settings',
      payload: {
        time_format: '24h'
      }
    });

    assert.strictEqual(response.statusCode, 200);
    const body = JSON.parse(response.body);
    assert.strictEqual(body.settings.time_format, '24h');
    // Ensure previous chime, 30, mm/dd/yyyy were preserved
    assert.strictEqual(body.settings.sound_tone, 'chime');
    assert.strictEqual(body.settings.ramp_seconds, 30);
    assert.strictEqual(body.settings.date_format, 'mm/dd/yyyy');
  });

  it('POST /api/settings should reject invalid sound_tone with 400', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/settings',
      payload: {
        sound_tone: 'invalid_sound_tone'
      }
    });

    assert.strictEqual(response.statusCode, 400);
    const body = JSON.parse(response.body);
    assert.match(body.error, /Invalid sound_tone/);
  });

  it('POST /api/settings should reject invalid ramp_seconds with 400', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/settings',
      payload: {
        ramp_seconds: 999
      }
    });

    assert.strictEqual(response.statusCode, 400);
    const body = JSON.parse(response.body);
    assert.match(body.error, /Invalid ramp_seconds/);
  });

  it('POST /api/settings should reject invalid date_format with 400', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/settings',
      payload: {
        date_format: 'invalid_format'
      }
    });

    assert.strictEqual(response.statusCode, 400);
    const body = JSON.parse(response.body);
    assert.match(body.error, /Invalid date_format/);
  });

  it('POST /api/settings should reject invalid time_format with 400', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/settings',
      payload: {
        time_format: '48h'
      }
    });

    assert.strictEqual(response.statusCode, 400);
    const body = JSON.parse(response.body);
    assert.match(body.error, /Invalid time_format/);
  });

  it('SettingsRepo directly verifies database read-write cycle', () => {
    SettingsRepo.update({ sound_tone: 'digital', ramp_seconds: 60 });
    const direct = SettingsRepo.getAll();
    assert.strictEqual(direct.sound_tone, 'digital');
    assert.strictEqual(direct.ramp_seconds, 60);
  });
});
