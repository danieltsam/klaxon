/**
 * `alarm status` — registered devices, battery, charging, last ping.
 */

import { rejectFlags } from "../args.js";
import { allDevicesStale, renderDeviceTable } from "../render.js";
import type { CommandContext } from "./shared.js";

export async function statusCommand(ctx: CommandContext): Promise<void> {
  rejectFlags(
    ctx.values,
    ["all", "history", "yes", "at", "label", "days", "tone", "ramp", "desc"],
    "status"
  );

  const devices = await ctx.client.listDevices();
  const now = ctx.now();

  if (ctx.json) {
    ctx.out.stdout(JSON.stringify({ count: devices.length, devices }, null, 2));
    return;
  }

  if (devices.length === 0) {
    ctx.out.stdout("No devices registered — alarms will not ring.");
    return;
  }

  ctx.out.stdout(renderDeviceTable(devices, now, ctx.palette));

  if (allDevicesStale(devices, now)) {
    ctx.out.stderr(
      ctx.palette.yellow(
        "warning: no registered device has checked in for over 24h — alarms may not ring."
      )
    );
  }
}
