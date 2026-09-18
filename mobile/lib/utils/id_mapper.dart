import 'package:shared_preferences/shared_preferences.dart';

/// Utility to map String UUIDs to 32-bit integers required by the `alarm` package,
/// and preserve reverse mapping to sync states back to the backend.
class IdMapper {
  static const String _prefPrefix = 'uuid_map_';
  static const String _labelPrefix = 'label_map_';
  static const String _snoozedPrefix = 'snoozed_';
  static const String _repeatDaysPrefix = 'repeat_days_';
  static const String _tonePrefix = 'sound_tone_';
  static const String _rampPrefix = 'ramp_seconds_';

  /// Convert a string UUID into a 32-bit positive integer (0 to 2,147,483,646)
  static int uuidToInt(String uuid) {
    return (uuid.hashCode.abs() % 2147483647);
  }

  /// Store the UUID and label associated with the generated intId
  static Future<void> saveMapping(int intId, String uuid, {String? label}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefPrefix$intId', uuid);
    if (label != null) {
      await prefs.setString('$_labelPrefix$intId', label);
    }
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

  /// Remove mapping after alarm is permanently completed/canceled
  static Future<void> removeMapping(int intId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefPrefix$intId');
    await prefs.remove('$_labelPrefix$intId');
    await prefs.remove('$_snoozedPrefix$intId');
    await prefs.remove('$_repeatDaysPrefix$intId');
    await prefs.remove('$_tonePrefix$intId');
    await prefs.remove('$_rampPrefix$intId');
  }
}
