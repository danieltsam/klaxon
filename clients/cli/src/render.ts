/**
 * Terminal rendering: colour, tables, relative times, trust messaging.
 *
 * Pure formatting — no I/O, no client calls. All time conversions go through
 * core's `toLocalDate` / `formatAlarm` so there is exactly one conversion point.
 */

import {
  formatAlarm,
  formatMissedReason,
  formatRelative,
  formatStatus,
  toLocalDate,
  type Alarm,
  type AlarmStatus,
  type DeviceStatus,
  type FcmDispatch,
  type Weekday,
} from "@remotealarm/core";

export interface Palette {
  readonly enabled: boolean;
  bold(s: string): string;
  dim(s: string): string;
  red(s: string): string;
  green(s: string): string;
  yellow(s: string): string;
  cyan(s: string): string;
}

export function makePalette(enabled: boolean): Palette {
  const wrap = (code: number) => (s: string) => (enabled ? `\u001b[${code}m${s}\u001b[0m` : s);
  return {
    enabled,
    bold: wrap(1),
    dim: wrap(2),
    red: wrap(31),
    green: wrap(32),
    yellow: wrap(33),
    cyan: wrap(36),
  };
}

const DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/** Render a decoded `Weekday[]` back to a human recurrence spec. */
export function formatRepeatDays(days?: Weekday[]): string | undefined {
  if (!days || days.length === 0) return undefined;
  const sorted = [...days].sort((a, b) => a - b);
  const key = sorted.join(",");
  if (key === "1,2,3,4,5,6,7") return "daily";
  if (key === "1,2,3,4,5") return "weekdays";
  if (key === "6,7") return "weekends";
  return sorted.map((d) => DAY_NAMES[d - 1]).join(",");
}

/** True when a UTC `target_time` string is present and parseable. */
export function hasValidTarget(alarm: Alarm): boolean {
  return (
    typeof alarm.target_time === "string" &&
    alarm.target_time.length > 0 &&
    !Number.isNaN(Date.parse(alarm.target_time))
  );
}

/**
 * SQLite `datetime('now')` is `"YYYY-MM-DD HH:MM:SS"` in UTC. `Date.parse`
 * would read it as local, so parse it explicitly as UTC.
 */
export function parseSqliteUtc(value: string): Date | null {
  if (!value) return null;
  const iso = value.includes("T") ? value : `${value.replace(" ", "T")}Z`;
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? null : date;
}

function statusStyle(status: AlarmStatus, palette: Palette): string {
  switch (status) {
    case "ringing":
      return palette.red(formatStatus(status));
    case "pending":
      return palette.green(formatStatus(status));
    case "snoozed":
      return palette.yellow(formatStatus(status));
    case "disabled":
    case "canceled":
    case "dismissed":
      return palette.dim(formatStatus(status));
    case "missed":
      // Time passed and it never rang, so it will not ring. Not a live alarm,
      // but a failure worth noticing rather than dimming away.
      return palette.yellow(formatStatus(status));
    default:
      return formatStatus(status);
  }
}

/** Human-readable lines for a single alarm, including the resolved local echo. */
export function renderAlarmBlock(alarm: Alarm, now: Date, palette: Palette): string {
  const lines: string[] = [];

  lines.push(`  ${palette.bold(alarm.label || "(no label)")}`);

  if (hasValidTarget(alarm)) {
    const local = formatAlarm(alarm);
    const relative = formatRelative(now, toLocalDate(alarm));
    lines.push(`  ${palette.cyan("→")} ${local} ${palette.dim(`(${relative})`)}`);
  } else {
    lines.push(`  ${palette.cyan("→")} ${palette.dim("no target time returned by server")}`);
  }

  const meta: string[] = [`status ${statusStyle(alarm.status, palette)}`];
  if (alarm.sound_tone) meta.push(`tone ${alarm.sound_tone}`);
  if (alarm.ramp_seconds !== undefined) meta.push(`ramp ${alarm.ramp_seconds}s`);
  meta.push(formatRepeatDays(alarm.repeat_days) ? `repeat ${formatRepeatDays(alarm.repeat_days)}` : "one-time");
  lines.push(`  ${meta.join(palette.dim(" · "))}`);

  // Audit detail (spec §7): when it was missed and why. Shown only when the
  // backend recorded it — `--json` carries the raw fields verbatim.
  if (alarm.missed_at || alarm.missed_reason) {
    const audit: string[] = ["missed"];
    if (alarm.missed_at) {
      const missedAt = new Date(alarm.missed_at);
      if (!Number.isNaN(missedAt.getTime())) {
        audit[0] = `missed ${formatRelative(now, missedAt)}`;
      }
    }
    if (alarm.missed_reason) audit.push(formatMissedReason(alarm.missed_reason));
    lines.push(`  ${palette.yellow(audit.join(" — "))}`);
  }

  if (alarm.description) lines.push(`  ${palette.dim(alarm.description)}`);
  lines.push(`  ${palette.dim(`id ${alarm.id}`)}`);

  return lines.join("\n");
}

/**
 * Trust messaging (spec §9): never "delivered", never infer success.
 */
export function renderDispatchLine(dispatch: FcmDispatch | undefined, palette: Palette): string {
  if (dispatch === undefined) {
    return palette.dim("no dispatch report");
  }
  if (dispatch.sent === 0) {
    return palette.yellow(
      "command sent — WARNING: no devices are registered, so this alarm will not ring."
    );
  }
  const plural = dispatch.sent === 1 ? "device" : "devices";
  const failed = dispatch.failed > 0 ? palette.dim(`, ${dispatch.failed} failed`) : "";
  // Kept deliberately free of a delivery caveat: `sent` is a device count, not proof
  // of receipt, and repeating that on every success trains the user to ignore it. The
  // actionable signals are the sent===0 warning above, the failed count, and the
  // stale-device warning. See README "Trust model" and spec §9.
  return `${palette.green(`command sent to ${dispatch.sent} ${plural}`)}${failed}`;
}

/** Warnings suitable for `--json` consumers. */
export function dispatchWarnings(dispatch: FcmDispatch | undefined): string[] {
  const warnings: string[] = [];
  if (dispatch !== undefined && dispatch.sent === 0) {
    warnings.push("no devices are registered — this alarm will not ring");
  }
  return warnings;
}

function pad(value: string, width: number): string {
  return value.length >= width ? value : value + " ".repeat(width - value.length);
}

interface Column {
  header: string;
  values: string[];
}

function renderTable(columns: Column[], palette: Palette): string {
  const widths = columns.map((column) =>
    Math.max(column.header.length, ...column.values.map((v) => v.length))
  );
  const header = columns
    .map((column, index) => palette.bold(pad(column.header, widths[index])))
    .join("  ");
  const rows = columns[0].values.map((_, rowIndex) =>
    columns.map((column, index) => pad(column.values[rowIndex], widths[index])).join("  ")
  );
  return [header, ...rows].join("\n");
}

export function renderAlarmTable(alarms: Alarm[], now: Date, palette: Palette): string {
  if (alarms.length === 0) return "No alarms.";
  const columns: Column[] = [
    { header: "ID", values: alarms.map((a) => a.id) },
    {
      header: "WHEN",
      values: alarms.map((a) => (hasValidTarget(a) ? formatAlarm(a) : "—")),
    },
    {
      header: "REL",
      values: alarms.map((a) => (hasValidTarget(a) ? formatRelative(now, toLocalDate(a)) : "—")),
    },
    { header: "STATUS", values: alarms.map((a) => formatStatus(a.status)) },
    {
      header: "REPEAT",
      values: alarms.map((a) => formatRepeatDays(a.repeat_days) ?? "one-time"),
    },
    { header: "LABEL", values: alarms.map((a) => a.label) },
  ];
  return renderTable(columns, palette);
}

export function renderDeviceTable(devices: DeviceStatus[], now: Date, palette: Palette): string {
  const columns: Column[] = [
    { header: "DEVICE", values: devices.map((d) => d.device_name) },
    {
      header: "BATTERY",
      values: devices.map((d) => (d.battery_level === null ? "—" : `${d.battery_level}%${d.is_charging ? " (charging)" : ""}`)),
    },
    {
      header: "LAST PING",
      values: devices.map((d) => {
        const date = parseSqliteUtc(d.updated_at);
        return date ? formatRelative(now, date) : "—";
      }),
    },
    {
      header: "STALE",
      values: devices.map((d) => {
        const date = parseSqliteUtc(d.updated_at);
        if (!date) return "—";
        return now.getTime() - date.getTime() > 24 * 60 * 60 * 1000 ? "yes" : "no";
      }),
    },
    { header: "TOKEN", values: devices.map((d) => d.token_masked) },
  ];
  return renderTable(columns, palette);
}

/** True when every device's last ping is older than 24h (or there are none). */
export function allDevicesStale(devices: DeviceStatus[], now: Date): boolean {
  if (devices.length === 0) return true;
  return devices.every((d) => {
    const date = parseSqliteUtc(d.updated_at);
    return date === null || now.getTime() - date.getTime() > 24 * 60 * 60 * 1000;
  });
}
