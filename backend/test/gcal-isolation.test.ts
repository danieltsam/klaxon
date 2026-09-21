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
