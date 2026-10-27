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
npm run lint     # Raycast lint
npm run build    # bundles the extension
npm test         # parser, formatting and client tests (node:test)
```

This repo vendors its client core from the Klaxon backend project. See `VENDORED-FROM.md` before editing anything under `src/core/`.
