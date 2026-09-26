# Implementation Plan: Drum Tumbler 5-Minute Magnetic Snapping, 3D Dials & Future Date Scheduling

We will implement the next round of refinements based on your feedback:
1. **5-Minute Incremental Magnetic Snapping for Minutes**: Custom ballistic wheel physics that smoothly gravitates and snaps to 5-minute increments (`:00, :05, :10...`) on normal scrolls and flings, while allowing single-minute micro-nudges (`1-4`, `6-9`) on slow drags.
2. **3D Physical Dial Aesthetics**: Refactor the Drum Tumbler with individual cylindrical wheel wells, depth gradients, specular apex highlights, vertical chassis grooves, and cylindrical perspective curvature.
3. **Unified Time & Schedule Sheet Refinements**:
   - Remove redundant `In X hours X mins` countdown pill from inside the modal.
   - Clean recurrence chips: `Once`, `Daily`, `Weekdays`, `Custom` (removing `Weekends`).
   - Dynamic `Today` button: Completely hidden when the selected time has already passed today (smoothly animating in when time is later today).
   - Future Date Picker: Add interactive `[ Pick Date 📅 ]` chip that opens a calendar for scheduling alarms on any future date, showing `[ DD MMM 📅 ]` when active.
4. **Haptics Alignment**:
   - Set `softCrownHalved` (relaxed crown every 2 units with milestone accents) as the default scroll haptic style.
   - Ensure Alarm Save triggers the Dual Mechanical Clack (`playArm`).
   - Alarm Switch Toggle: Dual Clack on activate (turn ON), Double Soft Tap on deactivate (turn OFF).
5. **Backlog Updates**:
   - Document Fortnightly recurrence, Raycast extension, and Google Calendar / Tailscale subscription architecture.

---

## User Review Required

> [!NOTE]
> - **Recurrence Categories**: We keep `Once`, `Daily`, `Weekdays`, and `Custom`. For weekends, users simply tap `Custom` and select Saturday and Sunday.
> - **Ballistic Snapping Threshold**: High-velocity and standard fling scrolls will automatically lock onto `:00, :05, :10, :15...` marks. Dragging or nudging slowly ($< 100\text{ px/s}$) allows fine-grained precision for single minutes (e.g. 07:07).

---

## Proposed Changes

### 1. Physics & Drum Tumbler (`mobile/lib/widgets/time_pickers.dart`)

#### [MODIFY] [time_pickers.dart](file:///Users/dsam/Documents/remotealarm/mobile/lib/widgets/time_pickers.dart)
- Implement `FiveMinuteSnapScrollPhysics` extending `FixedExtentScrollPhysics`:
  - Intercepts `createBallisticSimulation`.
  - When velocity $> 80\text{ px/s}$ or target landing is near a multiple of 5, rounds target item index to nearest 5 (`0, 5, 10, 15...`).
  - When velocity $\le 80\text{ px/s}$, snaps to nearest 1-minute discrete item.
- Enhance 3D dial visual styling:
  - Separate cylindrical columns for Hours, Minutes, and AM/PM with recessed dial borders and dark radial/linear cylinder depth gradients.
  - Center aperture lens highlight band with metallic borders.
  - Cylinder curvature with optimized perspective (`0.0045`) and diameter ratio (`1.25`).

---

### 2. Unified Modal & Day/Date Selection (`mobile/lib/main.dart`)

#### [MODIFY] [main.dart](file:///Users/dsam/Documents/remotealarm/mobile/lib/main.dart)
- In `_openTimeAndScheduleSheet`:
  - Remove redundant countdown pill (`In X hours X mins`).
  - Update recurrence chips: `Once`, `Daily`, `Weekdays`, `Custom` (drop `Weekends`).
  - One-off date selection row:
    - If selected time is past current time today: completely hide `Today` (animated switch).
    - If selected time is later today: show `Today` and `Tomorrow`.
    - Add `[ Pick Date 📅 ]` / `[ DD MMM 📅 ]` button allowing user to pick any specific future date via `showDatePicker`.
    - Handle custom future date in `computeFinalTime` and store in `curTime`.
  - In alarm switch toggle (`_toggleAlarmArmed`):
    - When turned ON: call `HapticService.playArm()`.
    - When turned OFF: call `HapticService.playDisarm()`.
  - In alarm save buttons (create & detail modals): trigger `HapticService.playArm()`.

---

### 3. Haptic Service Defaults (`mobile/lib/services/haptic_service.dart`)

#### [MODIFY] [haptic_service.dart](file:///Users/dsam/Documents/remotealarm/mobile/lib/services/haptic_service.dart)
- Change default `activeScrollStyle` to `ScrollHapticStyle.softCrownHalved`.
- Ensure `softCrownHalved` fires subtle clicks every 2 units and crisp milestone clicks on 5-minute / 15-minute marks.

---

### 4. Tests & Backlog

#### [MODIFY] [haptic_service_test.dart](file:///Users/dsam/Documents/remotealarm/mobile/test/haptic_service_test.dart)
- Update default scroll style test assertion to `ScrollHapticStyle.softCrownHalved`.

#### [MODIFY] [backlog.md](file:///Users/dsam/.gemini/antigravity/brain/bbc71631-0661-4d1f-a236-508748ab5ff8/backlog.md)
- Add Fortnightly recurrence alarms item.
- Add Raycast extension & Google Calendar / Tailscale homelab synchronization item.

---

## Verification Plan

### Automated Tests
- `flutter analyze` in `mobile/`: Zero warnings and zero errors.
- `flutter test` in `mobile/`: Verify all unit tests pass with the new scroll haptic defaults and physics.

### Manual Verification
- Test Drum Tumbler scrolling: fling quickly to verify it magnetically snaps to 5-minute increments; nudge slowly to verify it can land on single minutes (e.g. 7:03).
- Test Future Date Picker: Pick a date next week, verify the pill shows `[ Date 📅 ]` and applies correctly.
- Test "Today" visibility: Scroll past current time and watch "Today" disappear; scroll to future time and watch "Today" reappear.
- Build release APK and install to device once plugged in.
