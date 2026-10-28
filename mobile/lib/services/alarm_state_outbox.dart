import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A single alarm state change the device owes the backend.
///
/// [uuid] is the backend alarm id, [status] the state the device wants the
/// server to hold (e.g. `dismissed`), and [targetTime] an optional ISO-8601
/// next-ring time for states that carry one (snooze). [queuedAt] and
/// [attempts] drive the bounded retry.
class PendingAlarmState {
  final String uuid;
  final String status;
  final String? targetTime;
  final DateTime queuedAt;
  final int attempts;

  const PendingAlarmState({
    required this.uuid,
    required this.status,
    this.targetTime,
    required this.queuedAt,
    this.attempts = 0,
  });

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'status': status,
        if (targetTime != null) 'target_time': targetTime,
        'queued_at': queuedAt.toIso8601String(),
        'attempts': attempts,
      };

  factory PendingAlarmState.fromJson(Map<String, dynamic> json) {
    return PendingAlarmState(
      uuid: json['uuid'] as String,
      status: json['status'] as String,
      targetTime: json['target_time'] as String?,
      queuedAt:
          DateTime.tryParse(json['queued_at']?.toString() ?? '') ?? DateTime.now(),
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    );
  }

  PendingAlarmState withAttempts(int value) => PendingAlarmState(
        uuid: uuid,
        status: status,
        targetTime: targetTime,
        queuedAt: queuedAt,
        attempts: value,
      );
}

/// A tiny, dependency-free persisted outbox for alarm state changes that must
/// eventually reach the backend.
///
/// A dismissal is not silently losable: the state is written here before the
/// network call, and only removed once the backend confirms it. If the app is
/// backgrounded or killed mid-request — or the request simply fails — the entry
/// survives in `SharedPreferences` and is retried on the next flush (app start
/// and every reconcile). Retries are bounded by [maxAttempts] so a permanently
/// unreachable server cannot grow the outbox without limit.
///
/// Entries are keyed by [PendingAlarmState.uuid]; a newer state for the same
/// alarm supersedes an older one, so the outbox holds at most one entry per
/// alarm.
class AlarmStateOutbox {
  static const String prefKey = 'alarm_state_outbox_v1';

  /// Maximum delivery attempts before an entry is abandoned.
  static const int maxAttempts = 8;

  /// Every queued state, oldest first.
  static Future<List<PendingAlarmState>> all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefKey);
    if (raw == null || raw.isEmpty) return <PendingAlarmState>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <PendingAlarmState>[];
      return decoded
          .whereType<Map>()
          .map((e) => PendingAlarmState.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      // A corrupt payload must not wedge the sync path; treat it as empty.
      return <PendingAlarmState>[];
    }
  }

  /// Upserts [state], replacing any earlier entry for the same uuid.
  static Future<void> put(PendingAlarmState state) async {
    final entries = await all();
    entries.removeWhere((e) => e.uuid == state.uuid);
    entries.add(state);
    await _save(entries);
  }

  /// Removes the entry for [uuid] once the backend has confirmed it.
  static Future<void> remove(String uuid) async {
    final entries = await all();
    final before = entries.length;
    entries.removeWhere((e) => e.uuid == uuid);
    if (entries.length != before) {
      await _save(entries);
    }
  }

  /// Removes [state] only when it is still the stored entry.
  ///
  /// A flush can take seconds, and a newer report for the same uuid may be
  /// queued while it runs. Removing by uuid alone deleted that newer report,
  /// so the device's latest state was never sent.
  static Future<void> removeIfCurrent(PendingAlarmState state) async {
    final entries = await all();
    final before = entries.length;
    entries.removeWhere(
      (e) => e.uuid == state.uuid && e.queuedAt == state.queuedAt,
    );
    if (entries.length != before) {
      await _save(entries);
    }
  }

  /// Records a failed delivery for [state] if it is still the stored entry.
  static Future<void> recordFailureIfCurrent(PendingAlarmState state) async {
    final entries = await all();
    var changed = false;
    final kept = <PendingAlarmState>[];
    for (final entry in entries) {
      if (entry.uuid != state.uuid || entry.queuedAt != state.queuedAt) {
        kept.add(entry);
        continue;
      }
      changed = true;
      final next = entry.attempts + 1;
      if (next < maxAttempts) {
        kept.add(entry.withAttempts(next));
      }
    }
    if (changed) {
      await _save(kept);
    }
  }

  /// Records a failed delivery for [uuid], dropping the entry once it has
  /// reached [maxAttempts].
  static Future<void> recordFailure(String uuid) async {
    final entries = await all();
    var changed = false;
    final kept = <PendingAlarmState>[];
    for (final entry in entries) {
      if (entry.uuid != uuid) {
        kept.add(entry);
        continue;
      }
      changed = true;
      final next = entry.attempts + 1;
      if (next < maxAttempts) {
        kept.add(entry.withAttempts(next));
      }
      // else: abandoned after too many failures.
    }
    if (changed) {
      await _save(kept);
    }
  }

  /// Whether an entry for [uuid] with [status] is still waiting to be delivered.
  static Future<bool> hasPendingStatus(String uuid, String status) async {
    final entries = await all();
    return entries.any((e) => e.uuid == uuid && e.status == status);
  }

  /// Clears the outbox. Test-only.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefKey);
  }

  static Future<void> _save(List<PendingAlarmState> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefKey,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }
}
