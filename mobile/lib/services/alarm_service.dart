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

      final repeatDaysStr = data['repeat_days'];
      List<int>? repeatDaysList;
      if (repeatDaysStr != null && repeatDaysStr.toString().isNotEmpty) {
        repeatDaysList = repeatDaysStr.toString().split(',').map((s) => int.tryParse(s) ?? 0).where((d) => d >= 1 && d <= 7).toList();
        await IdMapper.setRepeatDays(intId, repeatDaysList);
      }

      final futureTarget = computeFutureOccurrence(parsedDateTime, repeatDays: repeatDaysList);

      final desc = data['description']?.toString();
      // Ensure mapping is preserved
      await IdMapper.saveMapping(
        intId,
        uuid.toString(),
        label: label.toString(),
        description: desc,
        targetTime: futureTarget,
      );
      await IdMapper.setSnoozed(intId, false);
      await IdMapper.setSoundTone(intId, tone);
      await IdMapper.setRampSeconds(intId, rampSec);
      await IdMapper.setEnabled(intId, true);

      final audioPath = getAudioPathForTone(tone);
      final volumeSettings = rampSec > 0
          ? VolumeSettings.fade(
              volume: 1.0,
              fadeDuration: Duration(seconds: rampSec),
            )
          : VolumeSettings.fixed(volume: 1.0);

      final alarmSettings = AlarmSettings(
        id: intId,
        dateTime: futureTarget,
        assetAudioPath: audioPath,
        loopAudio: true,
        vibrate: true,
        volumeSettings: volumeSettings,
        notificationSettings: NotificationSettings(
          title: label.toString(),
          body: 'Tap to dismiss or snooze',
          stopButton: 'Stop',
        ),
      );

      await Alarm.set(alarmSettings: alarmSettings);
      onRemoteDismissed.add(intId);
      // ignore: avoid_print
      print('[AlarmService] Successfully scheduled alarm $intId ($uuid) tone=$tone ramp=${rampSec}s for $futureTarget');
    } else if (action == 'DISABLE') {
      await Alarm.stop(intId);
      await IdMapper.setEnabled(intId, false);
      onRemoteDismissed.add(intId);
      // ignore: avoid_print
      print('[AlarmService] Disabled alarm $intId ($uuid)');
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
      final remoteAlarms = await BackendClient.fetchAllAlarms();
      final localAlarms = await Alarm.getAlarms();
      final remoteUuids = <String>{};

      for (final remote in remoteAlarms) {
        final uuid = remote['id']?.toString();
        final targetTimeStr = remote['target_time']?.toString();
        final label = remote['label']?.toString() ?? 'Remote Alarm';
        final repeatDaysStr = remote['repeat_days']?.toString();
        final tone = remote['sound_tone']?.toString() ?? 'alarm';
        final rampSec = int.tryParse(remote['ramp_seconds']?.toString() ?? '30') ?? 30;
        final status = remote['status']?.toString() ?? 'pending';
        final desc = remote['description']?.toString();

        if (uuid == null || targetTimeStr == null) continue;
        remoteUuids.add(uuid);

        final intId = IdMapper.uuidToInt(uuid);
        final targetDate = DateTime.parse(targetTimeStr).toLocal();
        final repeatDays = repeatDaysStr != null && repeatDaysStr.isNotEmpty
            ? repeatDaysStr.split(',').map((s) => int.tryParse(s.trim()) ?? 0).where((d) => d >= 1 && d <= 7).toList()
            : <int>[];

        await IdMapper.saveMapping(
          intId,
          uuid,
          label: label,
          description: desc,
          targetTime: targetDate,
          soundTone: tone,
          rampSeconds: rampSec,
          repeatDays: repeatDays,
        );

        if (status == 'disabled' || status == 'canceled' || status == 'dismissed') {
          await Alarm.stop(intId);
          await IdMapper.setEnabled(intId, false);
        } else {
          await IdMapper.setEnabled(intId, true);

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
              'description': desc,
              'repeat_days': repeatDaysStr,
              'sound_tone': tone,
              'ramp_seconds': rampSec.toString(),
            });
          }
        }
      }

      // Prune local alarms whose backend counterpart does not exist or was deleted, or non-canonical IDs
      for (final local in localAlarms) {
        final uuid = await IdMapper.getUuid(local.id);
        if (uuid != null && uuid.startsWith('local_')) {
          continue;
        }
        final isCanonical = uuid != null && local.id == IdMapper.uuidToInt(uuid);
        if (uuid == null || !remoteUuids.contains(uuid) || !isCanonical) {
          await Alarm.stop(local.id);
          await IdMapper.removeMapping(local.id);
          // ignore: avoid_print
          print('[AlarmService] Pruned non-canonical or stale local alarm ${local.id} ($uuid)');
        }
      }

      // Also prune any stored mappings that are no longer on server or non-canonical IDs
      final allStoredIds = await IdMapper.getAllKnownIds();
      for (final id in allStoredIds) {
        final uuid = await IdMapper.getUuid(id);
        if (uuid != null && uuid.startsWith('local_')) {
          continue;
        }
        final isCanonical = uuid != null && id == IdMapper.uuidToInt(uuid);
        if (uuid == null || !remoteUuids.contains(uuid) || !isCanonical) {
          await Alarm.stop(id);
          await IdMapper.removeMapping(id);
          // ignore: avoid_print
          print('[AlarmService] Purged non-canonical or stale stored mapping for $id ($uuid)');
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
    final futureTarget = computeFutureOccurrence(alignedDateTime, repeatDays: repeatDays);

    final volumeSettings = rampSec > 0
        ? VolumeSettings.fade(
            volume: 1.0,
            fadeDuration: Duration(seconds: rampSec),
          )
        : VolumeSettings.fixed(volume: 1.0);

    final alarmSettings = AlarmSettings(
      id: intId,
      dateTime: futureTarget,
      assetAudioPath: audioPath,
      loopAudio: true,
      vibrate: true,
      volumeSettings: volumeSettings,
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
      final nextTime = getNextOccurrence(settings.dateTime, repeatDays);
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

  /// Computes the next future occurrence of an alarm.
  /// Guarantees that the returned DateTime is strictly in the future.
  static DateTime computeFutureOccurrence(DateTime targetTime, {List<int>? repeatDays, DateTime? mockNow}) {
    final now = mockNow ?? DateTime.now();
    if (targetTime.isAfter(now)) {
      return targetTime;
    }

    if (repeatDays != null && repeatDays.isNotEmpty) {
      return getNextOccurrence(targetTime, repeatDays, mockNow: now);
    }

    // One-time alarm: if hour:minute has not passed today, schedule for today; else tomorrow.
    final todayCandidate = DateTime(
      now.year,
      now.month,
      now.day,
      targetTime.hour,
      targetTime.minute,
      0,
      0,
    );
    if (todayCandidate.isAfter(now)) {
      return todayCandidate;
    }
    return todayCandidate.add(const Duration(days: 1));
  }

  static DateTime getNextOccurrence(DateTime targetTime, List<int> repeatDays, {DateTime? mockNow}) {
    final now = mockNow ?? DateTime.now();
    for (int dayOffset = 0; dayOffset <= 7; dayOffset++) {
      final candidate = DateTime(
        now.year,
        now.month,
        now.day + dayOffset,
        targetTime.hour,
        targetTime.minute,
        0,
        0,
      );
      if (candidate.isBefore(now) || candidate.isAtSameMomentAs(now)) {
        continue;
      }
      if (repeatDays.contains(candidate.weekday)) {
        return candidate;
      }
    }
    return targetTime.add(const Duration(days: 1));
  }
}
