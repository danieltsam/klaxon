import { describe, it, before, after } from 'node:test';
import assert from 'node:assert';
import { app } from '../src/server.js';
import { db } from '../src/db.js';

const LABEL_PREFIX = 'EmptyBodyTest';

describe('Empty-body POST robustness', () => {
  before(async () => {
    await app.ready();
  });

  after(async () => {
    db.prepare('DELETE FROM alarms WHERE label LIKE ?').run(`${LABEL_PREFIX}%`);
    await app.close();
  });

  async function createAlarm(label: string): Promise<string> {
    const response = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: { target_time: '2026-12-15T08:00:00.000Z', label }
    });
    assert.strictEqual(response.statusCode, 201);
    return JSON.parse(response.body).id;
  }

  it('accepts an empty JSON body on silence and returns 200', async () => {
    const id = await createAlarm(`${LABEL_PREFIX} Empty`);

    const response = await app.inject({
      method: 'POST',
      url: `/api/alarms/${id}/silence`,
      headers: { 'content-type': 'application/json' },
      payload: ''
    });

    assert.strictEqual(response.statusCode, 200);
    const data = JSON.parse(response.body);
    assert.strictEqual(data.success, true);
  });

  it('still rejects malformed JSON with 400', async () => {
    const id = await createAlarm(`${LABEL_PREFIX} Malformed`);

    const response = await app.inject({
      method: 'POST',
      url: `/api/alarms/${id}/silence`,
      headers: { 'content-type': 'application/json' },
      payload: '{bad'
    });

    assert.strictEqual(response.statusCode, 400);
  });
});
