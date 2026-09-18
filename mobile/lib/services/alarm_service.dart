import 'package:alarm/alarm.dart';
import '../utils/id_mapper.dart';
import 'backend_client.dart';

class AlarmService {
  /// Entry point for FCM payload processing
  static Future<void> handleAlarmPayload(Map<String, dynamic> data) async {
    final action = data['action'];
    final uuid = data['id'];

    if (action == null || uuid == null) {
      // ignore: avoid_print
      print('[AlarmService] Missing action or id in FCM payload: $data');
      return;
    }

    final intId = IdMapper.uuidToInt(uuid.toString());

    if (action == 'CREATE') {
      final targetTimeStr = data['target_time'];
      final label = data['label'] ?? 'Remote Alarm';

      if (targetTimeStr == null) {
        // ignore: avoid_print
        print('[AlarmService] Missing target_time in CREATE payload');
        return;
      }

      final rawDateTime = DateTime.parse(targetTimeStr).toLocal();
      final parsedDateTime = DateTime(
        rawDateTime.year,
        rawDateTime.month,
        rawDateTime.day,
        rawDateTime.hour,
        rawDateTime.minute,
        0,
        0,
      );

      // Ensure mapping is preserved
      await IdMapper.saveMapping(intId, uuid.toString(), label: label.toString());
      await IdMapper.setSnoozed(intId, false);

      final repeatDaysStr = data['repeat_days'];
      if (repeatDaysStr != null && repeatDaysStr.toString().isNotEmpty) {
        final days = repeatDaysStr.toString().split(',').map((s) => int.tryParse(s) ?? 0).where((d) => d >= 1 && d <= 7).toList();
        await IdMapper.setRepeatDays(intId, days);
      }

      final alarmSettings = AlarmSettings(
        id: intId,
        dateTime: parsedDateTime,
        assetAudioPath: 'assets/alarm.mp3',
        loopAudio: true,
        vibrate: true,
        volumeSettings: VolumeSettings.fade(
          volume: 1.0,
          fadeDuration: const Duration(seconds: 3),
        ),
        notificationSettings: NotificationSettings(
          title: label.toString(),
          body: 'Tap to dismiss or snooze',
          stopButton: 'Stop',
        ),
      );

      await Alarm.set(alarmSettings: alarmSettings);
      // ignore: avoid_print
      print('[AlarmService] Successfully scheduled alarm $intId ($uuid) for $parsedDateTime');
    } else if (action == 'CANCEL') {
      await Alarm.stop(intId);
      await IdMapper.removeMapping(intId);
      // ignore: avoid_print
      print('[AlarmService] Canceled alarm $intId ($uuid)');
    }
  }

  /// Schedule an alarm created locally from the phone UI
  static Future<AlarmSettings> scheduleLocalAlarm({
    required DateTime dateTime,
    required String label,
    String? customUuid,
    List<int>? repeatDays,
  }) async {
    final uuid = customUuid ?? 'local_${DateTime.now().millisecondsSinceEpoch}';
    final intId = IdMapper.uuidToInt(uuid);

    await IdMapper.saveMapping(intId, uuid, label: label);
    await IdMapper.setSnoozed(intId, false);

    if (repeatDays != null && repeatDays.isNotEmpty) {
      await IdMapper.setRepeatDays(intId, repeatDays);
    }

    // Truncate seconds and milliseconds to ensure exact alarm triggers at :00
    final alignedDateTime = DateTime(
      dateTime.year,
      dateTime.month,
      dateTime.day,
      dateTime.hour,
      dateTime.minute,
      0,
      0,
    );

    final alarmSettings = AlarmSettings(
      id: intId,
      dateTime: alignedDateTime,
      assetAudioPath: 'assets/alarm.mp3',
      loopAudio: true,
      vibrate: true,
      volumeSettings: VolumeSettings.fade(
        volume: 1.0,
        fadeDuration: const Duration(seconds: 3),
      ),
      notificationSettings: NotificationSettings(
        title: label,
        body: 'Tap to dismiss or snooze',
        stopButton: 'Stop',
      ),
    );

    await Alarm.set(alarmSettings: alarmSettings);
    return alarmSettings;
  }

  /// Dismiss active alarm and notify backend
  static Future<void> dismissAlarm(AlarmSettings settings) async {
    await Alarm.stop(settings.id);
    await IdMapper.setSnoozed(settings.id, false);
    final uuid = await IdMapper.getUuid(settings.id);

    if (uuid != null && !uuid.startsWith('local_')) {
      // Async notify backend
      BackendClient.updateAlarmState(uuid, 'dismissed');
    }

    // Check if this was a recurring alarm; if so, schedule next occurrence
    final repeatDays = await IdMapper.getRepeatDays(settings.id);
    if (repeatDays.isNotEmpty) {
      final nextTime = _getNextOccurrence(settings.dateTime, repeatDays);
      final nextSettings = settings.copyWith(dateTime: nextTime);
      await Alarm.set(alarmSettings: nextSettings);
    }
  }

  /// Snooze active alarm for 9 minutes and notify backend
  static Future<AlarmSettings> snoozeAlarm(AlarmSettings settings) async {
    await Alarm.stop(settings.id);

    final now = DateTime.now();
    final snoozeTime = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
      0,
      0,
    ).add(const Duration(minutes: 9));
    final uuid = await IdMapper.getUuid(settings.id);

    // Persist snoozed state
    await IdMapper.setSnoozed(settings.id, true);

    final newSettings = settings.copyWith(
      dateTime: snoozeTime,
    );

    await Alarm.set(alarmSettings: newSettings);

    if (uuid != null && !uuid.startsWith('local_')) {
      // Async notify backend
      BackendClient.updateAlarmState(uuid, 'snoozed');
    }

    return newSettings;
  }

  static DateTime _getNextOccurrence(DateTime targetTime, List<int> repeatDays) {
    final now = DateTime.now();
    for (int dayOffset = 1; dayOffset <= 7; dayOffset++) {
      final candidate = DateTime(
        now.year,
        now.month,
        now.day + dayOffset,
        targetTime.hour,
        targetTime.minute,
        0,
        0,
      );
      if (repeatDays.contains(candidate.weekday)) {
        return candidate;
      }
    }
    return targetTime.add(const Duration(days: 1));
  }
}
