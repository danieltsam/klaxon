/**
 * Shared command plumbing: output context, server-confirmed alarm resolution,
 * mutation rendering (including spec §9 trust messaging), and error rendering.
 */

import {
  formatAlarm,
  formatRelative,
  toLocalDate,
  type Alarm,
  type AlarmMutationResult,
  type FcmDispatch,
  type RemoteAlarmClient,
} from "@remotealarm/core";
import { createInterface } from "node:readline/promises";
import { UsageError } from "../errors.js";
import {
  allDevicesStale,
  dispatchWarnings,
  hasValidTarget,
  renderAlarmBlock,
  renderDispatchLine,
  type Palette,
} from "../render.js";
import type { CliValues } from "../args.js";

export interface Output {
  stdout(text: string): void;
  stderr(text: string): void;
}

export interface CommandContext {
  client: RemoteAlarmClient;
  values: CliValues;
  /** Positionals after the command name (create passes the full list). */
  positionals: string[];
  out: Output;
  palette: Palette;
  json: boolean;
  now: () => Date;
  baseUrl: string;
}

export function requireId(positionals: string[], command: string): string {
  const id = positionals[0];
  if (!id) {
    throw new UsageError(`\`alarm ${command}\` requires an alarm id. Usage: alarm ${command} <id>`);
  }
  if (positionals.length > 1) {
    throw new UsageError(`Unexpected extra arguments: ${positionals.slice(1).join(" ")}`);
  }
  return id;
}

/**
 * Some endpoints (DELETE, silence, state) return only `{ id, status, ... }`
 * rather than the full row. The spec requires every mutating command to print
 * the server-confirmed alarm with its resolved local time, so re-read the
 * authoritative record from the server when the mutation payload is partial.
 *
 * Both `all` and `history` are searched: the backend's `all` view deliberately
 * excludes `canceled` rows (`db.ts` `WHERE status != 'canceled'`), so a cancel
 * can only be re-read from history.
 */
export async function confirmAlarm(
  client: RemoteAlarmClient,
  result: AlarmMutationResult
): Promise<Alarm> {
  const alarm = result.alarm;
  if (hasValidTarget(alarm) && alarm.label) return alarm;

  try {
    const [all, history] = await Promise.all([
      client.listAlarms("all"),
      client.listAlarms("history"),
    ]);
    const found = [...all, ...history].find((candidate) => candidate.id === alarm.id);
    if (found) {
      // The mutation payload carries the authoritative post-transition status.
      return { ...found, status: alarm.status || found.status };
    }
  } catch {
    // Best effort only — fall back to whatever the mutation returned.
  }
  return alarm;
}

/** Render a completed mutation to stdout (human or JSON). */
export function emitMutation(
  ctx: CommandContext,
  action: string,
  result: AlarmMutationResult,
  alarm: Alarm
): void {
  const now = ctx.now();
  const dispatch = result.dispatch;

  if (ctx.json) {
    ctx.out.stdout(
      JSON.stringify(
        {
          ok: true,
          action,
          alarm,
          local: hasValidTarget(alarm) ? formatAlarm(alarm) : null,
          iso: hasValidTarget(alarm) ? new Date(alarm.target_time).toISOString() : null,
          relative: hasValidTarget(alarm) ? formatRelative(now, toLocalDate(alarm)) : null,
          dispatch: dispatch ?? null,
          warnings: dispatchWarnings(dispatch),
        },
        null,
        2
      )
    );
    return;
  }

  const lines: string[] = [];
  lines.push(`${ctx.palette.green(action)} ${ctx.palette.bold(alarm.id)}`);
  lines.push(renderAlarmBlock(alarm, now, ctx.palette));
  lines.push(`  ${renderDispatchLine(dispatch, ctx.palette)}`);
  ctx.out.stdout(lines.join("\n"));
}

/**
 * Spec §9.3: reachability is asserted from `/api/devices`, never inferred from
 * `fcm_dispatch`. Best-effort — a device read failure must not fail the create.
 */
export async function warnIfDevicesStale(
  ctx: CommandContext,
  dispatch: FcmDispatch | undefined
): Promise<void> {
  if (dispatch === undefined || dispatch.sent === 0) return;
  try {
    const devices = await ctx.client.listDevices();
    if (devices.length === 0) return;
    if (allDevicesStale(devices, ctx.now())) {
      ctx.out.stderr(
        ctx.palette.yellow(
          "warning: no registered device has checked in for over 24h — the alarm may not ring."
        )
      );
    }
  } catch {
    // Reachability is advisory; ignore failures.
  }
}

/** Interactive y/N prompt. Only reached when stdin is a TTY. */
export async function confirmPrompt(question: string): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer = (await rl.question(question)).trim().toLowerCase();
    return answer === "y" || answer === "yes";
  } finally {
    rl.close();
  }
}

// ── Error rendering ────────────────────────────────────────────────────────

interface ErrorContext {
  palette: Palette;
  json: boolean;
  baseUrl: string;
  out: Output;
}

function describeNetworkHelp(baseUrl: string, palette: Palette): string {
  return [
    palette.dim(`  Tried: ${baseUrl}`),
    "  If the backend runs in Docker, it is published on host port 8001:",
    palette.cyan("    http://localhost:8001"),
    "  Over Tailscale, use the machine's MagicDNS name:",
    palette.cyan("    http://<host>.<tailnet>.ts.net:3000   (or :8001 when that host runs Docker)"),
  ].join("\n");
}

export function renderError(err: unknown, ctx: ErrorContext): void {
  const name = err instanceof Error ? err.name : "Error";
  const message = err instanceof Error ? err.message : String(err);
  const status =
    typeof (err as { status?: unknown }).status === "number"
      ? ((err as { status: number }).status as number)
      : undefined;
  const isNetwork = name === "RemoteAlarmNetworkError";

  if (ctx.json) {
    ctx.out.stderr(
      JSON.stringify(
        {
          ok: false,
          error: {
            name,
            message,
            ...(status !== undefined ? { status } : {}),
          },
        },
        null,
        2
      )
    );
    return;
  }

  const lines: string[] = [];
  const prefix = `${ctx.palette.red("error:")} `;
  const suffix = status !== undefined ? ctx.palette.dim(` (HTTP ${status})`) : "";
  lines.push(prefix + message + suffix);
  if (isNetwork) lines.push(describeNetworkHelp(ctx.baseUrl, ctx.palette));
  ctx.out.stderr(lines.join("\n"));
}
