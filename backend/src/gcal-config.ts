/**
 * Config resolution for the Google Calendar mirror.
 *
 * GCAL_TIMEZONE is the PHONE's IANA zone, not the server's. docker-compose
 * sets no TZ, so the container resolves to UTC; inferring would silently pick
 * the wrong recurrence-expansion zone (spec §7.3). We therefore require it
 * and disable the subsystem loudly if it is missing or invalid.
 */

export const GCAL_SCOPE = 'https://www.googleapis.com/auth/calendar.app.created';

export const DEFAULT_TOKEN_PATH = './google-oauth-token.json';
export const DEFAULT_CALENDAR_SUMMARY = 'Klaxon';

export interface GcalConfig {
  clientId: string;
  clientSecret: string;
  tokenPath: string;
  timeZone: string;
}

export function isValidTimeZone(timeZone: string): boolean {
  if (!timeZone) return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone });
    return true;
  } catch {
    return false;
  }
}

export function resolveGcalConfig(env: NodeJS.ProcessEnv = process.env): {
  config: GcalConfig | null;
  reason: string | null;
} {
  // Absent/false means "deliberately off" — not an error, and no warning.
  if (env.GCAL_ENABLED !== 'true') {
    return { config: null, reason: null };
  }

  const missing = ['GOOGLE_OAUTH_CLIENT_ID', 'GOOGLE_OAUTH_CLIENT_SECRET'].filter(
    (key) => !env[key]
  );
  if (missing.length > 0) {
    return { config: null, reason: `missing required env: ${missing.join(', ')}` };
  }

  const timeZone = env.GCAL_TIMEZONE ?? '';
  if (!timeZone) {
    return {
      config: null,
      reason: "GCAL_TIMEZONE is required (the phone's IANA zone); refusing to guess",
    };
  }
  if (!isValidTimeZone(timeZone)) {
    return { config: null, reason: `GCAL_TIMEZONE "${timeZone}" is not a valid IANA zone` };
  }

  return {
    config: {
      clientId: env.GOOGLE_OAUTH_CLIENT_ID as string,
      clientSecret: env.GOOGLE_OAUTH_CLIENT_SECRET as string,
      tokenPath: env.GOOGLE_OAUTH_TOKEN_PATH || DEFAULT_TOKEN_PATH,
      timeZone,
    },
    reason: null,
  };
}
