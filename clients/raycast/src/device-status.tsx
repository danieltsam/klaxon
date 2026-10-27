import {
  Action,
  ActionPanel,
  Color,
  getPreferenceValues,
  Icon,
  List,
  openExtensionPreferences,
} from "@raycast/api";
import { usePromise } from "@raycast/utils";
import type { Alarm, DeviceStatus } from "@remotealarm/core";
import { formatLocal, formatStatus } from "@remotealarm/core";
import {
  ErrorEmptyView,
  formatAge,
  iconForStatus,
  parseSqliteUtc,
  useClient,
} from "./lib";

/**
 * The whole window is the phone: one device is the normal case, so a list row
 * was a waste. Below it sits what the backend has actually done lately, which
 * is more useful than an empty section.
 */
export default function DeviceStatusCommand() {
  const client = useClient();
  const prefs = getPreferenceValues<Preferences>();

  const { data, isLoading, error, revalidate } = usePromise(async () => {
    const devices = await client.listDevices();
    const alarms = await client.listAlarms("all");

    const recent = [...alarms]
      .sort(
        (a, b) =>
          new Date(b.target_time).getTime() - new Date(a.target_time).getTime(),
      )
      .slice(0, 15);

    const latest = devices.reduce<DeviceStatus | null>((newest, device) => {
      if (!newest) return device;
      return parseSqliteUtc(device.updated_at).getTime() >
        parseSqliteUtc(newest.updated_at).getTime()
        ? device
        : newest;
    }, null);

    const ageMs = latest
      ? Date.now() - parseSqliteUtc(latest.updated_at).getTime()
      : null;

    return { devices, recent, latest, ageMs };
  });

  if (error && !isLoading) {
    return (
      <List isLoading={isLoading} navigationTitle="Klaxon · Device">
        <ErrorEmptyView
          error={error}
          backendUrl={prefs.backendUrl}
          onTest={revalidate}
        />
      </List>
    );
  }

  return (
    <List
      isLoading={isLoading}
      navigationTitle="Klaxon · Device"
      searchBarPlaceholder="Filter alarm history…"
    >
      <List.Section title="Device">
        {data && data.devices.length === 0 && (
          <List.Item
            title="No device registered"
            subtitle="No alarm can ring until the app registers"
            icon={{ source: Icon.ExclamationMark, tintColor: Color.Red }}
            actions={
              <ActionPanel>
                <Action
                  title="Refresh"
                  icon={Icon.ArrowClockwise}
                  onAction={revalidate}
                />
                <Action
                  title="Open Preferences"
                  icon={Icon.Gear}
                  onAction={openExtensionPreferences}
                />
              </ActionPanel>
            }
          />
        )}
        {data?.devices.map((device) => (
          <List.Item
            key={device.token_masked}
            title={device.device_name || "Android device"}
            subtitle={device.token_masked}
            icon={
              device.is_charging
                ? { source: Icon.Bolt, tintColor: Color.Green }
                : { source: Icon.Mobile, tintColor: Color.PrimaryText }
            }
            accessories={[
              {
                text: `${Math.round(device.battery_level ?? 0)}%`,
                icon: device.is_charging ? Icon.Bolt : Icon.Battery,
              },
              {
                text: `${formatAge(
                  Date.now() - parseSqliteUtc(device.updated_at).getTime(),
                )} ago`,
                icon: Icon.Clock,
              },
            ]}
            actions={
              <ActionPanel>
                <Action
                  title="Refresh"
                  icon={Icon.ArrowClockwise}
                  onAction={revalidate}
                />
                <Action
                  title="Open Preferences"
                  icon={Icon.Gear}
                  onAction={openExtensionPreferences}
                />
              </ActionPanel>
            }
          />
        ))}
        {data && data.devices.length > 0 && (
          <List.Item
            title="Reachability"
            subtitle={
              data.ageMs !== null && data.ageMs > 24 * 60 * 60 * 1000
                ? `Last ping ${formatAge(data.ageMs ?? 0)} ago. The phone may be asleep or off.`
                : "Reachable. Alarm delivery is being dispatched to this device."
            }
            icon={
              data.ageMs !== null && data.ageMs > 24 * 60 * 60 * 1000
                ? { source: Icon.ExclamationMark, tintColor: Color.Yellow }
                : { source: Icon.CheckCircle, tintColor: Color.Green }
            }
          />
        )}
      </List.Section>

      <List.Section
        title={`Recent alarms`}
        subtitle={`${data?.recent.length ?? 0}`}
      >
        {data?.recent.map((alarm: Alarm) => (
          <List.Item
            key={alarm.id}
            title={alarm.label}
            subtitle={formatStatus(alarm.status)}
            icon={iconForStatus(alarm.status)}
            accessories={[
              {
                text: formatLocal(new Date(alarm.target_time)),
                icon: Icon.Calendar,
              },
            ]}
            actions={
              <ActionPanel>
                <Action
                  title="Refresh"
                  icon={Icon.ArrowClockwise}
                  onAction={revalidate}
                />
                <Action
                  title="Open Preferences"
                  icon={Icon.Gear}
                  onAction={openExtensionPreferences}
                />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
    </List>
  );
}
