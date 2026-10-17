# Remote Alarm System — Features & Roadmap

This document tracks implemented features and future enhancements for the Remote Alarm System.

---

## 1. Implemented Features
 
### 1.1 Remote Silence & Kill from Web Dashboard
- **Live Ringing Alert Banner:** Real-time flashing notification on the web dashboard when an alarm transitions to `ringing`.
- **FCM `DISMISS` Payload:** 1-click **"Silence Alarm Now"** button on the web dashboard broadcasts a high-priority FCM `DISMISS` command, silencing the phone ringer immediately and closing `RingScreen`.
- **Dedicated Endpoint:** `POST /api/alarms/:id/silence` transitions status to `dismissed` and dispatches kill command.
 
### 1.2 Reconnection & Bi-directional Sync
- **Local <-> Server Reconciliation:** When the Android app starts, resumes from the background (`WidgetsBindingObserver`), or on manual pull-to-refresh, `AlarmService.syncWithBackend()` reconciles local `AlarmManager` schedules against `GET /api/alarms?view=active`.
- **Automatic Pruning:** Local alarms canceled or silenced on the server are automatically removed on reconnect.
- **Offline Recovery:** Alarms dispatched while the device was sleeping or disconnected are automatically pulled and scheduled.
 
### 1.3 Device Telemetry & Battery Indicator
- **Hardware Telemetry:** Mobile client collects battery percentage (`battery_plus`) and charging status and sends it with registration pings to `POST /api/devices/register`.
- **Dashboard Telemetry Pill:** Web dashboard displays connected device model, battery percentage, charging state, and last ping timestamp in the header.
 
### 1.4 Gentle Wake Engine (Universal Volume Ramp)
- **Smooth Fade-In:** Audio gradually ramps from mute to full volume over configurable durations: Instant (0s), Quick (15s), Gradual (30s default), or Deep Sleep (60s).
- **Supported Everywhere:** Selectable in the web dashboard creation form and the Android local alarm creation sheet.
 
### 1.5 Sound Tone Selection
- **Curated Tone Library:** Select between Classic Bell (`alarm`), Gentle Chimes (`chime`), and Digital Pulse (`digital`).
- **Persisted & Dispatched:** Configured per-alarm in SQLite, included in FCM payloads, and resolved to dedicated audio assets on mobile.
 
### 1.6 Calendar Export & Subscriptions
- **RFC 5545 iCalendar Subscription:** Web dashboard provides a **"Copy iCal Feed"** button with quick instructions to subscribe to `GET /api/calendar.ics` directly in Google Calendar, Apple Calendar, or Outlook.

### 1.7 Missed Alarms
- **Failure is recorded, not hidden:** a one-time alarm that is overdue by more than 5 minutes becomes
  `missed` rather than sitting silently overdue. A backend sweep runs every 60 seconds, and the phone
  reports stale alarms on reconnect through `POST /api/alarms/report-missed`.
- **`missed_reason`:** a closed set of six values describing what could be determined.
- **Visible everywhere:** a Missed group in the app with a Reschedule action, an annotated Google
  Calendar event, the dashboard, the CLI and Raycast.
- **Never revived automatically.** Spec: `superpowers/specs/2026-09-23-missed-alarms-design.md`.

### 1.8 Relative Time Display
- **Scales with distance:** `25 mins`, `13 hours 40 mins`, `13 days 19 hours 23 mins`,
  `3 months 12 days 5 hours`, `1 year 2 months 3 days`. Largest three components, zeros omitted.
- **One shared contract:** `fixtures/relative-time-cases.json` pins the rule for the Dart,
  TypeScript and dashboard implementations. Weeks are deliberately excluded from countdowns.

### 1.9 Fortnightly Recurrence
- **Interval recurrence:** alarms repeat every 1 or 2 weeks, anchored to their first occurrence. The
  backend validates `recurrence_interval_weeks` (1 or 2) and the Google Calendar mirror emits an
  `INTERVAL` RRULE.
- **Known gap:** the ICS feed does not emit `INTERVAL`.

---
 
## 2. Future Backlog (Roadmap)

### 2.1 Google Calendar Auto-Ingest
- **Export direction — IMPLEMENTED:** alarms mirror out into a dedicated "Remote Alarms" Google
  Calendar, with push-on-mutation, a 15-minute drift reconcile, and health at
  `GET /api/calendar/status`. See the **Google Calendar Sync** section in `README.md`.
- **Ingest direction — BACKLOG:** a background polling worker inspects the user's primary
  work/personal calendar via Google Calendar API or CalDAV.
- It would then automatically schedule an alarm (e.g. 45 minutes before the first morning meeting)
  and dispatch it through FCM.

### 2.2 Dismissal Challenges ("Mission Alarms")
- Optional challenges to prevent accidental dismissals:
  - Arithmetic problems (easy/medium/hard).
  - Accelerometer shake count (e.g. shake 20 times).
  - QR / Barcode scan requirement.

### 2.3 Post-Alarm Smart Morning Briefing
- When alarm is dismissed, text-to-speech (TTS) reads greeting, current weather, and first calendar events.

### 2.4 CLI Companion & Raycast Extension — COMPLETE
- Rapid terminal command (`alarm 25m "Oven"`) or Raycast extension for zero-friction scheduling without opening the browser.
- **Shipped** from the approved 2026-09-21 design: [`docs/superpowers/specs/2026-09-21-clients-cli-raycast-design.md`](superpowers/specs/2026-09-21-clients-cli-raycast-design.md). A shared dependency-free core (`clients/core`) with two presentation shells (`clients/cli`, `clients/raycast`). No backend changes were required.
- Verified end-to-end against the live homelab.

---

## 3. Backlog — UX & Polish (captured 2026-10-17, from a device walkthrough)

### 3.1 Bugs to fix first
- **"Arm Alarm" creates a ghost duplicate.** Arming creates two alarms; the second disappears after about a second. Data integrity — fix first.
- **Toasts queue and drift.** "Alarm armed" / "deactivated" toasts linger, stack, and describe actions that are no longer current. A new toast must pre-empt the previous one.
- **Deleting alarms is serialised.** Roughly half a second per alarm with dead screen time between. It should run as one action.

### 3.2 Alarm list
- **Reordering is invisible.** Selecting a later alarm moves it to the top, but the rows look nearly identical, so the move is not apparent. It needs a visible move animation.
- **The Duplicate action is in question.** The owner doubts anyone wants to duplicate an alarm rather than create one. Also open: what two alarms at the same clock time should do.

### 3.3 Set-an-alarm flow (the "quick to set" reinvestigation)
- **"New Alarm" should land in the title field.** Remove the pre-filled "morning workout" placeholder and focus the name input.
- **Review the hour and minute wheels.** The owner prefers them to Google Clock's inner/outer hour ring, but calls them "a little clunky" and wants alternatives explored.
- **Fewer taps overall.** Google Clock is the bar.

### 3.4 Haptics
- Add a **10-minute milestones** style. Also try **8, 6 and 12-minute** variants.
- **Promote SOS and double-heartbeat to permanent options** for alarm haptics.
- **Then retire the haptics testing lab.**

### 3.5 Settings polish
- The sound-profile dropdown gives **no preview** when tapping *ding / chime / digital*, and the labels are unclear.
- The dropdown box is **square** while the rest of the app is round.

### 3.6 Branding
- Rename the app to **KLAXON** (K-L-A-X-O-N) in the app title, with a small **klaxon SVG**.

### 3.7 Research (no code yet)
- **Tunnel options.** Test Tailscale Funnel and Cloudflare Tunnel properly.
- **Non-technical users.** What options exist for someone who does not want to run their own homelab or service — including what auth would entail. Revisit the reachability plan.
