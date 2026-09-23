import type { AlarmRecord } from './db.js';

/** Alarms are shown in the calendar as a 15-minute block, matching the ICS feed. */
export const GCAL_EVENT_DURATION_MINUTES = 15;

/** 1=Mon .. 7=Sun, matching the backend's repeat_days encoding. */
const WEEKDAY_CODES = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'] as const;

const EVENT_ID_PATTERN = /^[0-9a-v]{5,1024}$/;

export interface GoogleEventDateTime {
  dateTime: string;
  timeZone: string;
}

export interface GoogleEvent {
  id: string;
  summary: string;
  description?: string;
  start: GoogleEventDateTime;
  end: GoogleEventDateTime;
  recurrence?: string[];
  reminders: { useDefault: boolean };
  transparency: 'transparent' | 'opaque';
  status: 'confirmed';
}

export type GcalAction = 'upsert' | 'delete' | 'leave';

/**
 * Google accepts a client-supplied event id drawn from base32hex ([0-9a-v]).
 * A hyphen-stripped UUID is 32 chars of [0-9a-f], a strict subset, so it is
 * valid without re-encoding. This is what removes the need for a mapping
 * column (spec §3.3).
 */
export function deriveEventId(alarmId: string): string {
  const id = alarmId.toLowerCase().replace(/-/g, '');
  if (!EVENT_ID_PATTERN.test(id)) {
    throw new Error(`cannot derive a Google event id from "${alarmId}"`);
  }
  return id;
}

export function recurrenceRule(
  repeatDays?: string | null,
  recurrenceIntervalWeeks?: number | null
): string[] | undefined {
  if (!repeatDays) return undefined;
  const days = repeatDays
    .split(',')
    .map((part) => parseInt(part.trim(), 10))
    .filter((day) => Number.isInteger(day) && day >= 1 && day <= 7);
  if (days.length === 0) return undefined;
  const unique = [...new Set(days)].sort((a, b) => a - b);
  // Fortnightly (and wider) recurrences carry a FREQ=WEEKLY;INTERVAL=N clause.
  const interval = recurrenceIntervalWeeks ?? 1;
  const intervalClause = interval > 1 ? `;INTERVAL=${interval}` : '';
  // DTSTART must not appear here; Google infers it from `start`.
  return [`RRULE:FREQ=WEEKLY${intervalClause};BYDAY=${unique.map((day) => WEEKDAY_CODES[day - 1]).join(',')}`];
}

/**
 * Render a UTC instant as wall-clock time in `timeZone`, with that zone's
 * offset for that specific instant (so DST is handled per-date).
 */
export function zonedDateTime(
  instantIso: string,
  timeZone: string,
  addMinutes = 0
): GoogleEventDateTime {
  const instant = new Date(new Date(instantIso).getTime() + addMinutes * 60_000);
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    timeZoneName: 'longOffset',
  }).formatToParts(instant);
  const value = (type: string) => parts.find((part) => part.type === type)?.value ?? '';
  const rawOffset = parts.find((part) => part.type === 'timeZoneName')?.value ?? 'GMT+00:00';
  const offset = rawOffset === 'GMT' ? '+00:00' : rawOffset.replace('GMT', '');
  return {
    dateTime: `${value('year')}-${value('month')}-${value('day')}T${value('hour')}:${value('minute')}:${value('second')}${offset}`,
    timeZone,
  };
}

function describe(alarm: AlarmRecord): string {
  const lines = [`Alarm ID: ${alarm.id}`];
  if (alarm.sound_tone) lines.push(`Tone: ${alarm.sound_tone}`);
  if (alarm.ramp_seconds !== undefined) lines.push(`Ramp: ${alarm.ramp_seconds}s`);
  if (alarm.repeat_days) lines.push(`Repeat: ${alarm.repeat_days}`);
  return `Managed by Remote Alarm\n${lines.join('\n')}`;
}

export function toGoogleEvent(alarm: AlarmRecord, timeZone: string): GoogleEvent {
  const event: GoogleEvent = {
    id: deriveEventId(alarm.id),
    summary: alarm.label,
    description: describe(alarm),
    start: zonedDateTime(alarm.target_time, timeZone),
    end: zonedDateTime(alarm.target_time, timeZone, GCAL_EVENT_DURATION_MINUTES),
    reminders: { useDefault: false },
    transparency: 'transparent',
    status: 'confirmed',
  };
  const recurrence = recurrenceRule(alarm.repeat_days, alarm.recurrence_interval_weeks);
  if (recurrence) event.recurrence = recurrence;
  return event;
}

export function actionForStatus(status: AlarmRecord['status']): GcalAction {
  switch (status) {
    case 'pending':
    case 'ringing':
    case 'snoozed':
      return 'upsert';
    case 'canceled':
    case 'disabled':
      return 'delete';
    case 'dismissed':
      // It already rang. A past calendar entry is history, not an error.
      return 'leave';
    default:
      return 'leave';
  }
}
