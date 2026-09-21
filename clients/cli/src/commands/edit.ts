/**
 * `alarm edit <id> [when-and-label...] [flags]` — edit alarm fields.
 */

import type { UpdateAlarmInput } from "@remotealarm/core";
import {
  parseDaysSpec,
  parseRamp,
  parseTone,
  rejectFlags,
  splitTimeAndLabel,
} from "../args.js";
import { UsageError } from "../errors.js";
import { confirmAlarm, emitMutation, warnIfDevicesStale, type CommandContext } from "./shared.js";

export async function editCommand(ctx: CommandContext): Promise<void> {
  rejectFlags(ctx.values, ["all", "history", "yes"], "edit");

  const { values, positionals } = ctx;
  const id = positionals[0];
  if (!id) {
    throw new UsageError("`alarm edit` requires an alarm id. Usage: alarm edit <id> [flags]");
  }
  const rest = positionals.slice(1);

  let when = values.at;
  let label = values.label;

  const joined = rest.join(" ").trim();
  if (joined.length > 0) {
    if (when === undefined) {
      const split = splitTimeAndLabel(joined);
      if (split) {
        when = split.when;
        if (label === undefined && split.label.length > 0) label = split.label;
      } else if (label === undefined) {
        // No leading time: treat the text as a new label (explicit --at still wins).
        label = joined;
      }
    } else if (label === undefined) {
      label = joined;
    }
  }

  const patch: UpdateAlarmInput = {};
  if (when !== undefined) patch.when = when;
  if (label !== undefined) patch.label = label;
  if (values.days !== undefined) patch.repeat_days = parseDaysSpec(values.days);
  if (values.tone !== undefined) patch.sound_tone = parseTone(values.tone);
  if (values.ramp !== undefined) patch.ramp_seconds = parseRamp(values.ramp);
  if (values.desc !== undefined) patch.description = values.desc;

  if (Object.keys(patch).length === 0) {
    throw new UsageError(
      "Nothing to change. Provide a new time/label, or one of --days, --tone, --ramp, --desc."
    );
  }

  const result = await ctx.client.updateAlarm(id, patch);
  const alarm = await confirmAlarm(ctx.client, result);
  emitMutation(ctx, "edited", result, alarm);
  await warnIfDevicesStale(ctx, result.dispatch);
}
