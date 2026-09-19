import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

DateTime getNextOccurrence(DateTime targetTime, List<int> repeatDays, {DateTime? mockNow}) {
  return AlarmService.getNextOccurrence(targetTime, repeatDays, mockNow: mockNow);
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

  group('AlarmService.computeFutureOccurrence Tests', () {
    test('Returns future alarm as-is', () {
      final mockNow = DateTime(2026, 9, 19, 10, 0, 0);
      final futureTime = DateTime(2026, 9, 19, 15, 48, 0);

      final result = AlarmService.computeFutureOccurrence(futureTime, mockNow: mockNow);
      expect(result, equals(futureTime));
    });

    test('Rolls past one-time alarm to today when time is later today', () {
      final mockNow = DateTime(2026, 9, 19, 10, 0, 0);
      final yesterdayAlarm = DateTime(2026, 9, 18, 15, 48, 0); // 3:48 PM

      final result = AlarmService.computeFutureOccurrence(yesterdayAlarm, mockNow: mockNow);
      expect(result.year, equals(2026));
      expect(result.month, equals(9));
      expect(result.day, equals(19)); // Today!
      expect(result.hour, equals(15));
      expect(result.minute, equals(48));
    });

    test('Rolls past one-time alarm to tomorrow when time has passed today', () {
      final mockNow = DateTime(2026, 9, 19, 16, 0, 0); // 4:00 PM
      final yesterdayAlarm = DateTime(2026, 9, 18, 15, 48, 0); // 3:48 PM

      final result = AlarmService.computeFutureOccurrence(yesterdayAlarm, mockNow: mockNow);
      expect(result.year, equals(2026));
      expect(result.month, equals(9));
      expect(result.day, equals(20)); // Tomorrow!
      expect(result.hour, equals(15));
      expect(result.minute, equals(48));
    });

    test('Rolls past recurring alarm to next scheduled day', () {
      final saturdayNow = DateTime(2026, 9, 19, 10, 0, 0); // Saturday
      final staleAlarm = DateTime(2026, 9, 18, 7, 0, 0); // 7:00 AM Mon-Fri
      final repeatDays = [1, 2, 3, 4, 5];

      final result = AlarmService.computeFutureOccurrence(staleAlarm, repeatDays: repeatDays, mockNow: saturdayNow);
      expect(result.weekday, equals(DateTime.monday));
      expect(result.day, equals(21));
      expect(result.hour, equals(7));
      expect(result.minute, equals(0));
    });

    test('Rolls past recurring alarm to today if today is active repeat day and time is later today', () {
      final mondayNow = DateTime(2026, 9, 21, 10, 0, 0); // Monday 10:00 AM
      final staleAlarm = DateTime(2026, 9, 18, 15, 0, 0); // 3:00 PM Mon-Fri
      final repeatDays = [1, 2, 3, 4, 5];

      final result = AlarmService.computeFutureOccurrence(staleAlarm, repeatDays: repeatDays, mockNow: mondayNow);
      // Must be scheduled for TODAY (Monday), not tomorrow Tuesday!
      expect(result.day, equals(21));
      expect(result.hour, equals(15));
      expect(result.minute, equals(0));
    });
  });
}
