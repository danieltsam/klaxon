import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { buildFcmMessage, validateFcmPayload, FCM_TTL_MS } from '../src/fcm.js';

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
