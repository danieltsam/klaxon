/**
 * Backend URL resolution (spec §7.3).
 *
 * Precedence: `--url` flag → `REMOTEALARM_URL` env → config file → default.
 * The config file is XDG-respecting:
 *   $XDG_CONFIG_HOME/remotealarm/config.json  (or ~/.config/remotealarm/config.json)
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const DEFAULT_BASE_URL = "http://localhost:3000";

export type ConfigSource = "flag" | "env" | "config" | "default";

export interface ResolvedConfig {
  baseUrl: string;
  source: ConfigSource;
  configPath: string;
}

/** Absolute path to the config file, honouring XDG_CONFIG_HOME when set. */
export function configPath(): string {
  const xdg = process.env.XDG_CONFIG_HOME;
  const base = xdg && xdg.trim().length > 0 ? xdg.trim() : join(homedir(), ".config");
  return join(base, "remotealarm", "config.json");
}

function readConfigFile(): Record<string, unknown> {
  const path = configPath();
  if (!existsSync(path)) return {};
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : {};
  } catch {
    // A corrupt config file must not crash the CLI; fall through to defaults.
    return {};
  }
}

export function readConfigUrl(): string | undefined {
  const url = readConfigFile().url;
  return typeof url === "string" && url.trim().length > 0 ? url.trim() : undefined;
}

/** Persist `url` into the config file, preserving any other keys. */
export function writeConfigUrl(url: string): string {
  const path = configPath();
  mkdirSync(dirname(path), { recursive: true });
  const existing = readConfigFile();
  existing.url = url;
  writeFileSync(path, `${JSON.stringify(existing, null, 2)}\n`, "utf8");
  return path;
}

/** Resolve the effective base URL using the documented precedence. */
export function resolveBaseUrl(flagUrl?: string): ResolvedConfig {
  const path = configPath();

  if (flagUrl !== undefined && flagUrl.trim().length > 0) {
    return { baseUrl: flagUrl.trim(), source: "flag", configPath: path };
  }

  const env = process.env.REMOTEALARM_URL;
  if (env !== undefined && env.trim().length > 0) {
    return { baseUrl: env.trim(), source: "env", configPath: path };
  }

  const fileUrl = readConfigUrl();
  if (fileUrl !== undefined) {
    return { baseUrl: fileUrl, source: "config", configPath: path };
  }

  return { baseUrl: DEFAULT_BASE_URL, source: "default", configPath: path };
}
