import 'package:alarm/alarm.dart';
import 'package:alarm/service/alarm_storage.dart';
import 'package:alarm/src/generated/platform_bindings.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';
import 'package:mobile/utils/id_mapper.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the `alarm` plugin's platform channels so `Alarm.set` and
/// `Alarm.stop` succeed inside the test isolate (see `snooze_sync_test.dart`).
void _mockAlarmPlatformChannels() {
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
  Future<Object?> succeed(Object? message) async => <Object?>[null];
  for (final method in const [
    'setAlarm',
    'stopAlarm',
    'isRinging',
  ]) {
    final channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.alarm.AlarmApi.$method',
      AlarmApi.pigeonChannelCodec,
    );
    messenger.setMockDecodedMessageHandler<Object?>(channel, succeed);
  }
}

AlarmSettings _settings(int intId, DateTime target, String title) =>
    AlarmSettings(
      id: intId,
      dateTime: target,
      assetAudioPath: 'assets/alarm.mp3',
      loopAudio: true,
      vibrate: true,
      volumeSettings: const VolumeSettings.fixed(volume: 1.0),
      notificationSettings: NotificationSettings(
        title: title,
        body: 'Tap to open alarm',
        stopButton: 'stop',
      ),
    );

/// Every local int id whose stored mapping points at [uuid].
Future<List<int>> _ownersOf(String uuid) async {
  final owners = <int>[];
  for (final id in await IdMapper.getAllKnownIds()) {
    if (await IdMapper.getUuid(id) == uuid) owners.add(id);
  }
  return owners;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AlarmStorage.resetForTesting();
    Alarm.resetForTesting();
    AlarmService.resetMissedReportStateForTest();
    _mockAlarmPlatformChannels();
  });

  group('Arm Alarm duplicate (regression)', () {
    test(
        'a local arm remapped to the backend uuid and echoed as FCM CREATE '
        'stays a single alarm', () async {
      final target = DateTime.now().add(const Duration(minutes: 30));
      const localUuid = 'local_1700000000000';
      final localIntId = IdMapper.uuidToInt(localUuid);

      // 1. Optimistic local arm, exactly as the Arm Alarm handler does before
      //    the network answers: schedule under the provisional local id and
      //    record the mapping.
      await Alarm.set(alarmSettings: _settings(localIntId, target, 'Gym'));
      await IdMapper.saveMapping(localIntId, localUuid,
          label: 'Gym', targetTime: target);
      await IdMapper.setEnabled(localIntId, true);

      // 2. The create response arrives: the backend assigned the real uuid and
      //    the handler re-points the mapping at it.
      const remoteUuid = 'backend-assigned-uuid-1';
      await IdMapper.saveMapping(localIntId, remoteUuid,
          label: 'Gym', targetTime: target);

      // 3. The backend's FCM CREATE echo for the same alarm arrives.
      await AlarmService.handleAlarmPayload({
        'action': 'CREATE',
        'id': remoteUuid,
        'target_time': target.toUtc().toIso8601String(),
        'label': 'Gym',
        'sound_tone': 'alarm',
        'ramp_seconds': '30',
      });

      // The uuid must be owned by exactly one local id, and the OS alarm list
      // must hold exactly one alarm — not the optimistic one plus a canonical
      // echo that a later reconcile prunes (the "ghost" the owner saw).
      expect(
        await _ownersOf(remoteUuid),
        hasLength(1),
        reason: 'one backend uuid must map to one local id',
      );
      final alarms = await Alarm.getAlarms();
      expect(
        alarms,
        hasLength(1),
        reason: 'the FCM echo must not insert a second local alarm',
      );
      expect(alarms.single.id, equals(IdMapper.uuidToInt(remoteUuid)));
    });

    test('adoptRemoteId re-keys the armed alarm onto the canonical id',
        () async {
      final target = DateTime.now().add(const Duration(minutes: 30));
      const localUuid = 'local_1700000000001';
      final localIntId = IdMapper.uuidToInt(localUuid);
      const remoteUuid = 'backend-assigned-uuid-2';
      final canonicalId = IdMapper.uuidToInt(remoteUuid);

      await Alarm.set(alarmSettings: _settings(localIntId, target, 'Gym'));
      await IdMapper.saveMapping(localIntId, localUuid,
          label: 'Gym', targetTime: target);
      await IdMapper.setEnabled(localIntId, true);

      await AlarmService.adoptRemoteId(
        localIntId: localIntId,
        remoteUuid: remoteUuid,
        label: 'Gym',
        targetTime: target,
      );

      // The provisional identity is gone and the canonical one holds the alarm.
      expect(await _ownersOf(localUuid), isEmpty);
      expect(await _ownersOf(remoteUuid), equals([canonicalId]));

      final alarms = await Alarm.getAlarms();
      expect(alarms, hasLength(1));
      expect(alarms.single.id, equals(canonicalId));
      expect(alarms.single.dateTime, equals(target));

      // A following FCM echo is then idempotent.
      await AlarmService.handleAlarmPayload({
        'action': 'CREATE',
        'id': remoteUuid,
        'target_time': target.toUtc().toIso8601String(),
        'label': 'Gym',
        'sound_tone': 'alarm',
        'ramp_seconds': '30',
      });
      expect(await Alarm.getAlarms(), hasLength(1));
      expect(await _ownersOf(remoteUuid), equals([canonicalId]));
    });

    test('adoptRemoteId is a no-op when the FCM echo already claimed the '
        'canonical id', () async {
      final target = DateTime.now().add(const Duration(minutes: 30));
      const localUuid = 'local_1700000000002';
      final localIntId = IdMapper.uuidToInt(localUuid);
      const remoteUuid = 'backend-assigned-uuid-3';
      final canonicalId = IdMapper.uuidToInt(remoteUuid);

      // Optimistic arm still under the provisional id...
      await Alarm.set(alarmSettings: _settings(localIntId, target, 'Gym'));
      await IdMapper.saveMapping(localIntId, localUuid,
          label: 'Gym', targetTime: target);

      // ...then the push beats the create response.
      await AlarmService.handleAlarmPayload({
        'action': 'CREATE',
        'id': remoteUuid,
        'target_time': target.toUtc().toIso8601String(),
        'label': 'Gym',
        'sound_tone': 'alarm',
        'ramp_seconds': '30',
      });
      expect(await _ownersOf(remoteUuid), equals([canonicalId]));

      await AlarmService.adoptRemoteId(
        localIntId: localIntId,
        remoteUuid: remoteUuid,
        label: 'Gym',
        targetTime: target,
      );

      expect(await _ownersOf(remoteUuid), equals([canonicalId]));
      expect(await _ownersOf(localUuid), isEmpty);
      expect(await Alarm.getAlarms(), hasLength(1));
    });

    test('adoptRemoteId leaves a disabled alarm disabled', () async {
      final target = DateTime.now().add(const Duration(minutes: 30));
      const localUuid = 'local_1700000000003';
      final localIntId = IdMapper.uuidToInt(localUuid);
      const remoteUuid = 'backend-assigned-uuid-4';
      final canonicalId = IdMapper.uuidToInt(remoteUuid);

      // A disabled copy: mapping exists, nothing is scheduled.
      await IdMapper.saveMapping(localIntId, localUuid,
          label: 'Gym', targetTime: target);
      await IdMapper.setEnabled(localIntId, false);

      await AlarmService.adoptRemoteId(
        localIntId: localIntId,
        remoteUuid: remoteUuid,
        label: 'Gym',
        targetTime: target,
      );

      expect(await _ownersOf(remoteUuid), equals([canonicalId]));
      expect(await IdMapper.isEnabled(canonicalId), isFalse);
      expect(await Alarm.getAlarms(), isEmpty);
    });
  });
}
