import 'package:shared_preferences/shared_preferences.dart';

/// Utility to map String UUIDs to 32-bit integers required by the `alarm` package,
/// and preserve reverse mapping to sync states back to the backend.
class IdMapper {
  static const String _prefPrefix = 'uuid_map_';
  static const String _labelPrefix = 'label_map_';
  static const String _descPrefix = 'desc_map_';
  static const String _snoozedPrefix = 'snoozed_';
  static const String _repeatDaysPrefix = 'repeat_days_';
  static const String _intervalWeeksPrefix = 'interval_weeks_';
  static const String _anchorDatePrefix = 'anchor_date_';
  static const String _tonePrefix = 'sound_tone_';
  static const String _rampPrefix = 'ramp_seconds_';
  static const String _enabledPrefix = 'enabled_';
  static const String _timePrefix = 'time_iso_';

  /// Convert a string UUID into a 32-bit positive integer (0 to 2,147,483,646)
  static int uuidToInt(String uuid) {
    return (uuid.hashCode.abs() % 2147483647);
  }

  /// Store the UUID and label associated with the generated intId
  static Future<void> saveMapping(
    int intId,
    String uuid, {
    String? label,
    String? description,
    DateTime? targetTime,
    String? soundTone,
    int? rampSeconds,
    List<int>? repeatDays,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefPrefix$intId', uuid);
    if (label != null) {
      await prefs.setString('$_labelPrefix$intId', label);
    }
    if (description != null) {
      await prefs.setString('$_descPrefix$intId', description);
    }
    if (targetTime != null) {
      await prefs.setString('$_timePrefix$intId', targetTime.toIso8601String());
    }
    if (soundTone != null) {
      await prefs.setString('$_tonePrefix$intId', soundTone);
    }
    if (rampSeconds != null) {
      await prefs.setInt('$_rampPrefix$intId', rampSeconds);
    }
    if (repeatDays != null) {
      if (repeatDays.isEmpty) {
        await prefs.remove('$_repeatDaysPrefix$intId');
      } else {
        await prefs.setString('$_repeatDaysPrefix$intId', repeatDays.join(','));
      }
    }
    // Default to enabled
    if (!prefs.containsKey('$_enabledPrefix$intId')) {
      await prefs.setBool('$_enabledPrefix$intId', true);
    }
  }

  /// Store rich text description / notes
  static Future<void> setDescription(int intId, String desc) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_descPrefix$intId', desc);
  }

  /// Retrieve rich text description
  static Future<String> getDescription(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_descPrefix$intId') ?? '';
  }

  /// Mark alarm enabled or disabled (for sliders)
  static Future<void> setEnabled(int intId, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_enabledPrefix$intId', enabled);
  }

  /// Check whether alarm is enabled
  static Future<bool> isEnabled(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_enabledPrefix$intId') ?? true;
  }

  /// Store target time
  static Future<void> setTargetTime(int intId, DateTime dt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_timePrefix$intId', dt.toIso8601String());
  }

  /// Retrieve target time
  static Future<DateTime?> getTargetTime(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString('$_timePrefix$intId');
    if (str == null) return null;
    return DateTime.tryParse(str);
  }

  /// Mark whether an alarm is in a snoozed state
  static Future<void> setSnoozed(int intId, bool snoozed) async {
    final prefs = await SharedPreferences.getInstance();
    if (snoozed) {
      await prefs.setBool('$_snoozedPrefix$intId', true);
    } else {
      await prefs.remove('$_snoozedPrefix$intId');
    }
  }

  /// Check whether an alarm was previously snoozed
  static Future<bool> isSnoozed(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_snoozedPrefix$intId') ?? false;
  }

  /// Store recurring days of week (1 = Monday, 7 = Sunday)
  static Future<void> setRepeatDays(int intId, List<int> days) async {
    final prefs = await SharedPreferences.getInstance();
    if (days.isEmpty) {
      await prefs.remove('$_repeatDaysPrefix$intId');
    } else {
      await prefs.setString('$_repeatDaysPrefix$intId', days.join(','));
    }
  }

  /// Get recurring days of week
  static Future<List<int>> getRepeatDays(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString('$_repeatDaysPrefix$intId');
    if (str == null || str.isEmpty) return [];
    return str.split(',').map((s) => int.tryParse(s) ?? 0).where((d) => d >= 1 && d <= 7).toList();
  }

  /// Store recurrence interval in weeks (2 = fortnightly, <=1 = weekly).
  /// Values <= 1 clear the stored interval so weekly alarms never accumulate
  /// a stale interval key.
  static Future<void> setIntervalWeeks(int intId, int weeks) async {
    final prefs = await SharedPreferences.getInstance();
    if (weeks <= 1) {
      await prefs.remove('$_intervalWeeksPrefix$intId');
    } else {
      await prefs.setInt('$_intervalWeeksPrefix$intId', weeks);
    }
  }

  /// Get recurrence interval in weeks (null means 1 = weekly)
  static Future<int?> getIntervalWeeks(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_intervalWeeksPrefix$intId');
  }

  /// Store recurrence anchor date (ISO date string of the first occurrence,
  /// e.g. '2026-10-07'). Passing null/empty clears the stored anchor.
  static Future<void> setAnchorDate(int intId, String? isoDate) async {
    final prefs = await SharedPreferences.getInstance();
    if (isoDate == null || isoDate.isEmpty) {
      await prefs.remove('$_anchorDatePrefix$intId');
    } else {
      await prefs.setString('$_anchorDatePrefix$intId', isoDate);
    }
  }

  /// Get recurrence anchor date (ISO date string, null if not set)
  static Future<String?> getAnchorDate(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_anchorDatePrefix$intId');
  }

  /// Store sound tone ('alarm', 'chime', 'digital')
  static Future<void> setSoundTone(int intId, String tone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_tonePrefix$intId', tone);
  }

  /// Get sound tone ('alarm', 'chime', 'digital')
  static Future<String> getSoundTone(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_tonePrefix$intId') ?? 'alarm';
  }

  /// Store volume ramp in seconds
  static Future<void> setRampSeconds(int intId, int rampSeconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_rampPrefix$intId', rampSeconds);
  }

  /// Get volume ramp in seconds
  static Future<int> getRampSeconds(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_rampPrefix$intId') ?? 0;
  }

  /// Retrieve the UUID for a given integer ID
  static Future<String?> getUuid(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefPrefix$intId');
  }

  /// Retrieve the label for a given integer ID
  static Future<String?> getLabel(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_labelPrefix$intId');
  }

  /// Retrieve all known alarm integer IDs from stored keys
  static Future<List<int>> getAllKnownIds() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final ids = <int>{};
    for (final k in keys) {
      if (k.startsWith(_prefPrefix)) {
        final idStr = k.substring(_prefPrefix.length);
        final parsed = int.tryParse(idStr);
        if (parsed != null) ids.add(parsed);
      }
    }
    return ids.toList();
  }

  /// Remove mapping after alarm is permanently completed/canceled
  static Future<void> removeMapping(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefPrefix$intId');
    await prefs.remove('$_labelPrefix$intId');
    await prefs.remove('$_descPrefix$intId');
    await prefs.remove('$_snoozedPrefix$intId');
    await prefs.remove('$_repeatDaysPrefix$intId');
    await prefs.remove('$_intervalWeeksPrefix$intId');
    await prefs.remove('$_anchorDatePrefix$intId');
    await prefs.remove('$_tonePrefix$intId');
    await prefs.remove('$_rampPrefix$intId');
    await prefs.remove('$_enabledPrefix$intId');
    await prefs.remove('$_timePrefix$intId');
  }
}
