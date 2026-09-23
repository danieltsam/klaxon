import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { app } from '../src/server.js';
import { db, AlarmRepo } from '../src/db.js';

/**
 * `PATCH /api/alarms/:id` writes `status` unchecked. Before this guard a raw
 * client could set `status: "missed"` -- which the spec makes system-set only
 * -- or any arbitrary string, and corrupt the row.
 *
 * These tests pin the runtime check to the set the declared type already
 * promises, and pin that `missed` is NOT in it.
 */
describe('PATCH /api/alarms/:id status validation', () => {
  const id = '11111111-2222-3333-4444-555555555555';

  before(async () => {
    await app.ready();
    AlarmRepo.create({
      id,
      target_time: '2030-01-01T00:00:00.000Z',
      label: 'Patch Validation Probe',
      status: 'pending',
    });
  });

  after(async () => {
    db.prepare('DELETE FROM alarms WHERE id = ?').run(id);
    await app.close();
  });

  it('refuses to let a client set "missed" (system-set only, spec §5)', async () => {
    const response = await app.inject({
      method: 'PATCH',
      url: `/api/alarms/${id}`,
      payload: { status: 'missed' },
    });
    assert.strictEqual(response.statusCode, 400);
    // And it must not have been written anyway.
    assert.strictEqual(AlarmRepo.getById(id)?.status, 'pending');
  });

  it('refuses an arbitrary status string', async () => {
    const response = await app.inject({
      method: 'PATCH',
      url: `/api/alarms/${id}`,
      payload: { status: 'banana' },
    });
    assert.strictEqual(response.statusCode, 400);
    assert.strictEqual(AlarmRepo.getById(id)?.status, 'pending');
  });

  it('still accepts a legitimate status', async () => {
    const response = await app.inject({
      method: 'PATCH',
      url: `/api/alarms/${id}`,
      payload: { status: 'disabled' },
    });
    assert.strictEqual(response.statusCode, 200);
    assert.strictEqual(AlarmRepo.getById(id)?.status, 'disabled');
  });

  it('leaves a patch without a status untouched', async () => {
    const response = await app.inject({
      method: 'PATCH',
      url: `/api/alarms/${id}`,
      payload: { label: 'Renamed Probe' },
    });
    assert.strictEqual(response.statusCode, 200);
    assert.strictEqual(AlarmRepo.getById(id)?.label, 'Renamed Probe');
    assert.strictEqual(AlarmRepo.getById(id)?.status, 'disabled');
  });
});
