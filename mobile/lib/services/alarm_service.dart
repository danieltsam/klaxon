import 'dart:async';
import 'dart:math' as math;
import 'package:alarm/alarm.dart';
import '../utils/id_mapper.dart';
import 'alarm_state_outbox.dart';
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

  /// Injection seam for tests; the app wires the real post-receipt refresher
  /// (a pull of authoritative state) around this method's callers.
  static Future<void> Function()? onPayloadHandledForTest;

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

  /// Injection seam for tests; production posts through [BackendClient].
  static Future<bool> Function(String uuid, String status, String? targetTime)?
      stateSenderForTest;

  /// Delivers one queued state change to the backend. Returns whether the
  /// backend accepted it.
  static Future<bool> _sendState(
    String uuid,
    String status,
    String? targetTime,
  ) {
    final sender = stateSenderForTest;
    if (sender != null) return sender(uuid, status, targetTime);
    return BackendClient.updateAlarmState(uuid, status, targetTime: targetTime);
  }

  /// Persists [status] for [uuid] and immediately tries to deliver it.
  ///
  /// The entry is written before any network call, so a report that fails — or
  /// one interrupted by the app being backgrounded or killed — is not lost: it
  /// survives in [AlarmStateOutbox] and is retried on the next flush. The
  /// immediate attempt is fire-and-forget so the caller (e.g. the ring screen)
  /// is never blocked on the network.
  static Future<void> enqueueStateReport(
    String uuid,
    String status, {
    String? targetTime,
  }) async {
    await AlarmStateOutbox.put(PendingAlarmState(
      uuid: uuid,
      status: status,
      targetTime: targetTime,
      queuedAt: DateTime.now(),
    ));
    unawaited(flushPendingStateReports());
  }

  /// Retries every queued state change once, dropping entries the backend
  /// confirms and abandoning those that have failed [AlarmStateOutbox.maxAttempts]
  /// times. A failure is logged and swallowed: a lost state report must never
  /// break the reconcile of the alarms that did work.
  ///
  /// Flushes are serialised through [_stateFlushChain] so two overlapping calls
  /// (an immediate dismissal report and the periodic reconcile) cannot race the
  /// outbox's read-modify-write.
  static Future<void> flushPendingStateReports() {
    final run = _stateFlushChain.then((_) => _flushPendingStateReportsOnce());
    _stateFlushChain = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  static Future<void> _flushPendingStateReportsOnce() async {
    final entries = await AlarmStateOutbox.all();
    if (entries.isEmpty) return;
    for (final entry in entries) {
      try {
        final accepted =
            await _sendState(entry.uuid, entry.status, entry.targetTime);
        if (accepted) {
          await AlarmStateOutbox.remove(entry.uuid);
        } else {
          await AlarmStateOutbox.recordFailure(entry.uuid);
        }
      } catch (e) {
        // ignore: avoid_print
        print('[AlarmService] flushPendingStateReports error: $e');
        await AlarmStateOutbox.recordFailure(entry.uuid);
      }
    }
  }

  static Future<void> _stateFlushChain = Future<void>.value();

  /// Completes when every flush requested so far has finished. Test-only.
  static Future<void> get pendingStateFlush => _stateFlushChain;

  /// Clears the persisted outbox and the test seam. Test-only.
  static Future<void> resetStateOutboxForTest() async {
    stateSenderForTest = null;
    _stateFlushChain = Future<void>.value();
    await AlarmStateOutbox.clear();
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

  /// Exponent of the perceptual power curve used by [perceivedVolumeProgress].
  /// Lower values make the ramp rise earlier and feel more linear; higher
  /// values keep the start whisper-quiet for longer. 4.5 gives a smooth 30s
  /// wake that starts barely audible and reaches full volume without a final
  /// spike.
  static const double rampExponent = 4.5;

  /// Single source of truth for the gentle wake volume curve.
  ///
  /// Returns the perceived volume amplitude (0.001..1.0) for a normalized point
  /// [progress] (0..1) along the ramp. The curve is a power law v = p^e, which
  /// compensates for logarithmic human loudness perception while avoiding the
  /// near-silent-then-spiking feel of the previous e=6 curve.
  static double perceivedVolumeProgress(double progress) {
    final t = progress.clamp(0.0, 1.0);
    return math.pow(t, rampExponent).toDouble().clamp(0.001, 1.0);
  }

  /// Maps a linear amplitude [gain] (0.001..1.0) to a 0..1 perceived-loudness
  /// fraction.
  ///
  /// Human loudness perception is logarithmic, so a small gain like 1.6% reads
  /// as much more than 1.6% of full volume. This converts gain to decibels
  /// relative to full scale, with a -60 dB floor matching the 0.001 gain floor,
  /// then normalizes that range to 0..1 for the ring-screen bar and percentage.
  static double perceivedLoudnessProgress(double gain) {
    if (gain <= 0.0) return 0.0;
    if (gain >= 1.0) return 1.0;
    final db = 20.0 * math.log(gain) / math.ln10;
    return (1.0 + db / 60.0).clamp(0.0, 1.0);
  }

  /// Builds a perceptually-weighted volume ramp with fine-grained fade steps.
  ///
  /// Uses [perceivedVolumeProgress] so the ring-screen progress bar and the
  /// actual audio fade cannot drift. Step count scales with ramp duration so
  /// 30s ramps get ~120 imperceptible steps instead of the previous 20 coarse
  /// jumps.
  static VolumeSettings buildPerceptualVolumeSettings(int rampSec) {
    if (rampSec <= 0) {
      return const VolumeSettings.fixed(volume: 1.0);
    }

    final steps = <VolumeFadeStep>[];
    steps.add(VolumeFadeStep(Duration.zero, 0.001));

    final stepCount = (rampSec * 4).clamp(30, 200);
    for (int i = 1; i <= stepCount; i++) {
      final progress = i / stepCount;
      final timeMillis = ((rampSec * 1000 * i) / stepCount).round();
      final volume = perceivedVolumeProgress(progress);
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
      await _applyAlarmPayload(data);
    } finally {
      // Fires on every branch — including an early return for a malformed
      // payload — so a foreground receipt always converges state (spec §5.3).
      final hook = onPayloadHandledForTest;
      if (hook != null) {
        await hook();
      }
    }
  }

  /// Retires every local id other than [canonicalId] that still owns [uuid].
  ///
  /// A server alarm must map to exactly one local id: its canonical
  /// `IdMapper.uuidToInt(uuid)`. An optimistically-armed local alarm can still
  /// hold the uuid under a provisional `local_*` id when the backend's CREATE
  /// echo arrives (the create response and the push race for the same alarm).
  /// Dropping that stale owner here makes the CREATE idempotent — there is no
  /// second local alarm left for a later reconcile to prune, which is the
  /// duplicate row the user saw appear and vanish after tapping "arm alarm".
  static Future<void> _retireSupersededOwners(
    String uuid,
    int canonicalId,
  ) async {
    for (final otherId in await IdMapper.getAllKnownIds()) {
      if (otherId == canonicalId) continue;
      if (await IdMapper.getUuid(otherId) != uuid) continue;
      await Alarm.stop(otherId);
      await IdMapper.removeMapping(otherId);
      // ignore: avoid_print
      print('[AlarmService] Retired superseded local id $otherId for uuid $uuid (canonical $canonicalId)');
    }
  }

  static Future<void> _applyAlarmPayload(Map<String, dynamic> data) async {
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
        final label = data['label'] ?? 'Klaxon';
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
        // Idempotency keyed on the canonical uuid->int id: if the uuid is
        // already owned by a provisional local id, retire it before inserting
        // the canonical alarm so one user action never yields two local alarms.
        await _retireSupersededOwners(uuid.toString(), intId);
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
            stopButton: 'stop',
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
        // A cancel must never leave the phone with fewer armed alarms than the
        // backend has pending rows. On 2026-10-27 a duplicate's cancel removed
        // the only armed copy and the survivor stayed pending, silently: the
        // 06:30 alarm never rang. Reconcile re-arms anything now missing.
        await syncWithBackend();
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
        final label = remote['label']?.toString() ?? 'Klaxon';
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

        // Self-heal a dismissal the server never recorded. A persisted pending
        // `dismissed` entry means the device dismissed this alarm but the
        // backend never confirmed it (a lost or failed request). When the
        // server still reports it ringing — or pending past its target — push
        // the corrected state instead of leaving it stale. When the server has
        // already converged, drop the entry so a confirmed dismissal is never
        // re-sent. (Only backend uuids reach here; `local_` alarms are absent
        // from the remote list.)
        if (await AlarmStateOutbox.hasPendingStatus(uuid, 'dismissed')) {
          final serverAgrees = status == 'dismissed' ||
              status == 'disabled' ||
              status == 'canceled' ||
              status == 'missed';
          if (serverAgrees) {
            await AlarmStateOutbox.remove(uuid);
          } else {
            final targetIsPast = targetDate.isBefore(DateTime.now());
            final serverIsStale =
                status == 'ringing' || (status == 'pending' && targetIsPast);
            if (serverIsStale) {
              await Alarm.stop(intId);
              await IdMapper.setEnabled(intId, false);
              // Leave the entry queued: the flush at the end of this reconcile
              // pushes the corrected `dismissed` state.
              continue;
            }
          }
        }

        if (status == 'ringing') {
          // A remotely-ringing alarm is already being handled: the ring screen
          // owns it and the DISMISS push (or the next poll) ends it. Neither
          // arm nor force-stop it here. A synthetic CREATE for its now-past
          // target would fall inside the grace window and fire immediately,
          // restarting the alarm in an endless re-arm/ring loop after a remote
          // silence (the pre-existing status the fix guards against).
          await IdMapper.setEnabled(intId, true);
        } else if (status == 'disabled' ||
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

      // Retry any state change the backend never confirmed (e.g. a dismissal
      // lost while the app was backgrounded), so the fetch above can converge.
      // Bounded: entries are dropped after [AlarmStateOutbox.maxAttempts]
      // failures.
      await flushPendingStateReports();

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
        stopButton: 'stop',
      ),
    );

    await Alarm.set(alarmSettings: alarmSettings);
    return alarmSettings;
  }

  /// Re-keys an optimistically-armed local alarm onto the backend's canonical
  /// id once the server assigns it a uuid.
  ///
  /// The phone arms before the network answers, so the alarm starts life under
  /// an id hashed from a throwaway `local_*` uuid. Every other path (the FCM
  /// CREATE echo, `syncWithBackend`, the canonical prune) addresses a server
  /// alarm by `uuidToInt(uuid)`. Simply re-pointing the provisional id's
  /// mapping at the server uuid, as the Arm flow used to, left that id
  /// non-canonical: the echo inserted a second local alarm under the canonical
  /// id and the next reconcile pruned the phantom — the duplicate the owner saw
  /// appear and vanish.
  ///
  /// Moving the armed settings to the canonical id here means the echo finds
  /// the alarm already scheduled and stays idempotent. Safe whether the push
  /// beats the create response or not.
  static Future<void> adoptRemoteId({
    required int localIntId,
    required String remoteUuid,
    required String label,
    String? description,
    required DateTime targetTime,
    List<int>? repeatDays,
    int intervalWeeks = 1,
    String? anchorDateIso,
    String? soundTone,
    int rampSeconds = 30,
  }) async {
    final canonicalId = IdMapper.uuidToInt(remoteUuid);
    if (canonicalId == localIntId) {
      await IdMapper.saveMapping(
        localIntId,
        remoteUuid,
        label: label,
        description: description,
        targetTime: targetTime,
        soundTone: soundTone,
        rampSeconds: rampSeconds,
        repeatDays: repeatDays,
      );
      return;
    }

    // Snapshot what the optimistic arm left behind before retiring it.
    final scheduled = await Alarm.getAlarm(localIntId);
    final snoozed = await IdMapper.isSnoozed(localIntId);
    final enabled = await IdMapper.isEnabled(localIntId);

    await Alarm.stop(localIntId);
    await IdMapper.removeMapping(localIntId);

    // The FCM CREATE echo can beat the create response. If it already claimed
    // the canonical id for this uuid it owns the alarm; leave its copy intact.
    if (await IdMapper.getUuid(canonicalId) == remoteUuid) return;

    await IdMapper.saveMapping(
      canonicalId,
      remoteUuid,
      label: label,
      description: description,
      targetTime: targetTime,
      soundTone: soundTone,
      rampSeconds: rampSeconds,
      repeatDays: repeatDays,
    );
    await IdMapper.setSnoozed(canonicalId, snoozed);
    await IdMapper.setIntervalWeeks(canonicalId, intervalWeeks);
    await IdMapper.setAnchorDate(canonicalId, anchorDateIso);
    await IdMapper.setEnabled(canonicalId, enabled);

    // Preserve the exact armed settings (time, audio, volume ramp) under the
    // canonical id; nothing is armed for a disabled/unscheduled alarm.
    if (scheduled != null) {
      await Alarm.set(alarmSettings: scheduled.copyWith(id: canonicalId));
    }
  }

  /// Reports `ringing` to the backend for [intId], but only when the platform
  /// still confirms the alarm is actually ringing.
  ///
  /// Opening the ring screen can race a remote silence: a DISMISS push may stop
  /// the alarm after the screen was queued but before this report runs. An
  /// unconditional report would overwrite the server's `dismissed` back to
  /// `ringing`, which the reconcile then re-arms — the remote-silence loop.
  /// The `Alarm.isRinging` re-check keeps the server's authoritative state
  /// intact while still reporting a legitimately ringing alarm.
  static Future<void> reportRingingIfStillRinging(int intId) async {
    try {
      final uuid = await IdMapper.getUuid(intId);
      if (uuid == null || uuid.startsWith('local_')) return;
      if (!await Alarm.isRinging(intId)) return;
      // Deliberately NOT queued through AlarmStateOutbox: a durable 'ringing'
      // could be flushed after a remote silence and overwrite the server's
      // authoritative 'dismissed' back to 'ringing', which the reconcile then
      // re-arms — the remote-silence loop this guard exists to prevent.
      await BackendClient.updateAlarmState(uuid, 'ringing');
    } catch (e) {
      // ignore: avoid_print
      print('[AlarmService] reportRingingIfStillRinging error: $e');
    }
  }

  /// Dismiss active alarm and notify backend
  static Future<void> dismissAlarm(AlarmSettings settings) async {
    await Alarm.stop(settings.id);
    await IdMapper.setSnoozed(settings.id, false);
    final uuid = await IdMapper.getUuid(settings.id);

    if (uuid != null && !uuid.startsWith('local_')) {
      // Queue the dismissal before attempting delivery: if this report fails,
      // or the app is backgrounded/killed mid-request, it is retried from the
      // persisted outbox on the next flush (app start and every reconcile).
      await enqueueStateReport(uuid, 'dismissed');
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
      // Queue the snooze with the exact next-ring time so the server's
      // target_time matches the alarm the phone actually armed (§6.3). It goes
      // through the persisted outbox: a report lost to a failed request or to
      // the app being killed would otherwise leave the server stale.
      await enqueueStateReport(
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
