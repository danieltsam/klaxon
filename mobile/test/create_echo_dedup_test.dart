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
  for (final method in const ['setAlarm', 'stopAlarm', 'isRinging']) {
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

/// The rows the main list would build: IdMapper's mappings are what paint a row
/// even when the OS alarm behind it has been replaced or stopped.
Future<int> _rowCount() async => (await IdMapper.getAllKnownIds()).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AlarmStorage.resetForTesting();
    Alarm.resetForTesting();
    AlarmService.resetMissedReportStateForTest();
    _mockAlarmPlatformChannels();
  });

  group('CREATE echo vs optimistic create (duplicate row regression)', () {
    test('the echo for the just-created alarm adopts its provisional row '
        'instead of leaving two rows for it', () async {
      final target = DateTime.now().add(const Duration(minutes: 30));
      const localUuid = 'local_1793450114801';
      final localIntId = IdMapper.uuidToInt(localUuid);
      const remoteUuid = 'ee312cd3-6aba-4323-b10a-ce3213d48a44';
      final canonicalId = IdMapper.uuidToInt(remoteUuid);

      // 1. The Arm flow: schedule and map under a throwaway local uuid, so the
      //    row is on screen before the network answers.
      await Alarm.set(alarmSettings: _settings(localIntId, target, 'Gym'));
      await IdMapper.saveMapping(
        localIntId,
        localUuid,
        label: 'Gym',
        targetTime: target,
      );
      await IdMapper.setEnabled(localIntId, true);
      expect(await _rowCount(), equals(1));

      // 2. The backend's CREATE echo arrives first (it is dispatched before the
      //    POST response returns). It carries the canonical uuid the phone has
      //    never seen.
      await AlarmService.handleAlarmPayload({
        'action': 'CREATE',
        'id': remoteUuid,
        'target_time': target.toUtc().toIso8601String(),
        'label': 'Gym',
        'sound_tone': 'alarm',
        'ramp_seconds': '30',
      });

      // The provisional identity is gone, so the list cannot paint a second
      // row beside the canonical one.
      expect(
        await _ownersOf(localUuid),
        isEmpty,
        reason: 'the provisional row must be re-keyed, not left behind',
      );
      expect(await _ownersOf(remoteUuid), equals([canonicalId]));
      expect(
        await _rowCount(),
        equals(1),
        reason: 'one created alarm must be one row at every moment',
      );

      final alarms = await Alarm.getAlarms();
      expect(alarms, hasLength(1));
      expect(alarms.single.id, equals(canonicalId));
      expect(alarms.single.notificationSettings.title, equals('Gym'));
      expect(alarms.single.dateTime, equals(target));
      expect(await IdMapper.isEnabled(canonicalId), isTrue);
    });

    test(
      'the echo does not adopt a provisional row for a different instant',
      () async {
        final localTarget = DateTime.now().add(const Duration(minutes: 30));
        final echoTarget = localTarget.add(const Duration(hours: 1));
        const localUuid = 'local_1793450114802';
        final localIntId = IdMapper.uuidToInt(localUuid);
        const remoteUuid = 'backend-uuid-different-instant';

        await Alarm.set(
          alarmSettings: _settings(localIntId, localTarget, 'Gym'),
        );
        await IdMapper.saveMapping(
          localIntId,
          localUuid,
          label: 'Gym',
          targetTime: localTarget,
        );
        await IdMapper.setEnabled(localIntId, true);

        await AlarmService.handleAlarmPayload({
          'action': 'CREATE',
          'id': remoteUuid,
          'target_time': echoTarget.toUtc().toIso8601String(),
          'label': 'Gym',
          'sound_tone': 'alarm',
          'ramp_seconds': '30',
        });

        // A genuinely different alarm at a different time keeps its own row.
        expect(await _ownersOf(localUuid), equals([localIntId]));
        expect(
          await _ownersOf(remoteUuid),
          equals([IdMapper.uuidToInt(remoteUuid)]),
        );
        expect(await _rowCount(), equals(2));
      },
    );

    test('the echo does not adopt a provisional row for the same instant under '
        'another label', () async {
      final target = DateTime.now().add(const Duration(minutes: 30));
      const localUuid = 'local_1793450114803';
      final localIntId = IdMapper.uuidToInt(localUuid);
      const remoteUuid = 'backend-uuid-other-label';

      await Alarm.set(alarmSettings: _settings(localIntId, target, 'Gym'));
      await IdMapper.saveMapping(
        localIntId,
        localUuid,
        label: 'Gym',
        targetTime: target,
      );
      await IdMapper.setEnabled(localIntId, true);

      await AlarmService.handleAlarmPayload({
        'action': 'CREATE',
        'id': remoteUuid,
        'target_time': target.toUtc().toIso8601String(),
        'label': 'Swim',
        'sound_tone': 'alarm',
        'ramp_seconds': '30',
      });

      expect(await _ownersOf(localUuid), equals([localIntId]));
      expect(
        await _ownersOf(remoteUuid),
        equals([IdMapper.uuidToInt(remoteUuid)]),
      );
      expect(await _rowCount(), equals(2));
    });
  });
}
