import { describe, it, before, after } from 'node:test';
import assert from 'node:assert';
import { app } from '../src/server.js';
import { db } from '../src/db.js';

const LABEL_PREFIX = 'RollTest';

function truncateToMinute(date: Date): string {
  const copy = new Date(date.getTime());
  copy.setSeconds(0, 0);
  return copy.toISOString();
}

describe('POST /api/alarms rolls stale targets forward', () => {
  before(async () => {
    await app.ready();
  });

  after(async () => {
    db.prepare('DELETE FROM alarms WHERE label LIKE ?').run(`${LABEL_PREFIX}%`);
    await app.close();
  });

  it('rolls a one-time target ~24h in the past into the future, preserving UTC HH:MM', async () => {
    const past = new Date(Date.now() - 24 * 60 * 60 * 1000);
    const input = past.toISOString();

    const response = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: { target_time: input, label: `${LABEL_PREFIX} OneTime Past` }
    });

    assert.strictEqual(response.statusCode, 201);
    const data = JSON.parse(response.body);

    const returned = new Date(data.target_time);
    assert.ok(
      returned.getTime() > Date.now(),
      `rolled target must be strictly in the future, got ${data.target_time}`
    );

    const inputMinutes = input.slice(11, 16);
    const returnedMinutes = data.target_time.slice(11, 16);
    assert.strictEqual(returnedMinutes, inputMinutes);

    db.prepare('DELETE FROM alarms WHERE id = ?').run(data.id);
  });

  it('leaves a one-time target ~2 minutes in the past unchanged (within grace)', async () => {
    const past = new Date(Date.now() - 2 * 60 * 1000);
    const input = past.toISOString();
    const expected = truncateToMinute(past);

    const response = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: { target_time: input, label: `${LABEL_PREFIX} OneTime Grace` }
    });

    assert.strictEqual(response.statusCode, 201);
    const data = JSON.parse(response.body);

    assert.strictEqual(data.target_time, expected);
    assert.ok(new Date(data.target_time).getTime() < Date.now(), 'target must still be in the past');

    db.prepare('DELETE FROM alarms WHERE id = ?').run(data.id);
  });

  it('leaves a future target unchanged', async () => {
    const future = new Date(Date.now() + 24 * 60 * 60 * 1000);
    const input = future.toISOString();
    const expected = truncateToMinute(future);

    const response = await app.inject({
      method: 'POST',
      url: '/api/alarms',
      payload: { target_time: input, label: `${LABEL_PREFIX} Future` }
    });

    assert.strictEqual(response.statusCode, 201);
    const data = JSON.parse(response.body);

    assert.strictEqual(data.target_time, expected);

    db.prepare('DELETE FROM alarms WHERE id = ?').run(data.id);
  });
});
