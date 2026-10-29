/**
 * `alarm silence | kill | enable | disable <id>` — mutating state commands.
 */

import { rejectFlags } from "../args.js";
import { UsageError } from "../errors.js";
import {
  confirmAlarm,
  confirmPrompt,
  emitMutation,
  requireId,
  warnIfDevicesStale,
  type CommandContext,
} from "./shared.js";

const MUTATION_FLAGS = ["all", "history", "at", "label", "days", "tone", "ramp", "desc"] as const;

export async function silenceCommand(ctx: CommandContext): Promise<void> {
  rejectFlags(ctx.values, MUTATION_FLAGS, "silence");
  const id = requireId(ctx.positionals, "silence");
  const result = await ctx.client.silenceAlarm(id);
  const alarm = await confirmAlarm(ctx.client, result);
  emitMutation(ctx, "silenced", result, alarm);
}

export async function skipCommand(ctx: CommandContext): Promise<void> {
  rejectFlags(ctx.values, MUTATION_FLAGS, "skip");
  const id = requireId(ctx.positionals, "skip");
  const result = await ctx.client.skipAlarm(id);
  const alarm = await confirmAlarm(ctx.client, result);
  emitMutation(ctx, "skipped", result, alarm);
}

export async function unskipCommand(ctx: CommandContext): Promise<void> {
  rejectFlags(ctx.values, MUTATION_FLAGS, "unskip");
  const id = requireId(ctx.positionals, "unskip");
  const result = await ctx.client.unskipAlarm(id);
  const alarm = await confirmAlarm(ctx.client, result);
  emitMutation(ctx, "unskipped", result, alarm);
}

export async function enableCommand(ctx: CommandContext): Promise<void> {
  rejectFlags(ctx.values, MUTATION_FLAGS, "enable");
  const id = requireId(ctx.positionals, "enable");
  const result = await ctx.client.setState(id, "pending");
  const alarm = await confirmAlarm(ctx.client, result);
  emitMutation(ctx, "enabled", result, alarm);
  await warnIfDevicesStale(ctx, result.dispatch);
}

export async function disableCommand(ctx: CommandContext): Promise<void> {
  rejectFlags(ctx.values, MUTATION_FLAGS, "disable");
  const id = requireId(ctx.positionals, "disable");
  const result = await ctx.client.setState(id, "disabled");
  const alarm = await confirmAlarm(ctx.client, result);
  emitMutation(ctx, "disabled", result, alarm);
}

export async function killCommand(ctx: CommandContext): Promise<void> {
  rejectFlags(ctx.values, ["all", "history", "at", "label", "days", "tone", "ramp", "desc"], "kill");
  const id = requireId(ctx.positionals, "kill");

  if (!ctx.values.yes) {
    if (!process.stdin.isTTY) {
      throw new UsageError(
        "Refusing to cancel without --yes when stdin is not a TTY. " +
          `Re-run as: alarm kill ${id} --yes`
      );
    }
    const confirmed = await confirmPrompt(`Cancel alarm ${id}? [y/N] `);
    if (!confirmed) {
      ctx.out.stdout("Aborted.");
      return;
    }
  }

  const result = await ctx.client.cancelAlarm(id);
  const alarm = await confirmAlarm(ctx.client, result);
  emitMutation(ctx, "cancelled", result, alarm);
}
