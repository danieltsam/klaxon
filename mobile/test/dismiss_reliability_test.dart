import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alarm/alarm.dart';
import 'package:alarm/service/alarm_storage.dart';
import 'package:alarm/src/generated/platform_bindings.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';
import 'package:mobile/services/alarm_state_outbox.dart';
import 'package:mobile/services/backend_client.dart';
import 'package:mobile/utils/id_mapper.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts how often the `alarm` plugin's platform channels are hit so a test
/// can prove whether a dismissal armed or stopped an alarm.
int setAlarmCalls = 0;
int stopAlarmCalls = 0;

/// Stands in for the `alarm` plugin's platform channels so `Alarm.set` and
/// `Alarm.stop` succeed inside the test isolate.
void _mockAlarmPlatformChannels() {
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

/// Serves a canned `GET /api/alarms?view=all` response and records every POST
/// the client makes, so a test can observe the state report the reconcile emits.
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AlarmStorage.resetForTesting();
    Alarm.resetForTesting();
    AlarmService.resetMissedReportStateForTest();
    await AlarmService.resetStateOutboxForTest();
    _mockAlarmPlatformChannels();
    setAlarmCalls = 0;
    stopAlarmCalls = 0;
    // TestWidgetsFlutterBinding stubs all HTTP to status 400; these tests run a
    // real loopback server to exercise the actual BackendClient wire format.
    HttpOverrides.global = null;
  });

  group('dismissAlarm reliable report', () {
    test('a failed dismissal report is persisted and retried on a later flush',
        () async {
      const uuid = 'remote-dismiss-uuid';
      final intId = IdMapper.uuidToInt(uuid);
      await IdMapper.saveMapping(intId, uuid, label: 'Dismiss me');

      final sent = <String>[];
      AlarmService.stateSenderForTest = (u, s, t) async {
        sent.add('$u/$s');
        return false; // backend unreachable / request failed
      };

      await AlarmService.dismissAlarm(_settingsFor(intId));
      // Let the immediate (fire-and-forget) report settle.
      await AlarmService.pendingStateFlush;

      expect(
        await AlarmStateOutbox.hasPendingStatus(uuid, 'dismissed'),
        isTrue,
        reason: 'a failed dismissal report must not be silently lost',
      );
      expect(sent, isNotEmpty);

      // Backend recovers: the queued dismissal is delivered on the next flush.
      AlarmService.stateSenderForTest = (u, s, t) async {
        sent.add('$u/$s');
        return true;
      };
      await AlarmService.flushPendingStateReports();

      expect(await AlarmStateOutbox.all(), isEmpty);
      expect(sent, contains('$uuid/dismissed'));

      // Existing behaviour is preserved: the ring is stopped and the snoozed
      // flag is cleared.
      expect(stopAlarmCalls, greaterThanOrEqualTo(1));
      expect(await IdMapper.isSnoozed(intId), isFalse);
    });

    test('a recurring dismissal reports pending with the next occurrence', () async {
      const uuid = 'remote-recurring-uuid';
      final intId = IdMapper.uuidToInt(uuid);
      final firstRing = DateTime(2026, 10, 28, 7, 0);
      await IdMapper.saveMapping(intId, uuid, label: 'Daily', targetTime: firstRing);
      await IdMapper.setRepeatDays(intId, [1, 2, 3, 4, 5, 6, 7]);

      final reports = <({String status, String? target})>[];
      AlarmService.stateSenderForTest = (u, s, t) async {
        reports.add((status: s, target: t));
        return true;
      };

      await AlarmService.dismissAlarm(
        _settingsFor(intId).copyWith(dateTime: firstRing),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(reports, hasLength(1));
      expect(reports.single.status, 'pending',
          reason: 'a recurring dismissal must not end the row');
      expect(reports.single.target, isNotNull);
      expect(setAlarmCalls, greaterThan(0),
          reason: 'the next occurrence must be armed locally');
    });

    test('bounded retry abandons an undeliverable state after maxAttempts',
        () async {
      const uuid = 'remote-doomed-uuid';
      await AlarmStateOutbox.put(PendingAlarmState(
        uuid: uuid,
        status: 'dismissed',
        queuedAt: DateTime.now(),
      ));
      AlarmService.stateSenderForTest = (_, _, _) async => false;

      for (var i = 0; i < AlarmStateOutbox.maxAttempts; i++) {
        await AlarmService.flushPendingStateReports();
      }

      expect(
        await AlarmStateOutbox.all(),
        isEmpty,
        reason: 'a permanently undeliverable report must not grow without bound',
      );
    });
  });

  group('outbox identity', () {
    test('a newer queued state survives a stale flush', () async {
      const uuid = 'outbox-race-uuid';
      final older = PendingAlarmState(
        uuid: uuid,
        status: 'dismissed',
        queuedAt: DateTime(2026, 1, 1),
      );
      await AlarmStateOutbox.put(older);
      await AlarmStateOutbox.put(PendingAlarmState(
        uuid: uuid,
        status: 'disabled',
        queuedAt: DateTime(2026, 1, 2),
      ));

      await AlarmStateOutbox.removeIfCurrent(older);

      final remaining = await AlarmStateOutbox.all();
      expect(remaining, hasLength(1));
      expect(remaining.single.status, 'disabled',
          reason: 'the stale success must not delete the newer report');
    });
  });

  group('syncWithBackend dismissal self-heal', () {
    test('pushes a corrected dismissal when the server still shows ringing',
        () async {
      const uuid = 'remote-ghost-uuid';
      final intId = IdMapper.uuidToInt(uuid);
      await IdMapper.saveMapping(intId, uuid, label: 'Ghost');
      // The device dismissed this alarm ~17h ago; the report never landed.
      await AlarmStateOutbox.put(PendingAlarmState(
        uuid: uuid,
        status: 'dismissed',
        queuedAt: DateTime.now().subtract(const Duration(hours: 17)),
      ));

      final target =
          DateTime.now().toUtc().subtract(const Duration(hours: 17));
      final server = _RecordingServer([
        {
          'id': uuid,
          'target_time': target.toIso8601String(),
          'label': 'Ghost',
          'status': 'ringing',
          'sound_tone': 'alarm',
          'ramp_seconds': 30,
        },
      ]);
      await server.start();
      addTearDown(server.stop);

      final count = await AlarmService.syncWithBackend();

      expect(count, equals(1));
      final post = await server.firstPost.future.timeout(const Duration(seconds: 5));
      expect(post.path, equals('/api/alarms/$uuid/state'));
      expect(post.body['status'], equals('dismissed'));

      expect(
        setAlarmCalls,
        equals(0),
        reason: 'a locally-dismissed alarm must not be re-armed by the reconcile',
      );
      expect(
        await AlarmStateOutbox.hasPendingStatus(uuid, 'dismissed'),
        isFalse,
        reason: 'the corrected dismissal was accepted, so the entry is cleared',
      );
    });

    test('pushes a corrected dismissal for a pending alarm past its target',
        () async {
      const uuid = 'remote-false-missed-uuid';
      final intId = IdMapper.uuidToInt(uuid);
      await IdMapper.saveMapping(intId, uuid, label: 'False missed');
      await AlarmStateOutbox.put(PendingAlarmState(
        uuid: uuid,
        status: 'dismissed',
        queuedAt: DateTime.now().subtract(const Duration(minutes: 6)),
      ));

      // Five minutes past its target: without the self-heal the reconcile would
      // arm this (inside the grace window) and the server would sweep it missed.
      final target = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      final server = _RecordingServer([
        {
          'id': uuid,
          'target_time': target.toIso8601String(),
          'label': 'False missed',
          'status': 'pending',
          'sound_tone': 'alarm',
          'ramp_seconds': 30,
        },
      ]);
      await server.start();
      addTearDown(server.stop);

      await AlarmService.syncWithBackend();

      final post = await server.firstPost.future.timeout(const Duration(seconds: 5));
      expect(post.path, equals('/api/alarms/$uuid/state'));
      expect(post.body['status'], equals('dismissed'));
      expect(
        setAlarmCalls,
        equals(0),
        reason: 'a locally-dismissed alarm must not be re-armed',
      );
    });

    test('drops the queued dismissal once the server already agrees', () async {
      const uuid = 'remote-already-dismissed-uuid';
      final intId = IdMapper.uuidToInt(uuid);
      await IdMapper.saveMapping(intId, uuid, label: 'Already dismissed');
      await AlarmStateOutbox.put(PendingAlarmState(
        uuid: uuid,
        status: 'dismissed',
        queuedAt: DateTime.now(),
      ));

      final target = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      final server = _RecordingServer([
        {
          'id': uuid,
          'target_time': target.toIso8601String(),
          'label': 'Already dismissed',
          'status': 'dismissed',
          'sound_tone': 'alarm',
          'ramp_seconds': 30,
        },
      ]);
      await server.start();
      addTearDown(server.stop);

      await AlarmService.syncWithBackend();

      expect(
        await AlarmStateOutbox.all(),
        isEmpty,
        reason: 'a dismissal the server already holds must not be re-sent',
      );
      expect(
        server.posts.where((p) => p.path == '/api/alarms/$uuid/state'),
        isEmpty,
      );
    });
  });
}
