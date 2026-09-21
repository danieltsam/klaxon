/**
 * CLI error types and exit-code mapping (spec §7.4).
 *
 *   0 ok · 1 usage/parse · 2 network · 3 API · 4 not found
 */

import {
  RemoteAlarmError,
  RemoteAlarmNetworkError,
  RemoteAlarmNotFoundError,
  TimeParseError,
} from "@remotealarm/core";

/** Bad flags / missing arguments / unparseable time. Always exit 1. */
export class UsageError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UsageError";
    Object.setPrototypeOf(this, UsageError.prototype);
  }
}

/**
 * Map any thrown error onto a documented exit code.
 *
 * Order matters: the network/not-found subclasses must be checked before the
 * generic `RemoteAlarmError`.
 */
export function exitCodeForError(err: unknown): number {
  if (err instanceof UsageError || err instanceof TimeParseError) return 1;
  if (err instanceof RemoteAlarmNotFoundError) return 4;
  if (err instanceof RemoteAlarmNetworkError) return 2;
  if (err instanceof RemoteAlarmError) return 3;
  // Anything unexpected is a usage/programming failure, not a network one.
  return 1;
}
