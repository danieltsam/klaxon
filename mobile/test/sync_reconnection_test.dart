import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile/utils/id_mapper.dart';
import 'package:mobile/services/backend_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Sync & Reconnection Resilience Tests', () {
    test('IdMapper stores and retrieves enabled/disabled toggle state correctly', () async {
      const intId = 101;
      expect(await IdMapper.isEnabled(intId), isTrue); // default is true

      await IdMapper.setEnabled(intId, false);
      expect(await IdMapper.isEnabled(intId), isFalse);

      await IdMapper.setEnabled(intId, true);
      expect(await IdMapper.isEnabled(intId), isTrue);
    });

    test('IdMapper saves rich text description and notes', () async {
      const intId = 102;
      expect(await IdMapper.getDescription(intId), isEmpty);

      const notes = 'Take vitamins, hydrate with 500ml water, and review sprint tasks.';
      await IdMapper.setDescription(intId, notes);
      expect(await IdMapper.getDescription(intId), equals(notes));
    });

    test('IdMapper stores targetTime, soundTone, rampSeconds, and repeatDays together', () async {
      const intId = 103;
      const uuid = 'remote-alarm-uuid-103';
      final target = DateTime(2026, 9, 20, 7, 30);

      await IdMapper.saveMapping(
        intId,
        uuid,
        label: 'Early Morning Run',
        description: 'Running shoes by the door',
        targetTime: target,
        soundTone: 'chime',
        rampSeconds: 15,
        repeatDays: [1, 2, 3, 4, 5],
      );

      expect(await IdMapper.getUuid(intId), equals(uuid));
      expect(await IdMapper.getLabel(intId), equals('Early Morning Run'));
      expect(await IdMapper.getDescription(intId), equals('Running shoes by the door'));
      expect(await IdMapper.getTargetTime(intId), equals(target));
      expect(await IdMapper.getSoundTone(intId), equals('chime'));
      expect(await IdMapper.getRampSeconds(intId), equals(15));
      expect(await IdMapper.getRepeatDays(intId), equals([1, 2, 3, 4, 5]));
      expect(await IdMapper.isEnabled(intId), isTrue);
    });

    test('getAllKnownIds retrieves all registered IDs and ignores other prefs', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('unrelated_setting', 'some_value');

      await IdMapper.saveMapping(201, 'uuid-201', label: 'Alarm 1');
      await IdMapper.saveMapping(202, 'uuid-202', label: 'Alarm 2');
      await IdMapper.saveMapping(203, 'uuid-203', label: 'Alarm 3');

      final allIds = await IdMapper.getAllKnownIds();
      expect(allIds, containsAll([201, 202, 203]));
      expect(allIds.length, equals(3));
    });

    test('removeMapping cleanly purges all metadata for an alarm', () async {
      const intId = 301;
      const uuid = 'uuid-to-delete';
      await IdMapper.saveMapping(
        intId,
        uuid,
        label: 'Temporary',
        description: 'Notes',
        targetTime: DateTime.now(),
        soundTone: 'digital',
        rampSeconds: 30,
        repeatDays: [6, 7],
      );
      await IdMapper.setEnabled(intId, false);
      await IdMapper.setSnoozed(intId, true);

      // Verify stored
      expect(await IdMapper.getUuid(intId), equals(uuid));
      expect(await IdMapper.isSnoozed(intId), isTrue);

      // Remove
      await IdMapper.removeMapping(intId);

      // Verify completely purged
      expect(await IdMapper.getUuid(intId), isNull);
      expect(await IdMapper.getLabel(intId), isNull);
      expect(await IdMapper.getDescription(intId), isEmpty);
      expect(await IdMapper.getTargetTime(intId), isNull);
      expect(await IdMapper.getRepeatDays(intId), isEmpty);
      expect(await IdMapper.isSnoozed(intId), isFalse);

      final allIds = await IdMapper.getAllKnownIds();
      expect(allIds, isNot(contains(intId)));
    });

    test('Reconnection Reconciliation: prunes obsolete alarms and restores server state', () async {
      // 1. Suppose mobile had 3 alarms stored locally before going offline:
      // - Alarm A (uuid-a)
      // - Alarm B (uuid-b)
      // - Alarm C (uuid-c)
      final idA = IdMapper.uuidToInt('uuid-a');
      final idB = IdMapper.uuidToInt('uuid-b');
      final idC = IdMapper.uuidToInt('uuid-c');

      await IdMapper.saveMapping(idA, 'uuid-a', label: 'Alarm A');
      await IdMapper.saveMapping(idB, 'uuid-b', label: 'Alarm B');
      await IdMapper.saveMapping(idC, 'uuid-c', label: 'Alarm C');

      expect((await IdMapper.getAllKnownIds()).length, equals(3));

      // 2. While offline, server deleted Alarm C, kept Alarm A, added Alarm D, and disabled Alarm B:
      final simulatedServerAlarms = [
        {
          'id': 'uuid-a',
          'target_time': '2026-09-20T07:00:00.000Z',
          'label': 'Alarm A (Updated)',
          'status': 'pending',
          'sound_tone': 'chime',
          'ramp_seconds': 15,
        },
        {
          'id': 'uuid-b',
          'target_time': '2026-09-20T08:00:00.000Z',
          'label': 'Alarm B',
          'status': 'disabled',
          'sound_tone': 'alarm',
          'ramp_seconds': 30,
        },
        {
          'id': 'uuid-d',
          'target_time': '2026-09-20T09:00:00.000Z',
          'label': 'Alarm D (New)',
          'status': 'pending',
          'sound_tone': 'digital',
          'ramp_seconds': 0,
        }
      ];

      // 3. Reconcile simulated server alarms
      final remoteUuids = <String>{};
      for (final remote in simulatedServerAlarms) {
        final uuid = remote['id'] as String;
        remoteUuids.add(uuid);
        final intId = IdMapper.uuidToInt(uuid);
        final status = remote['status'] as String;

        await IdMapper.saveMapping(
          intId,
          uuid,
          label: remote['label'] as String,
          targetTime: DateTime.parse(remote['target_time'] as String),
          soundTone: remote['sound_tone'] as String,
          rampSeconds: remote['ramp_seconds'] as int,
        );

        if (status == 'disabled') {
          await IdMapper.setEnabled(intId, false);
        } else {
          await IdMapper.setEnabled(intId, true);
        }
      }

      // Prune local IDs not in remoteUuids
      final allStoredIds = await IdMapper.getAllKnownIds();
      for (final id in allStoredIds) {
        final uuid = await IdMapper.getUuid(id);
        if (uuid == null || !remoteUuids.contains(uuid)) {
          await IdMapper.removeMapping(id);
        }
      }

      // 4. Verify post-reconciliation state:
      final finalIds = await IdMapper.getAllKnownIds();
      expect(finalIds.length, equals(3));

      // Alarm C must be completely gone
      expect(await IdMapper.getUuid(idC), isNull);

      // Alarm A must be updated and enabled
      expect(await IdMapper.getLabel(idA), equals('Alarm A (Updated)'));
      expect(await IdMapper.isEnabled(idA), isTrue);

      // Alarm B must be disabled
      expect(await IdMapper.isEnabled(idB), isFalse);

      // Alarm D must be newly created and enabled
      final idD = IdMapper.uuidToInt('uuid-d');
      expect(await IdMapper.getLabel(idD), equals('Alarm D (New)'));
      expect(await IdMapper.isEnabled(idD), isTrue);
    });

    test('Offline Safety: BackendClient handles connection refusal gracefully', () async {
      // Set unreachable host
      await BackendClient.setBaseUrl('http://127.0.0.1:9999');

      // fetchActiveAlarms should not throw, returns empty list
      final active = await BackendClient.fetchActiveAlarms();
      expect(active, isEmpty);

      // fetchAllAlarms should not throw, returns empty list
      final all = await BackendClient.fetchAllAlarms();
      expect(all, isEmpty);

      // updateAlarmState should not throw, returns false
      final success = await BackendClient.updateAlarmState('test-uuid', 'disabled');
      expect(success, isFalse);

      // createRemoteAlarm should not throw, returns null
      final newId = await BackendClient.createRemoteAlarm(
        targetTime: DateTime.now(),
        label: 'Offline Test',
      );
      expect(newId, isNull);

      // deleteRemoteAlarm should not throw, returns false
      final deleted = await BackendClient.deleteRemoteAlarm('test-uuid');
      expect(deleted, isFalse);
    });
  });
}
