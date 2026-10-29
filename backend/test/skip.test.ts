import { describe, it, before, after } from 'node:test';
import assert from 'node:assert';
import { app, buildCreatePayload } from '../src/server.js';
import { db, AlarmRepo, DeviceRepo } from '../src/db.js';

const TOKEN = 'skip-test-token';

async function createAlarm(payload: Record<string, unknown>, label = 'SkipTest alarm') {
  const res = await app.inject({
    method: 'POST',
    url: '/api/alarms',
    payload: { label, ...payload },
  });
  return JSON.parse(res.body);
}

/** A future target already aligned to the minute, as the create route stores it. */
function futureTarget(minutesAhead: number): Date {
  const d = new Date(Date.now() + minutesAhead * 60_000);
  d.setSeconds(0, 0);
  return d;
}

function skip(id: string, payload: Record<string, unknown> = { utc_offset_minutes: 0 }) {
  return app.inject({ method: 'POST', url: `/api/alarms/${id}/skip`, payload });
}

describe('skip and unskip next occurrence', () => {
  before(async () => {
    await app.ready();
    DeviceRepo.upsert(TOKEN);
  });

  after(async () => {
    db.prepare("DELETE FROM alarms WHERE label LIKE 'SkipTest%'").run();
    DeviceRepo.remove(TOKEN);
    await app.close();
  });

  it('advances exactly one occurrence and records what was skipped', async () => {
    const target = futureTarget(60);
    const created = await createAlarm(
      { target_time: target.toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest advance'
    );
    const res = await skip(created.id);
    assert.strictEqual(res.statusCode, 200);
    const data = JSON.parse(res.body);
    assert.strictEqual(new Date(data.target_time).getTime(), target.getTime() + 86_400_000);
    assert.strictEqual(new Date(data.skipped_from).getTime(), target.getTime());
    const row = AlarmRepo.getById(created.id)!;
    assert.strictEqual(row.target_time, data.target_time);
    assert.strictEqual(row.skipped_from, data.skipped_from);
    assert.strictEqual(data.fcm_dispatch.sent, 1);
  });

  it('404s for an unknown alarm', async () => {
    const res = await skip('does-not-exist');
    assert.strictEqual(res.statusCode, 404);
  });

  it('409s for a one-time alarm', async () => {
    const created = await createAlarm(
      { target_time: futureTarget(90).toISOString() },
      'SkipTest one-time'
    );
    const res = await skip(created.id);
    assert.strictEqual(res.statusCode, 409);
    assert.match(JSON.parse(res.body).error, /not recurring|recurring/i);
  });

  it('409s for disabled, snoozed and ringing alarms', async () => {
    const statuses = ['disabled', 'snoozed', 'ringing'] as const;
    for (let i = 0; i < statuses.length; i++) {
      const status = statuses[i];
      const created = await createAlarm(
        {
          target_time: futureTarget(360 + i * 60).toISOString(),
          repeat_days: '1,2,3,4,5,6,7',
        },
        `SkipTest status ${status}`
      );
      const state = await app.inject({
        method: 'POST',
        url: `/api/alarms/${created.id}/state`,
        payload: { status },
      });
      assert.strictEqual(state.statusCode, 200);
      const res = await skip(created.id);
      assert.strictEqual(res.statusCode, 409, `expected 409 for ${status}`);
    }
  });

  it('409s on a second skip while one is pending, leaving the target unchanged', async () => {
    const created = await createAlarm(
      { target_time: futureTarget(120).toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest double'
    );
    const first = await skip(created.id);
    assert.strictEqual(first.statusCode, 200);
    const targetAfterFirst = JSON.parse(first.body).target_time;

    const second = await skip(created.id);
    assert.strictEqual(second.statusCode, 409);
    assert.strictEqual(AlarmRepo.getById(created.id)!.target_time, targetAfterFirst);
  });

  it('rolls a past target to the next future occurrence', async () => {
    const created = await createAlarm(
      { target_time: futureTarget(180).toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest past'
    );
    const past = new Date(Date.now() - 30_000);
    db.prepare('UPDATE alarms SET target_time = ? WHERE id = ?').run(
      past.toISOString(),
      created.id
    );

    const res = await skip(created.id);
    assert.strictEqual(res.statusCode, 200);
    const data = JSON.parse(res.body);
    const skipped = new Date(data.skipped_from);
    assert.ok(skipped.getTime() > past.getTime());
    assert.strictEqual(
      new Date(data.target_time).getTime(),
      skipped.getTime() + 86_400_000
    );

    const row = AlarmRepo.getById(created.id)!;
    assert.strictEqual(row.status, 'pending');
    assert.strictEqual(row.target_time, data.target_time);
  });

  it('applies a skip when no device is registered', async () => {
    const target = futureTarget(240);
    const created = await createAlarm(
      { target_time: target.toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest no device'
    );
    DeviceRepo.remove(TOKEN);
    try {
      const res = await skip(created.id);
      assert.strictEqual(res.statusCode, 200);
      const data = JSON.parse(res.body);
      assert.deepStrictEqual(data.fcm_dispatch, { sent: 0, failed: 0 });
      assert.strictEqual(
        new Date(data.target_time).getTime(),
        target.getTime() + 86_400_000
      );
    } finally {
      DeviceRepo.upsert(TOKEN);
    }
  });

  it('steps a fortnightly alarm by 14 days and stays skip-eligible without repeat_days', async () => {
    const target = futureTarget(300);
    const created = await createAlarm(
      {
        target_time: target.toISOString(),
        repeat_days: '',
        recurrence_interval_weeks: 2,
        recurrence_anchor_date: target.toISOString().slice(0, 10),
      },
      'SkipTest fortnightly skip'
    );
    const res = await skip(created.id);
    assert.strictEqual(res.statusCode, 200);
    const data = JSON.parse(res.body);
    const diff = new Date(data.target_time).getTime() - new Date(data.skipped_from).getTime();
    assert.strictEqual(diff, 14 * 86_400_000);
    assert.strictEqual(
      AlarmRepo.getById(created.id)!.recurrence_anchor_date,
      target.toISOString().slice(0, 10)
    );
  });

  it('builds the create payload with interval and anchor intact', () => {
    const payload = buildCreatePayload({
      id: 'fortnightly-id',
      target_time: '2026-11-13T09:00:00.000Z',
      label: 'SkipTest fortnightly',
      status: 'pending',
      repeat_days: '5',
      recurrence_interval_weeks: 2,
      recurrence_anchor_date: '2026-10-30',
      sound_tone: 'alarm',
      ramp_seconds: 30,
    });
    assert.strictEqual(payload.recurrence_interval_weeks, 2);
    assert.strictEqual(payload.recurrence_anchor_date, '2026-10-30');
    assert.strictEqual(payload.target_time, '2026-11-13T09:00:00.000Z');
    assert.strictEqual(payload.repeat_days, '5');
  });

  it('unskip restores the skipped instant and clears the marker', async () => {
    const target = futureTarget(540);
    const created = await createAlarm(
      { target_time: target.toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest unskip restore'
    );
    const skipped = await skip(created.id);
    assert.strictEqual(skipped.statusCode, 200);

    const res = await app.inject({
      method: 'POST',
      url: `/api/alarms/${created.id}/unskip`,
      payload: {},
    });
    assert.strictEqual(res.statusCode, 200);
    const data = JSON.parse(res.body);
    assert.strictEqual(new Date(data.target_time).getTime(), target.getTime());
    assert.strictEqual(data.skipped_from, null);
    assert.strictEqual(data.status, 'pending');
    assert.strictEqual(data.fcm_dispatch.sent, 1);

    const row = AlarmRepo.getById(created.id)!;
    assert.strictEqual(row.target_time, target.toISOString());
    assert.strictEqual(row.skipped_from, null);
  });

  it('409s unskip when nothing is pending', async () => {
    const created = await createAlarm(
      { target_time: futureTarget(600).toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest unskip nothing'
    );
    const res = await app.inject({
      method: 'POST',
      url: `/api/alarms/${created.id}/unskip`,
      payload: {},
    });
    assert.strictEqual(res.statusCode, 409);
    assert.match(JSON.parse(res.body).error, /no skipped occurrence|nothing/i);
  });

  it('409s unskip when the alarm was disabled after the skip', async () => {
    const created = await createAlarm(
      { target_time: futureTarget(660).toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest unskip disabled'
    );
    const skipped = await skip(created.id);
    assert.strictEqual(skipped.statusCode, 200);
    await app.inject({
      method: 'POST',
      url: `/api/alarms/${created.id}/state`,
      payload: { status: 'disabled' },
    });

    const res = await app.inject({
      method: 'POST',
      url: `/api/alarms/${created.id}/unskip`,
      payload: {},
    });
    assert.strictEqual(res.statusCode, 409);
    assert.strictEqual(AlarmRepo.getById(created.id)!.skipped_from !== null, true);
  });

  it('409s unskip once the skipped instant has passed', async () => {
    const created = await createAlarm(
      { target_time: futureTarget(720).toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest unskip passed'
    );
    const skipped = await skip(created.id);
    assert.strictEqual(skipped.statusCode, 200);
    const pastSkipped = new Date(Date.now() - 60_000).toISOString();
    db.prepare('UPDATE alarms SET skipped_from = ? WHERE id = ?').run(
      pastSkipped,
      created.id
    );

    const res = await app.inject({
      method: 'POST',
      url: `/api/alarms/${created.id}/unskip`,
      payload: {},
    });
    assert.strictEqual(res.statusCode, 409);
    assert.match(JSON.parse(res.body).error, /passed|past/i);
  });

  it('502s unskip and leaves the row untouched when the phone is unreachable', async () => {
    const created = await createAlarm(
      { target_time: futureTarget(780).toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest unskip unreachable'
    );
    const skipped = await skip(created.id);
    assert.strictEqual(skipped.statusCode, 200);
    // A label over the 4096-byte FCM payload limit makes dispatch fail.
    db.prepare('UPDATE alarms SET label = ? WHERE id = ?').run('x'.repeat(5000), created.id);
    const before = AlarmRepo.getById(created.id)!;

    const res = await app.inject({
      method: 'POST',
      url: `/api/alarms/${created.id}/unskip`,
      payload: {},
    });
    assert.strictEqual(res.statusCode, 502);
    const after_ = AlarmRepo.getById(created.id)!;
    assert.strictEqual(after_.target_time, before.target_time);
    assert.strictEqual(after_.skipped_from, before.skipped_from);
  });

  it('PATCH clears a pending skip and keeps the target', async () => {
    const target = futureTarget(840);
    const created = await createAlarm(
      { target_time: target.toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest patch clears'
    );
    const skipped = await skip(created.id);
    assert.strictEqual(skipped.statusCode, 200);
    const targetAfterSkip = JSON.parse(skipped.body).target_time;

    const res = await app.inject({
      method: 'PATCH',
      url: `/api/alarms/${created.id}`,
      payload: { label: 'SkipTest renamed' },
    });
    assert.strictEqual(res.statusCode, 200);
    const data = JSON.parse(res.body);
    assert.strictEqual(data.skipped_from, null);
    assert.strictEqual(data.target_time, targetAfterSkip);
    assert.strictEqual(AlarmRepo.getById(created.id)!.skipped_from, null);
  });

  it('a pending state write that moves the target clears the skip', async () => {
    const target = futureTarget(900);
    const created = await createAlarm(
      { target_time: target.toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest state clears'
    );
    const skipped = await skip(created.id);
    assert.strictEqual(skipped.statusCode, 200);
    const skippedTarget = JSON.parse(skipped.body).target_time;
    const movedTo = new Date(new Date(skippedTarget).getTime() + 86_400_000).toISOString();

    const res = await app.inject({
      method: 'POST',
      url: `/api/alarms/${created.id}/state`,
      payload: { status: 'pending', target_time: movedTo },
    });
    assert.strictEqual(res.statusCode, 200);
    assert.strictEqual(JSON.parse(res.body).target_time, movedTo);

    const row = AlarmRepo.getById(created.id)!;
    assert.strictEqual(row.skipped_from, null);
    assert.strictEqual(row.target_time, movedTo);
  });

  it('exposes skipped_from from GET /api/alarms?view=all', async () => {
    const target = futureTarget(960);
    const created = await createAlarm(
      { target_time: target.toISOString(), repeat_days: '1,2,3,4,5,6,7' },
      'SkipTest exposed'
    );
    const skipped = await skip(created.id);
    assert.strictEqual(skipped.statusCode, 200);
    const skippedFrom = JSON.parse(skipped.body).skipped_from;

    const res = await app.inject({ method: 'GET', url: '/api/alarms?view=all' });
    assert.strictEqual(res.statusCode, 200);
    const rows = JSON.parse(res.body) as Array<{ id: string; skipped_from?: string | null }>;
    const row = rows.find((r) => r.id === created.id);
    assert.ok(row);
    assert.strictEqual(row!.skipped_from, skippedFrom);
  });
});
