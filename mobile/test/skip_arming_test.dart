import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

void main() {
  test('a future recurring target is armed as given, not rolled back to today', () {
    final now = DateTime(2026, 10, 29, 1, 0); // Thursday 1am
    final target = DateTime(2026, 10, 30, 9, 0); // Friday 9am, the morning after a skip
    final armed = AlarmService.computeArmTarget(
      target,
      repeatDays: [1, 2, 3, 4, 5],
      mockNow: now,
    );
    expect(armed, equals(target));
  });

  test('a past recurring target still advances', () {
    final now = DateTime(2026, 10, 30, 10, 0); // Friday, after the ring
    final target = DateTime(2026, 10, 30, 9, 0);
    final armed = AlarmService.computeArmTarget(
      target,
      repeatDays: [1, 2, 3, 4, 5],
      mockNow: now,
    );
    expect(armed, equals(DateTime(2026, 11, 2, 9, 0))); // Monday
  });

  test('a target that already passed advances past it, never back to an earlier skip', () {
    final now = DateTime(2026, 11, 4, 12, 0); // Wednesday midday, phone was offline
    final target = DateTime(2026, 11, 3, 9, 0); // the Tuesday the alarm was meant to ring
    final armed = AlarmService.computeArmTarget(
      target,
      repeatDays: [1, 2, 3, 4, 5],
      mockNow: now,
    );
    expect(armed!.isAfter(target), isTrue);
    expect(armed, equals(DateTime(2026, 11, 5, 9, 0))); // Thursday, never the Monday before
  });
}
