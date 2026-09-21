# Future Backlog: Hero Card Animations & Haptics Roadmap

This document captures creative ideations and design options for future iterations on the **Hero Alarm Card animations** and the **System Haptics Engine**, preserving context for implementation when prioritized.

---

## 1. Hero Alarm Card Animation Concepts

Currently, when the last enabled alarm is toggled off (or the first alarm is enabled), the Hero Alarm card transitions using a combined **`AnimatedSize` (350ms, cubic ease)** and **`AnimatedSwitcher` (280ms fade + directional size transition)**.

Here are the explored alternatives and future animation variations:

### Concept A: Shared Axis / Card Morphing Transition
- **How it works**: Instead of the hero card collapsing into nothing and the list item sliding up, the active alarm card in the list *morphs* directly into the hero card (similar to Flutter's Material Container Transform / Shared Axis).
- **Visual effect**: When turning on an alarm in the list, that alarm card expands upward into the top slot, the time font smoothly interpolates to 42pt, and the ambient purple glow fades in behind it. When toggling off, the hero shrinks down and settles smoothly into its alphabetical/time slot in the list.
- **Tech stack**: `flutter/src/material/container_transform` or custom `Hero` / `LayoutBuilder` with an implicit curve.

### Concept B: Live Flip Counter / Digit Morph Countdown
- **How it works**: When the hero alarm is armed and time is counting down:
  - The remaining time digits (e.g. `in 7h 24m`) do a mechanical flip-clock tumble or vertical digit roll when the minute changes.
  - The hero time display (`07:00`) has a subtle breathing glow pulse on the active minute colon (`:`).
- **Visual effect**: High-precision, editorial timekeeper aesthetic that feels alive without distracting the user.

### Concept C: "Dark Pulse" on Disarm
- **How it works**: When the user taps the toggle to disarm the hero alarm:
  - The active violet border (`#5E6AD2`) flashes a quick desaturation wave from right to left (originating at the toggle switch).
  - The countdown pill fades to `#565A61` with a brief `0.98` spring scale down.
  - The hero card then folds upward into the status bar with a gentle spring curve rather than a linear collapse.

### Concept D: Particle Wave / Glow Ring on Arm
- **How it works**: When arming the hero alarm:
  - A subtle radial wave or glow ring expands outward from the toggle switch across the dark card surface.
  - The hero card expands with a spring overshoot (`curve: Curves.elasticOut` or `Curves.easeOutBack`).

### Concept E: Sticky Collapsible Hero on Scroll
- **How it works**: When the user has 10+ alarms and scrolls down the list:
  - The hero card smoothly compresses from a full 180px card into a compact 44px sticky top header strip (`[ ⏰ 07:00 • In 7h 24m ] [ Active ]`).
  - Scrolling back to the top seamlessly re-expands it into the hero card.

---

## 2. Tactile Haptics Engine Roadmap

To match the Linear Swiss dark editorial aesthetic, haptic feedback should feel distinct, crisp, and tactile rather than like generic vibration buzzes.

### Core Haptic Matrix

| User Action | Haptic Pattern | Android Implementation | Aesthetic Feeling |
|---|---|---|---|
| **Arming Hero Alarm** | Heavy Impact + Light Confirmation (Double Thud) | `HapticFeedback.heavyImpact()` followed 60ms later by `HapticFeedback.lightImpact()` | Solid tactile latch, like clicking a mechanical toggle switch |
| **Disarming Alarm** | Soft Vibration Pulse | `HapticFeedback.selectionClick()` | Gentle disengagement, low resistance |
| **Tape Ruler / Tumbler Scrolling** | Micro Selection Clicks | `HapticFeedback.selectionClick()` on every integer step | Crisp watch crown ratcheting (click-click-click) |
| **5-Unit / 15-Minute Accents** | Medium Tick on Quarter Hours | `HapticFeedback.lightImpact()` on 00, 15, 30, 45 mins | Notched tactile milestone while swiping quickly |
| **Preset Arrival (e.g. Quick +15m)** | Spring Snap Impact | `HapticFeedback.mediumImpact()` | Magnet snapping into position |
| **Swipe-to-Delete Action** | Resistance threshold click | `HapticFeedback.heavyImpact()` when passing 40% swipe threshold | Breaking a tactile shear pin |
| **Ring Test / Snooze Trigger** | Urgent Multi-pulse | 3 rapid `mediumImpact()` bursts (80ms spacing) | Distinct alert pattern |

---

## 3. Time Picker Evolution & Takeaways

The app has consolidated onto the **3D Cylindrical Drum Tumbler** as the definitive, instrument-grade time selector, featuring individual dial column wells, metallic depth lighting gradients, an aperture lens highlight band, and custom ballistic scroll physics with 5-minute magnetic milestone attraction.

---

## 4. Feature Backlog

### A. Fortnightly / Bi-Weekly Alarms
- **User Need**: Scheduling alarms that repeat every two weeks (e.g., bi-weekly paydays, alternating shift work, alternating trash collection).
- **Implementation Strategy**:
  - Add an optional `recurrence_interval_weeks: 2` and `recurrence_anchor_date` to backend schema and local DB.
  - Recurrence calculator computes difference in calendar weeks from the anchor date: `(targetDate.difference(anchorDate).inDays / 7).floor() % 2 == 0`.
  - Add "Fortnightly" / "Bi-Weekly" recurrence chip in the time & schedule sheet.

### B. Raycast Extension (macOS) + CLI Companion — IN PROGRESS
- **User Need**: Managing, viewing, and arming/disarming remote alarms directly from Raycast on Mac, without opening a browser.
- **Status**: Design approved 2026-09-21.
- **Design Spec**: [`docs/superpowers/specs/2026-09-21-clients-cli-raycast-design.md`](../superpowers/specs/2026-09-21-clients-cli-raycast-design.md)
- **Implementation Strategy**:
  - One shared, dependency-free core (`@remotealarm/core`) holding the typed API client and the natural-language time parser, consumed by two presentation shells. **This supersedes the earlier `extensions/remotealarm` path** — the code now lives in `clients/`.
  - `clients/cli` — an `alarm` command (`alarm 25m "Oven"`) for scripting and fast ad-hoc scheduling.
  - `clients/raycast` — React + TypeScript Raycast extension (author `danieltsam`).
  - Commands: `List Alarms` (browse, silence, enable/disable, edit, cancel), `Quick Create` (natural-language time input, e.g. `tomorrow at 7am`, with a live resolved-time preview), `Create Alarm` (full form), `Edit Alarm`, `Device Status`.
  - Deliberately **no backend changes** — every operation maps to an existing route.

### C. Google Calendar / Tailscale Homelab Synchronization
- **User Need**: Subscribing Google Calendar or Apple Calendar to the remote alarm feed hosted on a private homelab server over Tailscale.
- **Architecture Consideration**:
  - Google Calendar web servers cannot directly resolve or poll private `.ts.net` Tailscale nodes or private LAN IPs unless the endpoint is exposed via a secure tunnel (e.g. Cloudflare Tunnel / Funnel) or via a light sync daemon that pushes events directly to Google Calendar API using OAuth service account credentials.
  - Alternative: Local calendar subscriptions on macOS / iOS / Android via CalDAV or local iCal feed subscription that runs client-side inside the Tailscale network.
