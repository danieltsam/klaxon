#!/usr/bin/env node
/**
 * `alarm` — Remote Alarm CLI entry point.
 *
 * The CLI is a presentation shell: it parses input, calls `@remotealarm/core`,
 * and renders results. It must not reimplement timezone, `repeat_days`, or
 * error semantics — those live in core (spec §4.1).
 */

import { RemoteAlarmClient } from "@remotealarm/core";
import { configCommand } from "./commands/config.js";
import { createCommand } from "./commands/create.js";
import { editCommand } from "./commands/edit.js";
import { listCommand } from "./commands/list.js";
import {
  disableCommand,
  enableCommand,
  killCommand,
  silenceCommand,
  skipCommand,
  unskipCommand,
} from "./commands/mutate.js";
import { statusCommand } from "./commands/status.js";
import {
  COMMAND_NAMES,
  commandHelp,
  parseCliArgs,
  topHelp,
  type CliValues,
} from "./args.js";
import { resolveBaseUrl } from "./config.js";
import { exitCodeForError } from "./errors.js";
import { makePalette } from "./render.js";
import { renderError, type CommandContext, type Output } from "./commands/shared.js";

export function resolveColor(values: CliValues): boolean {
  if (values["no-color"]) return false;
  if (process.env.NO_COLOR) return false;
  return Boolean(process.stdout.isTTY);
}

function makeOutput(): Output {
  return {
    stdout: (text: string) => process.stdout.write(`${text}\n`),
    stderr: (text: string) => process.stderr.write(`${text}\n`),
  };
}

export async function main(argv: string[] = process.argv.slice(2)): Promise<number> {
  const out = makeOutput();

  let values: CliValues = {};
  let positionals: string[] = [];
  let baseUrl = resolveBaseUrl().baseUrl;

  try {
    const parsed = parseCliArgs(argv);
    values = parsed.values;
    positionals = parsed.positionals;

    const palette = makePalette(resolveColor(values));
    const json = Boolean(values.json);

    const command = positionals[0];
    const isKnownCommand = command !== undefined && COMMAND_NAMES.has(command);

    // --help (top level or per-command) always exits 0.
    if (values.help) {
      out.stdout(command !== undefined && isKnownCommand ? commandHelp(command) : topHelp());
      return 0;
    }

    if (command === undefined) {
      // `alarm --at <when> --label <text>` is a valid create with no positionals.
      if (values.at === undefined) {
        out.stderr(topHelp());
        return 1;
      }
    } else if (command === "help") {
      out.stdout(topHelp());
      return 0;
    }

    // `config` is the only command that does not need a client.
    if (command === "config") {
      configCommand({ values, out, palette, json });
      return 0;
    }

    const resolved = resolveBaseUrl(values.url);
    baseUrl = resolved.baseUrl;
    const client = new RemoteAlarmClient({ baseUrl: resolved.baseUrl });

    const ctx = (commandPositionals: string[]): CommandContext => ({
      client,
      values,
      positionals: commandPositionals,
      out,
      palette,
      json,
      now: () => new Date(),
      baseUrl: resolved.baseUrl,
    });

    switch (command) {
      case "list":
        await listCommand(ctx(positionals.slice(1)));
        return 0;
      case "silence":
        await silenceCommand(ctx(positionals.slice(1)));
        return 0;
      case "skip":
        await skipCommand(ctx(positionals.slice(1)));
        return 0;
      case "unskip":
        await unskipCommand(ctx(positionals.slice(1)));
        return 0;
      case "kill":
        await killCommand(ctx(positionals.slice(1)));
        return 0;
      case "enable":
        await enableCommand(ctx(positionals.slice(1)));
        return 0;
      case "disable":
        await disableCommand(ctx(positionals.slice(1)));
        return 0;
      case "edit":
        await editCommand(ctx(positionals.slice(1)));
        return 0;
      case "status":
        await statusCommand(ctx(positionals.slice(1)));
        return 0;
      default:
        // Anything that is not a known command is a create invocation.
        await createCommand(ctx(positionals));
        return 0;
    }
  } catch (err) {
    renderError(err, {
      palette: makePalette(resolveColor(values)),
      json: Boolean(values.json),
      baseUrl,
      out,
    });
    return exitCodeForError(err);
  }
}

const exitCode = await main();
process.exitCode = exitCode;
