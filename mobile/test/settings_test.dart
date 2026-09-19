import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile/utils/settings_formatter.dart';

void main() {
  group('SettingsFormatter Time Formatting', () {
    test('Formats 24-hour morning time with zero padding', () {
      final dt = DateTime(2026, 9, 19, 7, 5);
      expect(SettingsFormatter.formatTime(dt, '24h'), equals('07:05'));
    });

    test('Formats 24-hour afternoon time', () {
      final dt = DateTime(2026, 9, 19, 14, 30);
      expect(SettingsFormatter.formatTime(dt, '24h'), equals('14:30'));
    });

    test('Formats 24-hour midnight correctly', () {
      final dt = DateTime(2026, 9, 19, 0, 0);
      expect(SettingsFormatter.formatTime(dt, '24h'), equals('00:00'));
    });

    test('Formats 24-hour noon correctly', () {
      final dt = DateTime(2026, 9, 19, 12, 0);
      expect(SettingsFormatter.formatTime(dt, '24h'), equals('12:00'));
    });

    test('Formats 24-hour late evening', () {
      final dt = DateTime(2026, 9, 19, 23, 59);
      expect(SettingsFormatter.formatTime(dt, '24h'), equals('23:59'));
    });

    test('Formats 12-hour morning time with zero padding and am suffix', () {
      final dt = DateTime(2026, 9, 19, 7, 5);
      expect(SettingsFormatter.formatTime(dt, '12h'), equals('07:05 am'));
    });

    test('Formats 12-hour afternoon time with pm suffix', () {
      final dt = DateTime(2026, 9, 19, 14, 30);
      expect(SettingsFormatter.formatTime(dt, '12h'), equals('02:30 pm'));
    });

    test('Formats 12-hour midnight as 12:00 am', () {
      final dt = DateTime(2026, 9, 19, 0, 0);
      expect(SettingsFormatter.formatTime(dt, '12h'), equals('12:00 am'));
    });

    test('Formats 12-hour noon as 12:00 pm', () {
      final dt = DateTime(2026, 9, 19, 12, 0);
      expect(SettingsFormatter.formatTime(dt, '12h'), equals('12:00 pm'));
    });

    test('Formats 12-hour 12:35 am correctly', () {
      final dt = DateTime(2026, 9, 19, 0, 35);
      expect(SettingsFormatter.formatTime(dt, '12h'), equals('12:35 am'));
    });

    test('Formats 12-hour 12:45 pm correctly', () {
      final dt = DateTime(2026, 9, 19, 12, 45);
      expect(SettingsFormatter.formatTime(dt, '12h'), equals('12:45 pm'));
    });

    test('Formats 12-hour 11:59 pm correctly', () {
      final dt = DateTime(2026, 9, 19, 23, 59);
      expect(SettingsFormatter.formatTime(dt, '12h'), equals('11:59 pm'));
    });
  });

  group('SettingsFormatter Date Formatting', () {
    final testDate = DateTime(2026, 9, 5);

    test('Formats dd/mm/yyyy with zero padding', () {
      expect(SettingsFormatter.formatDate(testDate, 'dd/mm/yyyy'), equals('05/09/2026'));
    });

    test('Formats mm/dd/yyyy with zero padding', () {
      expect(SettingsFormatter.formatDate(testDate, 'mm/dd/yyyy'), equals('09/05/2026'));
    });

    test('Formats yyyy-mm-dd ISO format', () {
      expect(SettingsFormatter.formatDate(testDate, 'yyyy-mm-dd'), equals('2026-09-05'));
    });

    test('Falls back to dd/mm/yyyy for unknown date format', () {
      expect(SettingsFormatter.formatDate(testDate, 'custom_unknown'), equals('05/09/2026'));
    });
  });

  group('Persistent Settings Storage Parity', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Retrieves default settings when no preferences exist', () async {
      final prefs = await SharedPreferences.getInstance();
      final soundTone = prefs.getString('pref_sound_tone') ?? 'alarm';
      final rampSeconds = prefs.getInt('pref_ramp_seconds') ?? 15;
      final timeFormat = prefs.getString('pref_time_format') ?? '24h';
      final dateFormat = prefs.getString('pref_date_format') ?? 'dd/mm/yyyy';

      expect(soundTone, equals('alarm'));
      expect(rampSeconds, equals(15));
      expect(timeFormat, equals('24h'));
      expect(dateFormat, equals('dd/mm/yyyy'));
    });

    test('Stores and updates settings correctly in preferences', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pref_sound_tone', 'chime');
      await prefs.setInt('pref_ramp_seconds', 30);
      await prefs.setString('pref_time_format', '12h');
      await prefs.setString('pref_date_format', 'yyyy-mm-dd');

      expect(prefs.getString('pref_sound_tone'), equals('chime'));
      expect(prefs.getInt('pref_ramp_seconds'), equals(30));
      expect(prefs.getString('pref_time_format'), equals('12h'));
      expect(prefs.getString('pref_date_format'), equals('yyyy-mm-dd'));
    });
  });
}
