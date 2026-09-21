import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { toApiError } from '../src/gcal-google.js';
import { GcalApiError } from '../src/gcal.js';

describe('toApiError', () => {
  it('returns an existing GcalApiError unchanged, preserving its status', () => {
    const original = new GcalApiError('calendars.insert returned no id', 500);
    assert.strictEqual(toApiError(original, 'calendars.insert'), original);
    assert.strictEqual(toApiError(original, 'calendars.insert').status, 500);
  });

  it('does not double-prefix the message of an existing GcalApiError', () => {
    const original = new GcalApiError('boom', 503);
    assert.strictEqual(toApiError(original, 'events.insert').message, 'boom');
  });

  it('wraps a raw googleapis error with the response status and context', () => {
    const raw = Object.assign(new Error('backend unavailable'), {
      response: { status: 503 },
    });
    const wrapped = toApiError(raw, 'events.insert');
    assert.ok(wrapped instanceof GcalApiError);
    assert.strictEqual(wrapped.status, 503);
    assert.strictEqual(wrapped.message, 'events.insert: backend unavailable');
  });
});
