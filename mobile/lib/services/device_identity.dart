import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reads the phone's real model name from the platform.
///
/// Android implements this through the `com.klaxon.mobile/device` MethodChannel
/// in MainActivity.kt. Anything else (or a failed call) degrades to
/// `'unknown phone'` so callers never have to handle an exception.
class DeviceIdentity {
  static const String _channelName = 'com.klaxon.mobile/device';
  static const String _fallback = 'unknown phone';

  static const MethodChannel _channel = MethodChannel(_channelName);

  static String? _cached;

  /// Human-readable phone model, e.g. "moto g86 power 5G". Never throws.
  static Future<String> modelName() async {
    final cached = _cached;
    if (cached != null) return cached;

    if (defaultTargetPlatform != TargetPlatform.android) {
      return _fallback;
    }

    try {
      final model = await _channel.invokeMethod<String>('getDeviceModel');
      final trimmed = model?.trim() ?? '';
      if (trimmed.isEmpty) return _fallback;
      _cached = trimmed;
      return trimmed;
    } catch (_) {
      return _fallback;
    }
  }
}
