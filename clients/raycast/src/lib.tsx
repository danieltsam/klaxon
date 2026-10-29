import {
  Action,
  ActionPanel,
  Alert,
  Clipboard,
  Color,
  environment,
  confirmAlert,
  getPreferenceValues,
  Icon,
  List,
  openExtensionPreferences,
  showToast,
  Toast,
} from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { execFile } from "node:child_process";
import { join } from "node:path";
import { useMemo } from "react";
import type {
  Alarm,
  DeviceStatus,
  FcmDispatch,
  SoundTone,
  Weekday,
} from "@remotealarm/core";
import {
  formatClock,
  formatInterpretation,
  formatLocal,
  formatMissedReason,
  formatRelative,
  formatStatus,
  normalizeBaseUrl,
  RemoteAlarmClient,
  RemoteAlarmError,
  toLocalDate,
} from "@remotealarm/core";

export const SOUND_TONES: SoundTone[] = ["alarm", "chime", "digital"];
export const RAMP_OPTIONS = [0, 15, 30, 60];

export const RECURRENCE_OPTIONS: {
  label: string;
  key: string;
  days: Weekday[];
}[] = [
  { label: "One-time", key: "once", days: [] },
  { label: "Daily", key: "daily", days: [1, 2, 3, 4, 5, 6, 7] },
  { label: "Weekdays", key: "weekdays", days: [1, 2, 3, 4, 5] },
  { label: "Weekends", key: "weekends", days: [6, 7] },
];

/** The backend stores weekly (1) or fortnightly (2) recurrence only. */
export const INTERVAL_OPTIONS: { label: string; value: string }[] = [
  { label: "Every week", value: "1" },
  { label: "Every 2 weeks", value: "2" },
];

const WEEKDAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

export function useClient(): RemoteAlarmClient {
  const prefs = getPreferenceValues<Preferences>();
  return useMemo(
    () => new RemoteAlarmClient({ baseUrl: prefs.backendUrl }),
    [prefs.backendUrl],
  );
}

export function useSettings(client: RemoteAlarmClient) {
  return usePromise(() => client.getSettings());
}

export function useDevices(client: RemoteAlarmClient) {
  return usePromise(() => client.listDevices());
}

export function parseSqliteUtc(value: string): Date {
  return new Date(value.replace(" ", "T") + "Z");
}

export function formatAge(ms: number): string {
  const minutes = Math.round(ms / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

export interface DeviceSummary {
  devices: DeviceStatus[];
  noDevices: boolean;
  stale: boolean;
  battery: number | null;
  charging: boolean;
  ageMs: number | null;
}

export function summarizeDevices(devices?: DeviceStatus[]): DeviceSummary {
  if (!devices || devices.length === 0) {
    return {
      devices: [],
      noDevices: true,
      stale: false,
      battery: null,
      charging: false,
      ageMs: null,
    };
  }
  const latest = devices.reduce((a, b) => {
    const aTime = Number.isNaN(parseSqliteUtc(a.updated_at).getTime())
      ? 0
      : parseSqliteUtc(a.updated_at).getTime();
    const bTime = Number.isNaN(parseSqliteUtc(b.updated_at).getTime())
      ? 0
      : parseSqliteUtc(b.updated_at).getTime();
    return aTime > bTime ? a : b;
  });
  const updated = parseSqliteUtc(latest.updated_at);
  const ageMs = Number.isNaN(updated.getTime())
    ? Infinity
    : Date.now() - updated.getTime();
  return {
    devices,
    noDevices: false,
    stale: ageMs > 24 * 60 * 60 * 1000,
    battery: latest.battery_level,
    charging: latest.is_charging,
    ageMs,
  };
}

/**
 * `@raycast/api` 2.9 removed `FormValidation`; `useForm` wants a predicate that
 * returns an error string. An undefined export compiles but throws at render,
 * which is exactly how the create command broke.
 */
export function requiredField(value: unknown): string | undefined {
  if (value === undefined || value === null) return "Required";
  if (typeof value === "string" && value.trim() === "") return "Required";
  return undefined;
}

export function formatRecurrence(days?: Weekday[]): string {
  if (!days || days.length === 0) return "One-time";
  if (days.length === 7) return "Daily";
  if (days.length === 5 && days.every((d, i) => d === i + 1)) return "Weekdays";
  if (days.length === 2 && days[0] === 6 && days[1] === 7) return "Weekends";
  return days.map((d) => WEEKDAY_NAMES[d - 1]).join(", ");
}

/**
 * A fortnightly alarm keeps its weekday set and adds an interval; showing only
 * the day would read as weekly, which is the wrong promise to make.
 */
export function formatRecurrenceWithInterval(
  days: Weekday[] | undefined,
  intervalWeeks?: number,
): string {
  const base = formatRecurrence(days);
  if (intervalWeeks !== 2) return base;
  return days && days.length > 0 ? `${base} · every 2 weeks` : "Every 2 weeks";
}

export function recurrenceValueFromDays(days?: Weekday[]): string {
  if (!days || days.length === 0) return "once";
  const match = RECURRENCE_OPTIONS.find(
    (opt) =>
      opt.days.length === days.length &&
      opt.days.every((d, i) => d === days[i]),
  );
  return match ? match.key : `custom:${days.join(",")}`;
}

export function daysFromRecurrenceValue(value: string): Weekday[] | undefined {
  if (value === "once" || value === "") return undefined;
  if (value.startsWith("custom:")) {
    const parts = value.slice("custom:".length).split(",");
    const days = parts
      .map((p) => Number(p.trim()))
      .filter((n) => Number.isInteger(n) && n >= 1 && n <= 7) as Weekday[];
    return days.length > 0 ? days : undefined;
  }
  const match = RECURRENCE_OPTIONS.find((opt) => opt.key === value);
  return match && match.days.length > 0 ? match.days : undefined;
}

export function iconForStatus(status: Alarm["status"]): {
  source: Icon;
  tintColor?: Color;
} {
  switch (status) {
    case "ringing":
      return { source: Icon.Bell, tintColor: Color.Red };
    case "disabled":
      return { source: Icon.Moon, tintColor: Color.SecondaryText };
    case "snoozed":
      return { source: Icon.Moon, tintColor: Color.Yellow };
    case "canceled":
      return { source: Icon.XMarkCircle, tintColor: Color.SecondaryText };
    case "dismissed":
      return { source: Icon.CheckCircle, tintColor: Color.SecondaryText };
    case "missed":
      // Time passed and it never rang, so it will not ring. A failure, not a
      // live alarm and not a quiet end — flagged rather than dimmed.
      return { source: Icon.ExclamationMark, tintColor: Color.Orange };
    case "pending":
    default:
      return { source: Icon.Clock, tintColor: Color.Blue };
  }
}

export function alarmAccessories(alarm: Alarm, now: Date) {
  const local = toLocalDate(alarm);
  if (alarm.status === "ringing") {
    return [{ icon: Icon.Bell, text: "Ringing", tooltip: "Ringing now" }];
  }
  if (alarm.status === "missed") {
    // Not live: the time passed and it never rang, so it will not ring.
    return [
      {
        icon: Icon.ExclamationMark,
        text: "Missed",
        tooltip: "The alarm's time passed and it never rang — it will not ring",
      },
    ];
  }
  if (alarm.repeat_days && alarm.repeat_days.length > 0) {
    return [
      {
        icon: Icon.Calendar,
        text: formatRecurrenceWithInterval(
          alarm.repeat_days,
          alarm.recurrence_interval_weeks,
        ),
        tooltip: "Recurrence",
      },
      {
        icon: Icon.Clock,
        text: formatClock(local),
        tooltip: formatLocal(local),
      },
    ];
  }
  return [
    {
      icon: Icon.Clock,
      text: formatRelative(now, local),
      tooltip: formatLocal(local),
    },
  ];
}

export function ErrorEmptyView({
  error,
  backendUrl,
  onTest,
}: {
  error: unknown;
  backendUrl: string;
  onTest?: () => void;
}) {
  let message = "Could not reach the Klaxon backend.";
  if (error instanceof RemoteAlarmError) {
    message = error.message;
  } else if (error instanceof Error) {
    message = error.message;
  }
  let shownUrl = backendUrl;
  try {
    shownUrl = normalizeBaseUrl(backendUrl);
  } catch {
    // Keep the raw value so the user can see what is wrong with it.
  }
  return (
    <List.EmptyView
      icon={{ source: Icon.Warning, tintColor: Color.Red }}
      title="Backend unreachable"
      description={`${message} Backend URL: ${shownUrl}`}
      actions={
        <ActionPanel>
          {onTest && (
            <Action
              title="Test Connection"
              icon={Icon.Globe}
              onAction={onTest}
            />
          )}
          <Action
            title="Open Preferences"
            onAction={openExtensionPreferences}
          />
        </ActionPanel>
      }
    />
  );
}

export function NoAlarmsEmptyView() {
  return (
    <List.EmptyView
      icon={{ source: Icon.Bell, tintColor: Color.SecondaryText }}
      title="No alarms"
      description="Press ⌘K to create your first alarm."
    />
  );
}

/** What actually happened to the dispatch, in one clause. */
export function dispatchDetail(result: {
  alarm: Alarm;
  dispatch?: FcmDispatch;
}): string {
  const { dispatch } = result;
  if (!dispatch) return "no dispatch report";
  if (dispatch.sent === 0) {
    return "saved, but no devices are registered — this alarm won't ring";
  }
  let detail = `sent to ${dispatch.sent} device${dispatch.sent === 1 ? "" : "s"}`;
  if (dispatch.failed > 0) detail += ` (${dispatch.failed} failed)`;
  return detail;
}

export function showDispatchToast(
  result: { alarm: Alarm; dispatch?: FcmDispatch },
  action: string,
) {
  return showToast({
    title: "Klaxon",
    message: `${action}: ${result.alarm.label} · ${dispatchDetail(result)}`,
  });
}

/** Play a tone through the Mac so the name means something. */
export function previewTone(tone: SoundTone): void {
  const file = join(environment.assetsPath, "tones", `${tone}.mp3`);
  execFile("afplay", [file], (err) => {
    if (err) {
      void showToast({
        title: "Klaxon",
        message: `Could not play ${tone}: ${err.message}`,
        style: Toast.Style.Failure,
      });
    }
  });
}

export function showWarning(message: string) {
  return showToast({ title: "Klaxon", message, style: Toast.Style.Failure });
}

export async function toggleAlarmState(
  client: RemoteAlarmClient,
  alarm: Alarm,
) {
  if (alarm.status === "missed") {
    // A missed alarm's time is in the past, so enabling it would arm a stale
    // alarm. It must be rescheduled instead; never treat it as live.
    await showWarning(
      "This alarm was missed. Set a new time to reschedule it.",
    );
    return;
  }
  const next = alarm.status === "disabled" ? "pending" : "disabled";
  const result = await client.setState(alarm.id, next);
  await showDispatchToast(result, next === "pending" ? "Enabled" : "Disabled");
}

export async function cancelAlarmWithConfirm(
  client: RemoteAlarmClient,
  alarm: Alarm,
  confirm: boolean,
) {
  if (confirm) {
    const ok = await confirmAlert({
      title: "Cancel alarm?",
      message: `This will cancel "${alarm.label}".`,
      primaryAction: {
        title: "Cancel Alarm",
        style: Alert.ActionStyle.Destructive,
      },
    });
    if (!ok) return;
  }
  const result = await client.cancelAlarm(alarm.id);
  await showDispatchToast(result, "Canceled");
}

export async function silenceAlarm(client: RemoteAlarmClient, alarm: Alarm) {
  const result = await client.silenceAlarm(alarm.id);
  await showDispatchToast(result, "Silenced");
}

export async function copyAlarmId(alarm: Alarm) {
  await Clipboard.copy(alarm.id);
  await showToast({ title: "Klaxon", message: `Copied ID ${alarm.id}` });
}

export function DeviceStatusAccessory({ summary }: { summary: DeviceSummary }) {
  if (summary.noDevices) {
    return (
      <List.Item
        title="No devices"
        icon={{ source: Icon.ExclamationMark, tintColor: Color.Red }}
        accessories={[{ text: "alarm won't ring" }]}
      />
    );
  }
  const batteryText =
    summary.battery === null ? "—%" : `${Math.round(summary.battery)}%`;
  const ageText =
    summary.ageMs === null ? "—" : `${formatAge(summary.ageMs)} ago`;
  return (
    <List.Item
      title={summary.charging ? "Phone charging" : "Phone battery"}
      icon={{
        source: summary.charging ? Icon.Bolt : Icon.Mobile,
        tintColor: summary.stale ? Color.Yellow : Color.PrimaryText,
      }}
      accessories={[{ text: `${batteryText} · ${ageText}` }]}
    />
  );
}

export function AlarmDetail({
  alarm,
  now,
  summary,
}: {
  alarm: Alarm;
  now: Date;
  summary: DeviceSummary;
}) {
  const local = toLocalDate(alarm);
  const missedAt = alarm.missed_at ? new Date(alarm.missed_at) : null;
  const missedAtText =
    missedAt && !Number.isNaN(missedAt.getTime())
      ? formatLocal(missedAt)
      : (alarm.missed_at ?? "—");
  return (
    <List.Item.Detail
      metadata={
        <List.Item.Detail.Metadata>
          <List.Item.Detail.Metadata.Label
            title="Status"
            text={formatStatus(alarm.status)}
            icon={iconForStatus(alarm.status)}
          />
          <List.Item.Detail.Metadata.Label
            title="Time"
            text={formatInterpretation(local, now)}
          />
          <List.Item.Detail.Metadata.Label
            title="Recurrence"
            text={formatRecurrenceWithInterval(
              alarm.repeat_days,
              alarm.recurrence_interval_weeks,
            )}
          />
          <List.Item.Detail.Metadata.Label
            title="Tone"
            text={alarm.sound_tone ?? "alarm"}
          />
          <List.Item.Detail.Metadata.Label
            title="Ramp"
            text={`${alarm.ramp_seconds ?? 30}s`}
          />
          <List.Item.Detail.Metadata.Label
            title="Created"
            text={alarm.created_at ?? "—"}
          />
          {alarm.status === "missed" && (
            <>
              <List.Item.Detail.Metadata.Label
                title="Missed"
                text={missedAtText}
                icon={{ source: Icon.ExclamationMark, tintColor: Color.Orange }}
              />
              <List.Item.Detail.Metadata.Label
                title="Reason"
                text={
                  alarm.missed_reason
                    ? formatMissedReason(alarm.missed_reason)
                    : "—"
                }
              />
            </>
          )}
          {summary.noDevices && (
            <List.Item.Detail.Metadata.Label
              title="Reachability"
              text="No devices registered — this alarm won't ring"
              icon={{ source: Icon.ExclamationMark, tintColor: Color.Yellow }}
            />
          )}
          {!summary.noDevices && summary.stale && summary.ageMs !== null && (
            <List.Item.Detail.Metadata.Label
              title="Reachability"
              text={`Last ping ${formatAge(summary.ageMs)} ago`}
              icon={{ source: Icon.ExclamationMark, tintColor: Color.Yellow }}
            />
          )}
        </List.Item.Detail.Metadata>
      }
    />
  );
}

function isSameDay(a: Date, b: Date): boolean {
  return (
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
  );
}

export function groupAlarms(alarms: Alarm[], now: Date) {
  const ringing: Alarm[] = [];
  const missed: Alarm[] = [];
  const recurring: Alarm[] = [];
  const today: Alarm[] = [];
  const upcoming: Alarm[] = [];

  for (const alarm of alarms) {
    if (alarm.status === "ringing") {
      ringing.push(alarm);
      continue;
    }
    if (alarm.status === "missed") {
      // Never live: its time passed without ringing, so it must not fall into
      // Today/Upcoming as if it were still going to fire.
      missed.push(alarm);
      continue;
    }
    if (alarm.repeat_days && alarm.repeat_days.length > 0) {
      recurring.push(alarm);
      continue;
    }
    const local = toLocalDate(alarm);
    if (isSameDay(local, now)) {
      today.push(alarm);
    } else {
      upcoming.push(alarm);
    }
  }

  const byTime = (a: Alarm, b: Alarm) =>
    toLocalDate(a).getTime() - toLocalDate(b).getTime();
  return {
    ringing: ringing.sort(byTime),
    missed: missed.sort(byTime),
    recurring: recurring.sort(byTime),
    today: today.sort(byTime),
    upcoming: upcoming.sort(byTime),
  };
}
