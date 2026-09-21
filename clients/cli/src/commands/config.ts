/**
 * `alarm config [--url <base>]` — show or persist the backend URL.
 */

import { resolveBaseUrl, writeConfigUrl } from "../config.js";
import { rejectFlags, type CliValues } from "../args.js";
import type { Output } from "./shared.js";
import type { Palette } from "../render.js";

export interface ConfigContext {
  values: CliValues;
  out: Output;
  palette: Palette;
  json: boolean;
}

export function configCommand(ctx: ConfigContext): void {
  rejectFlags(
    ctx.values,
    ["all", "history", "yes", "at", "label", "days", "tone", "ramp", "desc"],
    "config"
  );

  if (ctx.values.url !== undefined) {
    const path = writeConfigUrl(ctx.values.url);
    if (ctx.json) {
      ctx.out.stdout(
        JSON.stringify({ ok: true, saved: true, baseUrl: ctx.values.url, configPath: path }, null, 2)
      );
      return;
    }
    ctx.out.stdout(`Saved backend URL ${ctx.palette.cyan(ctx.values.url)} to ${ctx.palette.dim(path)}`);
    return;
  }

  const resolved = resolveBaseUrl();
  if (ctx.json) {
    ctx.out.stdout(
      JSON.stringify(
        {
          baseUrl: resolved.baseUrl,
          source: resolved.source,
          configPath: resolved.configPath,
          envSet: Boolean(process.env.REMOTEALARM_URL),
        },
        null,
        2
      )
    );
    return;
  }

  ctx.out.stdout(`Backend URL: ${ctx.palette.cyan(resolved.baseUrl)}`);
  ctx.out.stdout(`Source:      ${resolved.source}`);
  ctx.out.stdout(`Config file: ${ctx.palette.dim(resolved.configPath)}`);
  if (resolved.source === "default") {
    ctx.out.stdout(
      ctx.palette.dim(
        "Set one with `alarm config --url <base>`, REMOTEALARM_URL, or --url for a single invocation."
      )
    );
  }
}
