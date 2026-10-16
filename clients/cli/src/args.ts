/**
 * Argument parsing, flag validation, and the CLI's help text.
 *
 * Uses Node's built-in `parseArgs` (no dependencies). All flags across all
 * commands are declared here in one superset; each command then rejects the
 * flags that do not apply to it, so an unknown or misplaced flag is a usage
 * error rather than being silently ignored.
 */

import { parseArgs } from "node:util";
import {
  parseLeadingTime,
  parseTime,
  TimeParseError,
  type SoundTone,
  type Weekday,
} from "@remotealarm/core";
import { UsageError } from "./errors.js";

export const COMMAND_NAMES: ReadonlySet<string> = new Set([
  "list",
  "silence",
  "kill",
  "enable",
  "disable",
  "edit",
  "status",
  "config",
]);

export interface CliValues {
  help?: boolean;
  json?: boolean;
  "no-color"?: boolean;
  yes?: boolean;
  all?: boolean;
  history?: boolean;
  at?: string;
  label?: string;
  days?: string;
  tone?: string;
  ramp?: string;
  desc?: string;
  url?: string;
}

const OPTIONS = {
  help: { type: "boolean", short: "h" },
  json: { type: "boolean" },
  "no-color": { type: "boolean" },
  yes: { type: "boolean", short: "y" },
  all: { type: "boolean" },
  history: { type: "boolean" },
  at: { type: "string" },
  label: { type: "string", short: "l" },
  days: { type: "string", short: "d" },
  tone: { type: "string" },
  ramp: { type: "string" },
  desc: { type: "string" },
  url: { type: "string" },
} as const;

export interface ParsedCli {
  positionals: string[];
  values: CliValues;
}

export function parseCliArgs(argv: string[]): ParsedCli {
  try {
    const parsed = parseArgs({
      args: argv,
      options: OPTIONS,
      allowPositionals: true,
      strict: true,
    });
    return {
      positionals: parsed.positionals,
      values: parsed.values as CliValues,
    };
  } catch (err) {
    throw new UsageError(err instanceof Error ? err.message : String(err));
  }
}

/** Throw if any of `flags` was supplied. Used for per-command validation. */
export function rejectFlags(values: CliValues, flags: readonly string[], context: string): void {
  for (const flag of flags) {
    if (values[flag as keyof CliValues] !== undefined) {
      throw new UsageError(`--${flag} is not valid for \`alarm ${context}\`.`);
    }
  }
}

// ── Time / label split (spec §7.1) ─────────────────────────────────────────

export interface TimeLabelSplit {
  when: string;
  label: string;
}

/**
 * Split `input` into the time expression and the remainder (the label). The
 * time is normally the longest leading prefix, but `parseLeadingTime` also
 * matches a span anywhere in the input (a label-first phrase like
 * `gym tomorrow 7am`), in which case the label leads. Returns `null` when no
 * time parses, or when the matched span is interior (no single `when` string).
 */
export function splitTimeAndLabel(input: string): TimeLabelSplit | null {
  const trimmed = input.trim();
  if (trimmed.length === 0) return null;

  const result = parseLeadingTime(trimmed);
  if (!result) return null;

  const all = trimmed.split(/\s+/).filter(Boolean);
  const label = result.rest.trim();
  const restTokens = label.length > 0 ? label.split(/\s+/).filter(Boolean) : [];

  if (restTokens.length === 0) {
    return { when: all.join(" "), label: "" };
  }

  // `rest` is the text surrounding the matched span: a leading time leaves the
  // label trailing, a label-first phrase leaves it leading. Detect which end.
  const labelTrails = restTokens.every(
    (token, k) => all[all.length - restTokens.length + k] === token
  );
  if (labelTrails) {
    return { when: all.slice(0, all.length - restTokens.length).join(" "), label };
  }
  const labelLeads = restTokens.every((token, k) => all[k] === token);
  if (labelLeads) {
    return { when: all.slice(restTokens.length).join(" "), label };
  }
  // An interior time span has no single contiguous `when` string.
  return null;
}

// ── Flag value validation (fail before any request) ────────────────────────

const TONES: readonly SoundTone[] = ["alarm", "chime", "digital"];
const RAMPS = [0, 15, 30, 60] as const;

export function parseTone(value: string): SoundTone {
  const normalized = value.trim().toLowerCase();
  if ((TONES as readonly string[]).includes(normalized)) return normalized as SoundTone;
  throw new UsageError(`Invalid --tone "${value}". Must be one of: ${TONES.join(", ")}.`);
}

export function parseRamp(value: string): number {
  const n = Number(value);
  if (!Number.isInteger(n) || !(RAMPS as readonly number[]).includes(n)) {
    throw new UsageError(`Invalid --ramp "${value}". Must be one of: ${RAMPS.join(", ")}.`);
  }
  return n;
}

/**
 * Parse `-d/--days <spec>` into a `Weekday[]`.
 *
 * The core parser is the only place that understands recurrence syntax, so we
 * reuse it: `parseTime("<spec> 12am")` yields `repeatDays`. A lone weekday
 * (`-d mon`) is a day *qualifier* rather than a recurrence, so it is retried
 * as `every mon` to express a weekly repeat.
 */
export function parseDaysSpec(spec: string): Weekday[] {
  const normalized = spec.trim().toLowerCase();
  if (normalized.length === 0) {
    throw new UsageError(
      "Invalid --days: expected daily, weekdays, weekends, mon-fri, or mon,wed,fri."
    );
  }

  const trySpec = (candidate: string): Weekday[] | null => {
    try {
      const parsed = parseTime(`${candidate} 12am`);
      return parsed.repeatDays.length > 0 ? parsed.repeatDays : null;
    } catch (err) {
      if (err instanceof TimeParseError) return null;
      throw err;
    }
  };

  const direct = trySpec(normalized);
  if (direct) return direct;

  const single = trySpec(`every ${normalized}`);
  if (single) return single;

  throw new UsageError(
    `Invalid --days "${spec}". Expected daily, weekdays, weekends, mon-fri, or mon,wed,fri.`
  );
}

// ── Help text ──────────────────────────────────────────────────────────────

const TIME_FORMS = `Time forms: 25m · 1h30m · 90s · 7am · 7:30am · 19:00 · tomorrow 6pm
            mon 8:30am · daily 7am · weekdays 7am · mon,wed,fri 7am`;

export function topHelp(): string {
  return `alarm — Remote Alarm CLI

Usage:
  alarm <when> <label> [flags]        Create an alarm
  alarm list [--all|--history]        List alarms (default: active)
  alarm silence <id>                  Silence a ringing alarm
  alarm kill <id> [--yes]             Cancel an alarm (DELETE)
  alarm enable <id>                   Re-enable a disabled alarm
  alarm disable <id>                  Disable an alarm
  alarm edit <id> [flags]             Edit an alarm
  alarm status                        Show device battery / charging / last ping
  alarm config [--url <base>]         Show or set the backend URL

Create/edit flags:
  -d, --days <spec>   Recurrence: daily | weekdays | weekends | mon-fri | mon,wed,fri
      --at <when>     Time expression (overrides the positional time/label split)
  -l, --label <text>  Label (overrides the positional split)
      --tone <tone>   alarm | chime | digital
      --ramp <secs>   0 | 15 | 30 | 60
      --desc <text>   Description

Global flags:
      --url <base>    Backend base URL (overrides env/config for this invocation)
      --json          Machine-readable JSON output
      --no-color      Disable ANSI colour
  -h, --help          Show help (per-command: alarm list --help)

${TIME_FORMS}

Exit codes: 0 ok · 1 usage/parse · 2 network · 3 API · 4 not found`;
}

export function commandHelp(command: string): string {
  switch (command) {
    case "list":
      return `Usage: alarm list [--all|--history] [--json]

  List alarms. Default view is active.

  --all       Include history (canceled / dismissed)
  --history   Only history
  --json      JSON output`;
    case "silence":
      return `Usage: alarm silence <id>

  Silences a ringing alarm (POST /api/alarms/:id/silence).
  Prints the server-confirmed alarm and its resolved local time.`;
    case "kill":
      return `Usage: alarm kill <id> [--yes]

  Cancels an alarm (DELETE /api/alarms/:id).

  Prompts interactively for confirmation. When stdin is not a TTY, --yes is
  required so a script can never delete an alarm by accident.`;
    case "enable":
      return `Usage: alarm enable <id>

  Re-enables a disabled alarm (status -> pending) and prints the
  server-confirmed alarm with its resolved local time.`;
    case "disable":
      return `Usage: alarm disable <id>

  Disables an alarm (status -> disabled) and prints the server-confirmed
  alarm with its resolved local time.`;
    case "edit":
      return `Usage: alarm edit <id> [when-and-label...] [flags]

  Edit an alarm's fields. Positional text uses the same time/label split as
  create; --at / --label override it.

  -d, --days <spec>   Recurrence: daily | weekdays | weekends | mon-fri | mon,wed,fri
      --at <when>     New time expression
  -l, --label <text>  New label
      --tone <tone>   alarm | chime | digital
      --ramp <secs>   0 | 15 | 30 | 60
      --desc <text>   Description`;
    case "status":
      return `Usage: alarm status [--json]

  Show registered devices: battery, charging state, and last-ping age.
  Alarms cannot ring without a registered device.`;
    case "config":
      return `Usage: alarm config [--url <base>] [--json]

  With no flags, show the resolved backend URL and where it came from.
  With --url, persist the URL to the config file.

  Precedence: --url -> REMOTEALARM_URL -> config file -> http://localhost:3000`;
    default:
      return topHelp();
  }
}

/** Usage message shown when no leading time prefix parses (spec §7.1). */
export function timeUsageError(input: string): UsageError {
  return new UsageError(
    `Could not parse a time from "${input}". A time expression must come first.\n\n` +
      `  alarm 25m Oven\n  alarm tomorrow 6pm Call mum\n  alarm 8am 5 minute warning\n\n` +
      `${TIME_FORMS}\n\nUse --at <when> to set the time explicitly and --label to set the label.`
  );
}
