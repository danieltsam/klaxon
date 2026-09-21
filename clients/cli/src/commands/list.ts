/**
 * `alarm list [--all|--history]` — list alarms.
 */

import { formatAlarm, formatRelative, toLocalDate } from "@remotealarm/core";
import { rejectFlags } from "../args.js";
import { UsageError } from "../errors.js";
import { hasValidTarget, renderAlarmTable } from "../render.js";
import type { CommandContext } from "./shared.js";

export async function listCommand(ctx: CommandContext): Promise<void> {
  rejectFlags(ctx.values, ["yes", "at", "label", "days", "tone", "ramp", "desc"], "list");

  const { values } = ctx;
  if (values.all && values.history) {
    throw new UsageError("Use either --all or --history, not both.");
  }

  const view: "active" | "history" | "all" = values.all ? "all" : values.history ? "history" : "active";
  const alarms = await ctx.client.listAlarms(view);
  const now = ctx.now();

  if (ctx.json) {
    ctx.out.stdout(
      JSON.stringify(
        {
          view,
          count: alarms.length,
          alarms: alarms.map((alarm) => ({
            ...alarm,
            local: hasValidTarget(alarm) ? formatAlarm(alarm) : null,
            relative: hasValidTarget(alarm) ? formatRelative(now, toLocalDate(alarm)) : null,
          })),
        },
        null,
        2
      )
    );
    return;
  }

  if (alarms.length === 0) {
    ctx.out.stdout(`No ${view} alarms.`);
    return;
  }

  ctx.out.stdout(renderAlarmTable(alarms, now, ctx.palette));
}
