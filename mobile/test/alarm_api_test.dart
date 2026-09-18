import 'package:alarm/alarm.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
