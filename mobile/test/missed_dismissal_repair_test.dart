import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

void main() {
  group('serverConfirmsDismissal', () {
    test('a dismissal already recorded is confirmed', () {
      expect(AlarmService.serverConfirmsDismissal('dismissed'), isTrue);
      expect(AlarmService.serverConfirmsDismissal('disabled'), isTrue);
      expect(AlarmService.serverConfirmsDismissal('canceled'), isTrue);
    });

    test('missed is a guess, not a confirmation', () {
      // The phone owes the server a dismissal; a missed row is exactly the case
      // where that report matters. Dropping it here left alarms the owner had
      // dismissed marked missed permanently.
      expect(AlarmService.serverConfirmsDismissal('missed'), isFalse);
    });

    test('statuses that still owe a report are not confirmations', () {
      expect(AlarmService.serverConfirmsDismissal('pending'), isFalse);
      expect(AlarmService.serverConfirmsDismissal('ringing'), isFalse);
      expect(AlarmService.serverConfirmsDismissal('snoozed'), isFalse);
    });
  });
}
