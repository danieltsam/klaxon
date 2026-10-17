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

/// Counts how often the `alarm` plugin's platform channels are hit so a test
/// can prove whether the reconcile armed or stopped an alarm.
int setAlarmCalls = 0;
int stopAlarmCalls = 0;

/// Stands in for the `alarm` plugin's platform channels. [isRingingResult]
/// lets a test drive `Alarm.isRinging`; when null the isRinging channel is left
/// unmocked (it is only needed by the ring-report tests).
void _mockAlarmPlatformChannels({bool? isRingingResult}) {
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;

  final setChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.alarm.AlarmApi.setAlarm',
    AlarmApi.pigeonChannelCodec,
  );
  messenger.setMockDecodedMessageHandler<Object?>(setChannel, (message) async {
    setAlarmCalls++;
    return <Object?>[null];
  });

  final stopChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.alarm.AlarmApi.stopAlarm',
    AlarmApi.pigeonChannelCodec,
  );
  messenger.setMockDecodedMessageHandler<Object?>(stopChannel, (message) async {
    stopAlarmCalls++;
    return <Object?>[null];
  });

  if (isRingingResult != null) {
    final ringingChannel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.alarm.AlarmApi.isRinging',
      AlarmApi.pigeonChannelCodec,
    );
    messenger.setMockDecodedMessageHandler<Object?>(ringingChannel,
        (message) async => <Object?>[isRingingResult]);
  }
}

/// Serves a canned `GET /api/alarms?view=all` response and records every POST
/// the client makes against this server.
class _RecordingServer {
  final List<Map<String, dynamic>> alarms;
  final List<({String path, Map<String, dynamic> body})> posts = [];
  final Completer<({String path, Map<String, dynamic> body})> firstPost =
      Completer<({String path, Map<String, dynamic> body})>();
  late final HttpServer _server;

  _RecordingServer(this.alarms);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      if (request.method == 'POST') {
        final record = (
          path: request.uri.path,
          body: raw.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(raw) as Map<String, dynamic>,
        );
        posts.add(record);
        if (!firstPost.isCompleted) firstPost.complete(record);
      }
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(alarms));
      await request.response.close();
    });
    await BackendClient.setBaseUrl('http://127.0.0.1:${_server.port}');
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AlarmStorage.resetForTesting();
    Alarm.resetForTesting();
    AlarmService.resetMissedReportStateForTest();
    setAlarmCalls = 0;
    stopAlarmCalls = 0;
    // TestWidgetsFlutterBinding stubs all HTTP to status 400; these tests run a
    // real loopback server to exercise the actual BackendClient wire format.
    HttpOverrides.global = null;
  });

  group('syncWithBackend ringing reconcile', () {
    test('does not re-arm a remote ringing alarm', () async {
      _mockAlarmPlatformChannels();
      const uuid = 'remote-ringing-uuid';
      final target = DateTime.now().toUtc().subtract(const Duration(minutes: 1));

      final server = _RecordingServer([
        {
          'id': uuid,
          'target_time': target.toIso8601String(),
          'label': 'Remote Ringing',
          'status': 'ringing',
          'sound_tone': 'alarm',
          'ramp_seconds': 30,
        },
      ]);
      await server.start();
      addTearDown(server.stop);

      final count = await AlarmService.syncWithBackend();

      expect(count, equals(1));
      expect(
        setAlarmCalls,
        equals(0),
        reason: 'a remotely-ringing alarm must never be re-armed',
      );
      expect(
        stopAlarmCalls,
        equals(0),
        reason: 'the reconcile must not force-stop a ringing alarm',
      );
    });

    test('control: arms a pending alarm whose past target is inside grace',
        () async {
      _mockAlarmPlatformChannels();
      const uuid = 'remote-pending-past-uuid';
      final target = DateTime.now().toUtc().subtract(const Duration(minutes: 1));

      final server = _RecordingServer([
        {
          'id': uuid,
          'target_time': target.toIso8601String(),
          'label': 'Remote Pending',
          'status': 'pending',
          'sound_tone': 'alarm',
          'ramp_seconds': 30,
        },
      ]);
      await server.start();
      addTearDown(server.stop);

      final count = await AlarmService.syncWithBackend();

      expect(count, equals(1));
      expect(
        setAlarmCalls,
        equals(1),
        reason: 'a pending alarm inside the grace window is armed, proving the '
            'test can observe an arm',
      );
      expect(stopAlarmCalls, equals(0));
    });
  });

  group('reportRingingIfStillRinging', () {
    test('does not report ringing when the alarm is not ringing', () async {
      _mockAlarmPlatformChannels(isRingingResult: false);
      const uuid = 'remote-stale-ring-uuid';
      final intId = IdMapper.uuidToInt(uuid);
      await IdMapper.saveMapping(intId, uuid, label: 'Stale');

      final server = _RecordingServer(const []);
      await server.start();
      addTearDown(server.stop);

      await AlarmService.reportRingingIfStillRinging(intId);

      // Give any (incorrect) fire-and-forget request time to land.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        server.posts,
        isEmpty,
        reason: 'a stale post-stop re-check must not overwrite dismissed',
      );
    });

    test('reports ringing when the alarm genuinely is ringing', () async {
      _mockAlarmPlatformChannels(isRingingResult: true);
      const uuid = 'remote-live-ring-uuid';
      final intId = IdMapper.uuidToInt(uuid);
      await IdMapper.saveMapping(intId, uuid, label: 'Live');

      final server = _RecordingServer(const []);
      await server.start();
      addTearDown(server.stop);

      await AlarmService.reportRingingIfStillRinging(intId);

      final post = await server.firstPost.future
          .timeout(const Duration(seconds: 5));
      expect(post.path, equals('/api/alarms/$uuid/state'));
      expect(post.body['status'], equals('ringing'));
    });
  });
}
