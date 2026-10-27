import { AlarmRepo } from './db.js';
import { deriveEventId } from './gcal-events.js';
import type { GcalMirror } from './gcal.js';

export interface ReconcileResult {
  created: number;
  deleted: number;
  failed: number;
}

/**
 * Repair drift between active alarms and the Klaxon calendar.
 *
 * Klaxon is the single source of truth: events with no matching active
 * alarm are deleted, and active alarms with no event are created (spec §9.3).
 * A full list is used deliberately rather than syncToken — a personal
 * calendar is a single cheap call (spec §9.4).
 */
export async function reconcile(mirror: GcalMirror): Promise<ReconcileResult> {
  const result: ReconcileResult = { created: 0, deleted: 0, failed: 0 };
  if (!mirror.isConfigured()) return result;

  const active = AlarmRepo.getAll('active');
  // Every non-cancelled row keeps its event. A missed or dismissed alarm is
  // history the owner looks for, and the sweep annotates the missed event —
  // deleting it 15 minutes later erased exactly that record.
  const kept = AlarmRepo.getAll('all');

  // Alarms whose id we cannot map are skipped, not fatal.
  const expected = new Map<string, string>(); // eventId -> alarmId
  for (const alarm of kept) {
    try {
      expected.set(deriveEventId(alarm.id), alarm.id);
    } catch {
      // Malformed id: nothing to reconcile it against.
    }
  }

  let existing: string[];
  try {
    existing = await mirror.listEventIds();
  } catch (err) {
    // Record it on the mirror too. Swallowing the error here would leave
    // status() claiming all is well — so a dead credential during a periodic
    // reconcile would be completely invisible (needs_reauth stays false).
    mirror.noteError(err);
    result.failed += 1;
    return result;
  }

  const existingSet = new Set(existing);

  for (const alarm of active) {
    let eventId: string;
    try {
      eventId = deriveEventId(alarm.id);
    } catch {
      continue;
    }
    if (existingSet.has(eventId)) continue;
    try {
      await mirror.syncAlarm(alarm);
      result.created += 1;
    } catch {
      result.failed += 1;
    }
  }

  for (const eventId of existing) {
    if (expected.has(eventId)) continue;
    try {
      await mirror.deleteEventById(eventId);
      result.deleted += 1;
    } catch {
      result.failed += 1;
    }
  }

  return result;
}
