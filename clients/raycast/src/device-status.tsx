import {
  Action,
  ActionPanel,
  Color,
  getPreferenceValues,
  Icon,
  List,
} from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { ErrorEmptyView, formatAge, parseSqliteUtc, useClient } from "./lib";

export default function DeviceStatusCommand() {
  const client = useClient();
  const prefs = getPreferenceValues<Preferences>();
  const {
    data: devices,
    isLoading,
    error,
    revalidate,
  } = usePromise(() => client.listDevices());

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
      searchBarPlaceholder="Search devices…"
      navigationTitle="Device Status"
    >
      {!devices || devices.length === 0 ? (
        <List.EmptyView
          icon={{ source: Icon.Mobile, tintColor: Color.SecondaryText }}
          title="No devices"
          description="No Android devices have registered yet. Open the mobile app and check the backend URL."
        />
      ) : (
        devices.map((device) => {
          const updated = parseSqliteUtc(device.updated_at);
          const ageMs = Number.isNaN(updated.getTime())
            ? null
            : Date.now() - updated.getTime();
          const stale = ageMs !== null && ageMs > 24 * 60 * 60 * 1000;
          return (
            <List.Item
              key={device.token_masked}
              title={device.device_name || "Android Phone"}
              subtitle={`Token ${device.token_masked}`}
              icon={{
                source: device.is_charging ? Icon.Bolt : Icon.Mobile,
                tintColor: stale ? Color.Yellow : Color.PrimaryText,
              }}
              accessories={[
                {
                  text:
                    device.battery_level === null
                      ? "—%"
                      : `${Math.round(device.battery_level)}%`,
                },
                { text: ageMs === null ? "—" : `${formatAge(ageMs)} ago` },
              ]}
              actions={
                <ActionPanel>
                  <Action
                    title="Refresh"
                    icon={Icon.ArrowClockwise}
                    onAction={revalidate}
                  />
                </ActionPanel>
              }
            />
          );
        })
      )}
    </List>
  );
}
