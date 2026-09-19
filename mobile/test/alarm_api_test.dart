import 'package:alarm/alarm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

void main() {
  test('Alarm API signature check', () {
    final now = DateTime.now().add(const Duration(hours: 1));
    final settings = AlarmSettings(
      id: 42,
      dateTime: now,
      assetAudioPath: 'assets/alarm.mp3',
      loopAudio: true,
      vibrate: true,
      volumeSettings: VolumeSettings.fade(
        volume: 1.0,
        fadeDuration: const Duration(seconds: 3),
      ),
      notificationSettings: const NotificationSettings(
        title: 'Test',
        body: 'Tap to dismiss',
        stopButton: 'Stop',
      ),
    );
    expect(settings.id, 42);
  });

  test('Perceptual volume settings generates whisper-soft start and smooth progression', () {
    final instant = AlarmService.buildPerceptualVolumeSettings(0);
    expect(instant.fadeSteps, isEmpty);
    expect(instant.fadeDuration, isNull);

    final ramp15 = AlarmService.buildPerceptualVolumeSettings(15);
    expect(ramp15.fadeSteps.isNotEmpty, isTrue);

    // Verify times are strictly increasing
    for (int i = 1; i < ramp15.fadeSteps.length; i++) {
      expect(ramp15.fadeSteps[i].time > ramp15.fadeSteps[i - 1].time, isTrue);
      expect(ramp15.fadeSteps[i].volume >= ramp15.fadeSteps[i - 1].volume, isTrue);
    }

    // Step 0 must start at 0.001
    expect(ramp15.fadeSteps.first.time, Duration.zero);
    expect(ramp15.fadeSteps.first.volume, 0.001);

    // Midpoint (~50% duration) must be whisper quiet (< 10% amplitude)
    final midStep = ramp15.fadeSteps[ramp15.fadeSteps.length ~/ 2];
    expect(midStep.volume < 0.10, isTrue);

    // Final step must reach 1.0
    expect(ramp15.fadeSteps.last.time, const Duration(seconds: 15));
    expect(ramp15.fadeSteps.last.volume, 1.0);
  });
}
