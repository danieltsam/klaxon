import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart' as app;

void main() {
  group('matchesAlarmFilter', () {
    test('active filter includes pending, snoozed and ringing', () {
      expect(app.matchesAlarmFilter('pending', 'active'), isTrue);
      expect(app.matchesAlarmFilter('snoozed', 'active'), isTrue);
      expect(app.matchesAlarmFilter('ringing', 'active'), isTrue);
    });

    test('active filter excludes disabled and missed', () {
      expect(app.matchesAlarmFilter('disabled', 'active'), isFalse);
      expect(app.matchesAlarmFilter('missed', 'active'), isFalse);
      expect(app.matchesAlarmFilter('completed', 'active'), isFalse);
    });

    test('off filter excludes active statuses', () {
      expect(app.matchesAlarmFilter('pending', 'off'), isFalse);
      expect(app.matchesAlarmFilter('snoozed', 'off'), isFalse);
      expect(app.matchesAlarmFilter('ringing', 'off'), isFalse);
    });

    test('off filter includes disabled and missed', () {
      expect(app.matchesAlarmFilter('disabled', 'off'), isTrue);
      expect(app.matchesAlarmFilter('missed', 'off'), isTrue);
      expect(app.matchesAlarmFilter('completed', 'off'), isTrue);
    });

    test('all filter includes every status', () {
      for (final status in ['pending', 'snoozed', 'ringing', 'disabled', 'missed', 'completed']) {
        expect(app.matchesAlarmFilter(status, 'all'), isTrue);
      }
    });

    test('unknown filter defaults to all', () {
      expect(app.matchesAlarmFilter('pending', 'unknown'), isTrue);
      expect(app.matchesAlarmFilter('disabled', 'unknown'), isTrue);
    });
  });
}
