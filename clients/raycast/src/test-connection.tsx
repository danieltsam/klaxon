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
import { normalizeBaseUrl } from "@remotealarm/core";
import type { DeviceStatus } from "@remotealarm/core";
import { formatAge, parseSqliteUtc, useClient } from "./lib";

/**
 * One place to answer "is the configured backend actually working?".
 *
 * The preference form cannot run code, so this command is the settings test: it
 * shows the resolved URL (with the scheme the client assumed), the health
 * response, and what the backend knows about the phone.
 */
export default function TestConnectionCommand() {
  const client = useClient();
  const prefs = getPreferenceValues<Preferences>();

  let resolvedUrl: string;
  try {
    resolvedUrl = normalizeBaseUrl(prefs.backendUrl);
  } catch (err) {
    resolvedUrl = err instanceof Error ? err.message : String(err);
  }

  const { data, isLoading, error, revalidate } = usePromise(async () => {
    const health = await client.health();
    const devices = await client.listDevices();
    const alarms = await client.listAlarms("all");

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

    return {
      health,
      devices,
      alarms,
      ageMs,
      pending: alarms.filter((alarm) => alarm.status === "pending").length,
    };
  });

  const failure =
    error instanceof Error ? error.message : error ? String(error) : null;
  const delivery = data?.health.delivery_health;

  return (
    <List isLoading={isLoading} navigationTitle="Klaxon Connection">
      <List.Section title="Backend">
        <List.Item
          title={resolvedUrl}
          subtitle={failure ?? (data ? "reachable" : "checking…")}
          icon={
            failure
              ? { source: Icon.XMarkCircle, tintColor: Color.Red }
              : data
                ? { source: Icon.CheckCircle, tintColor: Color.Green }
                : { source: Icon.Globe, tintColor: Color.SecondaryText }
          }
          actions={
            <ActionPanel>
              <Action
                title="Check Again"
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
      </List.Section>

      {data && (
        <List.Section title="What it returned">
          <List.Item
            title="health"
            subtitle={
              delivery
                ? `${data.health.status} · delivery ${delivery.ok ? "ok" : delivery.reasons.join(", ")}`
                : data.health.status
            }
            icon={Icon.Heartbeat}
          />
          <List.Item
            title="devices"
            subtitle={`${data.devices.length} registered${data.ageMs !== null ? ` · last ping ${formatAge(data.ageMs)} ago` : ""}`}
            icon={Icon.Mobile}
          />
          <List.Item
            title="alarms"
            subtitle={`${data.alarms.length} total · ${data.pending} pending`}
            icon={Icon.Bell}
          />
        </List.Section>
      )}
    </List>
  );
}
