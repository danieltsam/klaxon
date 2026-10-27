import {
  Action,
  ActionPanel,
  Color,
  getPreferenceValues,
  Icon,
  Keyboard,
  List,
  openExtensionPreferences,
  showToast,
  Toast,
} from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { useEffect } from "react";
import type { Alarm } from "@remotealarm/core";
import CreateAlarmCommand from "./create-alarm";
import { EditAlarm } from "./edit-alarm";
import {
  AlarmDetail,
  alarmAccessories,
  cancelAlarmWithConfirm,
  copyAlarmId,
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

  // Read every row: disabled alarms must stay visible so they can be switched
  // back on, and missed alarms are not in `active`. Cancelled rows are the only
  // ones this view hides.
  const {
    data: alarms,
    isLoading: alarmsLoading,
    error: alarmsError,
    revalidate,
  } = usePromise(() => client.listAlarms("all"));

  const {
    data: devices,
    isLoading: devicesLoading,
    error: devicesError,
    revalidate: revalidateDevices,
  } = useDevices(client);

  useEffect(() => {
    const interval = setInterval(() => {
      revalidate();
      revalidateDevices();
    }, 10000);
    return () => clearInterval(interval);
  }, [revalidate, revalidateDevices]);

  const now = new Date();
  const summary = summarizeDevices(devices);
  const visible = (alarms ?? []).filter((alarm) => alarm.status !== "canceled");
  const groups = groupAlarms(visible, now);
  const isLoading = alarmsLoading || devicesLoading;
  const error = alarmsError ?? devicesError;

  const hasAlarms =
    groups.ringing.length > 0 ||
    groups.missed.length > 0 ||
    groups.today.length > 0 ||
    groups.upcoming.length > 0 ||
    groups.recurring.length > 0;

  async function testConnection() {
    try {
      const health = await client.health();
      await showToast({
        title: "Klaxon",
        message: `Backend ok · ${health.status}`,
      });
    } catch (err) {
      await showToast({
        title: "Klaxon",
        message: err instanceof Error ? err.message : String(err),
        style: Toast.Style.Failure,
      });
    }
  }

  if (error && !isLoading) {
    return (
      <List isLoading={isLoading} navigationTitle="Klaxon">
        <ErrorEmptyView
          error={error}
          backendUrl={prefs.backendUrl}
          onTest={testConnection}
        />
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
                <Action
                  title="Test Connection"
                  icon={Icon.Globe}
                  onAction={testConnection}
                />
                <Action
                  title="Open Preferences"
                  icon={Icon.Gear}
                  onAction={openExtensionPreferences}
                />
              </ActionPanel>
            }
          />
        </List.Section>
      ) : (
        <>
          {groups.ringing.length > 0 && (
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
          )}
          {groups.upcoming.length > 0 && (
            <List.Section
              title="Upcoming"
              subtitle={`${groups.upcoming.length}`}
            >
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
          )}
          {groups.today.length > 0 && (
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
          )}
          {groups.recurring.length > 0 && (
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
          )}
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
