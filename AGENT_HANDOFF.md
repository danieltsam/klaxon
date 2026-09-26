# Remote Alarm — Agent Handoff Document

> **Last updated:** 2026-09-21  
> **Working directory:** `/Users/dsam/Documents/remotealarm`  
> **Flutter project:** `mobile/`  
> **Backend:** `backend/` (Node.js + Fastify + SQLite, deployed on homelab)  
> **Target device:** Android (ADB device `ZY32LWDN2S`, package `com.remotealarm.mobile`)

---

## 1. Project Summary

Remote Alarm is a personal homelab system: a Fastify backend (homelab server via Tailscale), a Flutter Android client, and a web dashboard. The user can create, manage, and silence alarms from their laptop; alarms ring at hardware level on the phone (full-screen, overrides DND/silent mode) via FCM + native AlarmManager.

The Flutter app has recently undergone significant UI/UX polish across:
- Custom haptic patterns (haptics lab modal + arm/disarm/scroll styles)
- Bespoke 3D drum tumbler time picker (replaces stock Flutter picker)
- Custom calendar date picker sheet (replaces `showDatePicker`)
- Schedule recurrence chips (Once / Daily / Weekdays / Custom) with day-of-week selector
- Alarm list card UI with optimistic toggle

---

## 2. Codebase Map

```
remotealarm/
├── README.md                      # Project overview and quick start
├── AGENT_HANDOFF.md               # ← this file
├── docs/
│   └── ROADMAP.md                 # Feature backlog
├── docker-compose.yml             # Homelab deployment
├── backend/                       # Node.js + Fastify + SQLite API server
│   ├── src/                       # TypeScript source
│   └── test/                      # Backend test suite (37 tests, 13 suites)
└── mobile/                        # Flutter Android app
    ├── lib/
    │   ├── main.dart              # ★ Primary UI — alarm list, create/edit sheets
    │   ├── screens/
    │   │   └── ring_screen.dart   # Full-screen alarm ringing UI
    │   ├── services/
    │   │   ├── haptic_service.dart  # ★ All haptic patterns + lab styles
    │   │   ├── alarm_service.dart   # AlarmManager scheduling, FCM payload handling
    │   │   └── backend_client.dart  # HTTP REST client for homelab backend
    │   ├── utils/
    │   │   ├── id_mapper.dart      # int↔UUID mapping persisted in SharedPreferences
    │   │   └── settings_formatter.dart
    │   └── widgets/
    │       ├── time_pickers.dart   # ★ 3D drum tumbler (DrumTumblerPicker)
    │       ├── calendar_picker.dart # ★ Custom calendar sheet (showCustomCalendarPicker)
    │       └── haptics_lab_modal.dart # ★ In-app haptic testing lab
    └── test/
        └── haptic_service_test.dart  # HapticService persistence tests
```

---

## 3. Design Language & Conventions

**Colour palette (dark mode only):**

| Token | Hex | Usage |
|---|---|---|
| Background deep | `#0F1013` | Modal backgrounds |
| Background surface | `#16181B` | Sheet backgrounds |
| Card background | `#101215` | Alarm row cards |
| Border subtle | `#26282E` | Card/sheet borders |
| Accent purple | `#5E6AD2` | Active state, CTAs, selected chips |
| Text primary | `#F7F8F8` | Main text |
| Text secondary | `#8A8F98` | Subtitle / inactive text |
| Text disabled | `#4A4E58` | Greyed-out (e.g. past Today) |
| Destructive | `#EB5757` | Delete buttons |

**Typography:** System default, weights `w500`/`w600` throughout.  
**Border radius:** Chips/cards `8px`, modals `20px` top corners.  
**Animation durations:** `200–220ms` for chip/state transitions, `300ms` for content reveals.

---

## 4. Haptic System

### File: `mobile/lib/services/haptic_service.dart`

Four style axes, each persisted to SharedPreferences:

| Axis | Enum | Default | Notes |
|---|---|---|---|
| Arm (enable alarm) | `ArmHapticStyle` | `dualClack180` | Plays when enabling switch or saving new alarm |
| Disarm (disable alarm) | `DisarmHapticStyle` | `doubleSoftTap150` | Plays when disabling switch |
| Scroll (tumbler tick) | `ScrollHapticStyle` | `softCrownHalved` | Plays during drum tumbler scroll |
| Preset (misc confirms) | `PresetHapticStyle` | `magneticSnap` | Misc UI confirmations |

### ArmHapticStyle variants:
```dart
dualClack180        // medium → 180ms → heavy  ← DEFAULT (user-approved sweet spot)
dualClackFast110    // medium → 110ms → heavy
tripleRelayClack    // light → 90ms → medium → 120ms → heavy
heavySolenoidSnap   // heavy → 140ms → medium
doubleReboundStrike // heavy → 180ms → heavy
```

### DisarmHapticStyle variants:
```dart
doubleSoftTap150     // light → 150ms → light  ← DEFAULT (user-approved)
gentleDoubleTap100   // light → 100ms → light
tripleSoftFade       // light → 70ms → light → 100ms → light
mechanicalSoftRelease // medium → 200ms → light
featherDecouple      // selection click only
```

### ScrollHapticStyle variants:
```dart
quarterMilestonesOnly  // tick every 15min (hours: every 3h)
fiveMinuteMilestones   // tick every 5min  ← user favourite for milestone feel
softCrownHalved        // tick every 2 items (halved density)  ← DEFAULT
softCrownThirds        // tick every 3 items
muted                  // no ticks
```

### Key method signatures:
```dart
HapticService.playArm([ArmHapticStyle? override])
HapticService.playDisarm([DisarmHapticStyle? override])
HapticService.playScrollTick()
HapticService.playPreset([PresetHapticStyle? override])
HapticService.selectionClick()
```

**User preferences (DO NOT CHANGE without explicit request):**
- `dualClack180` is the approved arm haptic — tested 110/160/180/210ms, 180ms was the sweet spot
- `doubleSoftTap150` is the approved disarm haptic
- "Whisper scrub ticks" were removed from the scroll options — they were too buzzy
- "15 minute milestones" and "relaxed crown" (softCrownHalved) are favourite scroll styles

---

## 5. Time Picker: Drum Tumbler

### File: `mobile/lib/widgets/time_pickers.dart`
### Widget: `DrumTumblerPicker`

3D-perspective spinning drum wheel replacing Flutter's stock CupertinoPicker.

**Key design details:**
- `ListWheelScrollView` with perspective transform for barrel-curve illusion
- `_MilledDiscRowPainter` draws CNC lathe micro-ribbing **strictly on the outer 8px lateral flanks** — the centre (behind numerals) is 100% clean
- Index ticks are also flank-only (outer 4.5px margin, range 0.5–5.0px)
- Well widths: Hour `is12h ? 72 : 84`, Minute `84`, AM/PM `60`
- **5-minute snap affinity:** Minute wheel snaps to nearest multiple of 5 on release; user then fine-tunes. This is intentional — common alarm times are 5-min increments.

**Haptic integration:** `HapticService.playScrollTick()` called in each wheel's `onSelectedItemChanged`.

**DO NOT:**
- Run ribbing across the full face width — it must only appear on flanks
- Add any visual chrome behind the numerals

---

## 6. Calendar Picker

### File: `mobile/lib/widgets/calendar_picker.dart`
### Entry point: `showCustomCalendarPicker({context, initialDate, firstDate, lastDate})`
### Returns: `Future<DateTime?>`

**Two-mode design:**
1. **Default:** Horizontal infinite date ribbon — 60 days scrollable, relative badges (`Today`, `Tomorrow`, `This Wknd`, `+Nd`)
2. **Expand Matrix button:** AnimatedCrossFade into full month grid — 7-column Mon–Sun calendar, past dates struck through

**Quick macro chips:** `Today`, `Tomorrow`, `This Weekend`, `Next Mon`, `In 1 Wk`

**Status: Widget complete, passes `flutter analyze` with 0 issues.**  
**NOT YET WIRED UP** — see §8.1 below.

---

## 7. Completed Work ✅

| Area | File |
|---|---|
| Drum tumbler ribbing confined to outer 8px flanks | `widgets/time_pickers.dart` |
| Drum tumbler index ticks flank-only | `widgets/time_pickers.dart` |
| Dial well widths expanded | `widgets/time_pickers.dart` |
| `CustomCalendarPickerSheet` widget (Concept B + expandable A) | `widgets/calendar_picker.dart` |
| `dualClack` delay tuned 210ms → 180ms | `services/haptic_service.dart` |
| Haptic tests updated for `dualClack180` | `test/haptic_service_test.dart` |
| Optimistic toggle UI (instant `setState` on switch flip) | `main.dart` `_toggleAlarmEnabled` |
| Haptics fire non-blocking (removed `await` on arm/disarm) | `main.dart` `_toggleAlarmEnabled` |
| Error rollback in toggle (re-flips switch on failure) | `main.dart` `_toggleAlarmEnabled` |
| `calendar_picker.dart` import added to `main.dart` | `main.dart` line 19 |
| Recurrence chips: Once / Daily / Weekdays / Custom | `main.dart` |
| Custom chip → clears day selection (blank slate) | `main.dart` |
| Today / Tomorrow / Pick Date 3-pill date row | `main.dart` |

---

## 8. Pending Work ⏳

### 8.1 Wire `showCustomCalendarPicker` to "Pick Date" button
**File:** `main.dart` ~line 1338  
**Find:** `final picked = await showDatePicker(`  
**Replace the entire `showDatePicker(...)` call** with:

```dart
final picked = await showCustomCalendarPicker(
  context: context,
  initialDate: customDate ?? (isTomorrow ? tomorrow : (isPastToday ? tomorrow : today)),
  firstDate: isPastToday ? tomorrow : today,
  lastDate: today.add(const Duration(days: 365)),
);
```

The `if (picked != null)` block below it is unchanged — return type is identical `Future<DateTime?>`.  
This will also clear the `unused_import` warning on `calendar_picker.dart`.

---

### 8.2 Directional Strike-Through on "Today" button
**File:** `main.dart` ~lines 1261–1289 (Today pill, inside `_openTimeAndScheduleSheet`)  
**Requirement:** Strike-through draws **Left-to-Right** when time is past (crossout). Retracts **Right-to-Left** when time becomes upcoming again.

**Current:** Uses `AnimatedContainer` growing from centre — wrong behaviour.

**Fix:** Replace the `AnimatedContainer` strike-through widget with a `CustomPaint` + `TweenAnimationBuilder`:

```dart
// Add this class near the top of _HomePageState or as a private top-level class:
class _DirectionalStrikePainter extends CustomPainter {
  final double progress;
  _DirectionalStrikePainter(this.progress);
  @override
  void paint(Canvas canvas, Size size) {
    if (progress == 0) return;
    final paint = Paint()
      ..color = const Color(0xFF6B7280)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width * progress, y), paint);
  }
  @override
  bool shouldRepaint(_DirectionalStrikePainter old) => old.progress != progress;
}

// Replace the Stack children in the Today button with:
Stack(
  alignment: Alignment.center,
  children: [
    TweenAnimationBuilder<double>(
      tween: Tween(begin: isPastToday ? 0.0 : 1.0, end: isPastToday ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (_, value, child) => CustomPaint(
        foregroundPainter: _DirectionalStrikePainter(value),
        child: child,
      ),
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 200),
        style: TextStyle(
          fontSize: 12,
          fontWeight: (!isTomorrow && customDate == null && !isPastToday)
              ? FontWeight.w600 : FontWeight.w500,
          color: isPastToday
              ? const Color(0xFF4A4E58)
              : ((!isTomorrow && customDate == null)
                  ? Colors.white
                  : const Color(0xFF8A8F98)),
        ),
        child: const Text('Today'),
      ),
    ),
  ],
)
```

---

### 8.3 "Save Adjustments" — Instant Modal Dismiss
**File:** `main.dart` ~lines 2109–2142  
**Problem:** Modal awaits `BackendClient.updateRemoteAlarm(...)` and `_toggleAlarmEnabled(...)` before popping — feels slow.  
**Fix:** Pop immediately after `IdMapper.saveMapping`, fire network/reschedule unawaited:

```dart
await IdMapper.saveMapping(item.id, item.uuid ?? 'local_${item.id}', ...);

// Pop and toast immediately
if (bottomSheetContext.mounted) Navigator.pop(bottomSheetContext);
_showToast('Adjustments saved');

// Background sync — fire-and-forget
if (item.uuid != null && !item.uuid!.startsWith('local_')) {
  BackendClient.updateRemoteAlarm(item.uuid!, ...); // no await
}
if (item.isEnabled) {
  _toggleAlarmEnabled(item, true); // no await
} else {
  _loadAllAlarms(); // no await
}
```

---

### 8.4 "Arm Alarm" — Verify Dismiss Speed
**File:** `main.dart` ~line 2942  
**Current:** `await BackendClient.createRemoteAlarm(...)` blocks before Navigator.pop.  
**Potential fix:** Move `createRemoteAlarm` to fire-and-forget after pop. The local-ID fallback (`'local_${DateTime.now()...}'`) already handles offline/failure cases. Only do this if the user finds the save feeling sluggish.

---

### 8.5 Known Bug: Alarm Firing Screen Not Appearing from Background
**Reported behaviour:** When alarm fires while app is in background, audio starts but `RingScreen` full-screen intent doesn't appear. Android shows the alarm list instead.  
**Files to investigate:**
- `android/app/src/main/AndroidManifest.xml` — verify `USE_FULL_SCREEN_INTENT` permission and that the `RingScreen` activity has `showWhenLocked="true"` and `turnScreenOn="true"`
- `screens/ring_screen.dart` — check for any Navigator logic that might be routing incorrectly
- `main.dart` `_firebaseMessagingBackgroundHandler` — verify alarm scheduling path when app is killed vs backgrounded
- Android 12+: `USE_FULL_SCREEN_INTENT` requires explicit user grant. Add a runtime permission check on app start.

---

## 9. Build & Deploy

```bash
# Tests
cd mobile && flutter test
cd backend && npm test

# Analyze
cd mobile && flutter analyze lib/
# Expected: 1 warning (unused calendar_picker import — resolves when §8.1 is done)

# Build release APK
cd mobile && flutter build apk --release

# Install to device
adb install -r build/app/outputs/flutter-apk/app-release.apk
# Device ID: ZY32LWDN2S

# Backend runs on homelab via Docker — no local setup needed
# App connects via Settings → Backend Server URL (Tailscale address)
```

---

## 10. Hard Design Decisions (DO NOT CHANGE without explicit user request)

| Decision | Rationale |
|---|---|
| `dualClack180` default arm haptic | User tested all durations — 180ms was the approved sweet spot |
| `doubleSoftTap150` default disarm haptic | User-approved |
| Drum tumbler is the ONLY time picker | All other pickers (stock Flutter, Cupertino, preset chips) removed |
| Time preview label above tumbler REMOVED | Redundant — tumbler already shows the time |
| Schedule content is IN the time modal | User wants time + recurrence in one sheet, not separate |
| Weekdays and Custom chips retained | User almost removed them but kept them |
| Custom chip → clears all day selection | User wants a blank slate when switching to Custom |
| Calendar Concept C (tumbler date) OMITTED | User: "probably a little unnecessary" |
| CNC ribbing on LATERAL EDGES ONLY (8px flanks) | Ribbing under text was rejected — centre must be pristine |
| Today/Tomorrow/Pick Date: fixed equal-width pills | User rejected dynamic-sizing animation for the date row |
| "Arm Alarm" and "Save Adjustments" should feel instant | Pop modal immediately, sync in background |

---

## 13. Antigravity Session Context

All design artefacts, interactive mockups, and verified device screenshots from the development session have been copied into the project for self-contained handoff:

```
docs/agent_context/
├── README.md                        # Index of all context files (start here)
├── walkthrough.md                   # Session summary — what was built and verified
├── backlog.md                       # Creative backlog: animation concepts, haptic roadmap, future features
├── implementation_plan.md           # Last session's detailed implementation plan
├── custom_calendar_mockups.html     # 3 calendar picker concepts (Concept B chosen)
├── time_selector_ideation.html      # Time picker ideation history
├── animation_mockups.html           # Hero card animation mockups
├── modal_mockups.html               # Alarm creation modal iterations
└── screenshots/                     # 21 ADB device screenshots showing current UI state
    ├── tumbler_ribbed_sheet.png     # Drum tumbler with flank-only ribbing (approved)
    ├── sheet_strikethrough_today.png # Today struck-through when time is past
    ├── sheet_custom_tapped_empty.png # Custom chip → blank day selection
    ├── phone_main_live_updated.png  # Home screen latest build
    └── ... (17 more — see README.md for full table)
```

**Originating Antigravity conversation ID:** `bbc71631-0661-4d1f-a236-508748ab5ff8`  
**Brain path:** `~/.gemini/antigravity/brain/bbc71631-0661-4d1f-a236-508748ab5ff8/`
