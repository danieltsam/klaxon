/**
 * RemoteAlarmClient — the only place that talks to the backend.
 *
 * Normalization rules (spec §5.3) all happen here, at the wire boundary:
 *  - `repeat_days`: `Weekday[]` -> "1,2,3,4,5" out; comma-string -> `Weekday[]` in.
 *  - `target_time`: zero seconds/ms before sending (mirrors `server.ts:150`).
 *  - `Alarm.target_time` stays the raw UTC string as returned.
 *  - `baseUrl` trailing slash stripped once at construction.
 *  - `AbortSignal.timeout()` on every request.
 *
 * Zero runtime dependencies: global `fetch` only.
 */

import {
  RemoteAlarmError,
  RemoteAlarmNetworkError,
  RemoteAlarmNotFoundError,
} from "./errors.js";
import { parseTime } from "./time.js";
import type {
  Alarm,
  AlarmMutationResult,
  CreateAlarmInput,
  DeviceStatus,
  FcmDispatch,
  FetchLike,
  Health,
  SetStateStatus,
  Settings,
  SoundTone,
  TimeoutConfig,
  UpdateAlarmInput,
  Weekday,
} from "./types.js";

export interface RemoteAlarmClientConfig {
  baseUrl: string;
  timeouts?: Partial<TimeoutConfig>;
  fetch?: FetchLike;
  /** Injectable clock (used by `when` parsing). Defaults to the real clock. */
  now?: () => Date;
}

const DEFAULT_TIMEOUTS: TimeoutConfig = {
  health: 4000,
  read: 10000,
  write: 8000,
};

const SOUND_TONES: readonly SoundTone[] = ["alarm", "chime", "digital"];

/** Encode `Weekday[]` to the wire's comma-joined string. */
function encodeRepeatDays(days: Weekday[]): string {
  return days.join(",");
}

/** Decode the wire's overloaded `repeat_days`, discarding out-of-range entries. */
function decodeRepeatDays(value: unknown): Weekday[] | undefined {
  if (value === undefined || value === null) return undefined;
  const parts = Array.isArray(value) ? value.map((v) => String(v)) : String(value).split(",");
  const out: Weekday[] = [];
  for (const part of parts) {
    const n = Number(String(part).trim());
    if (Number.isInteger(n) && n >= 1 && n <= 7) out.push(n as Weekday);
  }
  return out;
}

/** Zero seconds and milliseconds, then emit the UTC wire string. */
function toAlignedIso(date: Date): string {
  const aligned = new Date(date.getTime());
  aligned.setSeconds(0, 0);
  return aligned.toISOString();
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === "number" ? value : undefined;
}

function validateSoundTone(tone: unknown): void {
  if (tone === undefined) return;
  if (typeof tone !== "string" || !SOUND_TONES.includes(tone as SoundTone)) {
    throw new RemoteAlarmError(
      `Invalid sound_tone "${String(tone)}". Must be one of: ${SOUND_TONES.join(", ")}.`
    );
  }
}

function describeFetchError(err: unknown): string {
  if (err instanceof Error) {
    if (err.name === "TimeoutError" || err.name === "AbortError") {
      return "Request to Remote Alarm backend timed out.";
    }
    return `Could not reach Remote Alarm backend: ${err.message}`;
  }
  return `Could not reach Remote Alarm backend: ${String(err)}`;
}

/** Read the server's own message: `{ error }` first, then Fastify's `{ message }`. */
function extractServerMessage(body: unknown): string | undefined {
  if (typeof body !== "object" || body === null) return undefined;
  const record = body as Record<string, unknown>;
  return asString(record.error) ?? asString(record.message);
}

function extractDispatch(body: unknown): FcmDispatch | undefined {
  if (typeof body !== "object" || body === null) return undefined;
  const raw = (body as Record<string, unknown>).fcm_dispatch;
  if (typeof raw !== "object" || raw === null) return undefined;
  const record = raw as Record<string, unknown>;
  if (typeof record.sent !== "number" || typeof record.failed !== "number") return undefined;
  return { sent: record.sent, failed: record.failed };
}

/**
 * Build a domain `Alarm` from a server payload.
 *
 * The live backend returns optional columns explicitly as `null` (not omitted),
 * so every optional field is coerced `null -> undefined`. `null` must never
 * leak into the domain type.
 */
export function normalizeAlarm(payload: Record<string, unknown>): Alarm {
  const alarm: Alarm = {
    id: asString(payload.id) ?? "",
    target_time: asString(payload.target_time) ?? "",
    label: asString(payload.label) ?? "",
    status: (asString(payload.status) ?? "pending") as Alarm["status"],
  };

  const description = asString(payload.description);
  if (description !== undefined) alarm.description = description;

  const repeatDays = decodeRepeatDays(payload.repeat_days);
  if (repeatDays !== undefined) alarm.repeat_days = repeatDays;

  const soundTone = asString(payload.sound_tone);
  if (soundTone !== undefined) alarm.sound_tone = soundTone as SoundTone;

  const rampSeconds = asNumber(payload.ramp_seconds);
  if (rampSeconds !== undefined) alarm.ramp_seconds = rampSeconds;

  const createdAt = asString(payload.created_at);
  if (createdAt !== undefined) alarm.created_at = createdAt;

  return alarm;
}

export class RemoteAlarmClient {
  private readonly baseUrl: string;
  private readonly timeouts: TimeoutConfig;
  private readonly fetchImpl: FetchLike;
  private readonly now: () => Date;

  constructor(config: RemoteAlarmClientConfig) {
    // Strip trailing slash(es) once, at construction.
    this.baseUrl = config.baseUrl.replace(/\/+$/, "");
    this.timeouts = { ...DEFAULT_TIMEOUTS, ...(config.timeouts ?? {}) };
    this.fetchImpl = config.fetch ?? ((input, init) => fetch(input, init));
    this.now = config.now ?? (() => new Date());
  }

  // ── Transport ────────────────────────────────────────────────────────────

  private async request<T>(
    method: string,
    path: string,
    timeoutMs: number,
    body?: unknown
  ): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    const init: RequestInit = {
      method,
      signal: AbortSignal.timeout(timeoutMs),
    };
    if (body !== undefined) {
      init.headers = { "Content-Type": "application/json" };
      init.body = JSON.stringify(body);
    }

    let response: Response;
    try {
      response = await this.fetchImpl(url, init);
    } catch (err) {
      throw new RemoteAlarmNetworkError(describeFetchError(err));
    }

    let text = "";
    try {
      text = await response.text();
    } catch (err) {
      throw new RemoteAlarmNetworkError(describeFetchError(err));
    }

    let payload: unknown;
    if (text.length > 0) {
      try {
        payload = JSON.parse(text);
      } catch {
        payload = undefined;
      }
    }

    if (!response.ok) {
      const serverMessage = extractServerMessage(payload);
      const message =
        serverMessage ?? `Remote Alarm request failed with status ${response.status}.`;
      throw this.mapHttpError(response.status, message, serverMessage);
    }

    return payload as T;
  }

  private mapHttpError(
    status: number,
    message: string,
    serverMessage: string | undefined
  ): RemoteAlarmError {
    if (status === 404) {
      return new RemoteAlarmNotFoundError(message, { status, serverMessage });
    }
    return new RemoteAlarmError(message, { status, serverMessage });
  }

  private toMutationResult(payload: Record<string, unknown>): AlarmMutationResult {
    const result: AlarmMutationResult = { alarm: normalizeAlarm(payload) };
    const dispatch = extractDispatch(payload);
    if (dispatch) result.dispatch = dispatch;
    return result;
  }

  // ── Surface ──────────────────────────────────────────────────────────────

  async health(): Promise<Health> {
    return this.request<Health>("GET", "/api/health", this.timeouts.health);
  }

  async listAlarms(view: "active" | "history" | "all" = "active"): Promise<Alarm[]> {
    const raw = await this.request<unknown[]>(
      "GET",
      `/api/alarms?view=${encodeURIComponent(view)}`,
      this.timeouts.read
    );
    const list = Array.isArray(raw) ? raw : [];
    return list.map((item) => normalizeAlarm((item ?? {}) as Record<string, unknown>));
  }

  async createAlarm(input: CreateAlarmInput): Promise<AlarmMutationResult> {
    validateSoundTone(input.sound_tone);

    // Exactly one time path. The union makes "neither/both" a compile error,
    // but guard at runtime too for callers that bypass the type (e.g. JS).
    let targetTime: Date;
    let inferredRepeatDays: Weekday[] = [];
    if (input.targetTime !== undefined) {
      if ((input as { when?: unknown }).when !== undefined) {
        throw new RemoteAlarmError(
          "Provide exactly one of `when` or `targetTime`, not both."
        );
      }
      // Absolute LOCAL instant — the same single conversion point as parsed times.
      targetTime = input.targetTime;
    } else {
      const parsed = parseTime(input.when, this.now());
      targetTime = parsed.targetTime;
      inferredRepeatDays = parsed.repeatDays;
    }

    const repeatDays = input.repeat_days ?? inferredRepeatDays;

    const body: Record<string, unknown> = {
      target_time: toAlignedIso(targetTime),
      label: input.label,
    };
    if (input.description !== undefined) body.description = input.description;
    if (repeatDays.length > 0) body.repeat_days = encodeRepeatDays(repeatDays);
    if (input.sound_tone !== undefined) body.sound_tone = input.sound_tone;
    if (input.ramp_seconds !== undefined) body.ramp_seconds = input.ramp_seconds;

    const raw = await this.request<Record<string, unknown>>(
      "POST",
      "/api/alarms",
      this.timeouts.write,
      body
    );
    return this.toMutationResult(raw);
  }

  async updateAlarm(id: string, patch: UpdateAlarmInput): Promise<AlarmMutationResult> {
    validateSoundTone(patch.sound_tone);

    // At most one time path; both is rejected (the update type cannot express
    // a discriminated union without breaking partial patches).
    if (patch.when !== undefined && patch.targetTime !== undefined) {
      throw new RemoteAlarmError(
        "Provide at most one of `when` or `targetTime`, not both."
      );
    }

    const body: Record<string, unknown> = {};

    if (patch.when !== undefined) {
      const parsed = parseTime(patch.when, this.now());
      body.target_time = toAlignedIso(parsed.targetTime);
      if (patch.repeat_days === undefined && parsed.repeatDays.length > 0) {
        body.repeat_days = encodeRepeatDays(parsed.repeatDays);
      }
    } else if (patch.targetTime !== undefined) {
      // Absolute LOCAL instant — same single conversion point as parsed times.
      body.target_time = toAlignedIso(patch.targetTime);
    }
    if (patch.repeat_days !== undefined) {
      // An explicit empty array clears recurrence; send an empty string.
      body.repeat_days = encodeRepeatDays(patch.repeat_days);
    }
    if (patch.label !== undefined) body.label = patch.label;
    if (patch.description !== undefined) body.description = patch.description;
    if (patch.sound_tone !== undefined) body.sound_tone = patch.sound_tone;
    if (patch.ramp_seconds !== undefined) body.ramp_seconds = patch.ramp_seconds;
    if (patch.status !== undefined) body.status = patch.status;

    const raw = await this.request<Record<string, unknown>>(
      "PATCH",
      `/api/alarms/${encodeURIComponent(id)}`,
      this.timeouts.write,
      body
    );
    return this.toMutationResult(raw);
  }

  async cancelAlarm(id: string): Promise<AlarmMutationResult> {
    const raw = await this.request<Record<string, unknown>>(
      "DELETE",
      `/api/alarms/${encodeURIComponent(id)}`,
      this.timeouts.write
    );
    return this.toMutationResult(raw);
  }

  async silenceAlarm(id: string): Promise<AlarmMutationResult> {
    const raw = await this.request<Record<string, unknown>>(
      "POST",
      `/api/alarms/${encodeURIComponent(id)}/silence`,
      this.timeouts.write
    );
    return this.toMutationResult(raw);
  }

  async setState(
    id: string,
    status: SetStateStatus,
    targetTime?: Date
  ): Promise<AlarmMutationResult> {
    const body: Record<string, unknown> = { status };
    if (targetTime !== undefined) body.target_time = toAlignedIso(targetTime);

    const raw = await this.request<Record<string, unknown>>(
      "POST",
      `/api/alarms/${encodeURIComponent(id)}/state`,
      this.timeouts.write,
      body
    );
    return this.toMutationResult(raw);
  }

  async listDevices(): Promise<DeviceStatus[]> {
    const raw = await this.request<Record<string, unknown>>(
      "GET",
      "/api/devices",
      this.timeouts.read
    );
    const devices = Array.isArray(raw?.devices) ? (raw.devices as Record<string, unknown>[]) : [];
    return devices.map((device) => ({
      token_masked: asString(device.token_masked) ?? "",
      device_name: asString(device.device_name) ?? "Android Phone",
      battery_level: typeof device.battery_level === "number" ? device.battery_level : null,
      is_charging: device.is_charging === true,
      updated_at: asString(device.updated_at) ?? "",
    }));
  }

  async getSettings(): Promise<Settings> {
    return this.request<Settings>("GET", "/api/settings", this.timeouts.read);
  }
}
