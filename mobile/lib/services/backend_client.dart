import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class BackendClient {
  static const String _defaultUrl = 'http://127.0.0.1:3000'; // Works with adb reverse or local
  static const String _prefBackendUrlKey = 'backend_server_url';

  /// `baymax:8001` is a host and port, but `Uri.parse` reads "baymax" as the
  /// scheme. Assume http when no scheme is given, and drop trailing slashes.
  static String normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return trimmed;
    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed);
    final withScheme = hasScheme ? trimmed : 'http://$trimmed';
    return withScheme.replaceFirst(RegExp(r'/+$'), '');
  }

  static Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return normalizeBaseUrl(prefs.getString(_prefBackendUrlKey) ?? _defaultUrl);
  }

  static Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final cleanUrl = normalizeBaseUrl(url);
    if (cleanUrl.isEmpty) return;
    await prefs.setString(_prefBackendUrlKey, cleanUrl);
  }

  /// Check if the backend is reachable (GET /api/health or GET /api/settings fallback)
  static Future<bool> checkHealth([String? testUrl]) async {
    try {
      final baseUrl = testUrl != null ? normalizeBaseUrl(testUrl) : await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/health');
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) return true;
    } catch (_) {}

    try {
      final baseUrl = testUrl != null ? normalizeBaseUrl(testUrl) : await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/settings');
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Register device FCM token with backend along with battery/hardware telemetry
  static Future<bool> registerDeviceToken(
    String token, {
    int? batteryLevel,
    bool? isCharging,
    String? deviceName,
  }) async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/devices/register');
      final bodyMap = <String, dynamic>{
        'token': token,
      };
      if (batteryLevel != null) {
        bodyMap['battery_level'] = batteryLevel;
      }
      if (isCharging != null) {
        bodyMap['is_charging'] = isCharging;
      }
      if (deviceName != null) {
        bodyMap['device_name'] = deviceName;
      }

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(bodyMap),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] registerDeviceToken error: $e');
      return false;
    }
  }

  /// Sync alarm status change back to backend ('dismissed' | 'snoozed' | 'pending' | 'disabled')
  static Future<bool> updateAlarmState(String uuid, String status, {String? targetTime}) async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms/$uuid/state');
      final bodyMap = <String, dynamic>{'status': status};
      if (targetTime != null) {
        bodyMap['target_time'] = targetTime;
      }
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(bodyMap),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] updateAlarmState error: $e');
      return false;
    }
  }

  /// Report alarms the device declined to arm, in a single batched call (§6.2).
  ///
  /// [reason] is a closed set from the device: `device_reported_stale` when the
  /// device never got to the alarm, `device_reported_failed` when it tried and
  /// could not fire it. Failures are logged and swallowed, returning `false`;
  /// a missed report must never throw into the sync path.
  ///
  /// [client] is an injection seam for tests; production uses a fresh client.
  static Future<bool> reportMissedAlarms(
    List<String> ids, {
    String reason = 'device_reported_stale',
    http.Client? client,
  }) async {
    if (ids.isEmpty) return false;
    final httpClient = client ?? http.Client();
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms/report-missed');
      final response = await httpClient.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ids': ids, 'reason': reason}),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] reportMissedAlarms error: $e');
      return false;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Create alarm on backend so it appears on the dashboard and syncs
  static Future<String?> createRemoteAlarm({
    required DateTime targetTime,
    required String label,
    String? description,
    List<int>? repeatDays,
    int? intervalWeeks,
    String? anchorDate,
    String? soundTone,
    int? rampSeconds,
  }) async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms');
      final alignedTarget = DateTime(
        targetTime.year,
        targetTime.month,
        targetTime.day,
        targetTime.hour,
        targetTime.minute,
        0,
        0,
      );
      final bodyMap = <String, dynamic>{
        'target_time': alignedTarget.toUtc().toIso8601String(),
        'label': label,
      };
      if (description != null && description.isNotEmpty) {
        bodyMap['description'] = description;
      }
      if (repeatDays != null && repeatDays.isNotEmpty) {
        bodyMap['repeat_days'] = repeatDays;
      }
      if (intervalWeeks != null && intervalWeeks > 1) {
        bodyMap['recurrence_interval_weeks'] = intervalWeeks;
        if (anchorDate != null && anchorDate.isNotEmpty) {
          bodyMap['recurrence_anchor_date'] = anchorDate;
        }
      }
      if (soundTone != null) {
        bodyMap['sound_tone'] = soundTone;
      }
      if (rampSeconds != null) {
        bodyMap['ramp_seconds'] = rampSeconds;
      }

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(bodyMap),
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return data['id'] as String?;
      }
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] createRemoteAlarm error: $e');
      return null;
    }
  }

  /// Update an existing alarm on the backend (PATCH /api/alarms/:id)
  static Future<bool> updateRemoteAlarm(
    String uuid, {
    DateTime? targetTime,
    String? label,
    String? description,
    List<int>? repeatDays,
    int? intervalWeeks,
    String? anchorDate,
    String? soundTone,
    int? rampSeconds,
  }) async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms/$uuid');
      final bodyMap = <String, dynamic>{};
      if (targetTime != null) {
        final aligned = DateTime(
          targetTime.year,
          targetTime.month,
          targetTime.day,
          targetTime.hour,
          targetTime.minute,
          0,
          0,
        );
        bodyMap['target_time'] = aligned.toUtc().toIso8601String();
      }
      if (label != null) {
        bodyMap['label'] = label;
      }
      if (description != null) {
        bodyMap['description'] = description;
      }
      if (repeatDays != null) {
        bodyMap['repeat_days'] = repeatDays;
      }
      if (intervalWeeks != null) {
        bodyMap['recurrence_interval_weeks'] = intervalWeeks;
      }
      if (anchorDate != null) {
        bodyMap['recurrence_anchor_date'] = anchorDate;
      }
      if (soundTone != null) {
        bodyMap['sound_tone'] = soundTone;
      }
      if (rampSeconds != null) {
        bodyMap['ramp_seconds'] = rampSeconds;
      }

      final response = await http.patch(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(bodyMap),
      ).timeout(const Duration(seconds: 8));

      return response.statusCode == 200;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] updateRemoteAlarm error: $e');
      return false;
    }
  }

  /// Fetch active remote alarms from backend for bidirectional sync
  static Future<List<Map<String, dynamic>>?> fetchActiveAlarms() async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms?view=active');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] fetchActiveAlarms error: $e');
      return null;
    }
  }

  /// Fetch all alarms (both active and inactive) from backend
  static Future<List<Map<String, dynamic>>?> fetchAllAlarms() async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms?view=all');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] fetchAllAlarms error: $e');
      return null;
    }
  }

  /// Fetch remote alarms from backend
  static Future<List<Map<String, dynamic>>?> fetchRemoteAlarms() async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] fetchRemoteAlarms error: $e');
      return null;
    }
  }

  /// Cancel alarm remotely on backend
  static Future<bool> deleteRemoteAlarm(String uuid) async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms/$uuid');
      final response = await http.delete(uri).timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] deleteRemoteAlarm error: $e');
      return false;
    }
  }

  /// Fetch persistent settings from backend
  static Future<Map<String, dynamic>?> fetchSettings() async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/settings');
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        return Map<String, dynamic>.from(jsonDecode(response.body));
      }
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] fetchSettings error: $e');
      return null;
    }
  }

  /// Update persistent settings on backend
  static Future<bool> updateSettings(Map<String, dynamic> settings) async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/settings');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(settings),
      ).timeout(const Duration(seconds: 8));
      return response.statusCode == 200;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] updateSettings error: $e');
      return false;
    }
  }
}
