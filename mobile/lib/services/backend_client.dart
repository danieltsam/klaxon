import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class BackendClient {
  static const String _defaultUrl = 'http://127.0.0.1:3000'; // Works with adb reverse or local
  static const String _prefBackendUrlKey = 'backend_server_url';

  static Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefBackendUrlKey) ?? _defaultUrl;
  }

  static Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    // Strip trailing slash if present
    final cleanUrl = url.trim().endsWith('/') ? url.trim().substring(0, url.trim().length - 1) : url.trim();
    await prefs.setString(_prefBackendUrlKey, cleanUrl);
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

  /// Sync alarm status change back to backend ('dismissed' | 'snoozed')
  static Future<bool> updateAlarmState(String uuid, String status) async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms/$uuid/state');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'status': status}),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] updateAlarmState error: $e');
      return false;
    }
  }

  /// Create alarm on backend so it appears on the dashboard and syncs
  static Future<String?> createRemoteAlarm({
    required DateTime targetTime,
    required String label,
    List<int>? repeatDays,
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
      if (repeatDays != null && repeatDays.isNotEmpty) {
        bodyMap['repeat_days'] = repeatDays;
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

  /// Fetch active remote alarms from backend for bidirectional sync
  static Future<List<Map<String, dynamic>>> fetchActiveAlarms() async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms?view=active');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      return [];
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] fetchActiveAlarms error: $e');
      return [];
    }
  }

  /// Fetch remote alarms from backend
  static Future<List<Map<String, dynamic>>> fetchRemoteAlarms() async {
    try {
      final baseUrl = await getBaseUrl();
      final uri = Uri.parse('$baseUrl/api/alarms');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      return [];
    } catch (e) {
      // ignore: avoid_print
      print('[BackendClient] fetchRemoteAlarms error: $e');
      return [];
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
}
