import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

void main() {
  test('calendar day addition preserves the local wall clock', () {
    final from = DateTime(2026, 3, 28, 7, 30);
    final next = AlarmService.addCalendarDays(from, 14);
    expect(next.day, 11);
    expect(next.month, 4);
    expect(next.hour, 7);
    expect(next.minute, 30);
  });
}
