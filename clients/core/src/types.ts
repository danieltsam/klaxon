/**
 * Wire + domain types for the Remote Alarm backend.
 *
 * Wire-shape rules (verified against the live backend):
 * - `repeat_days` is overloaded on the wire: `string | number[]` on input, but
 *   always a comma-joined string on output, and sometimes `null`.
 * - `GET /api/alarms` returns a bare JSON array, not a wrapper.
 * - Optional columns are returned explicitly as `null` (not omitted).
 */

export type AlarmStatus =
  | "pending"
  | "ringing"
  | "dismissed"
  | "snoozed"
  | "canceled"
  | "disabled"
  /** System-set: the time passed and it never rang, so it will not ring. */
  | "missed";

/**
 * The closed vocabulary of `missed_reason` (spec §7). Both producers — the
 * backend sweep and the device report — use one of these six values.
 */
export type MissedReason =
  | "no_device_registered"
  | "delivery_failed"
  | "dispatched_not_reported"
  | "device_reported_stale"
  | "device_reported_failed"
  | "unknown";

export type SoundTone = "alarm" | "chime" | "digital";

/** 1 = Monday … 7 = Sunday (ISO-8601 weekday numbering). */
export type Weekday = 1 | 2 | 3 | 4 | 5 | 6 | 7;

export interface Alarm {
  id: string;
  /** ISO-8601 UTC, exactly as returned by the server. Derive local time with `toLocalDate`. */
  target_time: string;
  label: string;
  description?: string;
  status: AlarmStatus;
  /** DECODED — never the raw comma-string. */
  repeat_days?: Weekday[];
  sound_tone?: SoundTone;
  ramp_seconds?: number;
  created_at?: string;
  /** ISO-8601 UTC — when the alarm was declared missed. */
  missed_at?: string;
  /**
   * Why the alarm was missed. The six `MissedReason` values are the closed
   * vocabulary from spec §7. The open tail admits a value a newer backend adds
   * without dropping it (auditability) or crashing a client; `formatMissedReason`
   * renders any unrecognised value from its raw token.
   */
  missed_reason?: MissedReason | (string & {});
}

/**
 * Create accepts EXACTLY ONE time input:
 *  - `when` — natural language, parsed by core; or
 *  - `targetTime` — an absolute LOCAL wall-clock instant, used verbatim.
 *
 * Supplying neither, or both, is a compile-time error.
 */
export type CreateAlarmInput = {
  label: string;
  description?: string;
  repeat_days?: Weekday[];
  sound_tone?: SoundTone;
  ramp_seconds?: number;
} & (
  | { when: string; targetTime?: never }
  | { targetTime: Date; when?: never }
);

export interface FcmDispatch {
  sent: number;
  failed: number;
}

export interface AlarmMutationResult {
  alarm: Alarm;
  /** Absent for some transitions — see spec §5.4. Never fold into a success boolean. */
  dispatch?: FcmDispatch;
}

/**
 * `POST /api/alarms/:id/state` accepts a strict subset — `canceled` is rejected
 * (400), and the system-set `missed` is rejected the same way. A client can
 * never declare its own alarm missed.
 */
export type SetStateStatus = Exclude<AlarmStatus, "canceled" | "missed">;

export interface UpdateAlarmInput {
  /** Natural language; re-parsed by core. At most one of `when`/`targetTime`. */
  when?: string;
  /**
   * Absolute LOCAL wall-clock instant, used verbatim (no parsing).
   * At most one of `when`/`targetTime`; supplying both is rejected at runtime.
   */
  targetTime?: Date;
  label?: string;
  description?: string;
  repeat_days?: Weekday[];
  sound_tone?: SoundTone;
  ramp_seconds?: number;
  status?: SetStateStatus;
}

export interface Health {
  status: "ok";
  timestamp: string;
}

export interface DeviceStatus {
  token_masked: string;
  device_name: string;
  battery_level: number | null;
  is_charging: boolean;
  /** SQLite `datetime('now')`, NOT ISO — do not `Date.parse` blindly. */
  updated_at: string;
}

export interface Settings {
  sound_tone: SoundTone;
  /** Narrowed to `0|15|30|60` on write only. */
  ramp_seconds: number;
  date_format: "dd/mm/yyyy" | "mm/dd/yyyy" | "yyyy-mm-dd";
  time_format: "24h" | "12h";
}

/** Injectable transport seam so contract tests need no network. */
export type FetchLike = typeof fetch;

export interface TimeoutConfig {
  health: number;
  read: number;
  write: number;
}
