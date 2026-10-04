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
    // Exponent 6 keeps the 50% step far quieter still (well under 5%)
    expect(midStep.volume < 0.05, isTrue);

    // ~75% duration must remain in the gentle zone (< 30% amplitude)
    final threeQuarterStep =
        ramp15.fadeSteps[(ramp15.fadeSteps.length * 3) ~/ 4];
    expect(threeQuarterStep.volume < 0.30, isTrue);

    // Final step must reach 1.0
    expect(ramp15.fadeSteps.last.time, const Duration(seconds: 15));
    expect(ramp15.fadeSteps.last.volume, 1.0);
  });

  test('Perceived loudness progress maps gain to a logarithmic 0..1 fraction', () {
    const epsilon = 0.001;

    // Floor and ceiling
    expect(AlarmService.perceivedLoudnessProgress(0.001), closeTo(0.0, epsilon));
    expect(AlarmService.perceivedLoudnessProgress(1.0), closeTo(1.0, epsilon));

    // Out-of-bounds clamps
    expect(AlarmService.perceivedLoudnessProgress(0.0), 0.0);
    expect(AlarmService.perceivedLoudnessProgress(-0.5), 0.0);
    expect(AlarmService.perceivedLoudnessProgress(1.5), 1.0);

    // Monotonic non-decreasing across the ramp
    final values = <double>[];
    for (int i = 0; i <= 30; i++) {
      final gain = AlarmService.perceivedVolumeProgress(i / 30.0);
      values.add(AlarmService.perceivedLoudnessProgress(gain));
    }
    for (int i = 1; i < values.length; i++) {
      expect(values[i] >= values[i - 1], isTrue);
    }

    // 30s checkpoint expectations
    final at12 = AlarmService.perceivedLoudnessProgress(
      AlarmService.perceivedVolumeProgress(12 / 30.0),
    );
    final at20 = AlarmService.perceivedLoudnessProgress(
      AlarmService.perceivedVolumeProgress(20 / 30.0),
    );
    final at29 = AlarmService.perceivedLoudnessProgress(
      AlarmService.perceivedVolumeProgress(29 / 30.0),
    );
    expect(at12, closeTo(0.40, 0.02));
    expect(at20, closeTo(0.73, 0.02));
    expect(at29, closeTo(0.98, 0.02));
  });
}
