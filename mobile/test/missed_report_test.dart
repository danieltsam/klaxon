import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/services/alarm_service.dart';
import 'package:mobile/services/backend_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AlarmService.resetMissedReportStateForTest();
  });

  group('BackendClient.reportMissedAlarms', () {
    test('batches multiple ids into a single call', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"updated":2}', 200);
      });

      final ok = await BackendClient.reportMissedAlarms(
        ['uuid-1', 'uuid-2'],
        client: client,
      );

      expect(ok, isTrue);
      expect(requests.length, equals(1));
      final request = requests.single;
      expect(request.method, equals('POST'));
      expect(request.url.path, equals('/api/alarms/report-missed'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['ids'], equals(['uuid-1', 'uuid-2']));
      expect(body['reason'], equals('device_reported_stale'));
    });

    test('a reporting failure does not propagate', () async {
      final client = MockClient((_) async => throw Exception('network down'));

      final ok = await BackendClient.reportMissedAlarms(
        ['uuid-1'],
        client: client,
      );

      expect(ok, isFalse);
    });
  });

  group('AlarmService missed reporting', () {
    test('flushes all newly declined ids in one batched call', () async {
      final batches = <List<String>>[];
      AlarmService.missedReportSenderForTest = (ids) async {
        batches.add(List<String>.from(ids));
        return true;
      };

      AlarmService.recordDeclinedStaleAlarm('uuid-1');
      AlarmService.recordDeclinedStaleAlarm('uuid-2');
      await AlarmService.flushMissedReports();

      expect(batches.length, equals(1));
      expect(batches.single, equals(['uuid-1', 'uuid-2']));
    });

    test('never reports the same declined alarm twice', () async {
      final batches = <List<String>>[];
      AlarmService.missedReportSenderForTest = (ids) async {
        batches.add(List<String>.from(ids));
        return true;
      };

      // Same alarm declined twice within one sync queues a single entry.
      AlarmService.recordDeclinedStaleAlarm('uuid-1');
      AlarmService.recordDeclinedStaleAlarm('uuid-1');
      await AlarmService.flushMissedReports();

      // A later sync declines the same alarm again: already reported, so it
      // must not be sent a second time.
      AlarmService.recordDeclinedStaleAlarm('uuid-1');
      await AlarmService.flushMissedReports();

      expect(batches.length, equals(1));
      expect(batches.single, equals(['uuid-1']));
    });

    test('a failed flush does not throw and stays queued for retry', () async {
      var attempts = 0;
      AlarmService.missedReportSenderForTest = (ids) async {
        attempts++;
        return false;
      };
      AlarmService.recordDeclinedStaleAlarm('uuid-1');

      await expectLater(AlarmService.flushMissedReports(), completes);

      // The backend never accepted it, so it remains queued for the next sync.
      expect(attempts, equals(1));
      expect(AlarmService.pendingMissedReportIds, contains('uuid-1'));

      await AlarmService.flushMissedReports();
      expect(attempts, equals(2));
    });
  });
}
