/**
 * Error hierarchy for the Klaxon client.
 *
 * The client always surfaces the server's own `error`/`message` string rather
 * than replacing it with a generic message — the backend's validation messages
 * are specific and useful.
 */

export class RemoteAlarmError extends Error {
  /** HTTP status, if the request reached the server. */
  status?: number;
  /** The server's `{ error }` (or Fastify's `{ message }`) body, verbatim. */
  serverMessage?: string;

  constructor(
    message: string,
    options: { status?: number; serverMessage?: string } = {}
  ) {
    super(message);
    this.name = "RemoteAlarmError";
    this.status = options.status;
    this.serverMessage = options.serverMessage;
    // Keep a clean prototype chain when transpiled.
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

/** Unreachable host, DNS failure, or timeout. */
export class RemoteAlarmNetworkError extends RemoteAlarmError {
  constructor(
    message: string,
    options: { status?: number; serverMessage?: string } = {}
  ) {
    super(message, options);
    this.name = "RemoteAlarmNetworkError";
  }
}

/** 404 — unknown resource (or unmatched route). */
export class RemoteAlarmNotFoundError extends RemoteAlarmError {
  constructor(
    message: string,
    options: { status?: number; serverMessage?: string } = {}
  ) {
    super(message, options);
    this.name = "RemoteAlarmNotFoundError";
  }
}

/** Why a natural-language time input was refused. */
export type RefusalReason = "unparseable" | "already_passed";

/** Invalid natural-language time input. Carries the offending token in `token`. */
export class TimeParseError extends Error {
  token?: string;
  reason: RefusalReason;

  constructor(message: string, token?: string, reason: RefusalReason = "unparseable") {
    super(message);
    this.name = "TimeParseError";
    this.token = token;
    this.reason = reason;
    Object.setPrototypeOf(this, new.target.prototype);
  }
}
