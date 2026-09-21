import { readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { google } from 'googleapis';
import { GcalApiError, type GcalTransport } from './gcal.js';
import type { GcalConfig } from './gcal-config.js';
import type { GoogleEvent } from './gcal-events.js';

/**
 * googleapis surfaces HTTP failures as an error carrying `response.status`.
 * An existing `GcalApiError` is returned untouched: re-wrapping it would read
 * a non-existent `response.status` (yielding 0) and double-prefix the message,
 * destroying the status that `classifyGcalError` relies on.
 */
export function toApiError(err: unknown, context: string): GcalApiError {
  if (err instanceof GcalApiError) return err;
  const status = (err as { response?: { status?: number } })?.response?.status ?? 0;
  const message = err instanceof Error ? err.message : String(err);
  return new GcalApiError(`${context}: ${message}`, status);
}

export function createGcalTransport(config: GcalConfig): GcalTransport {
  const oauth2 = new google.auth.OAuth2(config.clientId, config.clientSecret);
  const tokens = JSON.parse(readFileSync(config.tokenPath, 'utf8'));
  oauth2.setCredentials(tokens);

  // Google rotates access tokens periodically; persist whatever comes back so
  // the refresh token survives a restart.
  oauth2.on('tokens', (fresh) => {
    try {
      writeFileSync(config.tokenPath, JSON.stringify({ ...tokens, ...fresh }, null, 2), 'utf8');
      chmodSync(config.tokenPath, 0o600);
    } catch (err) {
      console.error('[gcal] failed to persist refreshed token:', err);
    }
  });

  const calendar = google.calendar({ version: 'v3', auth: oauth2 });

  return {
    async ensureSecondaryCalendar(summary, timeZone) {
      try {
        const res = await calendar.calendars.insert({ requestBody: { summary, timeZone } });
        const id = res.data.id;
        if (!id) throw new GcalApiError('calendars.insert returned no id', 500);
        return id;
      } catch (err) {
        throw toApiError(err, 'calendars.insert');
      }
    },

    async insertEvent(calendarId, event) {
      try {
        await calendar.events.insert({ calendarId, sendUpdates: 'none', requestBody: event });
      } catch (err) {
        throw toApiError(err, 'events.insert');
      }
    },

    async updateEvent(calendarId, event) {
      try {
        // events.update is a full replace, so `event` must be the complete
        // object — which toGoogleEvent always produces.
        await calendar.events.update({
          calendarId,
          eventId: event.id,
          sendUpdates: 'none',
          requestBody: event,
        });
      } catch (err) {
        throw toApiError(err, 'events.update');
      }
    },

    async deleteEvent(calendarId, eventId) {
      try {
        await calendar.events.delete({ calendarId, eventId, sendUpdates: 'none' });
      } catch (err) {
        throw toApiError(err, 'events.delete');
      }
    },

    async listEventIds(calendarId) {
      try {
        const res = await calendar.events.list({ calendarId, maxResults: 2500 });
        return (res.data.items ?? [])
          .map((item) => item.id)
          .filter((id): id is string => typeof id === 'string');
      } catch (err) {
        throw toApiError(err, 'events.list');
      }
    },
  };
}
