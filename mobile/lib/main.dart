import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
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
  } catch (e) {
    // If already initialized or fails in background
  }
  await Alarm.init();
  await AlarmService.handleAlarmPayload(message.data);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase safely
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // ignore: avoid_print
    print('[Firebase] Initialization error: $e');
  }

  // Initialize Alarm plugin
  await Alarm.init();

  // Register background handler
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
        scaffoldBackgroundColor: const Color(0xFF090B14),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFF06B6D4),
          surface: Color(0xFF13172A),
          error: Color(0xFFEF4444),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF13172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0x1FFFFFFF), width: 1),
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
  String? _fcmToken;
  String _backendUrl = 'http://127.0.0.1:3000';
  bool _isLoadingToken = true;
  bool _isRegisteringDevice = false;
  late Timer _clockTimer;
  DateTime _currentTime = DateTime.now();
  StreamSubscription<AlarmSettings>? _ringSubscription;
  StreamSubscription<int>? _remoteDismissSubscription;
  final Battery _battery = Battery();
  int? _batteryLevel;
  bool _isCharging = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAlarms();
    _initFCM();
    _loadBackendUrl();
    _syncWithBackend(silent: true);

    // Live clock ticker
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _currentTime = DateTime.now());
      }
    });

    // Listen to Alarm ring stream
    // ignore: deprecated_member_use
    _ringSubscription = Alarm.ringStream.stream.listen((alarmSettings) {
      _navigateToRingScreen(alarmSettings);
    });

    // Refresh list when alarm is remotely dismissed/canceled
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
      print('[Battery] Error collecting battery telemetry: $e');
    }
  }

  Future<void> _syncWithBackend({bool silent = false}) async {
    final count = await AlarmService.syncWithBackend();
    await _loadAlarms();
    await _reportBatteryTelemetry();
    if (!silent && mounted) {
      _showToast('Synced with server ($count active alarms)');
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
    for (final a in alarms) {
      snoozeMap[a.id] = await IdMapper.isSnoozed(a.id);
      repeatMap[a.id] = await IdMapper.getRepeatDays(a.id);
    }
    if (mounted) {
      setState(() {
        _alarms = alarms;
        _snoozeMap = snoozeMap;
        _repeatMap = repeatMap;
      });
    }
  }

  String _formatAlarmDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final targetDay = DateTime(dt.year, dt.month, dt.day);
    final diff = targetDay.difference(today).inDays;

    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${weekdays[dt.weekday - 1]}, ${dt.day} ${months[dt.month - 1]}';
  }

  String _formatRepeatDays(List<int> days) {
    if (days.isEmpty) return '';
    if (days.length == 7) return 'Every day';
    if (days.length == 5 &&
        days.contains(1) &&
        days.contains(2) &&
        days.contains(3) &&
        days.contains(4) &&
        days.contains(5)) {
      return 'Weekdays';
    }
    if (days.length == 2 && days.contains(6) && days.contains(7)) {
      return 'Weekends';
    }
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days.map((d) => names[d - 1]).join(', ');
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

      // Foreground message handler
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

  Future<void> _registerDeviceWithBackend() async {
    if (_fcmToken == null || _fcmToken!.startsWith('Firebase unavailable')) {
      _showToast('No valid FCM token to register');
      return;
    }

    setState(() => _isRegisteringDevice = true);
    int? batteryLevel;
    bool? isCharging;
    try {
      batteryLevel = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      isCharging = state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {}

    final success = await BackendClient.registerDeviceToken(
      _fcmToken!,
      batteryLevel: batteryLevel,
      isCharging: isCharging,
      deviceName: 'Android Device',
    );
    if (!mounted) return;
    setState(() => _isRegisteringDevice = false);

    if (success) {
      _showToast('✅ Device registered with server!');
    } else {
      _showToast('❌ Failed to reach backend at $_backendUrl');
    }
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1E243E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

  void _showServerSettingsDialog() {
    final controller = TextEditingController(text: _backendUrl);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF161B30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Server Configuration', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the Fastify backend URL (e.g. Tailscale IP or LAN IP):',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: 'http://192.168.1.50:3000',
                filled: true,
                fillColor: const Color(0xFF0F1222),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
            onPressed: () async {
              final newUrl = controller.text.trim();
              if (newUrl.isNotEmpty) {
                await BackendClient.setBaseUrl(newUrl);
                if (!dialogContext.mounted) return;
                Navigator.pop(dialogContext);
                if (!mounted) return;
                setState(() => _backendUrl = newUrl);
                _showToast('Backend URL updated to $_backendUrl');
              }
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
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
    int selectedRampSeconds = 30;
    final labelController = TextEditingController(text: 'Morning Alarm');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF13172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (builderContext, setModalState) {
            final formattedTime =
                '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}';
            final dateLabel = _formatAlarmDate(selectedTime);
            final fullDateStr = '${selectedTime.day}/${selectedTime.month}/${selectedTime.year}';

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(builderContext).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Schedule Alarm',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 18),

                    // Date & Time Selectors Row
                    Row(
                      children: [
                        // Date picker button
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final pickedDate = await showDatePicker(
                                context: builderContext,
                                initialDate: selectedTime,
                                firstDate: DateTime.now().subtract(const Duration(days: 1)),
                                lastDate: DateTime.now().add(const Duration(days: 365)),
                              );
                              if (pickedDate != null) {
                                setModalState(() {
                                  selectedTime = DateTime(
                                    pickedDate.year,
                                    pickedDate.month,
                                    pickedDate.day,
                                    selectedTime.hour,
                                    selectedTime.minute,
                                    0,
                                    0,
                                  );
                                });
                              }
                            },
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F1222),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: const Color(0xFF06B6D4).withValues(alpha: 0.35)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Row(
                                    children: [
                                      Icon(Icons.calendar_today_outlined, size: 14, color: Color(0xFF06B6D4)),
                                      SizedBox(width: 6),
                                      Text('DATE', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    dateLabel,
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                                  ),
                                  Text(fullDateStr, style: const TextStyle(fontSize: 11, color: Colors.white38)),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Time picker button
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final timeOfDay = await showTimePicker(
                                context: builderContext,
                                initialTime: TimeOfDay.fromDateTime(selectedTime),
                              );
                              if (timeOfDay != null) {
                                setModalState(() {
                                  selectedTime = DateTime(
                                    selectedTime.year,
                                    selectedTime.month,
                                    selectedTime.day,
                                    timeOfDay.hour,
                                    timeOfDay.minute,
                                    0,
                                    0,
                                  );
                                });
                              }
                            },
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F1222),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.4)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Row(
                                    children: [
                                      Icon(Icons.access_time_rounded, size: 14, color: Color(0xFF6366F1)),
                                      SizedBox(width: 6),
                                      Text('TIME', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    formattedTime,
                                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF6366F1)),
                                  ),
                                  const Text('Tap to change', style: TextStyle(fontSize: 11, color: Colors.white38)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Quick Date shortcuts
                    Row(
                      children: [
                        _dateQuickPill('Today', () {
                          setModalState(() {
                            final now = DateTime.now();
                            selectedTime = DateTime(
                              now.year,
                              now.month,
                              now.day,
                              selectedTime.hour,
                              selectedTime.minute,
                              0,
                              0,
                            );
                          });
                        }),
                        const SizedBox(width: 8),
                        _dateQuickPill('Tomorrow', () {
                          setModalState(() {
                            final tomorrow = DateTime.now().add(const Duration(days: 1));
                            selectedTime = DateTime(
                              tomorrow.year,
                              tomorrow.month,
                              tomorrow.day,
                              selectedTime.hour,
                              selectedTime.minute,
                              0,
                              0,
                            );
                          });
                        }),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // Recurrence Options (M T W T F S S)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'REPEAT',
                          style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5),
                        ),
                        if (selectedRepeatDays.isNotEmpty)
                          GestureDetector(
                            onTap: () => setModalState(() => selectedRepeatDays.clear()),
                            child: const Text('Clear', style: TextStyle(color: Color(0xFF6366F1), fontSize: 11, fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _dayCircle('M', 1, selectedRepeatDays.contains(1), () {
                          setModalState(() => _toggleDay(selectedRepeatDays, 1));
                        }),
                        _dayCircle('T', 2, selectedRepeatDays.contains(2), () {
                          setModalState(() => _toggleDay(selectedRepeatDays, 2));
                        }),
                        _dayCircle('W', 3, selectedRepeatDays.contains(3), () {
                          setModalState(() => _toggleDay(selectedRepeatDays, 3));
                        }),
                        _dayCircle('T', 4, selectedRepeatDays.contains(4), () {
                          setModalState(() => _toggleDay(selectedRepeatDays, 4));
                        }),
                        _dayCircle('F', 5, selectedRepeatDays.contains(5), () {
                          setModalState(() => _toggleDay(selectedRepeatDays, 5));
                        }),
                        _dayCircle('S', 6, selectedRepeatDays.contains(6), () {
                          setModalState(() => _toggleDay(selectedRepeatDays, 6));
                        }),
                        _dayCircle('S', 7, selectedRepeatDays.contains(7), () {
                          setModalState(() => _toggleDay(selectedRepeatDays, 7));
                        }),
                      ],
                    ),
                    if (selectedRepeatDays.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        _formatRepeatDays(selectedRepeatDays),
                        style: const TextStyle(fontSize: 12, color: Color(0xFF818CF8), fontWeight: FontWeight.w500),
                      ),
                    ],
                    const SizedBox(height: 18),

                    // Label input
                    TextField(
                      controller: labelController,
                      decoration: InputDecoration(
                        labelText: 'Label / Note',
                        filled: true,
                        fillColor: const Color(0xFF0F1222),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Audio Tone & Gentle Wake Ramp Selectors
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: selectedTone,
                            decoration: InputDecoration(
                              labelText: 'Tone',
                              filled: true,
                              fillColor: const Color(0xFF0F1222),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            dropdownColor: const Color(0xFF161B30),
                            items: const [
                              DropdownMenuItem(value: 'alarm', child: Text('🔔 Bell', style: TextStyle(fontSize: 13))),
                              DropdownMenuItem(value: 'chime', child: Text('✨ Chime', style: TextStyle(fontSize: 13))),
                              DropdownMenuItem(value: 'digital', child: Text('⚡ Pulse', style: TextStyle(fontSize: 13))),
                            ],
                            onChanged: (val) {
                              if (val != null) setModalState(() => selectedTone = val);
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: selectedRampSeconds,
                            decoration: InputDecoration(
                              labelText: 'Gentle Wake',
                              filled: true,
                              fillColor: const Color(0xFF0F1222),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            dropdownColor: const Color(0xFF161B30),
                            items: const [
                              DropdownMenuItem(value: 30, child: Text('30s ramp', style: TextStyle(fontSize: 13))),
                              DropdownMenuItem(value: 15, child: Text('15s ramp', style: TextStyle(fontSize: 13))),
                              DropdownMenuItem(value: 60, child: Text('60s ramp', style: TextStyle(fontSize: 13))),
                              DropdownMenuItem(value: 0, child: Text('Instant', style: TextStyle(fontSize: 13))),
                            ],
                            onChanged: (val) {
                              if (val != null) setModalState(() => selectedRampSeconds = val);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),

                    // Schedule button
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6366F1),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () async {
                          final label = labelController.text.trim().isEmpty
                              ? 'Local Alarm'
                              : labelController.text.trim();

                          var alignedTime = DateTime(
                            selectedTime.year,
                            selectedTime.month,
                            selectedTime.day,
                            selectedTime.hour,
                            selectedTime.minute,
                            0,
                            0,
                          );

                          // If one-off and time is in the past, advance to tomorrow
                          if (selectedRepeatDays.isEmpty && alignedTime.isBefore(DateTime.now())) {
                            alignedTime = alignedTime.add(const Duration(days: 1));
                          }

                          // Sync with backend so it displays on the web dashboard
                          final remoteId = await BackendClient.createRemoteAlarm(
                            targetTime: alignedTime,
                            label: label,
                            repeatDays: selectedRepeatDays,
                            soundTone: selectedTone,
                            rampSeconds: selectedRampSeconds,
                          );

                          await AlarmService.scheduleLocalAlarm(
                            dateTime: alignedTime,
                            label: label,
                            customUuid: remoteId,
                            repeatDays: selectedRepeatDays,
                            soundTone: selectedTone,
                            rampSeconds: selectedRampSeconds,
                          );
                          if (!bottomSheetContext.mounted) return;
                          Navigator.pop(bottomSheetContext);
                          _showToast(remoteId != null
                              ? 'Alarm synced to server ($dateLabel $formattedTime)'
                              : 'Alarm scheduled ($dateLabel $formattedTime)');
                          _loadAlarms();
                        },
                        child: const Text(
                          'Set Alarm',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
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

  Widget _dayCircle(String label, int day, bool isSelected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isSelected ? const Color(0xFF6366F1) : const Color(0xFF161A30),
          border: Border.all(
            color: isSelected ? const Color(0xFF818CF8) : Colors.white12,
            width: isSelected ? 1.5 : 1.0,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  )
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? Colors.white : Colors.white60,
          ),
        ),
      ),
    );
  }

  void _toggleDay(List<int> list, int day) {
    if (list.contains(day)) {
      list.remove(day);
    } else {
      list.add(day);
    }
    list.sort();
  }

  Widget _dateQuickPill(String text, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF1E243E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ),
    );
  }

  Widget _repeatChip(String text, bool isSelected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF6366F1).withValues(alpha: 0.3) : const Color(0xFF1E243E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? const Color(0xFF6366F1) : Colors.white12),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? const Color(0xFF818CF8) : Colors.white70,
          ),
        ),
      ),
    );
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final hours = _currentTime.hour.toString().padLeft(2, '0');
    final minutes = _currentTime.minute.toString().padLeft(2, '0');
    final seconds = _currentTime.second.toString().padLeft(2, '0');

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.alarm_on, color: Color(0xFF6366F1), size: 20),
            ),
            const SizedBox(width: 10),
            const Text(
              'Remote Alarm',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          if (_batteryLevel != null)
            Container(
              margin: const EdgeInsets.only(right: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E243E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isCharging ? Icons.battery_charging_full_rounded : Icons.battery_std_rounded,
                    size: 14,
                    color: _isCharging ? const Color(0xFF10B981) : const Color(0xFF06B6D4),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$_batteryLevel%${_isCharging ? ' ⚡' : ''}',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white70),
                  ),
                ],
              ),
            ),
          IconButton(
            icon: const Icon(Icons.sync_rounded, color: Color(0xFF6366F1)),
            tooltip: 'Sync with server',
            onPressed: () => _syncWithBackend(silent: false),
          ),
          IconButton(
            icon: const Icon(Icons.dns_outlined, color: Colors.white70),
            tooltip: 'Server Settings',
            onPressed: _showServerSettingsDialog,
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _syncWithBackend(silent: false),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Live Clock Banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF171C35), Color(0xFF111425)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '$hours:$minutes',
                            style: const TextStyle(
                              fontSize: 54,
                              fontWeight: FontWeight.w200,
                              letterSpacing: -1,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            seconds,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w300,
                              color: Color(0xFF6366F1),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${_alarms.length} Scheduled Alarm${_alarms.length == 1 ? '' : 's'}',
                        style: const TextStyle(fontSize: 13, color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Alarms Section Title
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'ACTIVE ALARMS',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: Colors.white54,
                      ),
                    ),
                    Text(
                      'Auto-syncs via FCM',
                      style: TextStyle(fontSize: 11, color: const Color(0xFF06B6D4).withValues(alpha: 0.8)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Alarms List or Empty state
                if (_alarms.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    decoration: BoxDecoration(
                      color: const Color(0xFF12162A),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                    ),
                    child: const Column(
                      children: [
                        Icon(Icons.bedtime_outlined, size: 48, color: Colors.white24),
                        SizedBox(height: 12),
                        Text('No alarms set', style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w500)),
                        SizedBox(height: 4),
                        Text('Tap + to set an alarm or dispatch from server', style: TextStyle(color: Colors.white38, fontSize: 12)),
                      ],
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _alarms.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final alarm = _alarms[index];
                      final timeStr =
                          '${alarm.dateTime.hour.toString().padLeft(2, '0')}:${alarm.dateTime.minute.toString().padLeft(2, '0')}';
                      final title = alarm.notificationSettings.title.isNotEmpty
                          ? alarm.notificationSettings.title
                          : 'Alarm';
                      final isPast = alarm.dateTime.isBefore(DateTime.now());
                      final isSnoozed = _snoozeMap[alarm.id] ?? false;
                      final dateStr = _formatAlarmDate(alarm.dateTime);
                      final repeatText = _formatRepeatDays(_repeatMap[alarm.id] ?? []);

                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF13172A),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSnoozed
                                ? const Color(0xFFF59E0B).withValues(alpha: 0.8)
                                : isPast
                                    ? Colors.redAccent.withValues(alpha: 0.3)
                                    : const Color(0xFF6366F1).withValues(alpha: 0.25),
                            width: isSnoozed ? 1.5 : 1.0,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        timeStr,
                                        style: TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.bold,
                                          color: isPast ? Colors.redAccent : Colors.white,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1E243E),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          dateStr,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: dateStr == 'Today'
                                                ? const Color(0xFF06B6D4)
                                                : dateStr == 'Tomorrow'
                                                    ? const Color(0xFF818CF8)
                                                    : Colors.white70,
                                          ),
                                        ),
                                      ),
                                      if (isSnoozed) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: const Color(0x33F59E0B),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(color: const Color(0xFFF59E0B)),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.snooze, size: 12, color: Color(0xFFF59E0B)),
                                              SizedBox(width: 3),
                                              Text(
                                                'SNOOZED',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  color: Color(0xFFF59E0B),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    title,
                                    style: const TextStyle(fontSize: 14, color: Colors.white70, fontWeight: FontWeight.w500),
                                  ),
                                  if (repeatText.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        const Icon(Icons.repeat, size: 12, color: Color(0xFF818CF8)),
                                        const SizedBox(width: 4),
                                        Text(
                                          repeatText,
                                          style: const TextStyle(fontSize: 11, color: Color(0xFF818CF8)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                              tooltip: 'Cancel Alarm',
                              onPressed: () => _deleteAlarm(alarm),
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                const SizedBox(height: 28),

                // FCM Device Registration & Diagnostics Panel
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111425),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.cell_tower, color: Color(0xFF06B6D4), size: 18),
                          SizedBox(width: 8),
                          Text(
                            'FCM DEVICE TOKEN',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.1,
                              color: Color(0xFF06B6D4),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isLoadingToken
                            ? 'Fetching device token from Firebase...'
                            : (_fcmToken ?? 'Token unavailable'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _fcmToken == null
                                  ? null
                                  : () {
                                      Clipboard.setData(ClipboardData(text: _fcmToken!));
                                      _showToast('Copied FCM Device Token!');
                                    },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white70,
                                side: const BorderSide(color: Colors.white24),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.copy, size: 16),
                              label: const Text('Copy Token', style: TextStyle(fontSize: 12)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isRegisteringDevice ? null : _registerDeviceWithBackend,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF6366F1),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: _isRegisteringDevice
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.sync, size: 16),
                              label: const Text('Register', style: TextStyle(fontSize: 12)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: Text(
                          'Backend: $_backendUrl',
                          style: const TextStyle(fontSize: 10, color: Colors.white38),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 80),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateAlarmModal,
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_alarm),
        label: const Text('New Alarm', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}
