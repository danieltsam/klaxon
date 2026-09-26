# Remote Alarm — Working State

> **Last updated:** 2026-09-23
> **Session:** opencode orchestrator session (calendar → hero → recurrence → polish)
> **Working directory:** `/Users/dsam/Documents/remotealarm`
> **Device under test:** `ZY32LWDN2S` (moto g86 power 5G, Android 16, DPR 2.8125)

This document is the live state of in-flight work. It complements:
- `AGENT_HANDOFF.md` (repo root) — original onboarding doc, §8 work is now **done** (see below)
- `docs/ROADMAP.md` — feature roadmap
- `docs/agent_context/backlog.md` — creative + UI backlog

---

## 1. Session summary

This session took the app from "handoff §8 pending" to a substantially polished state across four areas:

1. **Handoff §8 items** — all five completed (§8.1–§8.5)
2. **Calendar picker** — evolved through six revisions (v1 concept → v6 final)
3. **Hero card** — glassmorphic styling + spring entry/exit + breathing border
4. **Recurrence** — fortnightly alarms (backend + mobile), chip-variant lab, C1/C2/C3 variants
5. **Mass-select** — long-press multi-select with bulk duplicate/delete
6. **Polish** — lowercase sweep, relative date titles, missed-alarm redesign, FCM reason wording, no-shift multi-select, FAB glow

All work verified on device. **122 mobile tests + 115 backend tests pass.** `flutter analyze` clean.

---

## 2. Completed work (this session)

### 2.1 Handoff §8 — all done

| Item | What was done |
|---|---|
| §8.1 | Wired `showCustomCalendarPicker` into the Pick Date pill (replaced stock `showDatePicker`) |
| §8.2 | Directional L→R strike-through on the Today pill (replaced centre-growing `AnimatedContainer` with `_DirectionalStrikePainter` + `TweenAnimationBuilder`) |
| §8.3 | "save adjustments" pops + toasts immediately; network sync fires in background |
| §8.4 | "arm alarm" local-id first, schedules locally, pops immediately, backend create in background |
| §8.5 | Background-firing fix: `onMessageOpenedApp` + `getInitialMessage` handlers, `_ensureCriticalPermissions` full-screen-intent prompt, native `onNewIntent` + `getLaunchIntentAction` channel for cold-launch via RING action |

**Files:** `mobile/lib/main.dart`, `mobile/android/app/src/main/kotlin/com/remotealarm/mobile/MainActivity.kt`

### 2.2 Calendar picker (`mobile/lib/widgets/calendar_picker.dart`)

Final state after six revisions:

- **Ribbon view (default)** — horizontal date ribbon, opens at **tomorrow** (today reachable by scrolling left), 3-letter day labels (`Mon`/`Tue`…), relative badges (`today`/`tomorrow`/`in N days`), no `Weekend` badge
- **Matrix view** — full month grid behind an **Expand** toggle; horizontal swipe (300px physical) or edge chevron buttons to change months; **max 1 month flip per gesture**; today outlined, past struck through
- **Tap-to-edit footer** — the full-form date label (`Tuesday, 22nd September 2026`) is tappable and swaps to inline DD/MM/YYYY fields with validation (invalid → red `#EB5757` border)
- **Removed** — the 4-tab switcher, Tumbler mode, Type mode, and the macro chip row (Today/Tomorrow/This Weekend/Next Mon/In 1 Wk)
- **5-year date range** (`lastDate: DateTime(today.year + 5, ...)` in `main.dart`)
- **Modal sizing** — capped at 85% screen height; keyboard no longer inflates the modal

### 2.3 Hero card (`mobile/lib/main.dart`)

- **Glassmorphic styling** — `BackdropFilter` blur (sigma 16), translucent purple tint, purple border
- **Entry** — slide-up spring, 900ms `Curves.elasticOut`, translateY 40→0, scale 0.92→1.0, opacity 0→1
- **Exit** — 200ms `Curves.easeInCubic`, translateY 0→-32, scale 1.0→0.95
- **Breathing border** — 2400ms cycle, border alpha `0x55`→`0x99` (≈33%→60%), pulsing outer glow (alpha 0.10→0.20, blur 14→18). Border width static at 1.5.

### 2.4 Fortnightly alarms

**Backend:** `backend/src/db.ts` (schema + migration), `backend/src/server.ts` (POST/PATCH validation, interval ∈ {1,2}), `backend/src/fcm.ts` (payload carries `recurrence_interval_weeks` + `recurrence_anchor_date`), `backend/src/gcal-events.ts` (`RRULE:FREQ=WEEKLY;INTERVAL=N`). New test file `backend/test/fortnightly.test.ts`.

**Mobile:** `id_mapper.dart` (persistence), `alarm_service.dart` (interval-aware `getNextOccurrence`), `backend_client.dart` (sends the fields), `main.dart` (5th recurrence option). New test `mobile/test/recurrence_test.dart`.

**Rule:** auto-anchor — anchor date = the alarm's first occurrence (`dateTime`). Subsequent fires are anchor + 14d, 28d, …

**Known gap:** the ICS feed (`/api/calendar.ics`) still emits `RRULE:FREQ=WEEKLY` without `INTERVAL`. Google Calendar mirror does include it.

### 2.5 Recurrence UI — variant lab

`mobile/lib/widgets/recurrence_chip_variants.dart` (chip treatments + row variants) and `mobile/lib/widgets/recurrence_lab.dart` (debug comparison screen, opened by **long-pressing the `repeats` label** in the schedule sheet).

**9 selectable variants**, persisted via the `recurrence_chip_variant` SharedPreferences key:

| ID | Style |
|---|---|
| `0` | Default chips (current production) |
| `1` | Glassmorphic chips |
| `2` | Soft-glow gradient chips |
| `4` | Outline-only chips |
| `5` | Two-row stacked chips |
| `6` | Segmented control (single connected bar) |
| `C1` | Collapsed pill (tap to expand into a list) |
| `C2` | Compact dropdown button |
| `C3` | Sticky compact pill (tap to cycle) |

### 2.6 Mass-select / bulk actions (`mobile/lib/main.dart`)

- **Long-press** any alarm row → multi-select mode, row auto-selected
- **Tap** rows to toggle; leading clock icon is **replaced in place** by a checkbox (no layout shift)
- **Toggle switches stay enabled** with normal colours during multi-select
- **Bottom action bar:** `Cancel · Duplicate (N) · Delete (N)` — replaces the FAB
- **Back gesture** exits multi-select
- Bulk duplicate creates copies with a ` (copy)` suffix at the next future occurrence; bulk delete removes all selected

### 2.7 Polish

- **Lowercase sweep** — all buttons, sheet titles, section headers, date pills, sound-tone names, haptic style names, snackbar messages. Guardrail: lowercase user-facing content throughout.
- **Relative date titles** — `today` / `yesterday` / `tomorrow` / weekday name (within ±7 days) / `DD/MM/YYYY` (beyond). Applied to alarm rows, hero card, detail modal.
- **Missed-alarm card redesign** — red outline only (no translucent fill), same dimensions as a normal alarm row, plain-text `reschedule` button.
- **FCM cause wording** — `_formatMissedReason` now returns cause-oriented text (`fcm token unavailable` / `fcm delivery failed` / `fcm delivery unconfirmed` / `fcm delivery delayed` / `device couldn't ring`) or `null` (line omitted when unknown). Backend dashboard mirrors this.
- **FAB** — added outer purple glow + deeper drop shadow.
- **Keyboard** — `TextCapitalization.none` + `autocorrect: false` on label/description fields.

---

## 3. In progress / queued

### 3.1 Hybrid segmented chip variants — SPEC'D, NOT DISPATCHED

User is leaning towards **variant 6 (segmented control)** but wants to see it combined with the other visual treatments first.

**To build:** segmented-control *structure* with each of these *treatments*:
- 6 + soft-glow gradient
- 6 + outline-only
- 6 + two-row stacked
- 6 + glassmorphic

Plus a **sliding highlight** that travels between cells on selection (gives the continuous motion the user liked in C1, without the layout shift).

**Files:** `mobile/lib/widgets/recurrence_chip_variants.dart` (new row widgets), `recurrence_lab.dart` (selectable), `mobile/lib/main.dart` (`_buildRecurrenceRow` dispatcher).

### 3.2 Chip variant final selection — AWAITING USER DECISION

The lab is live so the user can play with all 9 variants in the real flow. Once they pick a winner:
1. Bake that variant into production
2. Remove the lab + variant dispatcher + `recurrence_chip_variant` persistence
3. Delete `recurrence_chip_variants.dart` if nothing else uses it

### 3.3 C1 collapse motion — DECIDED NOT TO PURSUE

User noted C1's seamless collapse (height animation + selection change in one beat) is nice but "we're kind of inventing a problem." Agreed: leave C1 as a selectable option, don't engineer the seamless-collapse into the other variants.

---

## 4. Backlog

See `docs/agent_context/backlog.md` §5 for the full list. Summary:

| Item | Notes |
|---|---|
| **Missed alarms UI — full redesign** | Card is simplified; a fuller visual treatment is deferred |
| **Battery indicator** | Remove or redesign — user not a fan |
| **Home header icons** | Haptics-lab icon (remove) + settings icon (redesign — "too generic lucide") |
| **FAB texture + shadow** | Partially done this session; may want more |
| **Raycast extension (macOS) + CLI** | Design approved; spec at `docs/superpowers/specs/2026-09-21-clients-cli-raycast-design.md`; code lives in `clients/` |
| **Haptics matrix expansion** | Wire the fuller 7-pattern matrix from backlog.md §2 (several patterns exist but aren't triggered from real actions) |
| **iCal / CalDAV feed** | Deferred — Google Calendar sync covers the primary case |
| **ICS feed `INTERVAL`** | Small gap from the fortnightly work — `/api/calendar.ics` doesn't emit `INTERVAL` |
| **Design guardrails** | No pulsing dots, no translucent pastel tints, no pill overdose, no stock lucide icons, lowercase content, plain-text actions |

---

## 5. Design decisions & guardrails (do not violate)

| Decision | Rationale |
|---|---|
| `dualClack180` default arm haptic | User-tested sweet spot |
| `doubleSoftTap150` default disarm haptic | User-approved |
| Drum tumbler is the only time picker | Stock/Cupertino pickers removed |
| CNC ribbing on outer flanks only (4px) | The painter canvas was text-width; fixed to well-width so flanks are true edges |
| Calendar: ribbon default, opens at tomorrow | Today reachable by scrolling left |
| Matrix: swipe flips max 1 month, ~300px | Prevents over-flipping |
| Hero: 900ms entry / 200ms exit | Exit felt sluggish at 380ms |
| Hero border: static width, breathing alpha only | Outer glow + width pulse was "too much" |
| **No translucent pastel tints** | Explicit user instruction — "please never do this" |
| **Lowercase user-facing content** | Established across the app |
| **No layout shift on state change** | Multi-select must swap in place, not reflow |
| Missed-alarm reason = FCM cause or nothing | Symptom text ("phone saw it too late") rejected |

---

## 6. File map (current)

```
mobile/lib/
├── main.dart                          # ~5100 lines — home, sheets, modals, recurrence, multi-select, hero
├── screens/
│   └── ring_screen.dart               # full-screen ringing UI
├── services/
│   ├── alarm_service.dart             # scheduling, recurrence math, FCM payload handling
│   ├── backend_client.dart            # REST client
│   └── haptic_service.dart            # haptic patterns + persistence
├── utils/
│   ├── id_mapper.dart                 # int↔UUID mapping, per-alarm prefs (repeat days, interval, anchor, tone, ramp, enabled)
│   └── settings_formatter.dart
└── widgets/
    ├── time_pickers.dart              # DrumTumblerPicker + CNC flank painters
    ├── calendar_picker.dart           # ribbon + matrix + inline date editor
    ├── haptics_lab_modal.dart         # in-app haptic testing lab
    ├── recurrence_chip_variants.dart  # 6 chip rows + 3 collapsed variants
    └── recurrence_lab.dart            # debug comparison screen (long-press `repeats`)

backend/src/
├── db.ts                              # schema + migrations + AlarmRepo
├── server.ts                          # routes (alarms CRUD, silence, status)
├── fcm.ts                             # FCM payload builder
└── gcal-events.ts                     # Google Calendar RRULE mirror

docs/agent_context/                    # design artifacts (all untracked)
├── hero_card_v2_concepts.html         # 5 hero aesthetic directions
├── hero_card_entry_exit_concepts.html # 6 entry/exit transitions
├── recurrence_ui_concepts.html        # 6 recurrence UI concepts
├── recurrence_ui_integrated.html      # 6 concepts in sheet context
├── recurrence_chip_variations.html    # 7 chip visual treatments
├── mass_select_concepts.html          # 3 bulk-select approaches
├── custom_calendar_mockups.html       # 3 calendar concepts
├── screenshots/                       # device screenshots
└── WORKING_STATE.md                   # ← this file
```

---

## 7. Build / test / deploy

```bash
# Mobile tests + analyze
cd mobile && flutter analyze lib/ test/   # expect: 0 issues
cd mobile && flutter test                 # expect: 122 passing

# Backend tests
cd backend && npm run build && npm test   # expect: 115 passing

# Deploy to device
cd mobile && flutter build apk --debug
adb -s ZY32LWDN2S install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s ZY32LWDN2S shell am start -n com.remotealarm.mobile/.MainActivity
```

**Note:** `flutter run` sometimes fails with "log reader stopped unexpectedly" after a successful install — the APK is still installed correctly; launch via `adb shell am start` instead.

**Note:** Gradle build takes ~90–300s. Commands with a 120s timeout will fail; use background execution + polling.

---

## 8. Open questions / known limits

### App limits
- **Date range**: calendar picker accepts dates up to **5 years** ahead (`DateTime(today.year + 5, ...)`). Beyond that is rejected.
- **Recurrence interval**: only **1 (weekly)** or **2 (fortnightly)**. The backend rejects `recurrence_interval_weeks` outside `[1, 2]`.
- **No alarm-count cap** enforced client or server side.
- **Matrix swipe**: one month per gesture, ~300px physical threshold.
- **Snooze**: fixed 9 minutes.

### Open questions
- Should the ICS feed (`/api/calendar.ics`) emit `INTERVAL` for fortnightly alarms? (Currently doesn't.)
- Which chip variant becomes production? (User deciding — leaning variant 6, wants hybrids first.)
- Should the recurrence lab ship in release builds, or be debug-only?

---

## 9. Repo state note

The working tree contains substantial **uncommitted** changes from this session (mobile + backend + docs). Recent commits (`git log`) include work from parallel sessions:
- `7cb9ba4 feat: scale relative times to days, months and years`
- `d9ead19 feat(mobile): recurrence chip row variants with a comparison lab`

Before starting new work, check `git status` and `git log --oneline -10` to understand what's committed vs in-flight. No commits were made by this session's orchestrator (subagent checkpoint commits may exist).

**Untracked:** all of `docs/agent_context/` and `AGENT_HANDOFF.md`.
