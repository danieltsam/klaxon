import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ArmHapticStyle {
  dualClack180,
  dualClackFast110,
  tripleRelayClack,
  heavySolenoidSnap,
  doubleReboundStrike,
}

enum DisarmHapticStyle {
  doubleSoftTap150,
  gentleDoubleTap100,
  tripleSoftFade,
  mechanicalSoftRelease,
  featherDecouple,
}

enum ScrollHapticStyle {
  quarterMilestonesOnly,
  fiveMinuteMilestones,
  softCrownHalved,
  softCrownThirds,
  muted,
}

enum PresetHapticStyle {
  magneticSnap,
  mediumImpact,
  heavyLatch,
}

enum UrgentHapticStyle {
  sirenWave,
  doubleHeartbeat,
  sosMorse,
  rapidAlert4,
}

class HapticService {
  static const String _keyArm = 'haptic_arm_style';
  static const String _keyDisarm = 'haptic_disarm_style';
  static const String _keyScroll = 'haptic_scroll_style';
  static const String _keyPreset = 'haptic_preset_style';

  static ArmHapticStyle activeArmStyle = ArmHapticStyle.dualClack180;
  static DisarmHapticStyle activeDisarmStyle = DisarmHapticStyle.doubleSoftTap150;
  static ScrollHapticStyle activeScrollStyle = ScrollHapticStyle.softCrownHalved;
  static PresetHapticStyle activePresetStyle = PresetHapticStyle.magneticSnap;

  static bool _initialized = false;
  static int _lastScrollTickTime = 0;

  static Future<void> initialize() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final armIndex = prefs.getInt(_keyArm);
      if (armIndex != null && armIndex >= 0 && armIndex < ArmHapticStyle.values.length) {
        activeArmStyle = ArmHapticStyle.values[armIndex];
      }

      final disarmIndex = prefs.getInt(_keyDisarm);
      if (disarmIndex != null && disarmIndex >= 0 && disarmIndex < DisarmHapticStyle.values.length) {
        activeDisarmStyle = DisarmHapticStyle.values[disarmIndex];
      }

      final scrollIndex = prefs.getInt(_keyScroll);
      if (scrollIndex != null && scrollIndex >= 0 && scrollIndex < ScrollHapticStyle.values.length) {
        activeScrollStyle = ScrollHapticStyle.values[scrollIndex];
      }

      final presetIndex = prefs.getInt(_keyPreset);
      if (presetIndex != null && presetIndex >= 0 && presetIndex < PresetHapticStyle.values.length) {
        activePresetStyle = PresetHapticStyle.values[presetIndex];
      }
      _initialized = true;
    } catch (_) {
      _initialized = true;
    }
  }

  static Future<void> setArmStyle(ArmHapticStyle style) async {
    activeArmStyle = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyArm, style.index);
  }

  static Future<void> setDisarmStyle(DisarmHapticStyle style) async {
    activeDisarmStyle = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyDisarm, style.index);
  }

  static Future<void> setScrollStyle(ScrollHapticStyle style) async {
    activeScrollStyle = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyScroll, style.index);
  }

  static Future<void> setPresetStyle(PresetHapticStyle style) async {
    activePresetStyle = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyPreset, style.index);
  }

  // --- EXECUTE ARM PATTERNS (Mechanical & Dual Clack Variations) ---
  static Future<void> playArm([ArmHapticStyle? overrideStyle]) async {
    final style = overrideStyle ?? activeArmStyle;
    switch (style) {
      case ArmHapticStyle.dualClack180:
        await HapticFeedback.mediumImpact();
        await Future.delayed(const Duration(milliseconds: 180));
        await HapticFeedback.heavyImpact();
        break;

      case ArmHapticStyle.dualClackFast110:
        await HapticFeedback.mediumImpact();
        await Future.delayed(const Duration(milliseconds: 110));
        await HapticFeedback.heavyImpact();
        break;

      case ArmHapticStyle.tripleRelayClack:
        await HapticFeedback.lightImpact();
        await Future.delayed(const Duration(milliseconds: 90));
        await HapticFeedback.mediumImpact();
        await Future.delayed(const Duration(milliseconds: 120));
        await HapticFeedback.heavyImpact();
        break;

      case ArmHapticStyle.heavySolenoidSnap:
        await HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 140));
        await HapticFeedback.mediumImpact();
        break;

      case ArmHapticStyle.doubleReboundStrike:
        await HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 180));
        await HapticFeedback.heavyImpact();
        break;
    }
  }

  // --- EXECUTE DISARM PATTERNS (Soft Rebound & Decoupling Variations) ---
  static Future<void> playDisarm([DisarmHapticStyle? overrideStyle]) async {
    final style = overrideStyle ?? activeDisarmStyle;
    switch (style) {
      case DisarmHapticStyle.doubleSoftTap150:
        await HapticFeedback.lightImpact();
        await Future.delayed(const Duration(milliseconds: 150));
        await HapticFeedback.lightImpact();
        break;

      case DisarmHapticStyle.gentleDoubleTap100:
        await HapticFeedback.lightImpact();
        await Future.delayed(const Duration(milliseconds: 100));
        await HapticFeedback.lightImpact();
        break;

      case DisarmHapticStyle.tripleSoftFade:
        await HapticFeedback.lightImpact();
        await Future.delayed(const Duration(milliseconds: 80));
        await HapticFeedback.selectionClick();
        await Future.delayed(const Duration(milliseconds: 100));
        await HapticFeedback.selectionClick();
        break;

      case DisarmHapticStyle.mechanicalSoftRelease:
        await HapticFeedback.mediumImpact();
        await Future.delayed(const Duration(milliseconds: 130));
        await HapticFeedback.selectionClick();
        break;

      case DisarmHapticStyle.featherDecouple:
        await HapticFeedback.selectionClick();
        await Future.delayed(const Duration(milliseconds: 175));
        await HapticFeedback.selectionClick();
        break;
    }
  }

  // --- EXECUTE SCROLL / TUMBLER TICKS ---
  static void playScrollTick({
    bool isMajor = false,
    bool isSuperMajor = false,
    int unit = 0,
    ScrollHapticStyle? overrideStyle,
  }) {
    final style = overrideStyle ?? activeScrollStyle;
    if (style == ScrollHapticStyle.muted) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    // Throttle minimum interval (45ms) to prevent dense buzzing
    if (now - _lastScrollTickTime < 45 && !isMajor && !isSuperMajor) {
      return;
    }
    _lastScrollTickTime = now;

    switch (style) {
      case ScrollHapticStyle.quarterMilestonesOnly:
        // Silent on individual units, only fires on :00, :15, :30, :45
        if (isSuperMajor) {
          HapticFeedback.heavyImpact();
        } else if (unit % 15 == 0) {
          HapticFeedback.mediumImpact();
        }
        break;

      case ScrollHapticStyle.fiveMinuteMilestones:
        // Silent on individual units, fires every 5 minutes
        if (isSuperMajor) {
          HapticFeedback.heavyImpact();
        } else if (isMajor || unit % 5 == 0) {
          HapticFeedback.lightImpact();
        }
        break;

      case ScrollHapticStyle.softCrownHalved:
        // Relaxed crown: ticks every 2 units, with accented 5m and 15m milestones
        if (isSuperMajor) {
          HapticFeedback.heavyImpact();
        } else if (isMajor || unit % 5 == 0) {
          HapticFeedback.mediumImpact();
        } else if (unit % 2 == 0) {
          HapticFeedback.selectionClick();
        }
        break;

      case ScrollHapticStyle.softCrownThirds:
        // Relaxed crown: ticks every 3 units, with accented 5m and 15m milestones
        if (isSuperMajor) {
          HapticFeedback.heavyImpact();
        } else if (isMajor || unit % 5 == 0) {
          HapticFeedback.mediumImpact();
        } else if (unit % 3 == 0) {
          HapticFeedback.selectionClick();
        }
        break;

      case ScrollHapticStyle.muted:
        break;
    }
  }

  // --- EXECUTE PRESET SNAPS ---
  static Future<void> playPreset([PresetHapticStyle? overrideStyle]) async {
    final style = overrideStyle ?? activePresetStyle;
    switch (style) {
      case PresetHapticStyle.magneticSnap:
        await HapticFeedback.lightImpact();
        await Future.delayed(const Duration(milliseconds: 80));
        await HapticFeedback.mediumImpact();
        break;
      case PresetHapticStyle.mediumImpact:
        await HapticFeedback.mediumImpact();
        break;
      case PresetHapticStyle.heavyLatch:
        await HapticFeedback.heavyImpact();
        break;
    }
  }

  static void selectionClick() {
    HapticFeedback.selectionClick();
  }

  // --- EXECUTE URGENT ALERTS (Rhythmic continuous patterns with clear spacing) ---
  static Future<void> playUrgent(UrgentHapticStyle style) async {
    switch (style) {
      case UrgentHapticStyle.sirenWave:
        // Ascending into peak and descending wave (5 pulses)
        await HapticFeedback.lightImpact();
        await Future.delayed(const Duration(milliseconds: 90));
        await HapticFeedback.mediumImpact();
        await Future.delayed(const Duration(milliseconds: 95));
        await HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 120));
        await HapticFeedback.mediumImpact();
        await Future.delayed(const Duration(milliseconds: 90));
        await HapticFeedback.lightImpact();
        break;

      case UrgentHapticStyle.doubleHeartbeat:
        // Heartbeat cycle: lub-dub ... pause ... lub-dub
        await HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 110));
        await HapticFeedback.mediumImpact();
        await Future.delayed(const Duration(milliseconds: 350));
        await HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 110));
        await HapticFeedback.mediumImpact();
        break;

      case UrgentHapticStyle.sosMorse:
        // 3 short, 3 long, 3 short
        for (int i = 0; i < 3; i++) {
          await HapticFeedback.lightImpact();
          await Future.delayed(const Duration(milliseconds: 80));
        }
        await Future.delayed(const Duration(milliseconds: 140));
        for (int i = 0; i < 3; i++) {
          await HapticFeedback.heavyImpact();
          await Future.delayed(const Duration(milliseconds: 140));
        }
        await Future.delayed(const Duration(milliseconds: 140));
        for (int i = 0; i < 3; i++) {
          await HapticFeedback.lightImpact();
          await Future.delayed(const Duration(milliseconds: 80));
        }
        break;

      case UrgentHapticStyle.rapidAlert4:
        // 4 authoritative heavy pulses (120ms spacing)
        for (int i = 0; i < 4; i++) {
          await HapticFeedback.heavyImpact();
          if (i < 3) await Future.delayed(const Duration(milliseconds: 120));
        }
        break;
    }
  }

  // --- HUMAN-READABLE METADATA ---
  static String armStyleTitle(ArmHapticStyle style) {
    switch (style) {
      case ArmHapticStyle.dualClack180:
        return 'dual mechanical clack (180ms)';
      case ArmHapticStyle.dualClackFast110:
        return 'fast dual clack (110ms)';
      case ArmHapticStyle.tripleRelayClack:
        return 'triple relay clack (90/120ms)';
      case ArmHapticStyle.heavySolenoidSnap:
        return 'heavy solenoid snap (140ms)';
      case ArmHapticStyle.doubleReboundStrike:
        return 'double rebound strike (180ms)';
    }
  }

  static String armStyleDesc(ArmHapticStyle style) {
    switch (style) {
      case ArmHapticStyle.dualClack180:
        return 'Two distinct, widely spaced mechanical switch clacks (180ms separation).';
      case ArmHapticStyle.dualClackFast110:
        return 'Snappier mechanical clack pair with tight 110ms tactile response.';
      case ArmHapticStyle.tripleRelayClack:
        return 'Three progressive mechanical steps: light → medium → heavy latch.';
      case ArmHapticStyle.heavySolenoidSnap:
        return 'Authoritative solenoid strike settling 140ms later with medium click.';
      case ArmHapticStyle.doubleReboundStrike:
        return 'Dual heavy solenoid hits spaced 180ms apart (maximum mechanical presence).';
    }
  }

  static String disarmStyleTitle(DisarmHapticStyle style) {
    switch (style) {
      case DisarmHapticStyle.doubleSoftTap150:
        return 'double soft tap (150ms)';
      case DisarmHapticStyle.gentleDoubleTap100:
        return 'gentle double tap (100ms)';
      case DisarmHapticStyle.tripleSoftFade:
        return 'triple soft fade (80/100ms)';
      case DisarmHapticStyle.mechanicalSoftRelease:
        return 'mechanical soft release (130ms)';
      case DisarmHapticStyle.featherDecouple:
        return 'feather decouple (175ms)';
    }
  }

  static String disarmStyleDesc(DisarmHapticStyle style) {
    switch (style) {
      case DisarmHapticStyle.doubleSoftTap150:
        return 'Two gentle, spacious rebound taps (150ms separation). Clean & relaxing.';
      case DisarmHapticStyle.gentleDoubleTap100:
        return 'Snappy, featherlight double tap with 100ms interval.';
      case DisarmHapticStyle.tripleSoftFade:
        return 'Three soft descending micro-taps that dissolve into quiet silence.';
      case DisarmHapticStyle.mechanicalSoftRelease:
        return 'Medium disengage latch followed 130ms later by soft click.';
      case DisarmHapticStyle.featherDecouple:
        return 'Delicate twin micro-detents spaced 175ms apart.';
    }
  }

  static String scrollStyleTitle(ScrollHapticStyle style) {
    switch (style) {
      case ScrollHapticStyle.quarterMilestonesOnly:
        return '15-min milestones only';
      case ScrollHapticStyle.fiveMinuteMilestones:
        return '5-min milestones only';
      case ScrollHapticStyle.softCrownHalved:
        return 'relaxed crown (every 2 units)';
      case ScrollHapticStyle.softCrownThirds:
        return 'relaxed crown (every 3 units)';
      case ScrollHapticStyle.muted:
        return 'muted (silent)';
    }
  }

  static String scrollStyleDesc(ScrollHapticStyle style) {
    switch (style) {
      case ScrollHapticStyle.quarterMilestonesOnly:
        return 'Completely silent while sliding; crisp tactile notches ONLY at :00, :15, :30, :45.';
      case ScrollHapticStyle.fiveMinuteMilestones:
        return 'Silent between minutes; clean notches every 5 mins, heavy snap at the hour (:00).';
      case ScrollHapticStyle.softCrownHalved:
        return 'Half-density ticks (every 2 units), mimicking a relaxed luxury watch bezel.';
      case ScrollHapticStyle.softCrownThirds:
        return 'Spacious third-density ticks (every 3 units) for effortless, quiet detents.';
      case ScrollHapticStyle.muted:
        return 'Silky smooth scrolling with zero motor feedback.';
    }
  }

  static String presetStyleTitle(PresetHapticStyle style) {
    switch (style) {
      case PresetHapticStyle.magneticSnap:
        return 'magnetic snap (80ms)';
      case PresetHapticStyle.mediumImpact:
        return 'medium impact';
      case PresetHapticStyle.heavyLatch:
        return 'heavy latch';
    }
  }

  static String presetStyleDesc(PresetHapticStyle style) {
    switch (style) {
      case PresetHapticStyle.magneticSnap:
        return 'Light take-up into a crisp medium snap (80ms spacing).';
      case PresetHapticStyle.mediumImpact:
        return 'Clean, single-pulse tactile feedback.';
      case PresetHapticStyle.heavyLatch:
        return 'Solid, deep click for decisive actions.';
    }
  }
}
