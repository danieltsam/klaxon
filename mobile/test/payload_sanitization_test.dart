import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

void main() {
  group('FCM Payload Sanitization Tests', () {
    test('Ensures seconds and milliseconds are stripped from target_time', () {
      const rawIso = '2026-09-18T09:22:45.987Z';
      final rawDateTime = DateTime.parse(rawIso).toLocal();
      final parsedDateTime = DateTime(
        rawDateTime.year,
        rawDateTime.month,
        rawDateTime.day,
        rawDateTime.hour,
        rawDateTime.minute,
        0,
        0,
      );

      expect(parsedDateTime.second, equals(0));
      expect(parsedDateTime.millisecond, equals(0));
      expect(parsedDateTime.microsecond, equals(0));
    });

    test('Parses comma-separated repeat_days from FCM payload', () {
      const repeatDaysStr = '1,3,5';
      final days = repeatDaysStr
          .split(',')
          .map((s) => int.tryParse(s) ?? 0)
          .where((d) => d >= 1 && d <= 7)
          .toList();

      expect(days, equals([1, 3, 5]));
    });

    test('Gracefully ignores invalid or empty repeat_days', () {
      const repeatDaysStr = 'invalid,99,abc';
      final days = repeatDaysStr
          .split(',')
          .map((s) => int.tryParse(s) ?? 0)
          .where((d) => d >= 1 && d <= 7)
          .toList();

      expect(days, isEmpty);
    });

    test('Resolves audio assets correctly for sound tones', () {
      expect(AlarmService.getAudioPathForTone('alarm'), equals('assets/alarm.mp3'));
      expect(AlarmService.getAudioPathForTone('chime'), equals('assets/chime.mp3'));
      expect(AlarmService.getAudioPathForTone('digital'), equals('assets/digital.mp3'));
      expect(AlarmService.getAudioPathForTone('CHIME'), equals('assets/chime.mp3'));
      expect(AlarmService.getAudioPathForTone(null), equals('assets/alarm.mp3'));
      expect(AlarmService.getAudioPathForTone('unknown'), equals('assets/alarm.mp3'));
    });

    test('onRemoteDismissed stream emits dismissed integer ID', () async {
      expectLater(AlarmService.onRemoteDismissed.stream, emits(12345));
      AlarmService.onRemoteDismissed.add(12345);
    });
  });
}
