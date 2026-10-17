import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { buildFcmMessage, validateFcmPayload, FCM_TTL_MS, shouldPruneToken, withRetry } from '../src/fcm.js';

describe('buildFcmMessage', () => {
  it('sets high priority, a 1h TTL, and a per-alarm collapse key', () => {
    const msg: any = buildFcmMessage('CREATE', { id: 'abc', label: 'gym' }, 'tok-1');
    assert.equal(msg.token, 'tok-1');
    assert.equal(msg.android.priority, 'high');
    assert.equal(msg.android.ttl, FCM_TTL_MS);
    assert.equal(msg.android.collapseKey, 'alarm:abc');
    assert.equal(msg.data.action, 'CREATE');
    assert.equal(msg.data.id, 'abc');
  });

  it('rejects a payload whose JSON exceeds 4096 bytes', () => {
    const big = validateFcmPayload({ id: 'abc', label: 'x'.repeat(5000) });
    assert.equal(big.ok, false);
    assert.match((big as any).error, /4096/);
  });

  it('accepts a normal payload', () => {
    assert.deepEqual(validateFcmPayload({ id: 'abc', label: 'gym' }), { ok: true });
  });
});

describe('shouldPruneToken', () => {
  it('prunes only a genuinely dead token, not a payload error', () => {
    assert.equal(shouldPruneToken('messaging/registration-token-not-registered'), true);
    assert.equal(shouldPruneToken('messaging/invalid-argument'), false);
    assert.equal(shouldPruneToken(undefined), false);
  });
});

describe('withRetry', () => {
  it('retries a transient error and eventually succeeds', async () => {
    let calls = 0;
    const slept: number[] = [];
    const out = await withRetry(
      async () => { calls++; if (calls < 3) throw Object.assign(new Error('boom'), { code: 'messaging/internal-error' }); return 'ok'; },
      { attempts: 3, baseDelayMs: 10, sleep: async (ms) => { slept.push(ms); } },
    );
    assert.equal(out, 'ok');
    assert.equal(calls, 3);
    assert.deepEqual(slept, [10, 20]);
  });

  it('does not retry a permanent error', async () => {
    let calls = 0;
    await assert.rejects(() => withRetry(
      async () => { calls++; throw Object.assign(new Error('x'), { code: 'messaging/registration-token-not-registered' }); },
      { attempts: 3, sleep: async () => {} },
    ));
    assert.equal(calls, 1);
  });
});
