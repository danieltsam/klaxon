import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile/utils/id_mapper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('IdMapper Tests', () {
    test('uuidToInt generates consistent 32-bit positive integer', () {
      const uuid1 = 'de8b2aa3-4e6a-4b5e-9f79-9d80b379adc8';
      const uuid2 = 'aa97f686-47c5-4c1d-810d-7ebff3c6c99c';

      final int1 = IdMapper.uuidToInt(uuid1);
      final int2 = IdMapper.uuidToInt(uuid2);

      expect(int1, greaterThanOrEqualTo(0));
      expect(int1, lessThan(2147483647));
      expect(int2, greaterThanOrEqualTo(0));
      expect(int2, lessThan(2147483647));

      // Deterministic check
      expect(IdMapper.uuidToInt(uuid1), equals(int1));
    });

    test('saveMapping, getUuid, and getLabel store and retrieve correctly', () async {
      const uuid = 'test-uuid-12345';
      final intId = IdMapper.uuidToInt(uuid);

      await IdMapper.saveMapping(intId, uuid, label: 'Work Standup');

      final retrievedUuid = await IdMapper.getUuid(intId);
      final retrievedLabel = await IdMapper.getLabel(intId);

      expect(retrievedUuid, equals(uuid));
      expect(retrievedLabel, equals('Work Standup'));
    });

    test('setSnoozed and isSnoozed manage snoozed state correctly', () async {
      const intId = 12345;

      expect(await IdMapper.isSnoozed(intId), isFalse);

      await IdMapper.setSnoozed(intId, true);
      expect(await IdMapper.isSnoozed(intId), isTrue);

      await IdMapper.setSnoozed(intId, false);
      expect(await IdMapper.isSnoozed(intId), isFalse);
    });

    test('setRepeatDays and getRepeatDays preserve day lists', () async {
      const intId = 67890;

      expect(await IdMapper.getRepeatDays(intId), isEmpty);

      final days = [1, 3, 5]; // Mon, Wed, Fri
      await IdMapper.setRepeatDays(intId, days);

      final retrieved = await IdMapper.getRepeatDays(intId);
      expect(retrieved, equals([1, 3, 5]));

      await IdMapper.setRepeatDays(intId, []);
      expect(await IdMapper.getRepeatDays(intId), isEmpty);
    });

    test('setEnabled and isEnabled persist toggle state without deleting mapping', () async {
      const uuid = 'persist-toggle-uuid';
      final intId = IdMapper.uuidToInt(uuid);

      await IdMapper.saveMapping(intId, uuid, label: 'Evening Routine');
      expect(await IdMapper.isEnabled(intId), isTrue);

      // Disable alarm via slider toggle
      await IdMapper.setEnabled(intId, false);
      expect(await IdMapper.isEnabled(intId), isFalse);

      // Verify mapping, label, and known IDs are fully preserved
      expect(await IdMapper.getUuid(intId), equals(uuid));
      expect(await IdMapper.getLabel(intId), equals('Evening Routine'));
      final known = await IdMapper.getAllKnownIds();
      expect(known.contains(intId), isTrue);

      // Re-enable alarm
      await IdMapper.setEnabled(intId, true);
      expect(await IdMapper.isEnabled(intId), isTrue);
    });

    test('setIntervalWeeks and getIntervalWeeks persist and clear on 1', () async {
      const intId = 55555;

      expect(await IdMapper.getIntervalWeeks(intId), isNull);

      await IdMapper.setIntervalWeeks(intId, 2);
      expect(await IdMapper.getIntervalWeeks(intId), equals(2));

      // Values <= 1 mean weekly and clear the stored interval
      await IdMapper.setIntervalWeeks(intId, 1);
      expect(await IdMapper.getIntervalWeeks(intId), isNull);
    });

    test('setAnchorDate and getAnchorDate persist and clear on null', () async {
      const intId = 66666;

      expect(await IdMapper.getAnchorDate(intId), isNull);

      await IdMapper.setAnchorDate(intId, '2026-10-07');
      expect(await IdMapper.getAnchorDate(intId), equals('2026-10-07'));

      await IdMapper.setAnchorDate(intId, null);
      expect(await IdMapper.getAnchorDate(intId), isNull);
    });

    test('removeMapping clears interval and anchor metadata', () async {
      const uuid = 'fortnightly-cleanup-uuid';
      final intId = IdMapper.uuidToInt(uuid);

      await IdMapper.setIntervalWeeks(intId, 2);
      await IdMapper.setAnchorDate(intId, '2026-10-07');

      await IdMapper.removeMapping(intId);

      expect(await IdMapper.getIntervalWeeks(intId), isNull);
      expect(await IdMapper.getAnchorDate(intId), isNull);
    });

    test('removeMapping clears all associated metadata', () async {
      const uuid = 'temp-uuid-999';
      final intId = IdMapper.uuidToInt(uuid);

      await IdMapper.saveMapping(intId, uuid, label: 'Temporary');
      await IdMapper.setSnoozed(intId, true);
      await IdMapper.setRepeatDays(intId, [1, 2]);

      await IdMapper.removeMapping(intId);

      expect(await IdMapper.getUuid(intId), isNull);
      expect(await IdMapper.getLabel(intId), isNull);
      expect(await IdMapper.isSnoozed(intId), isFalse);
      expect(await IdMapper.getRepeatDays(intId), isEmpty);
    });
  });
}
