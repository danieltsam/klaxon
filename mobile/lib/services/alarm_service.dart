import 'dart:async';
import 'dart:math' as math;
import 'package:alarm/alarm.dart';
import '../utils/id_mapper.dart';
import 'backend_client.dart';

class AlarmService {
  /// Stream that emits whenever an alarm is remotely dismissed via FCM
  static final StreamController<int> onRemoteDismissed = StreamController<int>.broadcast();

  /// Grace window after which a one-time alarm is too stale to arm (§8.1).
  /// Fixed at 5 minutes; recurring alarm schedules are never subject to it.
  static const Duration staleAlarmGraceWindow = Duration(minutes: 5);

  /// Uuids declined since the last successful report, flushed as one batch.
  static final Set<String> _pendingMissedReports = <String>{};

  /// Uuids the backend has already accepted, so they are never reported twice.
  static final Set<String> _reportedMissedIds = <String>{};

  /// Injection seam for tests; production reports through [BackendClient].
  static Future<bool> Function(List<String> ids)? missedReportSenderForTest;

  /// Uuids waiting for the next [flushMissedReports]. Test-only.
  static Set<String> get pendingMissedReportIds =>
      Set<String>.unmodifiable(_pendingMissedReports);

  /// Clears the in-memory report bookkeeping. Test-only.
  static void resetMissedReportStateForTest() {
    _pendingMissedReports.clear();
    _reportedMissedIds.clear();
    missedReportSenderForTest = null;
  }

  /// Records that the device declined to arm [uuid] because the alarm was stale.
  /// De-duplicated: an alarm already reported is never queued again.
  static void recordDeclinedStaleAlarm(String uuid) {
    if (_reportedMissedIds.contains(uuid)) return;
    _pendingMissedReports.add(uuid);
  }

  /// Reports every alarm newly declined since the last successful flush in one
  /// batched call (§6.2). A failure is logged and swallowed: a missed report
  /// must never break synchronising the alarms that did work. Ids are kept for
  /// a retry only when the backend did not accept them.
  static Future<void> flushMissedReports() async {
    if (_pendingMissedReports.isEmpty) return;
    final ids = List<String>.from(_pendingMissedReports);
    try {
      final sender = missedReportSenderForTest ?? BackendClient.reportMissedAlarms;
      final accepted = await sender(ids);
      if (accepted) {
        _reportedMissedIds.addAll(ids);
        _pendingMissedReports.removeAll(ids);
      }
      // On failure the ids stay pending and are retried on the next sync.
    } catch (e) {
      // ignore: avoid_print
      print('[AlarmService] flushMissedReports error: $e');
    }
  }

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

  /// Builds a perceptually-weighted logarithmic/power volume ramp.
  /// Standard linear volume ramps sound like they jump to maximum volume almost
  /// immediately because human loudness perception is logarithmic (Weber-Fechner / Stevens' power law).
  /// By applying a steeper power curve v(t) = (t / T)^4:
  /// - 0% to 50% duration stays whisper-quiet (< 6.25% volume)
  /// - 50% to 75% duration stays in the gentle wake-up zone (< 31.6% volume)
  /// - 75% to 100% duration accelerates smoothly to full alert volume
  static VolumeSettings buildPerceptualVolumeSettings(int rampSec) {
    if (rampSec <= 0) {
      return const VolumeSettings.fixed(volume: 1.0);
    }

    final steps = <VolumeFadeStep>[];
    steps.add(VolumeFadeStep(Duration.zero, 0.001));

    final stepCount = rampSec.clamp(8, 20);
    for (int i = 1; i <= stepCount; i++) {
      final progress = i / stepCount;
      final timeMillis = ((rampSec * 1000 * i) / stepCount).round();
      final volume = math.pow(progress, 4.0).toDouble().clamp(0.001, 1.0);
      steps.add(VolumeFadeStep(Duration(milliseconds: timeMillis), volume));
    }

    return VolumeSettings.staircaseFade(
      fadeSteps: steps,
      volume: 1.0,
    );
  }

  /// Entry point for FCM payload processing
  static Future<void> handleAlarmPayload(Map<String, dynamic> data) async {
    try {
      final action = data['action'];
      final uuid = data['id'];

      if (action == null || uuid == null) {
        // ignore: avoid_print
        print('[AlarmService] Missing action or id in FCM payload: $data');
        return;
      }

      final intId = IdMapper.uuidToInt(uuid.toString());

      if (action == 'CREATE') {
        final targetTimeStr = data['target_time']?.toString();
        final label = data['label'] ?? 'Remote Alarm';
        final tone = data['sound_tone']?.toString() ?? 'alarm';
        final rampSec = int.tryParse(data['ramp_seconds']?.toString() ?? '30') ?? 30;

        if (targetTimeStr == null) {
          // ignore: avoid_print
          print('[AlarmService] Missing target_time in CREATE payload');
          return;
        }

        final rawDateTime = DateTime.tryParse(targetTimeStr)?.toLocal();
        if (rawDateTime == null) {
          // ignore: avoid_print
          print('[AlarmService] Invalid target_time in CREATE payload: $targetTimeStr');
          return;
        }

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

        // Fortnightly / interval-based recurrence (backend always sends these
        // keys in the CREATE payload: interval defaults to 1, anchor to '').
        int intervalWeeks = 1;
        DateTime? anchorDate;
        final intervalWeeksStr = data['recurrence_interval_weeks'];
        if (intervalWeeksStr != null && intervalWeeksStr.toString().isNotEmpty) {
          final parsedInterval = int.tryParse(intervalWeeksStr.toString());
          if (parsedInterval != null && parsedInterval > 1) {
            intervalWeeks = parsedInterval;
          }
        }
        await IdMapper.setIntervalWeeks(intId, intervalWeeks);
        final anchorDateStr = data['recurrence_anchor_date'];
        if (anchorDateStr != null && anchorDateStr.toString().isNotEmpty) {
          final parsedAnchor = DateTime.tryParse(anchorDateStr.toString());
          if (parsedAnchor != null) {
            anchorDate = DateTime(parsedAnchor.year, parsedAnchor.month, parsedAnchor.day);
            await IdMapper.setAnchorDate(intId, anchorDateStr.toString());
          }
        } else {
          await IdMapper.setAnchorDate(intId, null);
        }

        final futureTarget = computeArmTarget(
          parsedDateTime,
          repeatDays: repeatDaysList,
          intervalWeeks: intervalWeeks,
          anchorDate: anchorDate,
        );

        if (futureTarget == null) {
          // Stale one-time alarm beyond the grace window: refuse to arm it
          // (§8.1) and report the fact on the next batched flush (§6.2). It was
          // never delivered, so it must not be described as delivered anywhere.
          recordDeclinedStaleAlarm(uuid.toString());
          await Alarm.stop(intId);
          await IdMapper.setEnabled(intId, false);
          // ignore: avoid_print
          print('[AlarmService] Declined stale one-time alarm $intId ($uuid): '
              'target $parsedDateTime is past the '
              '${staleAlarmGraceWindow.inMinutes}-minute grace window; not delivered');
          return;
        }

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
        final volumeSettings = buildPerceptualVolumeSettings(rampSec);

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
    } catch (e) {
      // ignore: avoid_print
      print('[AlarmService] Error handling alarm payload: $e');
    }
  }

  /// Bidirectional sync: reconciles local alarms with the backend server
  static Future<int> syncWithBackend() async {
    try {
      final remoteAlarms = await BackendClient.fetchAllAlarms();
      if (remoteAlarms == null) {
        // ignore: avoid_print
        print('[AlarmService] syncWithBackend aborted: backend unreachable or returned error. Preserving local alarms.');
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
        final status = remote['status']?.toString() ?? 'pending';
        final desc = remote['description']?.toString();

        if (uuid == null || targetTimeStr == null) continue;
        remoteUuids.add(uuid);

        final intId = IdMapper.uuidToInt(uuid);
        final targetDate = DateTime.parse(targetTimeStr).toLocal();
        final repeatDays = repeatDaysStr != null && repeatDaysStr.isNotEmpty
            ? repeatDaysStr.split(',').map((s) => int.tryParse(s.trim()) ?? 0).where((d) => d >= 1 && d <= 7).toList()
            : <int>[];

        // Fortnightly / interval-based recurrence fields mirroring the backend
        final intervalWeeksStr = remote['recurrence_interval_weeks']?.toString();
        final anchorDateStr = remote['recurrence_anchor_date']?.toString();
        int intervalWeeks = 1;
        if (intervalWeeksStr != null && intervalWeeksStr.isNotEmpty) {
          final parsed = int.tryParse(intervalWeeksStr);
          if (parsed != null && parsed > 1) {
            intervalWeeks = parsed;
          }
        }
        await IdMapper.setIntervalWeeks(intId, intervalWeeks);
        if (anchorDateStr != null && anchorDateStr.isNotEmpty) {
          await IdMapper.setAnchorDate(intId, anchorDateStr);
        } else {
          await IdMapper.setAnchorDate(intId, null);
        }

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

        if (status == 'disabled' ||
            status == 'canceled' ||
            status == 'dismissed' ||
            status == 'missed') {
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
              'recurrence_interval_weeks': intervalWeeksStr,
              'recurrence_anchor_date': anchorDateStr,
            });
          }

          // A remote snooze must survive the reconcile so its badge stays lit.
          // Set AFTER the synthetic CREATE above, whose branch clears the flag
          // (handleAlarmPayload line ~208); setting it earlier would be undone.
          if (status == 'snoozed') {
            await IdMapper.setSnoozed(intId, true);
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

      // Report any stale alarms declined during this sync in a single call, so
      // the backend converges immediately on reconnect (§6.2). One failed
      // report must not disturb the alarms that synced correctly.
      await flushMissedReports();

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
    int intervalWeeks = 1,
    DateTime? anchorDate,
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
    await IdMapper.setIntervalWeeks(intId, intervalWeeks);
    if (intervalWeeks > 1 && anchorDate != null) {
      final m = anchorDate.month.toString().padLeft(2, '0');
      final d = anchorDate.day.toString().padLeft(2, '0');
      await IdMapper.setAnchorDate(intId, '${anchorDate.year}-$m-$d');
    } else {
      await IdMapper.setAnchorDate(intId, null);
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
    final futureTarget = computeArmTarget(
      alignedDateTime,
      repeatDays: repeatDays,
      intervalWeeks: intervalWeeks,
      anchorDate: anchorDate,
    );
    if (futureTarget == null) {
      throw ArgumentError.value(
        alignedDateTime,
        'dateTime',
        'A one-time alarm more than ${staleAlarmGraceWindow.inMinutes} minutes '
            'in the past cannot be armed; reschedule it.',
      );
    }

    final volumeSettings = buildPerceptualVolumeSettings(rampSec);

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
    final intervalWeeks = await IdMapper.getIntervalWeeks(settings.id) ?? 1;
    final anchorDateStr = await IdMapper.getAnchorDate(settings.id);
    final anchorDate = anchorDateStr != null ? DateTime.tryParse(anchorDateStr) : null;
    if (repeatDays.isNotEmpty || (intervalWeeks > 1 && anchorDate != null)) {
      final nextTime = getNextOccurrence(
        settings.dateTime,
        repeatDays,
        intervalWeeks: intervalWeeks,
        anchorDate: anchorDate,
      );
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
      // Async notify backend with the exact next-ring time so the server's
      // target_time matches the alarm the phone actually armed (§6.3).
      BackendClient.updateAlarmState(
        uuid,
        'snoozed',
        targetTime: snoozeTime.toUtc().toIso8601String(),
      );
    }

    return newSettings;
  }

  /// Decides the moment to actually arm an alarm, returning `null` when a
  /// one-time alarm is too stale to arm at all (§8.1).
  ///
  /// - a one-time alarm more than [staleAlarmGraceWindow] past is refused
  ///   (`null`), which closes the reconnect race: a 12am reconnect no longer
  ///   arms a 00:01 alarm for a minute later;
  /// - a one-time alarm inside the window is armed for its intended moment, so
  ///   a brief hiccup still rings a few minutes late;
  /// - a future alarm is returned unchanged;
  /// - recurring alarms (daily, weekdays, fortnightly) are never refused: a
  ///   stale stored time is normal for a repeating schedule, so they advance
  ///   via [getNextOccurrence] exactly as before.
  static DateTime? computeArmTarget(
    DateTime targetTime, {
    List<int>? repeatDays,
    int intervalWeeks = 1,
    DateTime? anchorDate,
    DateTime? mockNow,
  }) {
    final now = mockNow ?? DateTime.now();
    final isRecurring = (repeatDays != null && repeatDays.isNotEmpty) ||
        (intervalWeeks > 1 && anchorDate != null);

    if (!isRecurring) {
      if (targetTime.isAfter(now)) {
        return targetTime;
      }
      if (now.difference(targetTime) <= staleAlarmGraceWindow) {
        // Inside the grace window: arm for the intended moment and accept a
        // few minutes' lateness.
        return targetTime;
      }
      // Beyond the grace window: this one-time alarm was missed. Do not arm it.
      return null;
    }

    return getNextOccurrence(
      targetTime,
      repeatDays ?? const [],
      intervalWeeks: intervalWeeks,
      anchorDate: anchorDate,
      mockNow: now,
    );
  }

  /// Computes the next future occurrence of an alarm.
  /// Guarantees that the returned DateTime is strictly in the future.
  static DateTime computeFutureOccurrence(
    DateTime targetTime, {
    List<int>? repeatDays,
    int intervalWeeks = 1,
    DateTime? anchorDate,
    DateTime? mockNow,
  }) {
    final now = mockNow ?? DateTime.now();
    if (targetTime.isAfter(now)) {
      return targetTime;
    }

    final isRecurring = (repeatDays != null && repeatDays.isNotEmpty) ||
        (intervalWeeks > 1 && anchorDate != null);
    if (isRecurring) {
      return getNextOccurrence(
        targetTime,
        repeatDays ?? const [],
        intervalWeeks: intervalWeeks,
        anchorDate: anchorDate,
        mockNow: now,
      );
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

  static DateTime getNextOccurrence(
    DateTime targetTime,
    List<int> repeatDays, {
    int intervalWeeks = 1,
    DateTime? anchorDate,
    DateTime? mockNow,
  }) {
    final now = mockNow ?? DateTime.now();

    // Fortnightly / interval-based recurrence: step in (intervalWeeks * 7)-day
    // increments starting from the anchor date. The anchor's weekday already
    // matches repeatDays (the anchor was the first occurrence), so no weekday
    // membership check is needed here.
    if (intervalWeeks > 1 && anchorDate != null) {
      final anchor = DateTime(
        anchorDate.year,
        anchorDate.month,
        anchorDate.day,
        targetTime.hour,
        targetTime.minute,
        0,
        0,
      );
      // Up to ~2 years ahead before falling back to the next interval step
      for (int k = 0; k <= 60; k++) {
        final candidate = anchor.add(Duration(days: 7 * intervalWeeks * k));
        if (candidate.isAfter(now)) {
          return candidate;
        }
      }
      return anchor.add(Duration(days: 7 * intervalWeeks));
    }

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
