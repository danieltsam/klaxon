# Klaxon for Raycast

Set, inspect, and silence alarms on a self-hosted Klaxon backend without touching your phone.

Five commands:

| Command | What it does |
|---|---|
| **List Alarms** | Grouped Ringing / Missed / Today / Upcoming / Recurring, with a detail pane |
| **Quick Create Alarm** | One natural-language sentence, live resolved-time preview |
| **Create Alarm** | Full precision form |
| **Edit Alarm** | Edit an existing alarm by id |
| **Device Status** | Battery, charging state, last ping age |

## Setup

1. Install dependencies: `npm install`
2. Start it in Raycast: `npm run dev`
3. Set **Backend URL** in the extension preferences.

The backend is the Klaxon server (`remotealarm` in older docs). It exposes `GET /api/health`, `GET /api/alarms`, and the rest of the alarm CRUD surface. There is no authentication, so run it on a tailnet or a private network.

## What the natural-language field understands

`25m Oven`, `tomorrow 6pm Call mum`, `uni meeting tomorrow at 8pm`, `every other monday 7am Gym`, `chime tomorrow 7am`, `tomorrow 7am note: bring towel`.

Times resolve forward only. A sentence the parser cannot read confidently is refused with a message rather than guessed.

Recurrence is limited to weekly or fortnightly because that is what the backend stores. `every 3 days` is refused, not silently turned into a one-time alarm.

## Notes

- A dispatch report says "sent", never "delivered". A phone that is off will not be reached.
- Saving with no registered device shows a warning, because the alarm will not ring.
- A missed alarm is never treated as live; reschedule it instead of enabling it.

## Development

```bash
npm run lint       # Raycast lint
npm run build      # bundles the extension
npm run typecheck  # tsc; ray build does not type-check
```

The extension uses `@remotealarm/core` from `../core`. All parser, formatting and client behaviour lives there, so change it in one place and rebuild the core.

## Publishing to the Raycast Store

The extension stays in this repo until release. The store does not publish from a monorepo: it takes a pull request against `raycast/extensions` containing one self-contained folder, `extensions/klaxon/`, and runs `npm install` inside it. A `file:../core` dependency cannot resolve there.

At release, pick one:

1. **Vendor the core into the submission folder.** Copy `clients/core/src` into the submission as `src/core/`, strip the `.js` import specifiers, and rewrite the views to import `./core`. This is what the deleted standalone repo did. Repeatable, but the copy can drift.
2. **Publish the core as a package.** Publish `@remotealarm/core` (probably renamed `klaxon-core`) and depend on a version. No drift, but a second public artifact to maintain.

Either way the submission folder is generated and not the working copy. A small script that assembles it from `clients/raycast` plus `clients/core`, then runs `ray build`, is the thing to write when release comes.
