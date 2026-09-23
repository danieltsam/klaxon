import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

DateTime getNextOccurrence(DateTime targetTime, List<int> repeatDays,
    {int intervalWeeks = 1, DateTime? anchorDate, DateTime? mockNow}) {
  return AlarmService.getNextOccurrence(
    targetTime,
    repeatDays,
    intervalWeeks: intervalWeeks,
    anchorDate: anchorDate,
    mockNow: mockNow,
  );
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

  group('Fortnightly Recurrence Tests', () {
    // 2026-10-07 is a Wednesday (weekday = 3)
    final anchor = DateTime(2026, 10, 7);

    test('Returns the next 14-day step after the anchor', () {
      final now = DateTime(2026, 10, 8, 9, 0, 0); // Thursday after anchor
      final next = getNextOccurrence(
        DateTime(2026, 10, 7, 7, 30, 0),
        [3],
        intervalWeeks: 2,
        anchorDate: anchor,
        mockNow: now,
      );

      // Anchor + 14d = 2026-10-21 (Wednesday)
      expect(next.year, equals(2026));
      expect(next.month, equals(10));
      expect(next.day, equals(21));
      expect(next.weekday, equals(DateTime.wednesday));
      expect(next.hour, equals(7));
      expect(next.minute, equals(30));
    });

    test('Skips the in-between week entirely', () {
      // Even though 2026-10-14 (the in-between Wednesday) is after `now`,
      // it must NOT be selected because it is only 7 days from the anchor.
      final now = DateTime(2026, 10, 10, 9, 0, 0);
      final next = getNextOccurrence(
        DateTime(2026, 10, 7, 7, 30, 0),
        [3],
        intervalWeeks: 2,
        anchorDate: anchor,
        mockNow: now,
      );
      expect(next.day, equals(21));
    });

    test('Rolls forward when the anchor time has already passed today', () {
      final now = DateTime(2026, 10, 7, 8, 0, 0); // anchor day, 08:00
      final next = getNextOccurrence(
        DateTime(2026, 10, 7, 7, 30, 0),
        [3],
        intervalWeeks: 2,
        anchorDate: anchor,
        mockNow: now,
      );
      expect(next.day, equals(21));
    });

    test('Treats a candidate at the exact same moment as passed', () {
      final now = DateTime(2026, 10, 21, 7, 30, 0); // exactly anchor + 14d
      final next = getNextOccurrence(
        DateTime(2026, 10, 7, 7, 30, 0),
        [3],
        intervalWeeks: 2,
        anchorDate: anchor,
        mockNow: now,
      );
      expect(next.day, equals(4)); // 2026-11-04 (anchor + 28d)
      expect(next.month, equals(11));
    });

    test('computeFutureOccurrence returns a future fortnightly time as-is', () {
      final mockNow = DateTime(2026, 10, 10, 10, 0, 0);
      final futureTarget = DateTime(2026, 10, 21, 7, 30, 0);

      final result = AlarmService.computeFutureOccurrence(
        futureTarget,
        repeatDays: [3],
        intervalWeeks: 2,
        anchorDate: anchor,
        mockNow: mockNow,
      );
      expect(result, equals(futureTarget));
    });

    test('computeFutureOccurrence rolls a past fortnightly time to the next anchor step', () {
      final mockNow = DateTime(2026, 10, 10, 10, 0, 0);
      final staleTarget = DateTime(2026, 10, 7, 7, 30, 0);

      final result = AlarmService.computeFutureOccurrence(
        staleTarget,
        repeatDays: [3],
        intervalWeeks: 2,
        anchorDate: anchor,
        mockNow: mockNow,
      );
      expect(result.year, equals(2026));
      expect(result.month, equals(10));
      expect(result.day, equals(21));
      expect(result.hour, equals(7));
      expect(result.minute, equals(30));
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

  group('computeArmTarget stale one-time alarm guard', () {
    test('Refuses a past one-time alarm beyond the grace window (the 00:01 reconnect case)', () {
      // A one-time alarm set for 00:01 that was never delivered. The phone
      // reconnects at midnight two days later and must not arm it.
      final mockNow = DateTime(2026, 9, 23, 0, 0, 0);
      final staleAlarm = DateTime(2026, 9, 22, 0, 1, 0);

      final result = AlarmService.computeArmTarget(staleAlarm, mockNow: mockNow);
      expect(result, isNull);
    });

    test('Refuses a one-time alarm just beyond the 5-minute grace window', () {
      final mockNow = DateTime(2026, 9, 23, 12, 0, 0);
      final justTooLate = DateTime(2026, 9, 23, 11, 54, 59); // 5m01s past

      expect(AlarmService.computeArmTarget(justTooLate, mockNow: mockNow), isNull);
    });

    test('Arms a one-time alarm inside the grace window, a few minutes late', () {
      final mockNow = DateTime(2026, 9, 23, 12, 0, 0);
      final slightlyLate = DateTime(2026, 9, 23, 11, 57, 0); // 3 minutes past

      final result = AlarmService.computeArmTarget(slightlyLate, mockNow: mockNow);
      expect(result, equals(slightlyLate));
    });

    test('Arms exactly at the grace-window boundary', () {
      final mockNow = DateTime(2026, 9, 23, 12, 0, 0);
      final onBoundary = DateTime(2026, 9, 23, 11, 55, 0); // exactly 5 minutes

      final result = AlarmService.computeArmTarget(onBoundary, mockNow: mockNow);
      expect(result, equals(onBoundary));
    });

    test('Leaves a future one-time alarm unchanged', () {
      final mockNow = DateTime(2026, 9, 23, 12, 0, 0);
      final future = DateTime(2026, 9, 23, 18, 30, 0);

      expect(AlarmService.computeArmTarget(future, mockNow: mockNow), equals(future));
    });

    test('Still rolls a stale recurring (weekday) alarm', () {
      final mockNow = DateTime(2026, 9, 19, 10, 0, 0); // Saturday
      final stale = DateTime(2026, 9, 18, 7, 0, 0);

      final result = AlarmService.computeArmTarget(
        stale,
        repeatDays: [1, 2, 3, 4, 5],
        mockNow: mockNow,
      );
      expect(result, isNotNull);
      expect(result!.weekday, equals(DateTime.monday));
      expect(result.day, equals(21));
      expect(result.hour, equals(7));
    });

    test('Still rolls a stale fortnightly alarm with intervalWeeks/anchorDate', () {
      // Regression guard for the fortnightly work that landed in 6b5eee0.
      final mockNow = DateTime(2026, 10, 10, 10, 0, 0);
      final stale = DateTime(2026, 10, 7, 7, 30, 0);

      final result = AlarmService.computeArmTarget(
        stale,
        repeatDays: [3],
        intervalWeeks: 2,
        anchorDate: DateTime(2026, 10, 7),
        mockNow: mockNow,
      );
      expect(result, isNotNull);
      expect(result!.year, equals(2026));
      expect(result.month, equals(10));
      expect(result.day, equals(21));
      expect(result.hour, equals(7));
      expect(result.minute, equals(30));
    });
  });
}
