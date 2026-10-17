import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:alarm/service/alarm_storage.dart';
import 'package:alarm/src/generated/platform_bindings.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart' as app;
import 'package:mobile/utils/id_mapper.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the `alarm` plugin's platform channels so `Alarm.set` /
/// `Alarm.stop` succeed inside the test isolate (see `arm_dedup_test.dart`).
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
  // HapticFeedback goes over the platform channel; answer it so awaits to
  // `HapticService.playPreset` resolve under the test clock.
  messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
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

/// Seeds one known alarm: persisted under [intId] and mapped to [uuid].
///
/// Writes straight to [AlarmStorage] rather than `Alarm.set`, because the
/// latter drives platform timers that never fire under the test clock.
Future<void> _seedAlarm(String title, int intId, String uuid) async {
  final target = DateTime.now().add(const Duration(hours: 3));
  await AlarmStorage.saveAlarm(_settings(intId, target, title));
  await IdMapper.saveMapping(intId, uuid, label: title, targetTime: target);
  // Disabled: keeps the row in the list but out of the hero card, so each
  // title appears exactly once in the tree.
  await IdMapper.setEnabled(intId, false);
}

/// Regression: a mass delete must issue every removal at once instead of
/// awaiting them one-at-a-time (roughly one dead round-trip per alarm).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AlarmStorage.resetForTesting();
    Alarm.resetForTesting();
    _mockAlarmPlatformChannels();
    app.deleteRemoteAlarmForTest = null;
  });

  tearDown(() {
    app.deleteRemoteAlarmForTest = null;
  });

  testWidgets(
      'bulk delete issues every remote delete before the first one completes',
      (tester) async {
    await _seedAlarm('Gym', 101, 'uuid-gym');
    await _seedAlarm('Work', 102, 'uuid-work');

    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const app.AlarmApp());
    // Let initState's _loadAllAlarms() settle into the list.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Gym'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);

    // Enter multi-select on the first row, then select the second.
    await tester.longPress(find.text('Gym'));
    await tester.pump();
    await tester.tap(find.text('Work'));
    await tester.pump();
    expect(find.text('delete (2)'), findsOneWidget);

    // Gate every remote delete so we can observe how many start before any
    // finishes.
    final started = <String>[];
    final gates = <String, Completer<void>>{};
    app.deleteRemoteAlarmForTest = (uuid) {
      started.add(uuid);
      final gate = Completer<void>();
      gates[uuid] = gate;
      return gate.future;
    };

    await tester.tap(find.text('delete (2)'));
    // Clear the pre-batch haptic delay and let the batch reach its deletes.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(
      started,
      containsAll(<String>['uuid-gym', 'uuid-work']),
      reason: 'every selected alarm must be deleted in one batch, not '
          'serialised behind the previous one',
    );

    // Release the deletes and let the batch finish cleanly.
    for (final gate in gates.values) {
      gate.complete();
    }
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
  });
}
