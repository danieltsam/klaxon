import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import dotenv from 'dotenv';
import { resolveGcalConfig } from '../src/gcal-config.js';

/**
 * Tripwire for a bug that shipped once: the test suite resolved a LIVE Google
 * config and created 20 stray "Remote Alarms" calendars in a real account.
 *
 * Two things must hold, and this file pins both:
 *   1. dotenv must not arm gcal inside a test process.
 *   2. The test script must set GCAL_ENABLED=false, which dotenv will not
 *      override (dotenv never overrides an existing environment variable).
 *
 * If someone removes GCAL_ENABLED=false from backend/package.json's test
 * script while real credentials sit in .env, the resolver becomes live again
 * and these assertions fail -- before another calendar is created.
 */
describe('test-suite hermeticity (no live Google access)', () => {
  it('dotenv in a test process must not resolve a live gcal config', () => {
    // Mimic what src/server.ts does at module load.
    process.env.NODE_ENV = 'test';
    dotenv.config();

    const { config, reason } = resolveGcalConfig();

    assert.strictEqual(
      config,
      null,
      'gcal resolved a LIVE config under NODE_ENV=test. The suite can now create real ' +
        'Google calendars. Ensure backend/package.json sets GCAL_ENABLED=false for tests.'
    );
    // Unconfigured by policy is not an error, so there must be no reason string.
    assert.strictEqual(reason, null);
  });

  it('the guard is enforced at the config layer, not only the call site', () => {
    assert.strictEqual(process.env.NODE_ENV, 'test');
    assert.strictEqual(
      process.env.GCAL_ENABLED,
      'false',
      'the test script must set GCAL_ENABLED=false so a developer .env cannot arm live calls'
    );
  });
});
