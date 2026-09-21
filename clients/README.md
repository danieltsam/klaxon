# Remote Alarm clients

Headless clients for the Remote Alarm backend, sharing one logic core:

```
clients/
├── core/     @remotealarm/core — ALL logic: types, client, time parser, formatters
├── cli/      `alarm` — terminal command (later lane)
└── raycast/  Raycast extension (later lane)
```

`core` is the only package with logic. The CLI and Raycast extension are
presentation shells: they parse input, call core, and render results. Any
decision about timezones, `repeat_days` encoding, or error semantics belongs in
`core`, not in a shell.

## Setup

Requires Node 22+ (the Raycast host runs Node 22.22.2; core must not use
Node-24+ APIs).

```sh
cd clients
npm install
```

`cli/` and `raycast/` are workspace placeholders in this lane; the core package
is the only one with source and tests today.

## Build

```sh
npm run build          # tsc for @remotealarm/core -> core/dist
npm run watch:core     # rebuild core on change; required during Raycast dev
```

The Raycast bundler inlines `core/dist` at build time and **does not watch
`../core`**. A missing `dist` fails loudly, but a *stale* one will silently ship
old logic — so the core watcher is a required part of the dev loop, not a
convenience. Run `npm run watch:core` in one terminal before `ray develop`.

## Test

```sh
npm test               # node:test + node:assert/strict via tsx
```

All parser, client-contract, and formatter tests inject `fetch` and `now`, so
they need no network and never depend on the wall clock.

## Verification

```sh
cd clients
npm install
npm run build
npm test
```

`core` has **zero runtime dependencies** — only the global `fetch`. Do not add
one: Raycast's bundler rejects native modules, and a transitive dependency is a
permanent liability.

## Notes

- `Alarm.target_time` is the raw UTC string from the server. Derive local time
  only through `toLocalDate(alarm)` in `core/src/format.ts` — the single
  conversion point.
- `repeat_days` is overloaded on the wire (`string | number[]`); `core` encodes
  arrays to `"1,2,3,4,5"` and decodes strings back to `Weekday[]`.
- `fcm_dispatch` is an explicitly untrusted, separate field. It is never a
  success boolean: a missing report is "no dispatch report", and `sent > 0` is
  not proof of delivery. Reachability is asserted from `GET /api/devices`.
- No authentication (accepted risk — the backend has none).
