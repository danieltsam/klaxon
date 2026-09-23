import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alarm/alarm.dart';
import 'package:alarm/service/alarm_storage.dart';
import 'package:alarm/src/generated/platform_bindings.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';
import 'package:mobile/services/backend_client.dart';
import 'package:mobile/utils/id_mapper.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A device-time floored to the minute, plus the same 9-minute snooze the
/// service uses.
DateTime _floorPlusNine(DateTime now) => DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
      0,
      0,
    ).add(const Duration(minutes: 9));

/// Stands in for the `alarm` plugin's platform channels so `Alarm.set` and
/// `Alarm.stop` succeed inside the test isolate.
void _mockAlarmPlatformChannels() {
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
  Future<Object?> succeed(Object? message) async => <Object?>[null];
  for (final method in const ['setAlarm', 'stopAlarm']) {
    final channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.alarm.AlarmApi.$method',
      AlarmApi.pigeonChannelCodec,
    );
    messenger.setMockDecodedMessageHandler<Object?>(channel, succeed);
  }
}

/// Serves a canned `GET /api/alarms?view=all` response for the reconcile.
Future<HttpServer> _serveAlarms(
  List<Map<String, dynamic>> alarms, {
  void Function(Map<String, dynamic> body)? onRequestBody,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final raw = await utf8.decoder.bind(request).join();
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(alarms));
    await request.response.close();
    // Report the captured body only once the response is fully flushed, so the
    // caller's in-flight HTTP future cannot outlive its server.
    if (onRequestBody != null && raw.isNotEmpty) {
      onRequestBody(jsonDecode(raw) as Map<String, dynamic>);
    }
  });
  await BackendClient.setBaseUrl('http://127.0.0.1:${server.port}');
  return server;
}

AlarmSettings _settingsFor(int intId) => AlarmSettings(
      id: intId,
      dateTime: DateTime.now().add(const Duration(minutes: 30)),
      assetAudioPath: 'assets/alarm.mp3',
      loopAudio: true,
      vibrate: true,
      volumeSettings: const VolumeSettings.fixed(volume: 1.0),
      notificationSettings: const NotificationSettings(
        title: 'Test',
        body: 'Tap to dismiss or snooze',
        stopButton: 'Stop',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AlarmStorage.resetForTesting();
    Alarm.resetForTesting();
    AlarmService.resetMissedReportStateForTest();
    _mockAlarmPlatformChannels();
    // TestWidgetsFlutterBinding stubs all HTTP to status 400; these tests run a
    // real loopback server to exercise the actual BackendClient wire format.
    HttpOverrides.global = null;
  });

  group('snoozeAlarm backend reporting', () {
    test('sends the computed next-ring time as target_time', () async {
      final received = Completer<Map<String, dynamic>>();
      final server = await _serveAlarms(
        const [],
        onRequestBody: (body) {
          if (!received.isCompleted) received.complete(body);
        },
      );
      addTearDown(() => server.close(force: true));

      const intId = 777;
      await IdMapper.saveMapping(intId, 'remote-uuid-snooze', label: 'Snooze');

      final before = DateTime.now();
      final result = await AlarmService.snoozeAlarm(_settingsFor(intId));
      final after = DateTime.now();

      final body = await received.future.timeout(const Duration(seconds: 5));
      expect(body['status'], equals('snoozed'));

      final rawTarget = body['target_time'];
      expect(rawTarget, isA<String>());
      final sentTarget = DateTime.parse(rawTarget as String);
      expect(sentTarget.isUtc, isTrue);

      // The exact wire value is the floored, +9-minute local snooze in UTC.
      // Accept either side of a minute roll during the call.
      final candidates = {
        _floorPlusNine(before).toUtc(),
        _floorPlusNine(after).toUtc(),
      };
      expect(candidates.contains(sentTarget), isTrue);

      // The returned settings and the reported time describe the same instant.
      expect(result.dateTime, equals(sentTarget.toLocal()));
    });
  });

  group('syncWithBackend snooze reconciliation', () {
    test('keeps the local snoozed flag for a remote snoozed alarm', () async {
      const uuid = 'remote-snoozed-uuid';
      final intId = IdMapper.uuidToInt(uuid);
      final target = DateTime.now().toUtc().add(const Duration(minutes: 30));

      final server = await _serveAlarms([
        {
          'id': uuid,
          'target_time': target.toIso8601String(),
          'label': 'Remote Snoozed',
          'status': 'snoozed',
          'sound_tone': 'alarm',
          'ramp_seconds': 30,
        },
      ]);
      addTearDown(() => server.close(force: true));

      final count = await AlarmService.syncWithBackend();

      expect(count, equals(1));
      expect(await IdMapper.isSnoozed(intId), isTrue);
    });

    test('does not leave the snoozed flag set for a non-snoozed alarm',
        () async {
      const uuid = 'remote-pending-uuid';
      final intId = IdMapper.uuidToInt(uuid);
      final target = DateTime.now().toUtc().add(const Duration(minutes: 30));

      // Seed a stale local snooze: the reconcile must not preserve it.
      await IdMapper.setSnoozed(intId, true);

      final server = await _serveAlarms([
        {
          'id': uuid,
          'target_time': target.toIso8601String(),
          'label': 'Remote Pending',
          'status': 'pending',
          'sound_tone': 'alarm',
          'ramp_seconds': 30,
        },
      ]);
      addTearDown(() => server.close(force: true));

      final count = await AlarmService.syncWithBackend();

      expect(count, equals(1));
      expect(await IdMapper.isSnoozed(intId), isFalse);
    });
  });
}
