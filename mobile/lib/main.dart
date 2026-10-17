import 'dart:async';
import 'dart:ui';
import 'package:alarm/alarm.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart' hide NotificationSettings;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'screens/ring_screen.dart';
import 'services/alarm_service.dart';
import 'services/backend_client.dart';
import 'utils/id_mapper.dart';
import 'utils/relative_time.dart';
import 'utils/settings_formatter.dart';
import 'widgets/time_pickers.dart';
import 'services/haptic_service.dart';
import 'widgets/haptics_lab_modal.dart';
import 'widgets/calendar_picker.dart';
import 'widgets/recurrence_chip_variants.dart';

class _DirectionalStrikePainter extends CustomPainter {
  final double progress;
  _DirectionalStrikePainter(this.progress);
  @override
  void paint(Canvas canvas, Size size) {
    if (progress == 0) return;
    final paint = Paint()
      ..color = const Color(0xFF6B7280)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width * progress, y), paint);
  }
  @override
  bool shouldRepaint(_DirectionalStrikePainter old) => old.progress != progress;
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Injection seam for tests; production re-registers through [BackendClient].
@visibleForTesting
Future<void> Function(String token)? registerTokenForTest;

/// Injection seam for tests; production deletes remotely through
/// [BackendClient.deleteRemoteAlarm].
@visibleForTesting
Future<void> Function(String uuid)? deleteRemoteAlarmForTest;

/// Register (or re-register) this device's FCM token with the backend.
///
/// Called on cold start and on every [FirebaseMessaging.onTokenRefresh], so a
/// rotated token is never left dead on the backend (the original outage).
Future<void> registerToken(String token) async {
  final override = registerTokenForTest;
  if (override != null) {
    await override(token);
    return;
  }
  await BackendClient.registerDeviceToken(token);
}

/// Shows a transient bottom toast. A new toast pre-empts the current one: the
/// previous toast is dismissed immediately and never queued, so the visible
/// message always matches the action the user just took.
void showToast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  // Drop whatever toast is on screen first. Without this, `showSnackBar`
  // queues the new message behind the old one, so the UI shows stale,
  // out-of-sync confirmations.
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: const TextStyle(fontSize: 13, color: Color(0xFFF7F8F8)),
      ),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF16181B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFF26282E)),
      ),
      duration: const Duration(seconds: 3),
    ),
  );
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {}
  await Alarm.init();
  await AlarmService.handleAlarmPayload(message.data);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // ignore: avoid_print
    print('[Firebase] Initialization error: $e');
  }

  await Alarm.init();
  await HapticService.initialize();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(const AlarmApp());
}

class AlarmApp extends StatelessWidget {
  const AlarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Remote Alarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF08090A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF5E6AD2),
          secondary: Color(0xFF8A8F98),
          surface: Color(0xFF141619),
          error: Color(0xFFEB5757),
        ),
        fontFamily: 'Helvetica Neue',
        fontFamilyFallback: const [
          'Helvetica',
          'Arial',
          'sans-serif',
        ],
      ),
      home: const AlarmHomeScreen(),
    );
  }
}

class AlarmHomeScreen extends StatefulWidget {
  const AlarmHomeScreen({super.key});

  @override
  State<AlarmHomeScreen> createState() => _AlarmHomeScreenState();
}

class _AlarmItem {
  final int id;
  DateTime dateTime;
  String title;
  String description;
  bool isEnabled;
  bool isSnoozed;
  List<int> repeatDays;
  int intervalWeeks;
  String? anchorDate;
  String soundTone;
  int rampSeconds;
  String? uuid;
  String status = 'pending';
  DateTime? missedAt;
  String? missedReason;

  _AlarmItem({
    required this.id,
    required this.dateTime,
    required this.title,
    required this.description,
    required this.isEnabled,
    required this.isSnoozed,
    required this.repeatDays,
    this.intervalWeeks = 1,
    this.anchorDate,
    required this.soundTone,
    required this.rampSeconds,
    this.uuid,
  });
}

class _SyncResult {
  final bool success;
  final int? syncedCount;
  _SyncResult({required this.success, this.syncedCount});
}

class _AlarmHomeScreenState extends State<AlarmHomeScreen> with WidgetsBindingObserver {
  List<_AlarmItem> _allAlarms = [];
  String? _fcmToken;
  String _backendUrl = 'http://127.0.0.1:3000';
  bool _isBackendConnected = true;
  String? _backendError;
  late Timer _clockTimer;
  Timer? _foregroundSyncTimer;
  StreamSubscription<AlarmSettings>? _ringSubscription;
  StreamSubscription<dynamic>? _ringingSetSubscription;
  StreamSubscription<int>? _remoteDismissSubscription;
  AlarmSettings? _currentlyRingingAlarm;
  bool _isRingScreenOpen = false;
  final Battery _battery = Battery();
  int? _batteryLevel;
  bool _isCharging = false;
  bool _isSyncing = false;
  bool _isSearchVisible = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final AudioPlayer _previewAudioPlayer = AudioPlayer();
  List<Map<String, dynamic>>? _lastRemoteAlarms;

  // Bulk multi-select mode state
  bool _isMultiSelectMode = false;
  final Set<int> _selectedAlarmIds = <int>{};

  Future<void> _previewTone(String tone) async {
    try {
      await _previewAudioPlayer.stop();
      final assetFile = tone == 'chime'
          ? 'chime.mp3'
          : (tone == 'digital' ? 'digital.mp3' : 'alarm.mp3');
      await _previewAudioPlayer.setVolume(0.85);
      await _previewAudioPlayer.play(AssetSource(assetFile));
      Future.delayed(const Duration(milliseconds: 3000), () {
        _previewAudioPlayer.stop();
      });
    } catch (_) {}
  }

  // Persistent Settings
  String _defaultSoundTone = 'alarm';
  int _defaultRampSeconds = 15;
  String _timeFormat = '24h';
  String _dateFormat = 'dd/mm/yyyy';

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _defaultSoundTone = prefs.getString('pref_sound_tone') ?? 'alarm';
      _defaultRampSeconds = prefs.getInt('pref_ramp_seconds') ?? 15;
      _timeFormat = prefs.getString('pref_time_format') ?? '24h';
      _dateFormat = prefs.getString('pref_date_format') ?? 'dd/mm/yyyy';
    });

    try {
      final remote = await BackendClient.fetchSettings();
      if (remote != null && mounted) {
        setState(() {
          if (remote['sound_tone'] != null) _defaultSoundTone = remote['sound_tone'] as String;
          if (remote['ramp_seconds'] != null) _defaultRampSeconds = (remote['ramp_seconds'] as num).toInt();
          if (remote['time_format'] != null) _timeFormat = remote['time_format'] as String;
          if (remote['date_format'] != null) _dateFormat = remote['date_format'] as String;
        });
        await prefs.setString('pref_sound_tone', _defaultSoundTone);
        await prefs.setInt('pref_ramp_seconds', _defaultRampSeconds);
        await prefs.setString('pref_time_format', _timeFormat);
        await prefs.setString('pref_date_format', _dateFormat);
      }
    } catch (_) {}
  }

  Future<void> _updateSetting(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (key == 'sound_tone') _defaultSoundTone = value as String;
      if (key == 'ramp_seconds') _defaultRampSeconds = value as int;
      if (key == 'time_format') _timeFormat = value as String;
      if (key == 'date_format') _dateFormat = value as String;
    });

    if (value is String) {
      await prefs.setString('pref_$key', value);
    } else if (value is int) {
      await prefs.setInt('pref_$key', value);
    } else if (value is bool) {
      await prefs.setBool('pref_$key', value);
    }

    if (key != 'time_picker_style') {
      await BackendClient.updateSettings({key: value});
    }
  }

  String _formatTime(DateTime dt) {
    return SettingsFormatter.formatTime(dt, _timeFormat);
  }

  String _formatDate(DateTime dt) {
    return SettingsFormatter.formatDate(dt, _dateFormat);
  }

  /// Render a date as a plain ISO date string (e.g. '2026-10-07') for the
  /// fortnightly recurrence anchor.
  String _isoDate(DateTime dt) {
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '${dt.year}-$month-$day';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAllAlarms();
    _initFCM();
    _loadBackendUrl().then((_) {
      _loadSettings();
      _syncWithBackend(silent: true);
    });

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        _checkActiveRingingAlarm();
      }
    });

    _foregroundSyncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) {
        _syncWithBackend(silent: true);
      }
    });

    // ignore: deprecated_member_use
    _ringSubscription = Alarm.ringStream.stream.listen((alarmSettings) {
      _handleAlarmFired(alarmSettings);
    });

    _ringingSetSubscription = Alarm.ringing.listen((alarmSet) {
      if (alarmSet.alarms.isNotEmpty) {
        _handleAlarmFired(alarmSet.alarms.first);
      } else {
        if (mounted && _currentlyRingingAlarm != null) {
          setState(() => _currentlyRingingAlarm = null);
        }
      }
    });

    _remoteDismissSubscription = AlarmService.onRemoteDismissed.stream.listen((_) {
      _loadAllAlarms();
      _checkActiveRingingAlarm();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkActiveRingingAlarm();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer.cancel();
    _foregroundSyncTimer?.cancel();
    _ringSubscription?.cancel();
    _ringingSetSubscription?.cancel();
    _remoteDismissSubscription?.cancel();
    _searchController.dispose();
    _previewAudioPlayer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncWithBackend(silent: true);
      _reportBatteryTelemetry();
      _checkActiveRingingAlarm();
      _ensureFullScreenIntentPermission();
    }
  }

  Future<void> _reportBatteryTelemetry() async {
    if (_fcmToken == null || _fcmToken!.startsWith('Firebase unavailable')) return;
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      final charging = state == BatteryState.charging || state == BatteryState.full;
      if (mounted) {
        setState(() {
          _batteryLevel = level;
          _isCharging = charging;
        });
      }
      await BackendClient.registerDeviceToken(
        _fcmToken!,
        batteryLevel: level,
        isCharging: charging,
        deviceName: 'Android Device',
      );
    } catch (e) {
      // ignore: avoid_print
      print('[Battery] Error collecting telemetry: $e');
    }
  }

  Future<_SyncResult> _syncWithBackend({bool silent = false}) async {
    if (_isSyncing) return _SyncResult(success: false);
    setState(() => _isSyncing = true);

    final isHealthy = await BackendClient.checkHealth(_backendUrl);
    if (!mounted) return _SyncResult(success: false);

    if (!isHealthy) {
      setState(() {
        _isSyncing = false;
        _isBackendConnected = false;
        _backendError = 'Server at $_backendUrl is unreachable';
      });
      if (!silent) {
        _showToast('cannot reach backend server');
        _showBackendConnectionModal();
      }
      return _SyncResult(success: false);
    }

    setState(() {
      _isBackendConnected = true;
      _backendError = null;
    });

    // Fetch the full alarm list so _loadAllAlarms can surface missed status,
    // audit fields, and reason. This is the second fetch the design expects
    // (AlarmService.syncWithBackend fetches the same view internally).
    final remoteAlarms = await BackendClient.fetchAllAlarms();
    if (mounted) {
      setState(() => _lastRemoteAlarms = remoteAlarms);
    }

    final count = await AlarmService.syncWithBackend();
    await _loadAllAlarms();
    await _reportBatteryTelemetry();
    if (mounted) {
      setState(() => _isSyncing = false);
      if (!silent) {
        _showToast('synced with backend ($count active alarms)');
      }
    }
    return _SyncResult(success: true, syncedCount: count);
  }

  Future<bool> _runConnectionTest(String url) async {
    final stopwatch = Stopwatch()..start();
    final ok = await BackendClient.checkHealth(url);
    final elapsed = stopwatch.elapsed;
    const minDuration = Duration(milliseconds: 300);
    if (elapsed < minDuration) {
      await Future.delayed(minDuration - elapsed);
    }
    return ok;
  }

  void _showBackendConnectionModal() {
    final controller = TextEditingController(text: _backendUrl);
    bool isTesting = false;
    String? testResult;
    bool? testSuccess;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F1013),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF26282E)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (builderCtx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(builderCtx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFF26282E),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isBackendConnected ? const Color(0xFF3DD68C) : const Color(0xFFE66432),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'backend connection',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFF7F8F8),
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF8A8F98)),
                        onPressed: () => Navigator.pop(sheetCtx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _isBackendConnected
                        ? 'Connected to $_backendUrl'
                        : 'Server at $_backendUrl is unreachable. If the app was reloaded or reinstalled, verify your backend URL below.',
                    style: TextStyle(
                      fontSize: 12,
                      color: _isBackendConnected ? const Color(0xFF8A8F98) : const Color(0xFFE66432),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // URL Input
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF16181B),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: testSuccess == false
                            ? const Color(0xFFE66432)
                            : (testSuccess == true ? const Color(0xFF3DD68C) : const Color(0xFF26282E)),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: TextField(
                      controller: controller,
                      style: const TextStyle(fontSize: 13, color: Color(0xFFF7F8F8)),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'http://127.0.0.1:3000',
                        hintStyle: TextStyle(color: Color(0xFF565A61)),
                      ),
                    ),
                  ),

                  if (testResult != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      testResult!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: testSuccess == true ? const Color(0xFF3DD68C) : const Color(0xFFE66432),
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),

                  // Quick presets
                  Row(
                    children: [
                      const Text(
                        'presets:',
                        style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          controller.text = 'http://127.0.0.1:3000';
                          setModalState(() {
                            testResult = null;
                            testSuccess = null;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C1F26),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF2E323D)),
                          ),
                          child: const Text('127.0.0.1:3000 (USB)', style: TextStyle(fontSize: 10, color: Color(0xFF8A8F98))),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () {
                          controller.text = 'http://10.0.2.2:3000';
                          setModalState(() {
                            testResult = null;
                            testSuccess = null;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C1F26),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF2E323D)),
                          ),
                          child: const Text('10.0.2.2:3000 (Emu)', style: TextStyle(fontSize: 10, color: Color(0xFF8A8F98))),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Guide info box
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121417),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF20232A)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'connection tips',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF8A8F98)),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '• USB cable: run "adb reverse tcp:3000 tcp:3000" on computer.\n• Wi-Fi: ensure phone & computer are on same Wi-Fi, and use your computer\'s IP (e.g. http://192.168.x.x:3000).',
                          style: TextStyle(fontSize: 11, color: Color(0xFF6B7280), height: 1.4),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            side: const BorderSide(color: Color(0xFF26282E)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: isTesting
                              ? null
                              : () async {
                                  setModalState(() {
                                    isTesting = true;
                                    testResult = 'testing connection...';
                                  });
                                  final ok = await _runConnectionTest(controller.text.trim());
                                  if (builderCtx.mounted) {
                                    setModalState(() {
                                      isTesting = false;
                                      testSuccess = ok;
                                      testResult = ok
                                          ? '✓ Reachable (HTTP 200 OK)'
                                          : '✕ Unreachable: verify URL or adb reverse';
                                    });
                                  }
                                },
                          child: isTesting
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFF7F8F8)),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'testing...',
                                      style: TextStyle(fontSize: 12, color: Color(0xFFF7F8F8)),
                                    ),
                                  ],
                                )
                              : const Text(
                                  'test connection',
                                  style: TextStyle(fontSize: 12, color: Color(0xFFF7F8F8)),
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF5E6AD2),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () async {
                            final newUrl = controller.text.trim();
                            if (newUrl.isNotEmpty) {
                              await BackendClient.setBaseUrl(newUrl);
                              if (mounted) {
                                setState(() => _backendUrl = newUrl);
                              }
                              if (sheetCtx.mounted) {
                                Navigator.pop(sheetCtx);
                              }
                              await _syncWithBackend();
                            }
                          },
                          child: const Text(
                            'save & sync',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _checkActiveRingingAlarm() async {
    try {
      final isRinging = await Alarm.isRinging();
      if (!isRinging) {
        if (mounted && _currentlyRingingAlarm != null) {
          setState(() => _currentlyRingingAlarm = null);
        }
        return;
      }

      // Check Alarm.ringing set
      final ringingSet = Alarm.ringing.value;
      if (ringingSet.alarms.isNotEmpty) {
        _handleAlarmFired(ringingSet.alarms.first);
        return;
      }

      // Query scheduled alarms to find which one is currently ringing
      final alarms = await Alarm.getAlarms();
      for (final a in alarms) {
        if (await Alarm.isRinging(a.id)) {
          _handleAlarmFired(a);
          return;
        }
      }

      if (alarms.isNotEmpty) {
        _handleAlarmFired(alarms.first);
      }
    } catch (e, st) {
      debugPrint('[RingScreen] _checkActiveRingingAlarm failed: $e\n$st');
    }
  }

  void _handleAlarmFired(AlarmSettings alarmSettings) {
    if (mounted) {
      setState(() => _currentlyRingingAlarm = alarmSettings);
    }
    _navigateToRingScreen(alarmSettings);
  }

  void _navigateToRingScreen(AlarmSettings alarmSettings) async {
    // Report `ringing` only if the alarm has not already been stopped (e.g. by
    // a remote silence): a stale report would overwrite the server's dismissed
    // state and the reconcile would re-arm the alarm. Fire-and-forget so the
    // ring screen still opens without waiting on the network.
    unawaited(AlarmService.reportRingingIfStillRinging(alarmSettings.id));

    if (_isRingScreenOpen) return;
    _isRingScreenOpen = true;

    final nav = navigatorKey.currentState;
    if (nav == null) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted && _isRingScreenOpen) {
          _isRingScreenOpen = false;
          _navigateToRingScreen(alarmSettings);
        }
      });
      return;
    }

    nav.push(
      MaterialPageRoute(
        builder: (context) => RingScreen(alarmSettings: alarmSettings),
      ),
    ).then((_) {
      _isRingScreenOpen = false;
      _loadAllAlarms();
      _checkActiveRingingAlarm();
    });
  }

  Future<void> _loadAllAlarms() async {
    // 1. Get active alarms from Alarm plugin
    final scheduledAlarms = await Alarm.getAlarms();
    final scheduledMap = {for (var a in scheduledAlarms) a.id: a};

    // 2. Get all known IDs from IdMapper storage
    final allKnownIds = await IdMapper.getAllKnownIds();
    final combinedIds = {...scheduledMap.keys, ...allKnownIds};

    final items = <_AlarmItem>[];

    for (final id in combinedIds) {
      final isScheduled = scheduledMap.containsKey(id);
      final isStoredEnabled = await IdMapper.isEnabled(id);
      final isEnabled = isScheduled && isStoredEnabled;

      DateTime dt;
      String label;

      if (isScheduled) {
        dt = scheduledMap[id]!.dateTime;
        label = scheduledMap[id]!.notificationSettings.title;
        if (label.isEmpty) {
          label = await IdMapper.getLabel(id) ?? 'Alarm';
        }
      } else {
        dt = await IdMapper.getTargetTime(id) ?? DateTime.now().add(const Duration(hours: 8));
        label = await IdMapper.getLabel(id) ?? 'Alarm';
      }

      final desc = await IdMapper.getDescription(id);
      final isSnoozed = await IdMapper.isSnoozed(id);
      final repeatDays = await IdMapper.getRepeatDays(id);
      final intervalWeeks = await IdMapper.getIntervalWeeks(id) ?? 1;
      final anchorDate = await IdMapper.getAnchorDate(id);
      final tone = await IdMapper.getSoundTone(id);
      final ramp = await IdMapper.getRampSeconds(id);
      final uuid = await IdMapper.getUuid(id);

      items.add(_AlarmItem(
        id: id,
        dateTime: dt,
        title: label,
        description: desc,
        isEnabled: isEnabled,
        isSnoozed: isSnoozed,
        repeatDays: repeatDays,
        intervalWeeks: intervalWeeks,
        anchorDate: anchorDate,
        soundTone: tone,
        rampSeconds: ramp,
        uuid: uuid,
      ));
    }

    // Merge backend status and missed audit fields from the last full fetch.
    // Missed alarms are excluded from view=active, so the active list alone
    // would silently drop them; this is what makes failures visible.
    if (_lastRemoteAlarms != null) {
      final remoteByUuid = <String, Map<String, dynamic>>{};
      for (final remote in _lastRemoteAlarms!) {
        final uuid = remote['id']?.toString();
        if (uuid != null && uuid.isNotEmpty) {
          remoteByUuid[uuid] = remote;
        }
      }
      for (final item in items) {
        final remote = remoteByUuid[item.uuid];
        if (remote == null) continue;
        item.status = remote['status']?.toString() ?? 'pending';
        final missedAtStr = remote['missed_at']?.toString();
        if (missedAtStr != null && missedAtStr.isNotEmpty) {
          item.missedAt = DateTime.tryParse(missedAtStr)?.toLocal();
        }
        item.missedReason = remote['missed_reason']?.toString();
      }
    }

    // Sort: enabled upcoming first, then disabled
    items.sort((a, b) {
      if (a.isEnabled && !b.isEnabled) return -1;
      if (!a.isEnabled && b.isEnabled) return 1;
      return a.dateTime.compareTo(b.dateTime);
    });

    if (mounted) {
      setState(() {
        _allAlarms = items;
      });
    }
  }

  Future<void> _toggleAlarmEnabled(_AlarmItem item, bool enable) async {
    // 1. Instant optimistic UI update on Frame 0 for zero-latency switch animation
    setState(() {
      item.isEnabled = enable;
    });

    if (enable) {
      HapticService.playArm();
      try {
        final target = AlarmService.computeFutureOccurrence(
          item.dateTime,
          repeatDays: item.repeatDays,
          intervalWeeks: item.intervalWeeks,
          anchorDate: item.anchorDate != null ? DateTime.tryParse(item.anchorDate!) : null,
        );

        final audioPath = AlarmService.getAudioPathForTone(item.soundTone);
        final settings = AlarmSettings(
          id: item.id,
          dateTime: target,
          assetAudioPath: audioPath,
          loopAudio: true,
          vibrate: true,
          volumeSettings: AlarmService.buildPerceptualVolumeSettings(item.rampSeconds),
          notificationSettings: NotificationSettings(
            title: item.title,
            body: 'Tap to dismiss or snooze',
            stopButton: 'stop',
          ),
        );

        await Alarm.set(alarmSettings: settings);
        await IdMapper.setEnabled(item.id, true);
        await IdMapper.setTargetTime(item.id, target);
        if (item.uuid != null && !item.uuid!.startsWith('local_')) {
          BackendClient.updateAlarmState(
            item.uuid!,
            'pending',
            targetTime: target.toUtc().toIso8601String(),
          );
        }
        _showToast('alarm armed for ${_formatTime(target)}');
      } catch (e) {
        setState(() {
          item.isEnabled = false;
        });
        _showToast('failed to arm alarm: $e');
      }
    } else {
      HapticService.playDisarm();
      try {
        await Alarm.stop(item.id);
        await IdMapper.setEnabled(item.id, false);
        if (item.uuid != null && !item.uuid!.startsWith('local_')) {
          BackendClient.updateAlarmState(item.uuid!, 'disabled');
        }
        _showToast('alarm deactivated');
      } catch (e) {
        setState(() {
          item.isEnabled = true;
        });
        _showToast('failed to deactivate: $e');
      }
    }

    await _loadAllAlarms();
  }

  Future<void> _deleteAlarmItem(_AlarmItem item, {bool announce = true}) async {
    await HapticService.playPreset(PresetHapticStyle.heavyLatch);
    await Alarm.stop(item.id);
    if (item.uuid != null && !item.uuid!.startsWith('local_')) {
      final deleteRemote = deleteRemoteAlarmForTest ?? BackendClient.deleteRemoteAlarm;
      await deleteRemote(item.uuid!);
    }
    await IdMapper.removeMapping(item.id);
    if (announce) {
      _showToast('alarm deleted');
      _loadAllAlarms();
    }
  }

  // ── Bulk multi-select ────────────────────────────────────────────────

  void _enterMultiSelect(int alarmId) {
    HapticService.selectionClick();
    setState(() {
      _isMultiSelectMode = true;
      _selectedAlarmIds.add(alarmId);
    });
  }

  void _exitMultiSelect() {
    HapticService.selectionClick();
    setState(() {
      _isMultiSelectMode = false;
      _selectedAlarmIds.clear();
    });
  }

  void _toggleAlarmSelection(int alarmId) {
    HapticService.selectionClick();
    setState(() {
      if (_selectedAlarmIds.contains(alarmId)) {
        _selectedAlarmIds.remove(alarmId);
        if (_selectedAlarmIds.isEmpty) {
          _isMultiSelectMode = false;
        }
      } else {
        _selectedAlarmIds.add(alarmId);
      }
    });
  }

  Future<void> _bulkDeleteSelected() async {
    final ids = List<int>.from(_selectedAlarmIds);
    if (ids.isEmpty) return;
    await HapticService.playPreset();
    final itemsToDelete = _allAlarms.where((a) => ids.contains(a.id)).toList();
    // Issue every removal at once. Awaiting them one-by-one serialised the
    // whole selection behind each alarm's network round-trip, which is the
    // "stare at the screen between each delete" the owner reported. The whole
    // batch is awaited as one, then the list refreshes once.
    await Future.wait(
      itemsToDelete.map((item) => _deleteAlarmItem(item, announce: false)),
    );
    if (!mounted) return;
    setState(() {
      _isMultiSelectMode = false;
      _selectedAlarmIds.clear();
    });
    _showToast('${itemsToDelete.length} alarm${itemsToDelete.length == 1 ? '' : 's'} deleted');
    _loadAllAlarms();
  }

  Future<void> _bulkDuplicateSelected() async {
    final ids = List<int>.from(_selectedAlarmIds);
    if (ids.isEmpty) return;
    await HapticService.playPreset();
    final itemsToDuplicate = _allAlarms.where((a) => ids.contains(a.id)).toList();
    for (final item in itemsToDuplicate) {
      // Exact copy with a fresh local identity.
      final newUuid = 'local_${DateTime.now().millisecondsSinceEpoch}_${item.id}';
      final intId = IdMapper.uuidToInt(newUuid);
      final newTitle = '${item.title} (copy)';

      // Next future occurrence (same computation as the arm flow) so an
      // enabled copy never rings immediately when the original's stored time
      // has already passed. The persisted target time stays identical to the
      // original, keeping the copy exact.
      final nextTarget = AlarmService.computeFutureOccurrence(
        item.dateTime,
        repeatDays: item.repeatDays,
        intervalWeeks: item.intervalWeeks,
        anchorDate: item.anchorDate != null ? DateTime.tryParse(item.anchorDate!) : null,
      );

      final audioPath = AlarmService.getAudioPathForTone(item.soundTone);
      final settings = AlarmSettings(
        id: intId,
        dateTime: nextTarget,
        assetAudioPath: audioPath,
        loopAudio: true,
        vibrate: true,
        volumeSettings: AlarmService.buildPerceptualVolumeSettings(item.rampSeconds),
        notificationSettings: NotificationSettings(
          title: newTitle,
          body: 'Tap to open alarm',
          stopButton: 'stop',
        ),
      );

      // Only schedule when the copy inherits the enabled state; disabled
      // copies stay unscheduled so they never fire in the OS alarm plugin.
      if (item.isEnabled) {
        await Alarm.set(alarmSettings: settings);
      }
      await IdMapper.saveMapping(
        intId,
        newUuid,
        label: newTitle,
        description: item.description,
        targetTime: item.dateTime,
        soundTone: item.soundTone,
        rampSeconds: item.rampSeconds,
        repeatDays: item.repeatDays,
      );
      await IdMapper.setSoundTone(intId, item.soundTone);
      await IdMapper.setRampSeconds(intId, item.rampSeconds);
      await IdMapper.setIntervalWeeks(intId, item.intervalWeeks);
      await IdMapper.setAnchorDate(intId, item.anchorDate);
      await IdMapper.setRepeatDays(intId, item.repeatDays);
      await IdMapper.setEnabled(intId, item.isEnabled);

      // Background backend sync (fire-and-forget) when the original has a
      // remote uuid, mirroring the Arm Alarm flow.
      if (item.uuid != null && !item.uuid!.startsWith('local_')) {
        BackendClient.createRemoteAlarm(
          targetTime: nextTarget,
          label: newTitle,
          description: item.description,
          repeatDays: item.repeatDays.isNotEmpty ? item.repeatDays : null,
          intervalWeeks: item.intervalWeeks > 1 ? item.intervalWeeks : null,
          anchorDate: item.anchorDate,
          soundTone: item.soundTone,
          rampSeconds: item.rampSeconds,
        ).then((remoteId) async {
          if (remoteId != null && remoteId != newUuid) {
            // Same canonical re-key as the Arm flow: without it the duplicated
            // alarm is echoed back under the canonical id and the provisional
            // copy is pruned a moment later, showing a duplicate.
            await AlarmService.adoptRemoteId(
              localIntId: intId,
              remoteUuid: remoteId,
              label: newTitle,
              description: item.description,
              targetTime: item.dateTime,
              repeatDays: item.repeatDays.isNotEmpty ? item.repeatDays : null,
              intervalWeeks: item.intervalWeeks,
              anchorDateIso: item.anchorDate,
              soundTone: item.soundTone,
              rampSeconds: item.rampSeconds,
            );
            _loadAllAlarms();
          }
        });
      }
    }
    if (!mounted) return;
    setState(() {
      _isMultiSelectMode = false;
      _selectedAlarmIds.clear();
    });
    _showToast('${itemsToDuplicate.length} alarm${itemsToDuplicate.length == 1 ? '' : 's'} duplicated');
    _loadAllAlarms();
  }

  void _rescheduleMissedAlarm(_AlarmItem item) {
    _openTimePickerSheet(
      context: context,
      initialTime: item.dateTime,
      repeatDays: item.repeatDays,
      initialIntervalWeeks: item.intervalWeeks,
      initialAnchorDate: item.anchorDate,
      onApplied: (newTime, newDays, newIntervalWeeks, newAnchorDate) async {
        // Guard against silently re-arming a stale one-time alarm.
        final anchorDate = newAnchorDate != null ? DateTime.tryParse(newAnchorDate) : null;
        final armTarget = AlarmService.computeArmTarget(
          newTime,
          repeatDays: newDays,
          intervalWeeks: newIntervalWeeks,
          anchorDate: anchorDate,
        );
        if (armTarget == null) {
          _showToast('cannot reschedule a one-time alarm to the past');
          return;
        }

        final finalTarget = newDays.isEmpty
            ? newTime
            : AlarmService.computeFutureOccurrence(
                newTime,
                repeatDays: newDays,
                intervalWeeks: newIntervalWeeks,
                anchorDate: anchorDate,
              );

        final audioPath = AlarmService.getAudioPathForTone(item.soundTone);
        final settings = AlarmSettings(
          id: item.id,
          dateTime: finalTarget,
          assetAudioPath: audioPath,
          loopAudio: true,
          vibrate: true,
          volumeSettings: AlarmService.buildPerceptualVolumeSettings(item.rampSeconds),
          notificationSettings: NotificationSettings(
            title: item.title,
            body: 'Tap to dismiss or snooze',
            stopButton: 'stop',
          ),
        );

        await Alarm.set(alarmSettings: settings);
        await IdMapper.saveMapping(
          item.id,
          item.uuid ?? 'local_${item.id}',
          label: item.title,
          description: item.description,
          targetTime: finalTarget,
          soundTone: item.soundTone,
          rampSeconds: item.rampSeconds,
          repeatDays: newDays,
        );
        await IdMapper.setIntervalWeeks(item.id, newIntervalWeeks);
        await IdMapper.setAnchorDate(item.id, newIntervalWeeks > 1 ? _isoDate(finalTarget) : null);
        await IdMapper.setEnabled(item.id, true);

        // Tell the backend this alarm is alive again with a new target time.
        if (item.uuid != null && !item.uuid!.startsWith('local_')) {
          await BackendClient.updateAlarmState(
            item.uuid!,
            'pending',
            targetTime: finalTarget.toUtc().toIso8601String(),
          );
        }

        _showToast('alarm rescheduled for ${_formatTime(finalTarget)}');
        await _syncWithBackend(silent: true);
      },
    );
  }

  String _getRelativeCountdown(DateTime target) {
    final now = DateTime.now();
    final diff = target.difference(now);

    if (diff.isNegative) return 'due now';

    return 'in ${formatRelativeDuration(diff)}';
  }

  String _formatRepeatDays(List<int> days, {int intervalWeeks = 1}) {
    if (days.isEmpty) return 'Once';
    if (intervalWeeks > 1) return 'Fortnightly';
    if (days.length == 7) return 'Every day';
    if (days.length == 5 &&
        days.contains(1) &&
        days.contains(2) &&
        days.contains(3) &&
        days.contains(4) &&
        days.contains(5)) {
      return 'Mon, Tue, Wed, Thu, Fri';
    }
    if (days.length == 2 && days.contains(6) && days.contains(7)) {
      return 'Sat, Sun';
    }
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days.map((d) => names[d - 1]).join(', ');
  }

  /// Render a date as a lowercase relative title: today / yesterday / tomorrow,
  /// a weekday name for offsets within ±2-7 days, or DD/MM/YYYY beyond that.
  String _relativeDateTitle(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(dt.year, dt.month, dt.day);
    final diff = target.difference(today).inDays;

    if (diff == 0) return 'today';
    if (diff == -1) return 'yesterday';
    if (diff == 1) return 'tomorrow';

    if (diff >= -7 && diff <= 7) {
      const names = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
      return names[target.weekday - 1];
    }

    final d = target.day.toString().padLeft(2, '0');
    final m = target.month.toString().padLeft(2, '0');
    return '$d/$m/${target.year}';
  }

  String _formatRepeatDaysOrDate(List<int> days, DateTime targetTime, {int intervalWeeks = 1}) {
    if (days.isNotEmpty) {
      return _formatRepeatDays(days, intervalWeeks: intervalWeeks);
    }
    return _relativeDateTitle(targetTime);
  }

  String _formatMicroPillRecurrence(List<int> days, DateTime targetTime, {int intervalWeeks = 1}) {
    if (intervalWeeks > 1 && days.isNotEmpty) {
      const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return 'Fortnightly · ${names[(days.first - 1) % 7]}';
    }
    if (days.length == 7) return 'Daily';
    if (days.length == 5 && [1, 2, 3, 4, 5].every(days.contains)) return 'Weekdays';
    if (days.length == 2 && days.contains(6) && days.contains(7)) return 'Weekends';
    if (days.isNotEmpty) {
      if (days.length <= 3) {
        const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        return days.map((d) => names[d - 1]).join(', ');
      }
      return '${days.length} days';
    }

    return _relativeDateTitle(targetTime);
  }

  String _formatMicroPillSound(String tone, int rampSec) {
    String toneName = 'radar';
    if (tone.toLowerCase() == 'chime') toneName = 'chime';
    if (tone.toLowerCase() == 'digital') toneName = 'digital';

    final rampName = rampSec <= 0 ? 'instant' : '${rampSec}s';
    return '$toneName • $rampName';
  }

  void _openTimeAndScheduleSheet({
    required BuildContext context,
    required DateTime initialTime,
    required List<int> initialDays,
    required int initialIntervalWeeks,
    required String? initialAnchorDate,
    required void Function(DateTime newTime, List<int> newDays, int intervalWeeks, String? anchorDate) onApplied,
  }) {
    final bool is12h = _timeFormat == '12h';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final initialDay = DateTime(initialTime.year, initialTime.month, initialTime.day);

    int curHour = initialTime.hour;
    int curMinute = initialTime.minute;
    List<int> curRepeatDays = List<int>.from(initialDays);
    int intervalWeeks = initialIntervalWeeks;
    String? anchorDate = initialAnchorDate;
    String recurrenceMode = curRepeatDays.isEmpty
        ? 'once'
        : (curRepeatDays.length == 7
            ? 'daily'
            : ((curRepeatDays.length == 5 && [1, 2, 3, 4, 5].every(curRepeatDays.contains))
                ? 'weekdays'
                : (initialIntervalWeeks > 1 ? 'fortnightly' : 'custom')));

    final isInitialPast = (curHour < now.hour) || (curHour == now.hour && curMinute <= now.minute);
    bool isTomorrow = false;
    DateTime? customDate;
    if (curRepeatDays.isEmpty) {
      if (initialDay.isAfter(tomorrow)) {
        customDate = initialDay;
      } else if (isInitialPast) {
        isTomorrow = true;
      } else {
        isTomorrow = initialDay.isAtSameMomentAs(tomorrow);
      }
    }

    DateTime curTime = DateTime(
      curRepeatDays.isNotEmpty
          ? initialDay.year
          : (customDate != null ? customDate.year : (isTomorrow ? tomorrow.year : today.year)),
      curRepeatDays.isNotEmpty
          ? initialDay.month
          : (customDate != null ? customDate.month : (isTomorrow ? tomorrow.month : today.month)),
      curRepeatDays.isNotEmpty
          ? initialDay.day
          : (customDate != null ? customDate.day : (isTomorrow ? tomorrow.day : today.day)),
      curHour,
      curMinute,
      0,
      0,
    );

    int hour12 = curHour % 12;
    if (hour12 == 0) hour12 = 12;
    bool isPm = curHour >= 12;

    final FixedExtentScrollController hourController = FixedExtentScrollController(
      initialItem: is12h ? (hour12 - 1) : curHour,
    );
    final FixedExtentScrollController minuteController = FixedExtentScrollController(
      initialItem: curMinute,
    );
    final FixedExtentScrollController amPmController = FixedExtentScrollController(
      initialItem: isPm ? 1 : 0,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16181B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF26282E)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (builderCtx, setSheetState) {
            final currentNow = DateTime.now();
            final isPastToday = (curHour < currentNow.hour) ||
                (curHour == currentNow.hour && curMinute <= currentNow.minute);

            final isOnce = recurrenceMode == 'once';
            final isDaily = recurrenceMode == 'daily';
            final isWeekdays = recurrenceMode == 'weekdays';
            final isFortnightly = recurrenceMode == 'fortnightly';
            final isCustom = recurrenceMode == 'custom';

            DateTime computeFinalTime(
              int h,
              int m, {
              bool? forceTomorrow,
              DateTime? forceCustomDate,
              bool clearCustom = false,
            }) {
              final n = DateTime.now();
              final isPast = (h < n.hour) || (h == n.hour && m <= n.minute);
              final targetCustom = clearCustom ? null : (forceCustomDate ?? customDate);
              bool targetTomorrow = forceTomorrow ?? isTomorrow;

              if (targetCustom != null && isOnce) {
                return DateTime(
                  targetCustom.year,
                  targetCustom.month,
                  targetCustom.day,
                  h,
                  m,
                  0,
                  0,
                );
              }

              if (isPast && isOnce) {
                targetTomorrow = true;
              }
              final tDay = DateTime(n.year, n.month, n.day);
              final tmrw = tDay.add(const Duration(days: 1));
              final targetDate = !isOnce
                  ? initialDay
                  : (targetTomorrow ? tmrw : tDay);
              return DateTime(
                targetDate.year,
                targetDate.month,
                targetDate.day,
                h,
                m,
                0,
                0,
              );
            }

            void updateTime({
              int? newH,
              int? newM,
              bool? newIsTomorrow,
              DateTime? newCustomDate,
              bool clearCustom = false,
            }) {
              final h = newH ?? curHour;
              final m = newM ?? curMinute;
              final n = DateTime.now();
              final isPast = (h < n.hour) || (h == n.hour && m <= n.minute);

              DateTime? targetCustom = clearCustom ? null : (newCustomDate ?? customDate);
              bool targetTomorrow = newIsTomorrow ?? isTomorrow;
              if (targetCustom == null && isPast && isOnce) {
                targetTomorrow = true;
              }

              final newDt = computeFinalTime(
                h,
                m,
                forceTomorrow: targetTomorrow,
                forceCustomDate: targetCustom,
                clearCustom: clearCustom,
              );
              setSheetState(() {
                curHour = h;
                curMinute = m;
                isTomorrow = targetTomorrow;
                customDate = targetCustom;
                curTime = newDt;
              });
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 14,
                bottom: MediaQuery.of(builderCtx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFF3A3F4A),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'set time & schedule',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFF7F8F8),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          HapticService.selectionClick();
                          onApplied(curTime, curRepeatDays, intervalWeeks, anchorDate);
                          Navigator.pop(sheetCtx);
                        },
                        child: const Text(
                          'done',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF5E6AD2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Definitive 3D Drum Tumbler
                  DrumTumblerPicker(
                    curHour: curHour,
                    curMinute: curMinute,
                    is12h: is12h,
                    hourController: hourController,
                    minuteController: minuteController,
                    amPmController: amPmController,
                    onHourChanged: (newH) => updateTime(newH: newH),
                    onMinuteChanged: (newM) => updateTime(newM: newM),
                    onAmPmChanged: (newIsPm) {
                      isPm = newIsPm;
                      int h12 = curHour % 12;
                      if (h12 == 0) h12 = 12;
                      final newHour = isPm ? (h12 == 12 ? 12 : h12 + 12) : (h12 == 12 ? 0 : h12);
                      updateTime(newH: newHour);
                    },
                  ),

                  const SizedBox(height: 14),

                  // Repeats section label.
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      'repeats',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Recurrence Mode Chips.
                  SegmentedStackedChipRow(
                    labels: const [
                      'Once',
                      'Daily',
                      'Weekdays',
                      'Fortnightly',
                      'Custom',
                    ],
                    selectedIndex: isOnce
                        ? 0
                        : isDaily
                            ? 1
                            : isWeekdays
                                ? 2
                                : isFortnightly
                                    ? 3
                                    : isCustom
                                        ? 4
                                        : 0,
                    onSelect: (i) {
                      HapticService.selectionClick();
                      switch (i) {
                        case 0:
                          setSheetState(() {
                            recurrenceMode = 'once';
                            curRepeatDays.clear();
                            intervalWeeks = 1;
                            anchorDate = null;
                          });
                          updateTime();
                          break;
                        case 1:
                          setSheetState(() {
                            recurrenceMode = 'daily';
                            curRepeatDays = [1, 2, 3, 4, 5, 6, 7];
                            intervalWeeks = 1;
                            anchorDate = null;
                          });
                          updateTime(clearCustom: true);
                          break;
                        case 2:
                          setSheetState(() {
                            recurrenceMode = 'weekdays';
                            curRepeatDays = [1, 2, 3, 4, 5];
                          });
                          updateTime(clearCustom: true);
                          break;
                        case 3:
                          setSheetState(() {
                            recurrenceMode = 'fortnightly';
                            intervalWeeks = 2;
                            curRepeatDays = [curTime.weekday];
                            anchorDate = _isoDate(curTime);
                          });
                          updateTime(clearCustom: true);
                          break;
                        case 4:
                        default:
                          setSheetState(() {
                            recurrenceMode = 'custom';
                            curRepeatDays.clear();
                            intervalWeeks = 1;
                            anchorDate = null;
                          });
                          updateTime(clearCustom: true);
                      }
                    },
                  ),

                  // Animated Slide-out: Dynamic Date Row if Once, Day Circles if Repeating
                  AnimatedCrossFade(
                    duration: const Duration(milliseconds: 220),
                    firstCurve: Curves.easeInOut,
                    secondCurve: Curves.easeInOut,
                    crossFadeState: isOnce ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                    firstChild: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(
                        children: [
                          // "Today" - Fixed size with animated strike-through when time has passed today
                          Expanded(
                            child: GestureDetector(
                              onTap: isPastToday
                                  ? null
                                  : () {
                                      HapticService.selectionClick();
                                      updateTime(newIsTomorrow: false, clearCustom: true);
                                    },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                height: 38,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: (!isTomorrow && customDate == null && !isPastToday)
                                      ? const Color(0xFF5E6AD2)
                                      : const Color(0xFF101215),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: (!isTomorrow && customDate == null && !isPastToday)
                                        ? const Color(0xFF5E6AD2)
                                        : const Color(0xFF26282E),
                                  ),
                                ),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    TweenAnimationBuilder<double>(
                                      tween: Tween(begin: isPastToday ? 0.0 : 1.0, end: isPastToday ? 1.0 : 0.0),
                                      duration: const Duration(milliseconds: 220),
                                      curve: Curves.easeOutCubic,
                                      builder: (_, value, child) => CustomPaint(
                                        foregroundPainter: _DirectionalStrikePainter(value),
                                        child: child,
                                      ),
                                      child: AnimatedDefaultTextStyle(
                                        duration: const Duration(milliseconds: 200),
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: (!isTomorrow && customDate == null && !isPastToday)
                                              ? FontWeight.w600 : FontWeight.w500,
                                          color: isPastToday
                                              ? const Color(0xFF4A4E58)
                                              : ((!isTomorrow && customDate == null)
                                                  ? Colors.white
                                                  : const Color(0xFF8A8F98)),
                                        ),
                                        child: const Text('today'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),

                          // "Tomorrow" - Fixed size
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                HapticService.selectionClick();
                                updateTime(newIsTomorrow: true, clearCustom: true);
                              },
                              child: Container(
                                height: 38,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: (isTomorrow && customDate == null)
                                      ? const Color(0xFF5E6AD2)
                                      : const Color(0xFF101215),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: (isTomorrow && customDate == null)
                                        ? const Color(0xFF5E6AD2)
                                        : const Color(0xFF26282E),
                                  ),
                                ),
                                child: Text(
                                  'tomorrow',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: (isTomorrow && customDate == null)
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: (isTomorrow && customDate == null)
                                        ? Colors.white
                                        : const Color(0xFF8A8F98),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),

                          // "Pick Date 📅" / Custom Future Date Pill - Fixed size
                          Expanded(
                            child: GestureDetector(
                              onTap: () async {
                                HapticService.selectionClick();
                                final picked = await showCustomCalendarPicker(
                                  context: context,
                                  initialDate: customDate ?? (isTomorrow ? tomorrow : (isPastToday ? tomorrow : today)),
                                  firstDate: isPastToday ? tomorrow : today,
                                  lastDate: DateTime(today.year + 5, today.month, today.day),
                                );
                                if (picked != null) {
                                  final pickedDay = DateTime(picked.year, picked.month, picked.day);
                                  if (pickedDay.isAtSameMomentAs(today) && !isPastToday) {
                                    updateTime(newIsTomorrow: false, clearCustom: true);
                                  } else if (pickedDay.isAtSameMomentAs(tomorrow)) {
                                    updateTime(newIsTomorrow: true, clearCustom: true);
                                  } else {
                                    updateTime(newIsTomorrow: false, newCustomDate: pickedDay);
                                  }
                                }
                              },
                              child: Container(
                                height: 38,
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: customDate != null
                                      ? const Color(0xFF5E6AD2)
                                      : const Color(0xFF101215),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: customDate != null
                                        ? const Color(0xFF5E6AD2)
                                        : const Color(0xFF26282E),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.calendar_today_rounded,
                                      size: 12,
                                      color: customDate != null ? Colors.white : const Color(0xFF8A8F98),
                                    ),
                                    const SizedBox(width: 5),
                                    Flexible(
                                      child: Text(
                                        customDate != null
                                            ? '${customDate!.day}/${customDate!.month}'
                                            : 'pick date',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: customDate != null ? FontWeight.w600 : FontWeight.w500,
                                          color: customDate != null ? Colors.white : const Color(0xFF8A8F98),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    secondChild: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _buildWeekdaySelector(
                        selectedDays: curRepeatDays,
                        intervalWeeks: intervalWeeks,
                        onChanged: (newDays) {
                          setSheetState(() {
                            curRepeatDays = newDays;
                            intervalWeeks = 1;
                            anchorDate = null;
                            if (newDays.length == 7) {
                              recurrenceMode = 'daily';
                            } else if (newDays.length == 5 && [1, 2, 3, 4, 5].every(newDays.contains)) {
                              recurrenceMode = 'weekdays';
                            } else {
                              recurrenceMode = 'custom';
                            }
                          });
                          updateTime();
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openTimePickerSheet({
    required BuildContext context,
    required DateTime initialTime,
    required List<int> repeatDays,
    required int initialIntervalWeeks,
    required String? initialAnchorDate,
    required void Function(DateTime newTime, List<int> newDays, int intervalWeeks, String? anchorDate) onApplied,
  }) {
    _openTimeAndScheduleSheet(
      context: context,
      initialTime: initialTime,
      initialDays: repeatDays,
      initialIntervalWeeks: initialIntervalWeeks,
      initialAnchorDate: initialAnchorDate,
      onApplied: (newTime, newDays, intervalWeeks, anchorDate) {
        onApplied(newTime, newDays, intervalWeeks, anchorDate);
      },
    );
  }

  void _openRecurrenceSheet({
    required BuildContext context,
    required List<int> initialDays,
    required DateTime initialTime,
    required int initialIntervalWeeks,
    required String? initialAnchorDate,
    required void Function(List<int> newDays, DateTime newTime, int intervalWeeks, String? anchorDate) onApplied,
  }) {
    _openTimeAndScheduleSheet(
      context: context,
      initialTime: initialTime,
      initialDays: initialDays,
      initialIntervalWeeks: initialIntervalWeeks,
      initialAnchorDate: initialAnchorDate,
      onApplied: (newTime, newDays, intervalWeeks, anchorDate) {
        onApplied(newDays, newTime, intervalWeeks, anchorDate);
      },
    );
  }

  void _openSoundSheet({
    required BuildContext context,
    required String initialTone,
    required int initialRamp,
    required void Function(String newTone, int newRamp) onApplied,
  }) {
    String curTone = initialTone;
    int curRamp = initialRamp;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16181B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF26282E)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (builderCtx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(builderCtx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFF3A3F4A),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'sound & gentle ramp',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFF7F8F8),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          onApplied(curTone, curRamp);
                          Navigator.pop(sheetCtx);
                        },
                        child: const Text(
                          'done',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF5E6AD2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Sound Tone
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'sound tone',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF8A8F98),
                        ),
                      ),
                      const Text(
                        'Tap to audition',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFF565A61),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildLinearSegmentedControl<String>(
                    values: const ['alarm', 'chime', 'digital'],
                    selectedValue: curTone,
                    labels: const ['radar', 'chime', 'digital'],
                    icons: const [
                      Icons.volume_up_rounded,
                      Icons.volume_up_rounded,
                      Icons.volume_up_rounded,
                    ],
                    onSelected: (val) {
                      setSheetState(() => curTone = val);
                      _previewTone(val);
                    },
                  ),

                  const SizedBox(height: 18),

                  // Gentle Ramp
                  const Text(
                    'gentle volume ramp',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF8A8F98),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Power 4.0 logarithmic curve keeps volume under 32% for 75% of duration',
                    style: TextStyle(
                      fontSize: 10,
                      color: Color(0xFF565A61),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildLinearSegmentedControl<int>(
                    values: const [0, 15, 30, 60],
                    selectedValue: curRamp,
                    labels: const ['0s instant', '15s', '30s', '60s'],
                    onSelected: (val) => setSheetState(() => curRamp = val),
                  ),

                  const SizedBox(height: 20),

                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5E6AD2),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        onApplied(curTone, curRamp);
                        Navigator.pop(sheetCtx);
                      },
                      child: const Text(
                        'save sound settings',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLinearSegmentedControl<T>({
    required List<T> values,
    required T selectedValue,
    required List<String> labels,
    required ValueChanged<T> onSelected,
    List<IconData?>? icons,
  }) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF16181B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF26282E)),
      ),
      child: Row(
        children: List.generate(values.length, (index) {
          final val = values[index];
          final label = labels[index];
          final isSelected = val == selectedValue;
          final icon = icons != null && index < icons.length ? icons[index] : null;

          return Expanded(
            child: GestureDetector(
              onTap: () => onSelected(val),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: isSelected ? const Color(0xFF5E6AD2) : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(
                        icon,
                        size: 13,
                        color: isSelected ? Colors.white : const Color(0xFF8A8F98),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                          color: isSelected ? Colors.white : const Color(0xFF8A8F98),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildWeekdaySelector({
    required List<int> selectedDays,
    required ValueChanged<List<int>> onChanged,
    int intervalWeeks = 1,
  }) {
    const dayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S']; // 1=Mon ... 7=Sun
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(7, (index) {
            final dayNum = index + 1;
            final isSelected = selectedDays.contains(dayNum);
            return GestureDetector(
              onTap: () {
                final newDays = List<int>.from(selectedDays);
                if (isSelected) {
                  newDays.remove(dayNum);
                } else {
                  newDays.add(dayNum);
                  newDays.sort();
                }
                onChanged(newDays);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: isSelected ? const Color(0xFF5E6AD2) : const Color(0xFF16181B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? const Color(0xFF5E6AD2) : const Color(0xFF26282E),
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  dayLabels[index],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isSelected ? Colors.white : const Color(0xFF8A8F98),
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }



  Future<void> _loadBackendUrl() async {
    final url = await BackendClient.getBaseUrl();
    if (mounted) {
      setState(() => _backendUrl = url);
    }
  }

  Future<void> _initFCM() async {
    // Native → Dart bridge: the alarm plugin's full-screen notification can
    // deliver a fresh intent (com.gdelataillade.alarm.action.RING) while the
    // activity is already alive. Register once, reusing the permissions channel.
    const permChannel = MethodChannel('com.remotealarm.mobile/permissions');
    permChannel.setMethodCallHandler((call) async {
      if (call.method == 'onLaunchIntentAction') {
        final action = call.arguments as String?;
        if (action == 'com.gdelataillade.alarm.action.RING' && mounted) {
          // Defer until next frame so any in-progress navigation completes
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted) return;
            if (await Alarm.isRinging()) {
              _checkActiveRingingAlarm();
            }
          });
        }
      }
      return null;
    });

    // Cold-start: if the app was launched by the alarm plugin's full-screen
    // notification intent, pick it up once on the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        const ch = MethodChannel('com.remotealarm.mobile/permissions');
        final action = await ch.invokeMethod<String>('getLaunchIntentAction');
        if (action == 'com.gdelataillade.alarm.action.RING' && mounted) {
          if (await Alarm.isRinging()) _checkActiveRingingAlarm();
        }
      } catch (_) {}
    });

    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        criticalAlert: true,
      );

      final token = await messaging.getToken();
      if (mounted) {
        setState(() => _fcmToken = token);
      }

      // Re-register a rotated token without a cold start. This closes the
      // cold-start-only hole that caused the original `NotRegistered` outage.
      FirebaseMessaging.instance.onTokenRefresh.listen(registerToken);
      if (_fcmToken != null) {
        unawaited(registerToken(_fcmToken!));
      }

      if (token != null) {
        _reportBatteryTelemetry();
      }

      FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
        await AlarmService.handleAlarmPayload(message.data);
        // A foreground receipt is a poke: apply it, then pull authoritative
        // state so a dropped or stale poke converges (spec §5.3).
        unawaited(_syncWithBackend(silent: true));
        _loadAllAlarms();
      });

      // Tapping a notification while the app is in background → navigate if an alarm is ringing
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
        await AlarmService.handleAlarmPayload(message.data);
        unawaited(_syncWithBackend(silent: true));
        _loadAllAlarms();
        if (await Alarm.isRinging()) {
          _checkActiveRingingAlarm();
        }
      });

      // App was launched cold from a notification tap
      final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
      if (initialMessage != null) {
        await AlarmService.handleAlarmPayload(initialMessage.data);
        unawaited(_syncWithBackend(silent: true));
        _loadAllAlarms();
        // Defer until first frame so the navigator is mounted
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          if (await Alarm.isRinging()) {
            _checkActiveRingingAlarm();
          }
        });
      }

      _ensureFullScreenIntentPermission();
      _ensureBatteryOptimizationExemption();
    } catch (e) {
      if (mounted) {
        setState(() => _fcmToken = 'Firebase unavailable: $e');
      }
    }
  }

  /// Best-effort check that Android 14+ full-screen-intent permission is granted
  /// (required for the alarm plugin's notification to actually surface as
  /// full-screen). If not granted, show a snackbar with a button to open the
  /// relevant system Settings page. The prompt is rate-limited (re-shown at most
  /// every ~2 hours, or immediately when [force] is true) so a missed prompt is
  /// re-shown on later launches/resumes instead of never.
  Future<void> _ensureFullScreenIntentPermission({bool force = false}) async {
    try {
      const channel = MethodChannel('com.remotealarm.mobile/permissions');
      final granted = await channel.invokeMethod<bool>('canUseFullScreenIntent') ?? false;
      if (granted) return;

      final prefs = await SharedPreferences.getInstance();
      final lastShownMs = prefs.getInt('fsi_prompt_last_shown_ms') ?? 0;
      final elapsedMs = DateTime.now().millisecondsSinceEpoch - lastShownMs;
      const rePromptAfter = Duration(hours: 2);
      if (!force && elapsedMs < rePromptAfter.inMilliseconds) return;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF16181B),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 10),
          content: const Text(
            'Enable "Use full screen" notifications so alarms can wake you even on lock screen.',
            style: TextStyle(color: Color(0xFFF7F8F8), fontSize: 13),
          ),
          action: SnackBarAction(
            label: 'open',
            textColor: const Color(0xFF5E6AD2),
            onPressed: () {
              channel.invokeMethod('openFullScreenIntentSettings');
            },
          ),
        ),
      );

      await prefs.setInt(
        'fsi_prompt_last_shown_ms',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // Best-effort; never block app startup on a permission check failure.
    }
  }

  /// Best-effort check that the app is exempt from Android battery optimization
  /// (needed for alarms and push to stay reliable in the background). If not
  /// exempt, show a snackbar with a button to open the relevant system Settings
  /// page. The prompt is rate-limited (re-shown at most every ~2 hours, or
  /// immediately when [force] is true) so a missed prompt is re-shown on later
  /// launches/resumes instead of never.
  Future<void> _ensureBatteryOptimizationExemption({bool force = false}) async {
    try {
      const channel = MethodChannel('com.remotealarm.mobile/permissions');
      final exempt = await channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? true;
      if (exempt) return;

      final prefs = await SharedPreferences.getInstance();
      final lastShownMs = prefs.getInt('battery_prompt_last_shown_ms') ?? 0;
      final elapsedMs = DateTime.now().millisecondsSinceEpoch - lastShownMs;
      const rePromptAfter = Duration(hours: 2);
      if (!force && elapsedMs < rePromptAfter.inMilliseconds) return;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF16181B),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 10),
          content: const Text(
            'Allow the app to ignore battery optimization so alarms and push stay reliable in the background.',
            style: TextStyle(color: Color(0xFFF7F8F8), fontSize: 13),
          ),
          action: SnackBarAction(
            label: 'open',
            textColor: const Color(0xFF5E6AD2),
            onPressed: () {
              channel.invokeMethod('openBatteryOptimizationSettings');
            },
          ),
        ),
      );

      await prefs.setInt(
        'battery_prompt_last_shown_ms',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // Best-effort; never block app startup on a permission check failure.
    }
  }

  void _showToast(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  // ALARM DETAIL & ADJUSTMENTS MODAL
  void _showAlarmDetailModal(_AlarmItem item) {
    final titleController = TextEditingController(text: item.title);
    final descController = TextEditingController(text: item.description);
    DateTime selectedTime = item.dateTime;
    List<int> repeatDays = List.from(item.repeatDays);
    int intervalWeeks = item.intervalWeeks;
    String? anchorDate = item.anchorDate;
    String tone = item.soundTone;
    int ramp = item.rampSeconds;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F1013),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF26282E)),
      ),
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (builderContext, setModalState) {
            final formattedTime = _formatTime(selectedTime);

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(builderContext).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFF26282E),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'alarm details & adjustments',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFF7F8F8),
                            letterSpacing: -0.2,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF8A8F98)),
                          onPressed: () => Navigator.pop(bottomSheetContext),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // HERO MICRO-PILLS CARD
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16181B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF26282E)),
                      ),
                      child: Column(
                        children: [
                          // Large Time Display
                          GestureDetector(
                            onTap: () {
                              _openTimePickerSheet(
                                context: builderContext,
                                initialTime: selectedTime,
                                repeatDays: repeatDays,
                                initialIntervalWeeks: intervalWeeks,
                                initialAnchorDate: anchorDate,
                                onApplied: (newTime, newDays, newIntervalWeeks, newAnchorDate) {
                                  setModalState(() {
                                    selectedTime = newTime;
                                    repeatDays = newDays;
                                    intervalWeeks = newIntervalWeeks;
                                    anchorDate = newAnchorDate;
                                  });
                                },
                              );
                            },
                            child: Column(
                              children: [
                                Text(
                                  formattedTime,
                                    style: const TextStyle(
                                      fontSize: 50,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFFF7F8F8),
                                      letterSpacing: -1.0,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _getRelativeCountdown(AlarmService.computeFutureOccurrence(
                                      selectedTime,
                                      repeatDays: repeatDays,
                                      intervalWeeks: intervalWeeks,
                                      anchorDate: anchorDate != null ? DateTime.tryParse(anchorDate ?? '') : null,
                                    )),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFF5E6AD2),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 16),

                            // Micro-Pills Row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Recurrence Pill
                                GestureDetector(
                                  onTap: () {
                                    _openRecurrenceSheet(
                                      context: builderContext,
                                      initialDays: repeatDays,
                                      initialTime: selectedTime,
                                      initialIntervalWeeks: intervalWeeks,
                                      initialAnchorDate: anchorDate,
                                      onApplied: (newDays, newTime, newIntervalWeeks, newAnchorDate) {
                                        setModalState(() {
                                          repeatDays = newDays;
                                          selectedTime = newTime;
                                          intervalWeeks = newIntervalWeeks;
                                          anchorDate = newAnchorDate;
                                        });
                                      },
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF20232A),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: const Color(0xFF2E323D)),
                                    ),
                                    child: Text(
                                      _formatMicroPillRecurrence(repeatDays, selectedTime, intervalWeeks: intervalWeeks),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFF7F8F8),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),

                                // Sound & Ramp Pill
                                GestureDetector(
                                  onTap: () {
                                    _openSoundSheet(
                                      context: builderContext,
                                      initialTone: tone,
                                      initialRamp: ramp,
                                      onApplied: (newTone, newRamp) {
                                        setModalState(() {
                                          tone = newTone;
                                          ramp = newRamp;
                                        });
                                      },
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF20232A),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: const Color(0xFF2E323D)),
                                    ),
                                    child: Text(
                                      _formatMicroPillSound(tone, ramp),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFF7F8F8),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 16),
                            const Divider(color: Color(0xFF26282E), height: 1),
                            const SizedBox(height: 12),

                            // Inline Title Field
                            TextField(
                              controller: titleController,
                              textAlign: TextAlign.center,
                              textCapitalization: TextCapitalization.none,
                              autocorrect: false,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFFF7F8F8)),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                hintText: 'alarm title...',
                                hintStyle: TextStyle(color: Color(0xFF565A61)),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Description & Notes Container
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF16181B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF26282E)),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: TextField(
                          controller: descController,
                          maxLines: 2,
                          textCapitalization: TextCapitalization.none,
                          autocorrect: false,
                          style: const TextStyle(fontSize: 12, color: Color(0xFFF7F8F8), height: 1.4),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            hintText: 'Optional notes, checklist, or routine...',
                            hintStyle: TextStyle(color: Color(0xFF565A61), fontSize: 12),
                          ),
                        ),
                      ),

                    const SizedBox(height: 24),

                    // Actions Row (Save + Delete)
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFF7F8F8),
                                foregroundColor: const Color(0xFF08090A),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: () async {
                                await HapticService.playArm();
                                final updatedTitle = titleController.text.trim().isNotEmpty
                                    ? titleController.text.trim()
                                    : 'Alarm';
                                final updatedDesc = descController.text.trim();

                                DateTime finalTarget;
                                if (repeatDays.isNotEmpty) {
                                  finalTarget = AlarmService.computeFutureOccurrence(
                                    selectedTime,
                                    repeatDays: repeatDays,
                                    intervalWeeks: intervalWeeks,
                                    anchorDate: anchorDate != null ? DateTime.tryParse(anchorDate ?? '') : null,
                                  );
                                } else {
                                  finalTarget = AlarmService.computeFutureOccurrence(selectedTime);
                                }

                                item.title = updatedTitle;
                                item.description = updatedDesc;
                                item.dateTime = finalTarget;
                                item.soundTone = tone;
                                item.rampSeconds = ramp;
                                item.repeatDays = repeatDays;
                                item.intervalWeeks = intervalWeeks;
                                item.anchorDate = intervalWeeks > 1 ? _isoDate(finalTarget) : null;

                                await IdMapper.saveMapping(
                                  item.id,
                                  item.uuid ?? 'local_${item.id}',
                                  label: updatedTitle,
                                  description: updatedDesc,
                                  targetTime: finalTarget,
                                  soundTone: tone,
                                  rampSeconds: ramp,
                                  repeatDays: repeatDays,
                                );
                                await IdMapper.setIntervalWeeks(item.id, intervalWeeks);
                                await IdMapper.setAnchorDate(item.id, intervalWeeks > 1 ? _isoDate(finalTarget) : null);

                                // Pop immediately, sync in background
                                if (bottomSheetContext.mounted) {
                                  Navigator.pop(bottomSheetContext);
                                }
                                _showToast('adjustments saved');

                                // Background sync — fire-and-forget
                                if (item.uuid != null && !item.uuid!.startsWith('local_')) {
                                  BackendClient.updateRemoteAlarm(
                                    item.uuid!,
                                    targetTime: finalTarget,
                                    label: updatedTitle,
                                    description: updatedDesc,
                                    repeatDays: repeatDays,
                                    intervalWeeks: intervalWeeks,
                                    anchorDate: item.anchorDate,
                                    soundTone: tone,
                                    rampSeconds: ramp,
                                  );
                                }
                                if (item.isEnabled) {
                                  _toggleAlarmEnabled(item, true);
                                } else {
                                  _loadAllAlarms();
                                }
                              },
                              child: const Text(
                                'save adjustments',
                                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          height: 48,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFEB5757),
                              side: const BorderSide(color: Color(0xFF381F22)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: () async {
                              Navigator.pop(bottomSheetContext);
                              await _deleteAlarmItem(item);
                            },
                            child: const Text('delete'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // SETTINGS & CONFIGURATION MODAL
  void _showSettingsModal() {
    final controller = TextEditingController(text: _backendUrl);
    bool isTesting = false;
    bool isSaving = false;
    String? saveResult;
    bool? saveSuccess;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F1013),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF26282E)),
      ),
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (builderContext, setModalState) {
            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(builderContext).size.height * 0.88,
              ),
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(builderContext).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFF26282E),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'settings & configuration',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFF7F8F8),
                            letterSpacing: -0.2,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF8A8F98)),
                          onPressed: () => Navigator.pop(bottomSheetContext),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // SECTION 1: ALARM CONFIGURATION
                    const Text(
                      'alarm configuration',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Sound Tone Dropdown
                    _buildModalDropdown<String>(
                      label: 'default sound profile',
                      description: 'audio feedback sequence played when alarm triggers',
                      value: _defaultSoundTone,
                      items: const [
                        DropdownMenuItem(value: 'alarm', child: Text('ding (default alarm)')),
                        DropdownMenuItem(value: 'chime', child: Text('chime (gentle)')),
                        DropdownMenuItem(value: 'digital', child: Text('digital pulse')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setModalState(() => _defaultSoundTone = val);
                          _updateSetting('sound_tone', val);
                        }
                      },
                    ),
                    const SizedBox(height: 8),

                    // Tone Previews
                    Row(
                      children: [
                        _previewToneButton('ding', 'alarm'),
                        const SizedBox(width: 8),
                        _previewToneButton('chime', 'chime'),
                        const SizedBox(width: 8),
                        _previewToneButton('digital', 'digital'),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Ramp Seconds Dropdown
                    _buildModalDropdown<int>(
                      label: 'volume ramp duration',
                      description: 'gradual volume increase curve to prevent abrupt awakening',
                      value: _defaultRampSeconds,
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('immediate (0s)')),
                        DropdownMenuItem(value: 15, child: Text('gentle (15s)')),
                        DropdownMenuItem(value: 30, child: Text('standard (30s)')),
                        DropdownMenuItem(value: 60, child: Text('deep sleep ramp (60s)')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setModalState(() => _defaultRampSeconds = val);
                          _updateSetting('ramp_seconds', val);
                        }
                      },
                    ),

                    const SizedBox(height: 24),

                    // SECTION 2: DISPLAY & FORMATTING
                    const Text(
                      'display & formatting rules',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Time Format
                    _buildModalDropdown<String>(
                      label: 'time format convention',
                      description: 'clock readout and alarm time formatting rules',
                      value: _timeFormat,
                      items: const [
                        DropdownMenuItem(value: '24h', child: Text('24-hour (14:30)')),
                        DropdownMenuItem(value: '12h', child: Text('12-hour am/pm (02:30 pm)')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setModalState(() => _timeFormat = val);
                          _updateSetting('time_format', val);
                        }
                      },
                    ),

                    const SizedBox(height: 16),

                    // Date Format
                    _buildModalDropdown<String>(
                      label: 'date format convention',
                      description: 'standard system timestamp display layout',
                      value: _dateFormat,
                      items: const [
                        DropdownMenuItem(value: 'dd/mm/yyyy', child: Text('dd/mm/yyyy (19/09/2026)')),
                        DropdownMenuItem(value: 'mm/dd/yyyy', child: Text('mm/dd/yyyy (09/19/2026)')),
                        DropdownMenuItem(value: 'yyyy-mm-dd', child: Text('iso 8601 (2026-09-19)')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setModalState(() => _dateFormat = val);
                          _updateSetting('date_format', val);
                        }
                      },
                    ),

                    const SizedBox(height: 24),

                    // SECTION 3: CALENDAR FEED
                    const Text(
                      'calendar subscription (RFC 5545)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy_rounded, size: 14),
                        label: const Text('copy iCal Feed URL', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: const Color(0xFF16181B),
                          foregroundColor: const Color(0xFFF7F8F8),
                          side: const BorderSide(color: Color(0xFF26282E)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () async {
                          final url = '$_backendUrl/api/calendar.ics';
                          await Clipboard.setData(ClipboardData(text: url));
                          _showToast('copied iCal URL to clipboard');
                        },
                      ),
                    ),

                    const SizedBox(height: 24),

                    // SECTION 4: SERVER & DEVICE TELEMETRY
                    const Text(
                      'server & hardware telemetry',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isBackendConnected ? const Color(0xFF3DD68C) : const Color(0xFFE66432),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isBackendConnected ? 'backend reachable' : 'backend unreachable',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _isBackendConnected ? const Color(0xFF3DD68C) : const Color(0xFFE66432),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF16181B),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF26282E)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: TextField(
                        controller: controller,
                        style: const TextStyle(fontSize: 13, color: Color(0xFFF7F8F8)),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'http://127.0.0.1:3000',
                          hintStyle: TextStyle(color: Color(0xFF565A61)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Test checks this address without saving it. Save & Resync adopts it and syncs alarms.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF8A8F98),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              backgroundColor: const Color(0xFF16181B),
                              foregroundColor: const Color(0xFFF7F8F8),
                              side: const BorderSide(color: Color(0xFF26282E)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: isTesting || isSaving
                                ? null
                                : () async {
                                    setModalState(() => isTesting = true);
                                    final testUrl = controller.text.trim();
                                    final ok = await _runConnectionTest(testUrl);
                                    if (bottomSheetContext.mounted) {
                                      setModalState(() => isTesting = false);
                                    }
                                    _showToast(ok ? '✓ Backend Reachable (200 OK)' : '✕ Cannot reach $testUrl');
                                  },
                            child: isTesting
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFF7F8F8)),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      const Text(
                                        'testing...',
                                        style: TextStyle(fontSize: 13, color: Color(0xFFF7F8F8)),
                                      ),
                                    ],
                                  )
                                : const Text(
                                    'test',
                                    style: TextStyle(fontSize: 13, color: Color(0xFFF7F8F8)),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF5E6AD2),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: isTesting || isSaving
                                ? null
                                : () async {
                                    final newUrl = controller.text.trim();
                                    if (newUrl.isEmpty) return;
                                    setModalState(() {
                                      isSaving = true;
                                      saveResult = null;
                                      saveSuccess = null;
                                    });
                                    await BackendClient.setBaseUrl(newUrl);
                                    if (mounted) {
                                      setState(() => _backendUrl = newUrl);
                                    }
                                    final result = await _syncWithBackend(silent: true);
                                    if (bottomSheetContext.mounted) {
                                      setModalState(() {
                                        isSaving = false;
                                        if (result.success && result.syncedCount != null) {
                                          final n = result.syncedCount ?? 0;
                                          final noun = n == 1 ? 'alarm' : 'alarms';
                                          saveResult = '✓ Saved · $n $noun synced';
                                          saveSuccess = true;
                                        } else {
                                          saveResult = '✕ Saved, but cannot reach $newUrl';
                                          saveSuccess = false;
                                        }
                                      });
                                    }
                                  },
                            child: isSaving
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      const Text(
                                        'saving...',
                                        style: TextStyle(fontSize: 13, color: Colors.white),
                                      ),
                                    ],
                                  )
                                : const Text(
                                    'save & resync',
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                  ),
                          ),
                        ),
                      ],
                    ),
                    if (saveResult != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        saveResult!,
                        style: TextStyle(
                          fontSize: 12,
                          color: saveSuccess! ? const Color(0xFF3DD68C) : const Color(0xFFE66432),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16181B),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF26282E)),
                      ),
                      child: Column(
                        children: [
                          _telemetryRow('phone model', 'Android Device'),
                          const Divider(color: Color(0xFF26282E), height: 16),
                          _telemetryRow(
                            'battery',
                            _batteryLevel != null
                                ? '$_batteryLevel% (${_isCharging ? 'Charging' : 'On Battery'})'
                                : 'Checking...',
                          ),
                          const Divider(color: Color(0xFF26282E), height: 16),
                          _telemetryRow(
                            'push token',
                            _fcmToken != null && _fcmToken!.length > 16
                                ? '${_fcmToken!.substring(0, 8)}...${_fcmToken!.substring(_fcmToken!.length - 6)}'
                                : 'Acquiring...',
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // SECTION 4: EXPERIMENTS & TACTILE ENGINE
                    const Text(
                      'experiments & tactile engine',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                      ),
                    ),
                    const SizedBox(height: 12),

                    InkWell(
                      onTap: () {
                        Navigator.pop(bottomSheetContext);
                        HapticsLabModal.show(context);
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF16181B),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF5E6AD2).withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF5E6AD2).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.vibration_rounded, color: Color(0xFF717DF0), size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
'haptic testing lab',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFF7F8F8),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'active: ${HapticService.armStyleTitle(HapticService.activeArmStyle)}',
                                    style: const TextStyle(fontSize: 11, color: Color(0xFF8A8F98)),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.arrow_forward_ios_rounded, size: 13, color: Color(0xFF8A8F98)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildModalDropdown<T>({
    required String label,
    required String description,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Color(0xFFF7F8F8),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          description,
          style: const TextStyle(
            fontSize: 10,
            color: Color(0xFF8A8F98),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF16181B),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF26282E)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isExpanded: true,
              dropdownColor: const Color(0xFF16181B),
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Color(0xFF8A8F98)),
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFF7F8F8),
                fontFamily: 'Helvetica Neue',
              ),
              items: items,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _previewToneButton(String label, String tone) {
    return Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: const Color(0xFF16181B),
          foregroundColor: const Color(0xFFF7F8F8),
          side: const BorderSide(color: Color(0xFF26282E)),
          padding: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: () {
          _showToast('previewing $label audio');
        },
        child: Text(label, style: const TextStyle(fontSize: 11)),
      ),
    );
  }

  Widget _telemetryRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF8A8F98))),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFFF7F8F8),
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  // CREATE NEW ALARM MODAL
  void _showCreateAlarmModal() {
    final now = DateTime.now();
    DateTime selectedTime = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
      0,
      0,
    ).add(const Duration(minutes: 5));
    List<int> selectedDays = [];
    int selectedIntervalWeeks = 1;
    String? selectedAnchorDate;
    String selectedTone = _defaultSoundTone;
    int selectedRampSeconds = _defaultRampSeconds;
    final labelController = TextEditingController(text: 'Morning workout');
    final descController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F1013),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF26282E)),
      ),
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (builderContext, setModalState) {
            final formattedTime = _formatTime(selectedTime);

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(builderContext).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFF26282E),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'schedule new alarm',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFF7F8F8),
                            letterSpacing: -0.2,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF8A8F98)),
                          onPressed: () => Navigator.pop(bottomSheetContext),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // HERO MICRO-PILLS CARD
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16181B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF26282E)),
                      ),
                      child: Column(
                        children: [
                          // Large Time Display
                          GestureDetector(
                            onTap: () {
                              _openTimePickerSheet(
                                context: builderContext,
                                initialTime: selectedTime,
                                repeatDays: selectedDays,
                                initialIntervalWeeks: selectedIntervalWeeks,
                                initialAnchorDate: selectedAnchorDate,
                                onApplied: (newTime, newDays, newIntervalWeeks, newAnchorDate) {
                                  setModalState(() {
                                    selectedTime = newTime;
                                    selectedDays = newDays;
                                    selectedIntervalWeeks = newIntervalWeeks;
                                    selectedAnchorDate = newAnchorDate;
                                  });
                                },
                              );
                            },
                            child: Column(
                              children: [
                                Text(
                                  formattedTime,
                                    style: const TextStyle(
                                      fontSize: 50,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFFF7F8F8),
                                      letterSpacing: -1.0,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _getRelativeCountdown(AlarmService.computeFutureOccurrence(
                                      selectedTime,
                                      repeatDays: selectedDays,
                                      intervalWeeks: selectedIntervalWeeks,
                                      anchorDate: selectedAnchorDate != null ? DateTime.tryParse(selectedAnchorDate ?? '') : null,
                                    )),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFF5E6AD2),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 16),

                            // Micro-Pills Row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Recurrence Pill
                                GestureDetector(
                                  onTap: () {
                                    _openRecurrenceSheet(
                                      context: builderContext,
                                      initialDays: selectedDays,
                                      initialTime: selectedTime,
                                      initialIntervalWeeks: selectedIntervalWeeks,
                                      initialAnchorDate: selectedAnchorDate,
                                      onApplied: (newDays, newTime, newIntervalWeeks, newAnchorDate) {
                                        setModalState(() {
                                          selectedDays = newDays;
                                          selectedTime = newTime;
                                          selectedIntervalWeeks = newIntervalWeeks;
                                          selectedAnchorDate = newAnchorDate;
                                        });
                                      },
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF20232A),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: const Color(0xFF2E323D)),
                                    ),
                                    child: Text(
                                      _formatMicroPillRecurrence(selectedDays, selectedTime, intervalWeeks: selectedIntervalWeeks),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFF7F8F8),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),

                                // Sound & Ramp Pill
                                GestureDetector(
                                  onTap: () {
                                    _openSoundSheet(
                                      context: builderContext,
                                      initialTone: selectedTone,
                                      initialRamp: selectedRampSeconds,
                                      onApplied: (newTone, newRamp) {
                                        setModalState(() {
                                          selectedTone = newTone;
                                          selectedRampSeconds = newRamp;
                                        });
                                      },
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF20232A),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: const Color(0xFF2E323D)),
                                    ),
                                    child: Text(
                                      _formatMicroPillSound(selectedTone, selectedRampSeconds),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFF7F8F8),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 16),
                            const Divider(color: Color(0xFF26282E), height: 1),
                            const SizedBox(height: 12),

                            // Inline Title Field
                            TextField(
                              controller: labelController,
                              textAlign: TextAlign.center,
                              textCapitalization: TextCapitalization.none,
                              autocorrect: false,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFFF7F8F8)),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                hintText: 'alarm title...',
                                hintStyle: TextStyle(color: Color(0xFF565A61)),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Description & Notes Container
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF16181B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF26282E)),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: TextField(
                          controller: descController,
                          maxLines: 2,
                          textCapitalization: TextCapitalization.none,
                          autocorrect: false,
                          style: const TextStyle(fontSize: 12, color: Color(0xFFF7F8F8), height: 1.4),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            hintText: 'Optional notes, checklist, or routine...',
                            hintStyle: TextStyle(color: Color(0xFF565A61), fontSize: 12),
                          ),
                        ),
                      ),

                    const SizedBox(height: 24),

                    // Arm Button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF7F8F8),
                          foregroundColor: const Color(0xFF08090A),
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () async {
                          await HapticService.playArm();
                          final cleanTime = DateTime(
                            selectedTime.year,
                            selectedTime.month,
                            selectedTime.day,
                            selectedTime.hour,
                            selectedTime.minute,
                            0,
                            0,
                          );

                          DateTime finalTarget;
                          if (selectedDays.isNotEmpty) {
                            finalTarget = AlarmService.computeFutureOccurrence(
                              cleanTime,
                              repeatDays: selectedDays,
                              intervalWeeks: selectedIntervalWeeks,
                              anchorDate: selectedAnchorDate != null ? DateTime.tryParse(selectedAnchorDate ?? '') : null,
                            );
                          } else {
                            finalTarget = AlarmService.computeFutureOccurrence(cleanTime);
                          }
                          final recurrenceAnchor = selectedIntervalWeeks > 1 ? _isoDate(finalTarget) : null;

                          String assetAudio = AlarmService.getAudioPathForTone(selectedTone);
                          final title = labelController.text.trim().isNotEmpty
                              ? labelController.text.trim()
                              : 'Alarm';
                          final desc = descController.text.trim();

                          // Local-id FIRST so we can arm immediately regardless of network
                          final localFallbackUuid = 'local_${DateTime.now().millisecondsSinceEpoch}';
                          final intId = IdMapper.uuidToInt(localFallbackUuid);

                          final settings = AlarmSettings(
                            id: intId,
                            dateTime: finalTarget,
                            assetAudioPath: assetAudio,
                            loopAudio: true,
                            vibrate: true,
                            volumeSettings: AlarmService.buildPerceptualVolumeSettings(selectedRampSeconds),
                            notificationSettings: NotificationSettings(
                              title: title,
                              body: 'Tap to open alarm',
                              stopButton: 'stop',
                            ),
                          );

                          await Alarm.set(alarmSettings: settings);
                          await IdMapper.saveMapping(
                            intId,
                            localFallbackUuid,
                            label: title,
                            description: desc,
                            targetTime: finalTarget,
                            soundTone: selectedTone,
                            rampSeconds: selectedRampSeconds,
                            repeatDays: selectedDays,
                          );
                          await IdMapper.setSoundTone(intId, selectedTone);
                          await IdMapper.setRampSeconds(intId, selectedRampSeconds);
                          await IdMapper.setIntervalWeeks(intId, selectedIntervalWeeks);
                          await IdMapper.setAnchorDate(intId, recurrenceAnchor);
                          await IdMapper.setEnabled(intId, true);

                          // Pop + toast immediately
                          if (bottomSheetContext.mounted) {
                            Navigator.pop(bottomSheetContext);
                          }
                          _showToast('alarm armed for ${_formatTime(finalTarget)}');
                          _loadAllAlarms();

                          // Background sync to backend; if it succeeds, remap local intId → remoteId
                          BackendClient.createRemoteAlarm(
                            targetTime: finalTarget,
                            label: title,
                            description: desc,
                            repeatDays: selectedDays.isNotEmpty ? selectedDays : null,
                            intervalWeeks: selectedIntervalWeeks > 1 ? selectedIntervalWeeks : null,
                            anchorDate: recurrenceAnchor,
                            soundTone: selectedTone,
                            rampSeconds: selectedRampSeconds,
                          ).then((remoteId) async {
                            if (remoteId != null && remoteId != localFallbackUuid) {
                              // Re-key the armed alarm to the backend's canonical
                              // id so the FCM CREATE echo (and the reconcile) find
                              // it already armed instead of inserting a duplicate.
                              await AlarmService.adoptRemoteId(
                                localIntId: intId,
                                remoteUuid: remoteId,
                                label: title,
                                description: desc,
                                targetTime: finalTarget,
                                repeatDays: selectedDays.isNotEmpty ? selectedDays : null,
                                intervalWeeks: selectedIntervalWeeks,
                                anchorDateIso: recurrenceAnchor,
                                soundTone: selectedTone,
                                rampSeconds: selectedRampSeconds,
                              );
                              _loadAllAlarms();
                            }
                          });
                        },
                        child: const Text(
                          'arm alarm',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Filtered list based on search query
    final filteredAlarms = _allAlarms.where((item) {
      if (_searchQuery.isEmpty) return true;
      final query = _searchQuery.toLowerCase();
      return item.title.toLowerCase().contains(query) ||
          item.description.toLowerCase().contains(query);
    }).toList();

    // Missed alarms are failures, not live alarms. Split them out so they are
    // never mixed into the active list or the hero card.
    final missedAlarms = filteredAlarms.where((a) => a.status == 'missed').toList()
      ..sort((a, b) {
        final aAt = a.missedAt ?? a.dateTime;
        final bAt = b.missedAt ?? b.dateTime;
        return bAt.compareTo(aAt);
      });
    final activeAlarms = filteredAlarms.where((a) => a.status != 'missed').toList();

    // Hero alarm: earliest upcoming enabled alarm (missed alarms never qualify)
    final enabledAlarms = activeAlarms.where((a) => a.isEnabled).toList();
    final upcomingHeroAlarm = enabledAlarms.isNotEmpty ? enabledAlarms.first : null;

    // Back (swipe-back) exits multi-select mode instead of leaving the app.
    final Widget homeScaffold = Scaffold(
      backgroundColor: const Color(0xFF08090A),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Linear Workspace App Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF222326))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Workspace Picker
                  Row(
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: const Color(0xFF5E6AD2),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Center(
                          child: Text(
                            'A',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFF7F8F8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'alarmcore / mobile',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFF7F8F8),
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),

                  // Actions: Search, Battery Telemetry, Settings
                  Row(
                    children: [
                      // Search Toggle
                      IconButton(
                        icon: Icon(
                          _isSearchVisible ? Icons.close_rounded : Icons.search_rounded,
                          size: 19,
                          color: _isSearchVisible ? const Color(0xFFF7F8F8) : const Color(0xFF8A8F98),
                        ),
                        onPressed: () {
                          setState(() {
                            _isSearchVisible = !_isSearchVisible;
                            if (!_isSearchVisible) {
                              _searchQuery = '';
                              _searchController.clear();
                            }
                          });
                        },
                      ),

                      // Battery Badge (no emoji)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF141619),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF26282E)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _isCharging
                                  ? Icons.battery_charging_full_rounded
                                  : Icons.battery_full_rounded,
                              size: 13,
                              color: _isCharging
                                  ? const Color(0xFF5E6AD2)
                                  : const Color(0xFF8A8F98),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _batteryLevel != null ? '$_batteryLevel%' : '--%',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF8A8F98),
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),

                      // Haptic Testing Lab
                      IconButton(
                        icon: const Icon(Icons.vibration_rounded, size: 18, color: Color(0xFF8A8F98)),
                        tooltip: 'haptic testing lab',
                        onPressed: () => HapticsLabModal.show(context),
                      ),

                      // Settings
                      IconButton(
                        icon: const Icon(Icons.tune_rounded, size: 18, color: Color(0xFF8A8F98)),
                        onPressed: _showSettingsModal,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Search Bar Input (Expands when toggled)
            if (_isSearchVisible)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: const BoxDecoration(
                  color: Color(0xFF101215),
                  border: Border(bottom: BorderSide(color: Color(0xFF222326))),
                ),
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16181B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF26282E)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search_rounded, size: 16, color: Color(0xFF8A8F98)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          autofocus: true,
                          style: const TextStyle(fontSize: 13, color: Color(0xFFF7F8F8)),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'Search alarms by title or notes...',
                            hintStyle: TextStyle(color: Color(0xFF565A61), fontSize: 13),
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: (val) {
                            setState(() => _searchQuery = val.trim());
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Scrollable Content
            Expanded(
              child: RefreshIndicator(
                color: const Color(0xFF5E6AD2),
                backgroundColor: const Color(0xFF141619),
                onRefresh: () => _syncWithBackend(),
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  children: [
                    // Active Firing Alarm Banner
                    if (_currentlyRingingAlarm != null) ...[
                      _buildActiveFiringAlarmBanner(_currentlyRingingAlarm!),
                    ],

                    // Backend Offline Warning Banner
                    if (!_isBackendConnected) ...[
                      InkWell(
                        onTap: _showBackendConnectionModal,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF2994A).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFF2994A).withValues(alpha: 0.35)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.cloud_off_rounded, color: Color(0xFFF2994A), size: 20),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'backend unreachable',
                                      style: TextStyle(
                                        color: Color(0xFFF2994A),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _backendError ?? 'Cannot connect to $_backendUrl. Tap to configure.',
                                      style: const TextStyle(
                                        color: Color(0xFF8A8F98),
                                        fontSize: 11,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF2994A).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'fix',
                                  style: TextStyle(
                                    color: Color(0xFFF2994A),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],

                    // Hero Upcoming Alarm Card (slide-up spring + glassmorphic bloom)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeInOutCubic,
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 900),
                        reverseDuration: const Duration(milliseconds: 200),
                        switchInCurve: Curves.elasticOut,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final bool isEntering = animation.status == AnimationStatus.forward ||
                              animation.status == AnimationStatus.completed;

                          return AnimatedBuilder(
                            animation: animation,
                            builder: (context, child) {
                              final double t = animation.value;
                              final double progress = isEntering ? t : 1.0 - t;

                              final double opacity = t.clamp(0.0, 1.0);
                              final double translateY = isEntering
                                  ? Tween<double>(begin: 40.0, end: 0.0).transform(t)
                                  : Tween<double>(begin: 0.0, end: -32.0).transform(progress);
                              final double scale = isEntering
                                  ? Tween<double>(begin: 0.92, end: 1.0).transform(t)
                                  : Tween<double>(begin: 1.0, end: 0.95).transform(progress);

                              return Opacity(
                                opacity: opacity,
                                child: Transform.translate(
                                  offset: Offset(0, translateY),
                                  child: Transform.scale(
                                    scale: scale,
                                    alignment: Alignment.topCenter,
                                    child: child,
                                  ),
                                ),
                              );
                            },
                            child: child,
                          );
                        },
                        child: (upcomingHeroAlarm != null && _searchQuery.isEmpty)
                            ? KeyedSubtree(
                                key: ValueKey('hero_card_${upcomingHeroAlarm.id}'),
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  child: _BreathingHeroCard(
                                    alarm: upcomingHeroAlarm,
                                    onTap: () => _showAlarmDetailModal(upcomingHeroAlarm),
                                    bodyBuilder: _buildHeroCardBody,
                                  ),
                                ),
                              )
                            : const SizedBox(
                                key: ValueKey('hero_card_empty'),
                                width: double.infinity,
                                height: 0,
                              ),
                      ),
                    ),

                    // Section Header: ALL ALARMS (Renamed from active alarms)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'all alarms',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF8A8F98),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1C1E24),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${activeAlarms.length}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFF8A8F98),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // List of active / non-missed alarms
                    if (activeAlarms.isEmpty && missedAlarms.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        decoration: BoxDecoration(
                          color: const Color(0xFF141619),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF26282E)),
                        ),
                        child: const Center(
                          child: Column(
                            children: [
                              Icon(Icons.check_circle_outline_rounded, size: 28, color: Color(0xFF565A61)),
                              SizedBox(height: 8),
                              Text(
                                'no alarms found',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF8A8F98),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (activeAlarms.isNotEmpty)
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: activeAlarms.length,
                        separatorBuilder: (context, index) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final alarm = activeAlarms[index];
                          return _buildAlarmRowCard(alarm);
                        },
                      ),

                    // Missed alarms section: failures must be seen, not buried.
                    if (missedAlarms.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFEB5757)),
                          const SizedBox(width: 6),
                          const Text(
                            'missed alarms',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFEB5757),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF381F22),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${missedAlarms.length}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xFFEB5757),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: missedAlarms.length,
                        separatorBuilder: (context, index) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final alarm = missedAlarms[index];
                          return _buildMissedAlarmCard(alarm);
                        },
                      ),
                    ],

                    const SizedBox(height: 80), // Space for FAB
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _isMultiSelectMode
          ? _buildMultiSelectActionBar()
          : GestureDetector(
              onTap: _showCreateAlarmModal,
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  color: const Color(0xFF5E6AD2),
                  borderRadius: BorderRadius.circular(21),
                  boxShadow: const [
                    // Outer purple glow.
                    BoxShadow(
                      color: Color(0x665E6AD2),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                    // Deeper drop shadow beneath.
                    BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, size: 18, color: Color(0xFFF7F8F8)),
                    SizedBox(width: 8),
                    Text(
                      'new alarm',
                      style: TextStyle(
                        color: Color(0xFFF7F8F8),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );

    return PopScope(
      canPop: !_isMultiSelectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isMultiSelectMode) {
          _exitMultiSelect();
        }
      },
      child: homeScaffold,
    );
  }

  // Hero Upcoming Alarm Card body. The border color/width and outer glow are
  // driven by the breathing wrapper's pulsing animation.
  Widget _buildHeroCardBody({
    required _AlarmItem alarm,
    required VoidCallback onTap,
    required Color borderColor,
    required double borderWidth,
    required double glowAlpha,
    required double glowBlur,
  }) {
    final formattedTime = _formatTime(alarm.dateTime);
    final countdown = _getRelativeCountdown(alarm.dateTime);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0x1A5E6AD2),
                  Color(0x081A1D22),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor, width: borderWidth),
              boxShadow: [
                const BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 20,
                  spreadRadius: -2,
                  offset: Offset(0, 8),
                ),
                BoxShadow(
                  color: Color(((glowAlpha * 255).toInt() << 24) | 0x5E6AD2),
                  blurRadius: glowBlur,
                ),
              ],
            ),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: next upcoming alarm • in x hours x mins
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Color(0xFF5E6AD2),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'next upcoming alarm • $countdown',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF8A8F98),
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Large Clock (Swiss editorial light)
            Text(
              formattedTime,
              style: TextStyle(
                fontSize: _timeFormat == '12h' ? 44 : 52,
                fontWeight: FontWeight.w300,
                color: const Color(0xFFF7F8F8),
                letterSpacing: -1.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 4),

            // Title
            Text(
              alarm.title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Color(0xFFF7F8F8),
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 14),

            // Tags Row
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF20232A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF2E323B)),
                  ),
                  child: Text(
                    _formatRepeatDaysOrDate(alarm.repeatDays, alarm.dateTime, intervalWeeks: alarm.intervalWeeks),
                    style: const TextStyle(fontSize: 11, color: Color(0xFF8A8F98)),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF20232A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF2E323B)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.volume_up_outlined, size: 12, color: Color(0xFF8A8F98)),
                      const SizedBox(width: 4),
                      Text(
                        '${alarm.soundTone} • ${alarm.rampSeconds}s gentle ramp',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF8A8F98)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Map the backend's closed missed-reason vocabulary (§7 / server.ts) to a
  /// lowercase FCM-cause line, matching the app's content style. Returns null
  /// when the cause is genuinely unknown so the caller can omit the line.
  String? _formatMissedReason(String? reason) {
    switch (reason) {
      case 'no_device_registered':
        return 'fcm token unavailable';
      case 'delivery_failed':
        return 'fcm delivery failed';
      case 'dispatched_not_reported':
        return 'fcm delivery unconfirmed';
      case 'device_reported_stale':
        return 'fcm delivery delayed';
      case 'device_reported_failed':
        return 'device couldn\'t ring';
      case 'unknown':
      default:
        return null;
    }
  }

  // Missed Alarm Row Card: same dimensions as a normal alarm row, no
  // translucent fill — a red outline is the only colour cue (§8.3). No toggle,
  // just audit detail and a plain-text Reschedule action.
  Widget _buildMissedAlarmCard(_AlarmItem alarm) {
    final timeStr = _formatTime(alarm.dateTime);
    final missedAtStr = alarm.missedAt != null
        ? '${_formatDate(alarm.missedAt!)} at ${_formatTime(alarm.missedAt!)}'
        : 'time unknown';
    final missedReasonStr = _formatMissedReason(alarm.missedReason);
    final missedDetailStr = missedReasonStr != null
        ? '$missedReasonStr · missed $missedAtStr'
        : 'missed $missedAtStr';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF16181B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEB5757), width: 1.5),
      ),
      child: Row(
        children: [
          // Middle Column: audit detail (time + badge + title on the main row,
          // technical reason on a secondary line below).
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      timeStr,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFF8A8F98),
                        letterSpacing: -0.4,
                        fontFeatures: [FontFeature.tabularFigures()],
                        decoration: TextDecoration.lineThrough,
                        decorationColor: Color(0xFF6B7280),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF381F22),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'missed',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFEB5757),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        alarm.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFFF7F8F8),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  missedDetailStr,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8A8F98),
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),

          // Reschedule action: plain text, no border, no fill.
          const SizedBox(width: 10),
          TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _rescheduleMissedAlarm(alarm),
            child: const Text(
              'reschedule',
              style: TextStyle(color: Color(0xFFF7F8F8), fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // Individual Alarm Row Card with smooth slider & click for rich details
  Widget _buildAlarmRowCard(_AlarmItem alarm) {
    final timeStr = _formatTime(alarm.dateTime);
    final textColor = alarm.isEnabled ? const Color(0xFFF7F8F8) : const Color(0xFF565A61);
    final subtextColor = alarm.isEnabled ? const Color(0xFF8A8F98) : const Color(0xFF45484F);
    final bool isSelected = _selectedAlarmIds.contains(alarm.id);

    return GestureDetector(
      onLongPress: () {
        if (_isMultiSelectMode) {
          _toggleAlarmSelection(alarm.id);
        } else {
          _enterMultiSelect(alarm.id);
        }
      },
      onTap: () {
        if (_isMultiSelectMode) {
          _toggleAlarmSelection(alarm.id);
        } else {
          _showAlarmDetailModal(alarm);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isSelected
                ? [const Color(0xFF1B1D2E), const Color(0xFF161829)]
                : alarm.isEnabled
                    ? [const Color(0xFF16181C), const Color(0xFF121417)]
                    : [const Color(0xFF111215), const Color(0xFF0D0E10)],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF5E6AD2)
                : (alarm.isEnabled ? const Color(0xFF262930) : const Color(0xFF1C1D21)),
            width: isSelected ? 1.5 : 1,
          ),
          boxShadow: alarm.isEnabled
              ? const [
                  BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 12,
                    spreadRadius: -2,
                    offset: Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            // Leading slot: clock status icon normally, selection checkbox in
            // multi-select mode. Both live in an identical 20px slot so the
            // time/label/toggle never shift when multi-select toggles on/off.
            SizedBox(
              width: 20,
              height: 20,
              child: Center(
                child: _isMultiSelectMode
                    ? _buildMultiSelectCheckbox(isSelected)
                    : Icon(
                        Icons.access_time_rounded,
                        size: 18,
                        color: alarm.isEnabled
                            ? (alarm.isSnoozed ? const Color(0xFFE5A158) : const Color(0xFF5E6AD2))
                            : const Color(0xFF45484F),
                      ),
              ),
            ),
            const SizedBox(width: 12),

            // Middle Column: Time + Title (Only title is shown from dashboard view)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w400,
                          color: textColor,
                          letterSpacing: -0.4,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          alarm.title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: subtextColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: alarm.isEnabled ? const Color(0xFF1E2128) : const Color(0xFF16171A),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _formatRepeatDaysOrDate(alarm.repeatDays, alarm.dateTime, intervalWeeks: alarm.intervalWeeks),
                          style: TextStyle(
                            fontSize: 10,
                            color: subtextColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        alarm.soundTone,
                        style: TextStyle(
                          fontSize: 11,
                          color: subtextColor,
                        ),
                      ),
                      if (alarm.description.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.notes_rounded, size: 12, color: subtextColor),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Smooth Slider Switch (Linear style).
            // Kept enabled with its normal colours during multi-select; the
            // Switch consumes its own taps so it toggles enabled state rather
            // than selecting the row.
            Switch.adaptive(
              value: alarm.isEnabled,
              activeThumbColor: const Color(0xFFFFFFFF),
              activeTrackColor: const Color(0xFF5E6AD2),
              inactiveThumbColor: const Color(0xFF565A61),
              inactiveTrackColor: const Color(0xFF1E2024),
              onChanged: (val) {
                _toggleAlarmEnabled(alarm, val);
              },
            ),
          ],
        ),
      ),
    );
  }

  // 20×20 rounded checkbox shown at the row's leading position in
  // multi-select mode. AnimatedContainer gives the 150ms check transition.
  Widget _buildMultiSelectCheckbox(bool isSelected) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF5E6AD2) : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: isSelected ? const Color(0xFF5E6AD2) : const Color(0xFF4A4E58),
          width: 1.5,
        ),
      ),
      child: isSelected
          ? const Center(
              child: Icon(Icons.check_rounded, size: 14, color: Color(0xFFFFFFFF)),
            )
          : null,
    );
  }

  // Bottom action bar shown while multi-select mode is active. Replaces the
  // FAB slot (centerFloat) so it floats above the content with full width.
  Widget _buildMultiSelectActionBar() {
    final count = _selectedAlarmIds.length;
    return Container(
      width: MediaQuery.of(context).size.width - 32,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF16181B),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        border: const Border(top: BorderSide(color: Color(0xFF5E6AD2), width: 2)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // "N selected" count
          Text.rich(
            TextSpan(
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF8A8F98),
                letterSpacing: 0.3,
              ),
              children: [
                TextSpan(
                  text: '$count',
                  style: const TextStyle(
                    color: Color(0xFFF7F8F8),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(text: ' selected'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _multiSelectBarButton(
                label: 'cancel',
                onTap: _exitMultiSelect,
                bg: const Color(0xFF1B1E26),
                fg: const Color(0xFF8A8F98),
              ),
              const Spacer(),
              _multiSelectBarButton(
                label: 'duplicate ($count)',
                onTap: _bulkDuplicateSelected,
                bg: const Color(0x265E6AD2),
                fg: const Color(0xFF5E6AD2),
              ),
              const SizedBox(width: 8),
              _multiSelectBarButton(
                label: 'delete ($count)',
                onTap: _bulkDeleteSelected,
                bg: const Color(0xFFEB5757),
                fg: Colors.white,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _multiSelectBarButton({
    required String label,
    required VoidCallback onTap,
    required Color bg,
    required Color fg,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
      ),
    );
  }

  Widget _buildActiveFiringAlarmBanner(AlarmSettings alarm) {
    final title = alarm.notificationSettings.title.isNotEmpty ? alarm.notificationSettings.title : 'Alarm';
    final timeStr = _formatTime(alarm.dateTime);

    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF2B1416),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEB5757), width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66EB5757),
            blurRadius: 18,
            spreadRadius: 1,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFFEB5757).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.alarm_on_rounded, color: Color(0xFFEB5757), size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'alarm is firing right now',
                      style: TextStyle(
                        color: Color(0xFFEB5757),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$timeStr • $title',
                      style: const TextStyle(
                        color: Color(0xFFF7F8F8),
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFEB5757)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _navigateToRingScreen(alarm),
                child: const Text('open screen', style: TextStyle(color: Color(0xFFEB5757), fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.snooze_rounded, size: 14),
                  label: const Text('snooze 10m', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFF7F8F8),
                    side: const BorderSide(color: Color(0xFF45484F)),
                    backgroundColor: const Color(0xFF1E2024),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () async {
                    await AlarmService.snoozeAlarm(alarm);
                    if (mounted) setState(() => _currentlyRingingAlarm = null);
                    _showToast('alarm snoozed for 10 minutes');
                    _loadAllAlarms();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: const Text('dismiss', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEB5757),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () async {
                    await AlarmService.dismissAlarm(alarm);
                    if (mounted) setState(() => _currentlyRingingAlarm = null);
                    _showToast('alarm dismissed');
                    _loadAllAlarms();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Typedef for the hero card body builder: builds the card body with the
// current pulsing border/glow values from the breathing animation.
typedef _HeroCardBodyBuilder = Widget Function({
  required _AlarmItem alarm,
  required VoidCallback onTap,
  required Color borderColor,
  required double borderWidth,
  required double glowAlpha,
  required double glowBlur,
});

// Hero Upcoming Alarm Card with a breathing purple border and pulsing outer
// glow. Wraps the card body (built by the parent state's _buildHeroCardBody)
// and drives the border alpha (peak ~60%) plus a subtle glow pulse on a
// 2400ms cycle.
class _BreathingHeroCard extends StatefulWidget {
  final _AlarmItem alarm;
  final VoidCallback onTap;
  final _HeroCardBodyBuilder bodyBuilder;

  const _BreathingHeroCard({
    required this.alarm,
    required this.onTap,
    required this.bodyBuilder,
  });

  @override
  State<_BreathingHeroCard> createState() => _BreathingHeroCardState();
}

class _BreathingHeroCardState extends State<_BreathingHeroCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathController;
  late final Animation<double> _breath;

  @override
  void initState() {
    super.initState();
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _breath = CurvedAnimation(
      parent: _breathController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _breathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alpha = (0x55 + (0x99 - 0x55) * _breath.value).toInt();
    return widget.bodyBuilder(
      alarm: widget.alarm,
      onTap: widget.onTap,
      borderColor: Color((alpha << 24) | 0x5E6AD2),
      borderWidth: 1.5,
      glowAlpha: 0.10 + 0.10 * _breath.value,
      glowBlur: 14 + 4 * _breath.value,
    );
  }
}
