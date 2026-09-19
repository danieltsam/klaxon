/// Utility for formatting dates and times according to user preferences.
class SettingsFormatter {
  /// Formats [dt] according to [timeFormat] ('24h' or '12h').
  static String formatTime(DateTime dt, String timeFormat) {
    if (timeFormat == '12h') {
      int h = dt.hour;
      final m = dt.minute.toString().padLeft(2, '0');
      final ampm = h >= 12 ? 'pm' : 'am';
      h = h % 12;
      if (h == 0) h = 12;
      return '${h.toString().padLeft(2, '0')}:$m $ampm';
    }
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// Formats [dt] according to [dateFormat] ('dd/mm/yyyy', 'mm/dd/yyyy', 'yyyy-mm-dd').
  static String formatDate(DateTime dt, String dateFormat) {
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year.toString();

    if (dateFormat == 'mm/dd/yyyy') {
      return '$mm/$dd/$yyyy';
    } else if (dateFormat == 'yyyy-mm-dd') {
      return '$yyyy-$mm-$dd';
    }
    return '$dd/$mm/$yyyy';
  }
}
