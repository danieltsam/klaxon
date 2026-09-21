import { SettingsRepo, type AlarmRecord } from './db.js';
import { actionForStatus, deriveEventId, toGoogleEvent, type GoogleEvent } from './gcal-events.js';
import { DEFAULT_CALENDAR_SUMMARY, type GcalConfig } from './gcal-config.js';

const CALENDAR_ID_KEY = 'gcal_calendar_id';

/** An error carrying an HTTP status from the Calendar API. */
export class GcalApiError extends Error {
  readonly status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = 'GcalApiError';
    this.status = status;
  }
}

export function isStatus(err: unknown, status: number): boolean {
  return err instanceof GcalApiError && err.status === status;
}

export type GcalErrorKind = 'auth' | 'rate_limit' | 'permanent' | 'transient' | 'unknown';

export function classifyGcalError(err: unknown): GcalErrorKind {
  const message = err instanceof Error ? err.message : String(err);
  if (/invalid_grant/i.test(message)) return 'auth';
  if (err instanceof GcalApiError) {
    if (err.status === 401) return 'auth';
    if (err.status === 429) return 'rate_limit';
    if (err.status === 403) return /rate|quota/i.test(message) ? 'rate_limit' : 'auth';
    if (err.status === 400) return 'permanent'; // documented as not retryable
    if (err.status >= 500) return 'transient';
  }
  if (/fetch failed|ECONNRESET|ETIMEDOUT|ENOTFOUND/i.test(message)) return 'transient';
  return 'unknown';
}

/** Low-level Google calls. Injected so tests never touch the network. */
export interface GcalTransport {
  ensureSecondaryCalendar(summary: string, timeZone: string): Promise<string>;
  insertEvent(calendarId: string, event: GoogleEvent): Promise<void>;
  updateEvent(calendarId: string, event: GoogleEvent): Promise<void>;
  deleteEvent(calendarId: string, eventId: string): Promise<void>;
  listEventIds(calendarId: string): Promise<string[]>;
}

/**
 * Transport used while unconfigured. `GcalMirror` returns early whenever
 * `config` is null, so no method here is ever reached — it exists only so the
 * mirror can be constructed in a supported state without a Google client.
 */
export function unconfiguredTransport(): GcalTransport {
  const fail = (): never => {
    throw new Error('gcal transport used while unconfigured');
  };
  return {
    ensureSecondaryCalendar: async () => fail(),
    insertEvent: async () => fail(),
    updateEvent: async () => fail(),
    deleteEvent: async () => fail(),
    listEventIds: async () => fail(),
  };
}

export interface GcalStatus {
  configured: boolean;
  ok: boolean;
  calendar_id: string | null;
  last_sync_at: string | null;
  last_error: string | null;
  last_error_at: string | null;
  reason: string | null;
}

export class GcalMirror {
  private readonly config: GcalConfig | null;
  private readonly transport: GcalTransport;
  private readonly reasonText: string | null;
  private calendarIdCache: string | null = null;
  private lastSyncAt: string | null = null;
  private lastError: string | null = null;
  private lastErrorAt: string | null = null;

  constructor(options: {
    config: GcalConfig | null;
    transport: GcalTransport;
    reason?: string | null;
  }) {
    this.config = options.config;
    this.transport = options.transport;
    this.reasonText = options.reason ?? null;
  }

  isConfigured(): boolean {
    return this.config !== null;
  }

  configReason(): string | null {
    return this.reasonText;
  }

  timeZone(): string {
    if (!this.config) throw new Error('gcal is not configured');
    return this.config.timeZone;
  }

  clearCalendarCache(): void {
    this.calendarIdCache = null;
    SettingsRepo.deleteRaw(CALENDAR_ID_KEY);
  }

  async ensureCalendar(): Promise<string> {
    if (this.calendarIdCache) return this.calendarIdCache;
    const stored = SettingsRepo.getRaw(CALENDAR_ID_KEY);
    if (stored) {
      this.calendarIdCache = stored;
      return stored;
    }
    if (!this.config) throw new Error('gcal is not configured');
    const created = await this.transport.ensureSecondaryCalendar(
      DEFAULT_CALENDAR_SUMMARY,
      this.config.timeZone
    );
    SettingsRepo.setRaw(CALENDAR_ID_KEY, created);
    this.calendarIdCache = created;
    return created;
  }

  async listEventIds(): Promise<string[]> {
    const calendarId = await this.ensureCalendar();
    return this.transport.listEventIds(calendarId);
  }

  /**
   * Idempotent upsert: insert, and on 409 fall back to update; on 404 from
   * that update, fall back to insert again (the user deleted it in Google).
   */
  private async upsertEvent(calendarId: string, event: GoogleEvent): Promise<void> {
    try {
      await this.transport.insertEvent(calendarId, event);
      return;
    } catch (err) {
      if (!isStatus(err, 409)) throw err;
    }
    try {
      await this.transport.updateEvent(calendarId, event);
    } catch (err) {
      if (!isStatus(err, 404)) throw err;
      // The user deleted the event in Google, so recreate it. A 409 on the
      // retry means a concurrent writer recreated it first: both reach the
      // desired end state (the event exists), so treat that as success.
      try {
        await this.transport.insertEvent(calendarId, event);
      } catch (retryErr) {
        if (!isStatus(retryErr, 409)) throw retryErr;
      }
    }
  }

  private async removeEvent(calendarId: string, eventId: string): Promise<void> {
    try {
      await this.transport.deleteEvent(calendarId, eventId);
    } catch (err) {
      if (isStatus(err, 404) || isStatus(err, 410)) return; // already gone
      throw err;
    }
  }

  /** Delete an event by id. Used by the reconciler for orphans (Task 5). */
  async deleteEventById(eventId: string): Promise<void> {
    if (!this.config) return;
    const calendarId = await this.ensureCalendar();
    await this.removeEvent(calendarId, eventId);
  }

  /**
   * Mirror one alarm. Throws on failure so the caller can time-box and record
   * it; callers in request paths MUST catch (see mirrorSafely in server.ts).
   */
  async syncAlarm(alarm: AlarmRecord): Promise<void> {
    if (!this.config) return;

    let eventId: string;
    try {
      eventId = deriveEventId(alarm.id);
    } catch (err) {
      // A malformed row must never break the caller.
      this.recordError(err);
      return;
    }

    try {
      const action = actionForStatus(alarm.status);
      if (action === 'leave') return;
      const calendarId = await this.ensureCalendar();
      if (action === 'delete') {
        await this.removeEvent(calendarId, eventId);
      } else {
        await this.upsertEvent(calendarId, toGoogleEvent(alarm, this.config.timeZone));
      }
      this.recordSuccess();
    } catch (err) {
      this.recordError(err);
      throw err;
    }
  }

  private recordSuccess(): void {
    this.lastSyncAt = new Date().toISOString();
    this.lastError = null;
    this.lastErrorAt = null;
  }

  private recordError(err: unknown): void {
    this.lastError = err instanceof Error ? err.message : String(err);
    this.lastErrorAt = new Date().toISOString();
  }

  status(): GcalStatus {
    return {
      configured: this.isConfigured(),
      ok: this.isConfigured() && this.lastError === null,
      calendar_id: this.calendarIdCache ?? SettingsRepo.getRaw(CALENDAR_ID_KEY),
      last_sync_at: this.lastSyncAt,
      last_error: this.lastError,
      last_error_at: this.lastErrorAt,
      reason: this.reasonText,
    };
  }
}
