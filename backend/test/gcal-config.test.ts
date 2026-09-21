import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { isValidTimeZone, resolveGcalConfig } from '../src/gcal-config.js';

const base = {
  GCAL_ENABLED: 'true',
  GOOGLE_OAUTH_CLIENT_ID: 'client-id',
  GOOGLE_OAUTH_CLIENT_SECRET: 'client-secret',
  GCAL_TIMEZONE: 'Australia/Brisbane',
};

describe('isValidTimeZone', () => {
  it('accepts real IANA zones', () => {
    assert.ok(isValidTimeZone('Australia/Brisbane'));
    assert.ok(isValidTimeZone('UTC'));
  });

  it('rejects nonsense', () => {
    assert.ok(!isValidTimeZone('Mars/Olympus'));
    assert.ok(!isValidTimeZone(''));
  });
});

describe('resolveGcalConfig', () => {
  it('returns a config when everything is present', () => {
    const { config, reason } = resolveGcalConfig({ ...base });
    assert.strictEqual(reason, null);
    assert.strictEqual(config?.timeZone, 'Australia/Brisbane');
    assert.strictEqual(config?.clientId, 'client-id');
  });

  it('is a silent no-op when not enabled', () => {
    const { config, reason } = resolveGcalConfig({});
    assert.strictEqual(config, null);
    assert.strictEqual(reason, null);
  });

  it('refuses to guess the timezone', () => {
    const env = { ...base, GCAL_TIMEZONE: undefined } as NodeJS.ProcessEnv;
    const { config, reason } = resolveGcalConfig(env);
    assert.strictEqual(config, null);
    assert.match(reason ?? '', /GCAL_TIMEZONE is required/i);
  });

  it('rejects an invalid timezone rather than falling back', () => {
    const { config, reason } = resolveGcalConfig({ ...base, GCAL_TIMEZONE: 'Mars/Olympus' });
    assert.strictEqual(config, null);
    assert.match(reason ?? '', /not a valid IANA zone/i);
  });

  it('reports missing credentials', () => {
    const env = { ...base, GOOGLE_OAUTH_CLIENT_ID: undefined } as NodeJS.ProcessEnv;
    const { config, reason } = resolveGcalConfig(env);
    assert.strictEqual(config, null);
    assert.match(reason ?? '', /GOOGLE_OAUTH_CLIENT_ID/);
  });

  it('defaults the token path', () => {
    const { config } = resolveGcalConfig({ ...base });
    assert.strictEqual(config?.tokenPath, './google-oauth-token.json');
  });
});
