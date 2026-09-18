import 'package:flutter_test/flutter_test.dart';

DateTime getNextOccurrence(DateTime targetTime, List<int> repeatDays, {DateTime? mockNow}) {
  final now = mockNow ?? DateTime.now();
  for (int dayOffset = 1; dayOffset <= 7; dayOffset++) {
    final candidate = DateTime(
      now.year,
      now.month,
      now.day + dayOffset,
      targetTime.hour,
      targetTime.minute,
      0,
      0,
    );
    if (repeatDays.contains(candidate.weekday)) {
      return candidate;
    }
  }
  return targetTime.add(const Duration(days: 1));
}

void main() {
  group('Recurrence Calculation Tests', () {
    test('Calculates next weekday correctly from Friday', () {
      // 2026-09-18 is a Friday (weekday = 5)
      final fridayNow = DateTime(2026, 9, 18, 9, 0, 0);
      final targetTime = DateTime(2026, 9, 18, 7, 30, 0);
      final repeatDays = [1, 2, 3, 4, 5]; // Mon - Fri

      final next = getNextOccurrence(targetTime, repeatDays, mockNow: fridayNow);

      // Next weekday after Friday is Monday (2026-09-21)
      expect(next.weekday, equals(DateTime.monday));
      expect(next.year, equals(2026));
      expect(next.month, equals(9));
      expect(next.day, equals(21));
      expect(next.hour, equals(7));
      expect(next.minute, equals(30));
      expect(next.second, equals(0));
      expect(next.millisecond, equals(0));
    });

    test('Calculates next weekend day correctly from Saturday', () {
      // 2026-09-19 is a Saturday (weekday = 6)
      final saturdayNow = DateTime(2026, 9, 19, 10, 0, 0);
      final targetTime = DateTime(2026, 9, 19, 9, 0, 0);
      final repeatDays = [6, 7]; // Sat & Sun

      final next = getNextOccurrence(targetTime, repeatDays, mockNow: saturdayNow);

      // Next weekend day after Saturday is Sunday (2026-09-20)
      expect(next.weekday, equals(DateTime.sunday));
      expect(next.day, equals(20));
      expect(next.second, equals(0));
    });

    test('Calculates daily recurrence correctly for next day', () {
      final wednesdayNow = DateTime(2026, 9, 16, 8, 0, 0);
      final targetTime = DateTime(2026, 9, 16, 7, 0, 0);
      final repeatDays = [1, 2, 3, 4, 5, 6, 7]; // Every day

      final next = getNextOccurrence(targetTime, repeatDays, mockNow: wednesdayNow);

      // Next day is Thursday (2026-09-17)
      expect(next.weekday, equals(DateTime.thursday));
      expect(next.day, equals(17));
      expect(next.second, equals(0));
    });
  });
}
