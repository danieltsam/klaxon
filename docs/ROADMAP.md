# Remote Alarm System — Future Ideas & Architecture Roadmap

This document captures high-value features, architectural concepts, and future expansions planned for upcoming iterations of the Remote Alarm System.

---

## 1. Core Alarm & Audio Features

### 1.1 Custom Sound Selection (Mobile)
- **Local Sound Library:** Offer a curated set of alarm sounds in `mobile/assets/sounds/` (e.g., Gentle Chimes, Digital Pulse, Classic Bell, Energetic Synth).
- **Custom Ringtone Picker:** Integrate native Android `RingtoneManager` or system sound picker to allow users to select their favorite phone ringtone or local MP3 file.
- **Sound Preview:** In-app audio player in the alarm creation sheet to test volume and sound before saving.

### 1.2 Gentle Wake Engine (Universal Volume Ramp)
- **Smooth Exponential / Linear Ramp:** Gradual increase from mute/5% volume to 100% volume over a configurable ramp period (e.g., 30s, 60s, 2m, 5m).
- **Screen Brightness Fade:** Synchronize display brightness on `RingScreen` to slowly ramp from dark to warm morning light.
- **Pre-Alarm Chime:** Optional soft single chime 10 minutes prior to main alarm time.

---

## 2. Advanced Scheduling & Recurrence

### 2.1 Extended Recurrence Patterns
- **Fortnightly (Bi-weekly):** Alarms that trigger every two weeks on specified days (common for shift work and alternating schedules).
- **Monthly / Day-of-Month:** Alarms scheduled on specific days of the month (e.g., 1st and 15th for billing or medication).
- **Custom Skip / Holiday Exceptions:** Option to mute or skip recurring alarms on national holidays or vacation dates.

### 2.2 Calendar Synchronization and Event Management
- **RFC 5545 iCalendar Export (Implemented):** The backend serves `GET /api/calendar.ics`. Users can subscribe to this live URL from Google Calendar, Apple Calendar, or Microsoft Outlook. Active alarms automatically appear as calendar events with recurrence rules (`RRULE`).
- **Google Calendar API Push Integration:** Backend service can authenticate with Google Calendar via OAuth 2.0 or Service Account. When an alarm is created or modified, the backend automatically inserts or updates a corresponding Google Calendar event.
- **Upstream Calendar Event Ingestion:** A background polling worker inspects the user's primary work calendar. The worker automatically creates a remote alarm (for example, 45 minutes before the first meeting of the day) and dispatches it through FCM.
- **CalDAV Server Synchronization:** Support standard CalDAV synchronization for Nextcloud and Fastmail users who prefer self-hosted calendar backends.

---

## 3. Dismissal Challenges ("Mission Alarms")

To prevent accidental shutoffs or oversleeping:
- **Math Challenge:** Solve 2–3 arithmetic problems (easy, medium, hard) before the dismiss button becomes active.
- **Shake Mission:** Vigorously shake the phone 20–50 times (measured via accelerometer).
- **QR / Barcode Scan:** Require scanning a specific QR code taped in the bathroom or kitchen to shut off the alarm.
- **Typing Challenge:** Type a motivational quote or sentence with 100% accuracy.

---

## 4. Multi-Device & Remote Control

### 4.1 Multi-Device Remote Kill
- **Web Dashboard Dismiss:** If your phone is ringing in another room, the web dashboard displays a glowing red **"Ring Active: [Phone Name] — Click to Silence / Dismiss"** button that broadcasts an immediate `KILL` / `DISMISS` FCM command.
- **Multi-Device Sync:** Ring multiple registered devices (e.g. bedside phone + tablet or smart speaker) simultaneously with unified dismiss.

---

## 5. Post-Alarm Smart Briefing

### 5.1 Text-to-Speech (TTS) Morning Briefing
- When the alarm is dismissed, a soothing voice reads out:
  - Current time and greeting.
  - Local weather conditions and forecast temperature.
  - Top 3 calendar events or reminders for the day.
  - Commute traffic conditions.

---

## 6. Backend Control & Settings Panel

### 6.1 Server Configuration Dashboard
- Web UI settings panel to view and modify:
  - Active FCM credentials and connection health.
  - Registered device list with ping / test-signal button.
  - Configurable port, host, and database retention policies.
  - Webhook endpoints for Home Assistant / smart home integrations.
