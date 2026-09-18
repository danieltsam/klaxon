import 'dart:async';
import 'package:alarm/alarm.dart';
import '../utils/id_mapper.dart';
import 'backend_client.dart';

class AlarmService {
  /// Stream that emits whenever an alarm is remotely dismissed via FCM
  static final StreamController<int> onRemoteDismissed = StreamController<int>.broadcast();

  /// Resolve audio asset path for given tone name
  static String getAudioPathForTone(String? tone) {
    switch (tone?.trim().toLowerCase()) {
      case 'chime':
        return 'assets/chime.mp3';
      case 'digital':
        return 'assets/digital.mp3';
      case 'alarm':
      default:
        return 'assets/alarm.mp3';
    }
  }

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
      final tone = data['sound_tone']?.toString() ?? 'alarm';
      final rampSec = int.tryParse(data['ramp_seconds']?.toString() ?? '30') ?? 30;

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

      final audioPath = getAudioPathForTone(tone);
      final fadeDuration = Duration(seconds: rampSec > 0 ? rampSec : 0);

      final alarmSettings = AlarmSettings(
        id: intId,
        dateTime: parsedDateTime,
        assetAudioPath: audioPath,
        loopAudio: true,
        vibrate: true,
        volumeSettings: VolumeSettings.fade(
          volume: 1.0,
          fadeDuration: fadeDuration,
        ),
        notificationSettings: NotificationSettings(
          title: label.toString(),
          body: 'Tap to dismiss or snooze',
          stopButton: 'Stop',
        ),
      );

      await Alarm.set(alarmSettings: alarmSettings);
      // ignore: avoid_print
      print('[AlarmService] Successfully scheduled alarm $intId ($uuid) tone=$tone ramp=${rampSec}s for $parsedDateTime');
    } else if (action == 'CANCEL') {
      await Alarm.stop(intId);
      await IdMapper.removeMapping(intId);
      onRemoteDismissed.add(intId);
      // ignore: avoid_print
      print('[AlarmService] Canceled alarm $intId ($uuid)');
    } else if (action == 'DISMISS') {
      await Alarm.stop(intId);
      await IdMapper.setSnoozed(intId, false);
      onRemoteDismissed.add(intId);
      // ignore: avoid_print
      print('[AlarmService] Remotely dismissed alarm $intId ($uuid)');
    }
  }

  /// Bidirectional sync: reconciles local alarms with the backend server
  static Future<int> syncWithBackend() async {
    try {
      final remoteAlarms = await BackendClient.fetchActiveAlarms();
      if (remoteAlarms.isEmpty) {
        return 0;
      }

      final localAlarms = await Alarm.getAlarms();
      final remoteUuids = <String>{};

      for (final remote in remoteAlarms) {
        final uuid = remote['id']?.toString();
        final targetTimeStr = remote['target_time']?.toString();
        final label = remote['label']?.toString() ?? 'Remote Alarm';
        final repeatDaysStr = remote['repeat_days']?.toString();
        final tone = remote['sound_tone']?.toString() ?? 'alarm';
        final rampSec = int.tryParse(remote['ramp_seconds']?.toString() ?? '30') ?? 30;

        if (uuid == null || targetTimeStr == null) continue;
        remoteUuids.add(uuid);

        final intId = IdMapper.uuidToInt(uuid);
        final targetDate = DateTime.parse(targetTimeStr).toLocal();
        final now = DateTime.now();

        // If target is in the past and has no repeat days, skip
        final hasRepeat = repeatDaysStr != null && repeatDaysStr.isNotEmpty;
        if (targetDate.isBefore(now) && !hasRepeat) {
          continue;
        }

        // If not scheduled or time changed, schedule it
        final existingLocal = localAlarms.cast<AlarmSettings?>().firstWhere(
          (a) => a?.id == intId,
          orElse: () => null,
        );

        final isSameTime = existingLocal != null &&
            existingLocal.dateTime.year == targetDate.year &&
            existingLocal.dateTime.month == targetDate.month &&
            existingLocal.dateTime.day == targetDate.day &&
            existingLocal.dateTime.hour == targetDate.hour &&
            existingLocal.dateTime.minute == targetDate.minute;

        if (!isSameTime) {
          await handleAlarmPayload({
            'action': 'CREATE',
            'id': uuid,
            'target_time': targetTimeStr,
            'label': label,
            'repeat_days': repeatDaysStr,
            'sound_tone': tone,
            'ramp_seconds': rampSec.toString(),
          });
        }
      }

      // Prune local alarms whose backend counterpart was canceled/dismissed remotely
      for (final local in localAlarms) {
        final uuid = await IdMapper.getUuid(local.id);
        if (uuid != null && !uuid.startsWith('local_') && !remoteUuids.contains(uuid)) {
          await Alarm.stop(local.id);
          await IdMapper.removeMapping(local.id);
          // ignore: avoid_print
          print('[AlarmService] Pruned local alarm ${local.id} ($uuid) as it is no longer active on server');
        }
      }

      return remoteAlarms.length;
    } catch (e) {
      // ignore: avoid_print
      print('[AlarmService] syncWithBackend error: $e');
      return 0;
    }
  }

  /// Schedule an alarm created locally from the phone UI
  static Future<AlarmSettings> scheduleLocalAlarm({
    required DateTime dateTime,
    required String label,
    String? customUuid,
    List<int>? repeatDays,
    String? soundTone,
    int? rampSeconds,
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

    final audioPath = getAudioPathForTone(soundTone);
    final rampSec = rampSeconds ?? 30;

    final alarmSettings = AlarmSettings(
      id: intId,
      dateTime: alignedDateTime,
      assetAudioPath: audioPath,
      loopAudio: true,
      vibrate: true,
      volumeSettings: VolumeSettings.fade(
        volume: 1.0,
        fadeDuration: Duration(seconds: rampSec > 0 ? rampSec : 0),
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
