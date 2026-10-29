import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

void main() {
  test('eligible only for an enabled, unsnoozed, pending recurring alarm', () {
    final now = DateTime(2026, 10, 29, 1, 0);
    bool at({
      bool enabled = true,
      bool snoozed = false,
      List<int> days = const [1, 2, 3, 4, 5],
      int weeks = 1,
      String? anchor,
      String status = 'pending',
      String? skipped,
    }) =>
        AlarmService.isSkipEligible(
          isEnabled: enabled,
          isSnoozed: snoozed,
          repeatDays: days,
          intervalWeeks: weeks,
          anchorDate: anchor,
          status: status,
          skippedFrom: skipped,
          mockNow: now,
        );

    expect(at(), isTrue);
    expect(at(enabled: false), isFalse);
    expect(at(snoozed: true), isFalse);
    expect(at(days: const []), isFalse);
    expect(at(days: const [], weeks: 2, anchor: '2026-10-30'), isTrue);
    expect(at(status: 'ringing'), isFalse);
    expect(at(status: 'disabled'), isFalse);
    expect(at(skipped: '2026-10-30T00:00:00.000Z'), isFalse);
  });

  test('the skip line names what was skipped and when it is back', () {
    final label = AlarmService.skipLineLabel(DateTime(2026, 10, 30, 9), DateTime(2026, 11, 2, 9));
    expect(label, 'skipped fri 30 oct, 9:00am · back mon 2 nov, 9:00am');
  });
}
