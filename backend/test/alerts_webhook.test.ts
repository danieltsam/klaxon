import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { formatWebhookAlert, sendWebhookAlert } from '../src/alerts.js';

describe('formatWebhookAlert', () => {
  const alert = { title: 'Delivery unhealthy', body: 'no_registered_devices' };
  it('shapes a Discord payload', () => {
    assert.deepEqual(JSON.parse(formatWebhookAlert('discord', alert).body!), { content: 'Delivery unhealthy\nno_registered_devices' });
  });
  it('shapes a Slack payload', () => {
    assert.deepEqual(JSON.parse(formatWebhookAlert('slack', alert).body!), { text: 'Delivery unhealthy\nno_registered_devices' });
  });
  it('shapes a plain JSON payload', () => {
    assert.deepEqual(JSON.parse(formatWebhookAlert('generic', alert).body!), alert);
  });
  it('uses a GET heartbeat for Healthchecks', () => {
    const r = formatWebhookAlert('healthchecks', alert);
    assert.equal(r.method, 'GET');
    assert.equal(r.body, undefined);
  });
});

describe('sendWebhookAlert', () => {
  it('no-ops and returns false when no URL is configured', async () => {
    assert.equal(await sendWebhookAlert('', 'generic', { title: 't', body: 'b' }), false);
  });
});
