import {
  Action,
  ActionPanel,
  Color,
  getPreferenceValues,
  Icon,
  Keyboard,
  List,
} from "@raycast/api";
import { useFetch } from "@raycast/utils";
import { useEffect } from "react";
import type { Alarm } from "@remotealarm/core";
import CreateAlarmCommand from "./create-alarm";
import { EditAlarm } from "./edit-alarm";
import {
  AlarmDetail,
  alarmAccessories,
  cancelAlarmWithConfirm,
  copyAlarmId,
  DeviceStatusAccessory,
  ErrorEmptyView,
  groupAlarms,
  iconForStatus,
  silenceAlarm,
  summarizeDevices,
  toggleAlarmState,
  useClient,
  useDevices,
} from "./lib";
import QuickCreateCommand from "./quick-create";

export default function ListAlarmsCommand() {
  const client = useClient();
  const prefs = getPreferenceValues<Preferences>();

  const {
    data: alarms,
    isLoading: alarmsLoading,
    error: alarmsError,
    revalidate,
  } = useFetch<Alarm[]>(async () => client.listAlarms("active"), {
    execute: true,
  });

  // `missed` is excluded from `view=active` by design — the phone must never
  // treat one as something to arm — and included in `view=all`. Read it
  // separately and keep only the missed rows: `all` also returns dismissed and
  // disabled alarms, which must not leak into the live groups below.
  const {
    data: allAlarms,
    isLoading: allAlarmsLoading,
    revalidate: revalidateAll,
  } = useFetch<Alarm[]>(async () => client.listAlarms("all"), {
    execute: true,
  });

  const {
    data: devices,
    isLoading: devicesLoading,
    error: devicesError,
    revalidate: revalidateDevices,
  } = useDevices(client);

  useEffect(() => {
    const interval = setInterval(() => {
      revalidate();
      revalidateAll();
      revalidateDevices();
    }, 10000);
    return () => clearInterval(interval);
  }, [revalidate, revalidateAll, revalidateDevices]);

  const now = new Date();
  const summary = summarizeDevices(devices);
  const missedAlarms = (allAlarms ?? []).filter(
    (alarm) => alarm.status === "missed",
  );
  // The active fetch already excludes missed, so this is a merge, not a dedupe.
  const groups = groupAlarms([...(alarms ?? []), ...missedAlarms], now);
  const isLoading = alarmsLoading || allAlarmsLoading || devicesLoading;
  // A failed `all` read is best-effort: the active list is the primary view and
  // must not be replaced by an error screen just because the missed read failed.
  const error = alarmsError ?? devicesError;

  const hasAlarms =
    groups.ringing.length > 0 ||
    groups.missed.length > 0 ||
    groups.today.length > 0 ||
    groups.upcoming.length > 0 ||
    groups.recurring.length > 0;

  if (error && !isLoading) {
    return (
      <List isLoading={isLoading} navigationTitle="Klaxon">
        <ErrorEmptyView error={error} backendUrl={prefs.backendUrl} />
      </List>
    );
  }

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={!(!isLoading && !hasAlarms)}
      searchBarPlaceholder="Search alarms…"
      navigationTitle="Klaxon"
    >
      <DeviceStatusAccessory summary={summary} />
      {!isLoading && !hasAlarms ? (
        <List.Section title="Alarms">
          <List.Item
            title="No alarms"
            subtitle="Press ⌘K to create your first alarm"
            icon={{ source: Icon.Bell, tintColor: Color.SecondaryText }}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Quick Create Alarm"
                  icon={Icon.Plus}
                  target={<QuickCreateCommand />}
                />
                <Action.Push
                  title="Create Alarm"
                  icon={Icon.Plus}
                  target={<CreateAlarmCommand />}
                />
              </ActionPanel>
            }
          />
        </List.Section>
      ) : (
        <>
          <List.Section title="Ringing" subtitle={`${groups.ringing.length}`}>
            {groups.ringing.map((alarm) => (
              <AlarmItem
                key={alarm.id}
                alarm={alarm}
                now={now}
                summary={summary}
                client={client}
                onChange={revalidate}
                confirmDestructive={prefs.confirmDestructive}
              />
            ))}
          </List.Section>
          {groups.missed.length > 0 && (
            <List.Section title="Missed" subtitle={`${groups.missed.length}`}>
              {groups.missed.map((alarm) => (
                <AlarmItem
                  key={alarm.id}
                  alarm={alarm}
                  now={now}
                  summary={summary}
                  client={client}
                  onChange={revalidate}
                  confirmDestructive={prefs.confirmDestructive}
                />
              ))}
            </List.Section>
          )}
          <List.Section title="Today" subtitle={`${groups.today.length}`}>
            {groups.today.map((alarm) => (
              <AlarmItem
                key={alarm.id}
                alarm={alarm}
                now={now}
                summary={summary}
                client={client}
                onChange={revalidate}
                confirmDestructive={prefs.confirmDestructive}
              />
            ))}
          </List.Section>
          <List.Section title="Upcoming" subtitle={`${groups.upcoming.length}`}>
            {groups.upcoming.map((alarm) => (
              <AlarmItem
                key={alarm.id}
                alarm={alarm}
                now={now}
                summary={summary}
                client={client}
                onChange={revalidate}
                confirmDestructive={prefs.confirmDestructive}
              />
            ))}
          </List.Section>
          <List.Section
            title="Recurring"
            subtitle={`${groups.recurring.length}`}
          >
            {groups.recurring.map((alarm) => (
              <AlarmItem
                key={alarm.id}
                alarm={alarm}
                now={now}
                summary={summary}
                client={client}
                onChange={revalidate}
                confirmDestructive={prefs.confirmDestructive}
              />
            ))}
          </List.Section>
        </>
      )}
    </List>
  );
}

function AlarmItem({
  alarm,
  now,
  summary,
  client,
  onChange,
  confirmDestructive,
}: {
  alarm: Alarm;
  now: Date;
  summary: ReturnType<typeof summarizeDevices>;
  client: ReturnType<typeof useClient>;
  onChange: () => void;
  confirmDestructive: boolean;
}) {
  return (
    <List.Item
      title={alarm.label}
      subtitle={alarm.description}
      icon={iconForStatus(alarm.status)}
      accessories={alarmAccessories(alarm, now)}
      detail={<AlarmDetail alarm={alarm} now={now} summary={summary} />}
      actions={
        <ActionPanel>
          {alarm.status === "ringing" && (
            <Action
              title="Silence"
              icon={Icon.SpeakerOff}
              onAction={async () => {
                await silenceAlarm(client, alarm);
                onChange();
              }}
            />
          )}
          {alarm.status !== "missed" && (
            <Action
              title={alarm.status === "disabled" ? "Enable" : "Disable"}
              icon={alarm.status === "disabled" ? Icon.Play : Icon.Pause}
              onAction={async () => {
                await toggleAlarmState(client, alarm);
                onChange();
              }}
            />
          )}
          <Action.Push
            title="Edit Alarm"
            icon={Icon.Pencil}
            target={<EditAlarm alarm={alarm} />}
          />
          <Action
            title="Cancel Alarm"
            icon={Icon.Trash}
            style={Action.Style.Destructive}
            onAction={async () => {
              await cancelAlarmWithConfirm(client, alarm, confirmDestructive);
              onChange();
            }}
          />
          <Action
            title="Copy ID"
            icon={Icon.Clipboard}
            shortcut={{ modifiers: ["cmd"], key: "c" }}
            onAction={() => copyAlarmId(alarm)}
          />
          <Action
            title="Refresh"
            icon={Icon.ArrowClockwise}
            shortcut={Keyboard.Shortcut.Common.Refresh}
            onAction={onChange}
          />
        </ActionPanel>
      }
    />
  );
}
