import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart' hide NotificationSettings;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'firebase_options.dart';
import 'screens/ring_screen.dart';
import 'services/alarm_service.dart';
import 'services/backend_client.dart';
import 'utils/id_mapper.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

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
          surface: Color(0xFF121316),
          error: Color(0xFFEB5757),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF121316),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFF222326), width: 1),
          ),
          elevation: 0,
        ),
        fontFamily: 'Roboto',
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

class _AlarmHomeScreenState extends State<AlarmHomeScreen> with WidgetsBindingObserver {
  List<AlarmSettings> _alarms = [];
  Map<int, bool> _snoozeMap = {};
  Map<int, List<int>> _repeatMap = {};
  Map<int, String> _toneMap = {};
  Map<int, int> _rampMap = {};
  String? _fcmToken;
  String _backendUrl = 'http://127.0.0.1:3000';
  bool _isLoadingToken = true;
  late Timer _clockTimer;
  DateTime _currentTime = DateTime.now();
  StreamSubscription<AlarmSettings>? _ringSubscription;
  StreamSubscription<int>? _remoteDismissSubscription;
  final Battery _battery = Battery();
  int? _batteryLevel;
  bool _isCharging = false;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAlarms();
    _initFCM();
    _loadBackendUrl();
    _syncWithBackend(silent: true);

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _currentTime = DateTime.now());
      }
    });

    // ignore: deprecated_member_use
    _ringSubscription = Alarm.ringStream.stream.listen((alarmSettings) {
      _navigateToRingScreen(alarmSettings);
    });

    _remoteDismissSubscription = AlarmService.onRemoteDismissed.stream.listen((_) {
      _loadAlarms();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer.cancel();
    _ringSubscription?.cancel();
    _remoteDismissSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncWithBackend(silent: true);
      _reportBatteryTelemetry();
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

  Future<void> _syncWithBackend({bool silent = false}) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    final count = await AlarmService.syncWithBackend();
    await _loadAlarms();
    await _reportBatteryTelemetry();
    if (mounted) {
      setState(() => _isSyncing = false);
      if (!silent) {
        _showToast('Synced with backend ($count active alarms)');
      }
    }
  }

  void _navigateToRingScreen(AlarmSettings alarmSettings) async {
    final uuid = await IdMapper.getUuid(alarmSettings.id);
    if (uuid != null && !uuid.startsWith('local_')) {
      BackendClient.updateAlarmState(uuid, 'ringing');
    }

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (context) => RingScreen(alarmSettings: alarmSettings),
      ),
    ).then((_) => _loadAlarms());
  }

  Future<void> _loadAlarms() async {
    final alarms = await Alarm.getAlarms();
    alarms.sort((a, b) => a.dateTime.compareTo(b.dateTime));
    final snoozeMap = <int, bool>{};
    final repeatMap = <int, List<int>>{};
    final toneMap = <int, String>{};
    final rampMap = <int, int>{};

    for (final a in alarms) {
      snoozeMap[a.id] = await IdMapper.isSnoozed(a.id);
      repeatMap[a.id] = await IdMapper.getRepeatDays(a.id);
      toneMap[a.id] = await IdMapper.getSoundTone(a.id);
      rampMap[a.id] = await IdMapper.getRampSeconds(a.id);
    }
    if (mounted) {
      setState(() {
        _alarms = alarms;
        _snoozeMap = snoozeMap;
        _repeatMap = repeatMap;
        _toneMap = toneMap;
        _rampMap = rampMap;
      });
    }
  }

  Future<void> _loadBackendUrl() async {
    final url = await BackendClient.getBaseUrl();
    if (mounted) {
      setState(() => _backendUrl = url);
    }
  }

  Future<void> _initFCM() async {
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
        setState(() {
          _fcmToken = token;
          _isLoadingToken = false;
        });
      }

      if (token != null) {
        _reportBatteryTelemetry();
      }

      FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
        await AlarmService.handleAlarmPayload(message.data);
        _loadAlarms();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _fcmToken = 'Firebase unavailable: $e';
          _isLoadingToken = false;
        });
      }
    }
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontSize: 13, color: Color(0xFFF7F8F8)),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF121316),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFF222326)),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _deleteAlarm(AlarmSettings settings) async {
    await Alarm.stop(settings.id);
    final uuid = await IdMapper.getUuid(settings.id);
    if (uuid != null && !uuid.startsWith('local_')) {
      await BackendClient.deleteRemoteAlarm(uuid);
    }
    await IdMapper.removeMapping(settings.id);
    _showToast('Alarm canceled');
    _loadAlarms();
  }

  String _formatRepeatDays(List<int> days) {
    if (days.isEmpty) return 'Once';
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

  void _showSettingsModal() {
    final controller = TextEditingController(text: _backendUrl);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF08090A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: Color(0xFF222326)),
      ),
      builder: (bottomSheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 16,
            bottom: MediaQuery.of(bottomSheetContext).viewInsets.bottom + 24,
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
                    color: const Color(0xFF222326),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Settings & Backend Sync',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFF7F8F8),
                      letterSpacing: -0.2,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: Color(0xFF8A8F98)),
                    onPressed: () => Navigator.pop(bottomSheetContext),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Server URL Section
              const Text(
                'BACKEND SERVER URL',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF8A8F98),
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF121316),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF222326)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
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
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: const Color(0xFF121316),
                        foregroundColor: const Color(0xFFF7F8F8),
                        side: const BorderSide(color: Color(0xFF222326)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () async {
                        final newUrl = controller.text.trim();
                        if (newUrl.isNotEmpty) {
                          await BackendClient.setBaseUrl(newUrl);
                          setState(() => _backendUrl = newUrl);
                          await _syncWithBackend();
                          if (bottomSheetContext.mounted) {
                            Navigator.pop(bottomSheetContext);
                          }
                        }
                      },
                      child: const Text('Save & Resync', style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Hardware & Sync Telemetry
              const Text(
                'DEVICE TELEMETRY',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF8A8F98),
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF121316),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF222326)),
                ),
                child: Column(
                  children: [
                    _telemetryRow('Phone Model', 'Android Device'),
                    const Divider(color: Color(0xFF1C1D21), height: 16),
                    _telemetryRow(
                      'Battery',
                      _batteryLevel != null
                          ? '$_batteryLevel% (${_isCharging ? 'Charging' : 'On Battery'})'
                          : 'Checking...',
                    ),
                    const Divider(color: Color(0xFF1C1D21), height: 16),
                    _telemetryRow(
                      'Push Token',
                      _fcmToken != null && _fcmToken!.length > 16
                          ? '${_fcmToken!.substring(0, 8)}...${_fcmToken!.substring(_fcmToken!.length - 6)}'
                          : 'Acquiring...',
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Audio Previews
              const Text(
                'SOUND PREVIEWS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF8A8F98),
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _previewToneButton('Radar', 'assets/alarm.mp3'),
                  const SizedBox(width: 8),
                  _previewToneButton('Chime', 'assets/chime.mp3'),
                  const SizedBox(width: 8),
                  _previewToneButton('Digital', 'assets/digital.mp3'),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _previewToneButton(String name, String asset) {
    return Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: const Color(0xFF121316),
          foregroundColor: const Color(0xFFF7F8F8),
          side: const BorderSide(color: Color(0xFF222326)),
          padding: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: () async {
          _showToast('Playing $name tone');
        },
        child: Text(name, style: const TextStyle(fontSize: 12)),
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
    List<int> selectedRepeatDays = [];
    String selectedTone = 'alarm';
    int selectedRampSeconds = 15;
    final labelController = TextEditingController(text: 'Morning workout');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF08090A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: Color(0xFF222326)),
      ),
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (builderContext, setModalState) {
            final formattedTime =
                '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}';

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
                          color: const Color(0xFF222326),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Schedule Alarm',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFF7F8F8),
                            letterSpacing: -0.2,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18, color: Color(0xFF8A8F98)),
                          onPressed: () => Navigator.pop(bottomSheetContext),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Label Input
                    const Text(
                      'ALARM LABEL',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF121316),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF222326)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: labelController,
                        style: const TextStyle(fontSize: 14, color: Color(0xFFF7F8F8)),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'e.g. Quick catchup',
                          hintStyle: TextStyle(color: Color(0xFF565A61)),
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Trigger Time Picker
                    const Text(
                      'TRIGGER TIME',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(selectedTime),
                        );
                        if (picked != null) {
                          setModalState(() {
                            selectedTime = DateTime(
                              selectedTime.year,
                              selectedTime.month,
                              selectedTime.day,
                              picked.hour,
                              picked.minute,
                              0,
                              0,
                            );
                          });
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121316),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF222326)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              formattedTime,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFF7F8F8),
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            const Icon(Icons.access_time_rounded, size: 18, color: Color(0xFF8A8F98)),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Sound Profile & Gentle Ramp
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'TONE',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF8A8F98),
                                  letterSpacing: 1.0,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF121316),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFF222326)),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: selectedTone,
                                    isExpanded: true,
                                    dropdownColor: const Color(0xFF121316),
                                    items: const [
                                      DropdownMenuItem(value: 'alarm', child: Text('Radar')),
                                      DropdownMenuItem(value: 'chime', child: Text('Chime')),
                                      DropdownMenuItem(value: 'digital', child: Text('Digital')),
                                    ],
                                    onChanged: (val) {
                                      if (val != null) setModalState(() => selectedTone = val);
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'GENTLE RAMP',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF8A8F98),
                                  letterSpacing: 1.0,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF121316),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFF222326)),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<int>(
                                    value: selectedRampSeconds,
                                    isExpanded: true,
                                    dropdownColor: const Color(0xFF121316),
                                    items: const [
                                      DropdownMenuItem(value: 0, child: Text('0s (Instant)')),
                                      DropdownMenuItem(value: 15, child: Text('15s Ramp')),
                                      DropdownMenuItem(value: 30, child: Text('30s Ramp')),
                                      DropdownMenuItem(value: 60, child: Text('60s Ramp')),
                                    ],
                                    onChanged: (val) {
                                      if (val != null) setModalState(() => selectedRampSeconds = val);
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Submit Button
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF7F8F8),
                          foregroundColor: const Color(0xFF08090A),
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () async {
                          final id = DateTime.now().millisecondsSinceEpoch % 100000;
                          final cleanTime = DateTime(
                            selectedTime.year,
                            selectedTime.month,
                            selectedTime.day,
                            selectedTime.hour,
                            selectedTime.minute,
                            0,
                            0,
                          );

                          String assetAudio = 'assets/alarm.mp3';
                          if (selectedTone == 'chime') assetAudio = 'assets/chime.mp3';
                          if (selectedTone == 'digital') assetAudio = 'assets/digital.mp3';

                          final settings = AlarmSettings(
                            id: id,
                            dateTime: cleanTime,
                            assetAudioPath: assetAudio,
                            loopAudio: true,
                            vibrate: true,
                            volumeSettings: selectedRampSeconds > 0
                                ? VolumeSettings.fade(
                                    volume: 1.0,
                                    fadeDuration: Duration(seconds: selectedRampSeconds),
                                  )
                                : VolumeSettings.fixed(volume: 1.0),
                            notificationSettings: NotificationSettings(
                              title: labelController.text.trim().isNotEmpty
                                  ? labelController.text.trim()
                                  : 'Alarm',
                              body: 'Tap to open alarm',
                              stopButton: 'Stop',
                            ),
                          );

                          await Alarm.set(alarmSettings: settings);
                          await IdMapper.saveMapping(id, 'local_$id', label: labelController.text.trim());
                          await IdMapper.setSoundTone(id, selectedTone);
                          await IdMapper.setRampSeconds(id, selectedRampSeconds);

                          if (bottomSheetContext.mounted) {
                            Navigator.pop(bottomSheetContext);
                          }
                          _showToast('Alarm scheduled for $formattedTime');
                          _loadAlarms();
                        },
                        child: const Text(
                          'Arm Alarm',
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
    // Determine upcoming alarm (hero card)
    final upcomingAlarm = _alarms.isNotEmpty ? _alarms.first : null;
    final otherAlarms = _alarms;

    return Scaffold(
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
                  // Workspace Switcher
                  Row(
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: const Color(0xFF5E6AD2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Center(
                          child: Text(
                            'A',
                            style: TextStyle(
                              fontSize: 11,
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
                      const SizedBox(width: 4),
                      const Icon(Icons.unfold_more_rounded, size: 14, color: Color(0xFF8A8F98)),
                    ],
                  ),

                  // Actions: Battery Telemetry & Settings
                  Row(
                    children: [
                      // Battery Badge (no emoji)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121316),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF222326)),
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
                      const SizedBox(width: 8),
                      // Settings Action
                      IconButton(
                        icon: const Icon(Icons.tune_rounded, size: 18, color: Color(0xFF8A8F98)),
                        onPressed: _showSettingsModal,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Scrollable Content
            Expanded(
              child: RefreshIndicator(
                color: const Color(0xFF5E6AD2),
                backgroundColor: const Color(0xFF121316),
                onRefresh: () => _syncWithBackend(),
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  children: [
                    // Hero Upcoming Cycle Card (Linear style)
                    if (upcomingAlarm != null) ...[
                      _buildUpcomingCycleCard(upcomingAlarm),
                      const SizedBox(height: 24),
                    ],

                    // Section Header: ACTIVE ALARMS (matches test assertion)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'ACTIVE ALARMS',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF8A8F98),
                                letterSpacing: 0.8,
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
                                '${_alarms.length}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFF8A8F98),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                        TextButton(
                          onPressed: _showCreateAlarmModal,
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF5E6AD2),
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text(
                            '+ new alarm',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // Alarms Issue-List Feed
                    if (otherAlarms.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121316),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF222326)),
                        ),
                        child: const Center(
                          child: Column(
                            children: [
                              Icon(Icons.check_circle_outline, size: 28, color: Color(0xFF565A61)),
                              SizedBox(height: 8),
                              Text(
                                'no alarms scheduled',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF8A8F98),
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'all quiet for now',
                                style: TextStyle(fontSize: 11, color: Color(0xFF565A61)),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF121316),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF222326)),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: otherAlarms.length,
                          separatorBuilder: (context, index) => const Divider(
                            color: Color(0xFF1C1D21),
                            height: 1,
                          ),
                          itemBuilder: (context, index) {
                            final alarm = otherAlarms[index];
                            final isSnoozed = _snoozeMap[alarm.id] == true;
                            final repeatDays = _repeatMap[alarm.id] ?? [];
                            final tone = _toneMap[alarm.id] ?? 'alarm';
                            final timeStr =
                                '${alarm.dateTime.hour.toString().padLeft(2, '0')}:${alarm.dateTime.minute.toString().padLeft(2, '0')}';
                            final title = alarm.notificationSettings.title.isNotEmpty
                                ? alarm.notificationSettings.title
                                : 'Alarm';

                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.access_time_rounded,
                                    size: 16,
                                    color: isSnoozed
                                        ? const Color(0xFFE5A158)
                                        : const Color(0xFF5E6AD2),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              timeStr,
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w600,
                                                color: Color(0xFFF7F8F8),
                                                fontFeatures: [FontFeature.tabularFigures()],
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                title,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w500,
                                                  color: Color(0xFF8A8F98),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF1C1E24),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                _formatRepeatDays(repeatDays),
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color: Color(0xFF8A8F98),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              tone,
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Color(0xFF565A61),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                      color: Color(0xFF565A61),
                                    ),
                                    onPressed: () => _deleteAlarm(alarm),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpcomingCycleCard(AlarmSettings alarm) {
    final hourStr = alarm.dateTime.hour.toString().padLeft(2, '0');
    final minuteStr = alarm.dateTime.minute.toString().padLeft(2, '0');
    final title = alarm.notificationSettings.title.isNotEmpty
        ? alarm.notificationSettings.title
        : 'Alarm';
    final repeatDays = _repeatMap[alarm.id] ?? [];
    final tone = _toneMap[alarm.id] ?? 'alarm';
    final ramp = _rampMap[alarm.id] ?? 0;
    final isSnoozed = _snoozeMap[alarm.id] == true;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF121316),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF222326)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$hourStr:$minuteStr',
                style: const TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFF7F8F8),
                  letterSpacing: -1.0,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isSnoozed ? const Color(0xFF2E2419) : const Color(0xFF1B261F),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: isSnoozed ? const Color(0xFFE5A158) : const Color(0xFF4CB782),
                  ),
                ),
                child: Text(
                  isSnoozed ? 'Snoozed' : 'Armed',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isSnoozed ? const Color(0xFFE5A158) : const Color(0xFF4CB782),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Color(0xFFF7F8F8),
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1E24),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _formatRepeatDays(repeatDays),
                  style: const TextStyle(fontSize: 11, color: Color(0xFF8A8F98)),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1E24),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.volume_up_outlined, size: 12, color: Color(0xFF8A8F98)),
                    const SizedBox(width: 4),
                    Text(
                      '$tone • ${ramp}s gentle ramp',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF8A8F98)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
