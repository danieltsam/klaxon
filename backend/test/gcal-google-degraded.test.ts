// Regression test for the headline property: a hostile/broken Google Calendar
// setup must never break alarm creation. The exact failure this guards against
// is "configured credentials, but no token file yet" — the normal state before
// the owner runs `npm run gcal:auth`. `resolveGcalConfig()` reads process.env
// at module load, so these MUST be set before the server is imported. Each
// test file runs in its own process, so this env cannot leak into others.
process.env.GCAL_ENABLED = 'true';
process.env.GOOGLE_OAUTH_CLIENT_ID = 'dummy-client-id';
process.env.GOOGLE_OAUTH_CLIENT_SECRET = 'dummy-secret';
process.env.GCAL_TIMEZONE = 'Australia/Brisbane';
process.env.GOOGLE_OAUTH_TOKEN_PATH = './definitely-missing-token.json';

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';

const { app } = await import('../src/server.js');
const { db } = await import('../src/db.js');

describe('Google Calendar degradation with a missing token', () => {
  before(async () => {
    await app.ready();
  });

  after(async () => {
    db.prepare("DELETE FROM alarms WHERE label LIKE 'Degraded%'").run();
    await app.close();
  });

  it('still creates alarms when the token file is missing', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: {
        target_time: '2030-01-01T21:00:00.000Z',
        label: 'Degraded Probe',
      },
    });
    assert.strictEqual(response.statusCode, 201);
    const body = JSON.parse(response.body);
    assert.ok(body.fcm_dispatch, 'fcm_dispatch must still be present');
    assert.strictEqual(body.fcm_dispatch.sent, 0);
  });

  it('reports genuinely unconfigured, with the token problem as the reason', async () => {
    const response = await app.inject({ method: 'GET', url: '/api/calendar/status' });
    assert.strictEqual(response.statusCode, 200);
    const body = JSON.parse(response.body);
    assert.strictEqual(body.configured, false);
    assert.ok(body.reason, 'reason must be non-null');
    assert.match(body.reason.toLowerCase(), /token/);
    // Never leak credentials even in the degraded path.
    const serialized = response.body.toLowerCase();
    for (const forbidden of ['secret', 'refresh_token', 'access_token', 'client_id']) {
      assert.ok(!serialized.includes(forbidden), `status leaked "${forbidden}"`);
    }
  });
});
