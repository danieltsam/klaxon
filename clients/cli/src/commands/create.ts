/**
 * `alarm <when> <label> [flags]` — create an alarm.
 */

import type { CreateAlarmInput } from "@remotealarm/core";
import {
  parseDaysSpec,
  parseRamp,
  parseTone,
  rejectFlags,
  splitTimeAndLabel,
  timeUsageError,
} from "../args.js";
import { UsageError } from "../errors.js";
import {
  confirmAlarm,
  emitMutation,
  warnIfDevicesStale,
  type CommandContext,
} from "./shared.js";

export async function createCommand(ctx: CommandContext): Promise<void> {
  rejectFlags(ctx.values, ["all", "history", "yes"], "<when> <label>");

  const { values, positionals } = ctx;
  let when = values.at;
  let label = values.label;

  const joined = positionals.join(" ").trim();

  if (when === undefined) {
    const split = splitTimeAndLabel(joined);
    if (!split) throw timeUsageError(joined);
    when = split.when;
    if (label === undefined) label = split.label.length > 0 ? split.label : undefined;
  } else if (label === undefined) {
    // `--at` supplies the time; the positionals are the label.
    label = joined.length > 0 ? joined : undefined;
  }

  if (when.length === 0) throw timeUsageError(joined);
  if (label === undefined || label.length === 0) {
    throw new UsageError(
      "A label is required. Usage: alarm <when> <label>   e.g. `alarm 25m Oven` (or --label <text>)."
    );
  }

  const input: CreateAlarmInput = { label, when };
  if (values.days !== undefined) input.repeat_days = parseDaysSpec(values.days);
  if (values.tone !== undefined) input.sound_tone = parseTone(values.tone);
  if (values.ramp !== undefined) input.ramp_seconds = parseRamp(values.ramp);
  if (values.desc !== undefined) input.description = values.desc;

  const result = await ctx.client.createAlarm(input);
  const alarm = await confirmAlarm(ctx.client, result);
  emitMutation(ctx, "created", result, alarm);
  await warnIfDevicesStale(ctx, result.dispatch);
}
