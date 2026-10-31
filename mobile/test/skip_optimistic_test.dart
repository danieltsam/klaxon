import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

void main() {
  group('occurrenceAfter', () {
    test('steps a future Friday weekday target to Monday', () {
      final friday = DateTime(2026, 11, 6, 9, 0);
      expect(
        AlarmService.occurrenceAfter(friday, const [1, 2, 3, 4, 5], 1, null),
        equals(DateTime(2026, 11, 9, 9, 0)),
      );
    });

    test('steps a fortnightly target by 14 days', () {
      final anchor = DateTime(2026, 10, 2);
      final onPattern = DateTime(2026, 10, 30, 9, 0); // anchor + 28 days
      expect(
        AlarmService.occurrenceAfter(onPattern, const [5], 2, anchor),
        equals(DateTime(2026, 11, 13, 9, 0)),
      );
    });

    test('is null for a one-time alarm', () {
      expect(
        AlarmService.occurrenceAfter(DateTime(2026, 11, 6, 9, 0), const [], 1, null),
        isNull,
      );
    });
  });
}
