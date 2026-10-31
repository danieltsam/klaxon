import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

void main() {
  group('computeFutureOccurrence for a repeating alarm', () {
    test('a weekdays alarm picked on a Saturday lands on Monday, not Saturday', () {
      final now = DateTime(2026, 10, 31, 0, 5); // Saturday
      final picked = DateTime(2026, 10, 31, 9, 0); // today 9am: future, but not a weekday

      final target = AlarmService.computeFutureOccurrence(
        picked,
        repeatDays: const [1, 2, 3, 4, 5],
        mockNow: now,
      );

      expect(target, equals(DateTime(2026, 11, 2, 9, 0)));
    });

    test('a weekdays alarm picked today at a later time stays today', () {
      final now = DateTime(2026, 11, 3, 9, 0); // Tuesday
      final picked = DateTime(2026, 11, 3, 17, 0);

      final target = AlarmService.computeFutureOccurrence(
        picked,
        repeatDays: const [1, 2, 3, 4, 5],
        mockNow: now,
      );

      expect(target, equals(DateTime(2026, 11, 3, 17, 0)));
    });

    test('a one-time alarm picked today at a later time is unchanged', () {
      final now = DateTime(2026, 10, 31, 0, 5);
      final picked = DateTime(2026, 10, 31, 9, 0);

      final target = AlarmService.computeFutureOccurrence(picked, mockNow: now);

      expect(target, equals(picked));
    });
  });
}
