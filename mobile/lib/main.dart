import 'dart:async';
import 'package:alarm/alarm.dart';
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
import 'utils/settings_formatter.dart';

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
  String soundTone;
  int rampSeconds;
  String? uuid;

  _AlarmItem({
    required this.id,
    required this.dateTime,
    required this.title,
    required this.description,
    required this.isEnabled,
    required this.isSnoozed,
    required this.repeatDays,
    required this.soundTone,
    required this.rampSeconds,
    this.uuid,
  });
}

class _AlarmHomeScreenState extends State<AlarmHomeScreen> with WidgetsBindingObserver {
  List<_AlarmItem> _allAlarms = [];
  String? _fcmToken;
  String _backendUrl = 'http://127.0.0.1:3000';
  late Timer _clockTimer;
  Timer? _foregroundSyncTimer;
  DateTime _currentTime = DateTime.now();
  StreamSubscription<AlarmSettings>? _ringSubscription;
  StreamSubscription<int>? _remoteDismissSubscription;
  final Battery _battery = Battery();
  int? _batteryLevel;
  bool _isCharging = false;
  bool _isSyncing = false;
  bool _isSearchVisible = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

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
    }

    await BackendClient.updateSettings({key: value});
  }

  String _formatTime(DateTime dt) {
    return SettingsFormatter.formatTime(dt, _timeFormat);
  }

  String _formatDate(DateTime dt) {
    return SettingsFormatter.formatDate(dt, _dateFormat);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAllAlarms();
    _initFCM();
    _loadBackendUrl();
    _loadSettings();
    _syncWithBackend(silent: true);

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _currentTime = DateTime.now());
      }
    });

    _foregroundSyncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) {
        _syncWithBackend(silent: true);
      }
    });

    // ignore: deprecated_member_use
    _ringSubscription = Alarm.ringStream.stream.listen((alarmSettings) {
      _navigateToRingScreen(alarmSettings);
    });

    _remoteDismissSubscription = AlarmService.onRemoteDismissed.stream.listen((_) {
      _loadAllAlarms();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer.cancel();
    _foregroundSyncTimer?.cancel();
    _ringSubscription?.cancel();
    _remoteDismissSubscription?.cancel();
    _searchController.dispose();
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
    await _loadAllAlarms();
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
    ).then((_) => _loadAllAlarms());
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
        soundTone: tone,
        rampSeconds: ramp,
        uuid: uuid,
      ));
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
    if (enable) {
      // Re-enable and schedule
      final target = AlarmService.computeFutureOccurrence(
        item.dateTime,
        repeatDays: item.repeatDays,
      );

      final audioPath = AlarmService.getAudioPathForTone(item.soundTone);
      final settings = AlarmSettings(
        id: item.id,
        dateTime: target,
        assetAudioPath: audioPath,
        loopAudio: true,
        vibrate: true,
        volumeSettings: item.rampSeconds > 0
            ? VolumeSettings.fade(
                volume: 1.0,
                fadeDuration: Duration(seconds: item.rampSeconds),
              )
            : VolumeSettings.fixed(volume: 1.0),
        notificationSettings: NotificationSettings(
          title: item.title,
          body: 'Tap to dismiss or snooze',
          stopButton: 'Stop',
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
      _showToast('Alarm armed for ${_formatTime(target)}');
    } else {
      // Disable / deactivate without deleting
      await Alarm.stop(item.id);
      await IdMapper.setEnabled(item.id, false);
      if (item.uuid != null && !item.uuid!.startsWith('local_')) {
        BackendClient.updateAlarmState(item.uuid!, 'disabled');
      }
      _showToast('Alarm deactivated');
    }

    await _loadAllAlarms();
  }

  Future<void> _deleteAlarmItem(_AlarmItem item) async {
    await Alarm.stop(item.id);
    if (item.uuid != null && !item.uuid!.startsWith('local_')) {
      await BackendClient.deleteRemoteAlarm(item.uuid!);
    }
    await IdMapper.removeMapping(item.id);
    _showToast('Alarm deleted');
    _loadAllAlarms();
  }

  String _getRelativeCountdown(DateTime target) {
    final now = DateTime.now();
    final diff = target.difference(now);

    if (diff.isNegative) return 'due now';

    final hours = diff.inHours;
    final mins = diff.inMinutes % 60;

    if (hours == 0 && mins == 0) return 'in less than a minute';
    if (hours == 0) return 'in $mins mins';
    if (mins == 0) return 'in $hours hours';
    return 'in $hours hours $mins mins';
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
        setState(() => _fcmToken = token);
      }

      if (token != null) {
        _reportBatteryTelemetry();
      }

      FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
        await AlarmService.handleAlarmPayload(message.data);
        _loadAllAlarms();
      });
    } catch (e) {
      if (mounted) {
        setState(() => _fcmToken = 'Firebase unavailable: $e');
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
        backgroundColor: const Color(0xFF16181B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF26282E)),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ALARM DETAIL & ADJUSTMENTS MODAL
  void _showAlarmDetailModal(_AlarmItem item) {
    final titleController = TextEditingController(text: item.title);
    final descController = TextEditingController(text: item.description);
    DateTime selectedTime = item.dateTime;
    List<int> repeatDays = List.from(item.repeatDays);
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
                          'Alarm Details & Adjustments',
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

                    // Title
                    const Text(
                      'TITLE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.8,
                      ),
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
                        controller: titleController,
                        style: const TextStyle(fontSize: 14, color: Color(0xFFF7F8F8)),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Alarm Title',
                          hintStyle: TextStyle(color: Color(0xFF565A61)),
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // Free Rich Text Description
                    const Text(
                      'DESCRIPTION & NOTES (RICH TEXT)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF16181B),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF26282E)),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: descController,
                        maxLines: 3,
                        style: const TextStyle(fontSize: 13, color: Color(0xFFF7F8F8), height: 1.4),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Add rich details, checklists, wake goals, or routine notes...',
                          hintStyle: TextStyle(color: Color(0xFF565A61)),
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // Time Picker
                    const Text(
                      'TIME',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.8,
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
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF16181B),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF26282E)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              formattedTime,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFF7F8F8),
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            const Icon(Icons.access_time_rounded, size: 20, color: Color(0xFF8A8F98)),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // Sound Tone & Gentle Ramp Row
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
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF16181B),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFF26282E)),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: tone,
                                    isExpanded: true,
                                    dropdownColor: const Color(0xFF16181B),
                                    items: const [
                                      DropdownMenuItem(value: 'alarm', child: Text('Radar')),
                                      DropdownMenuItem(value: 'chime', child: Text('Chime')),
                                      DropdownMenuItem(value: 'digital', child: Text('Digital')),
                                    ],
                                    onChanged: (val) {
                                      if (val != null) setModalState(() => tone = val);
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
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF16181B),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFF26282E)),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<int>(
                                    value: ramp,
                                    isExpanded: true,
                                    dropdownColor: const Color(0xFF16181B),
                                    items: const [
                                      DropdownMenuItem(value: 0, child: Text('0s (Instant)')),
                                      DropdownMenuItem(value: 15, child: Text('15s Ramp')),
                                      DropdownMenuItem(value: 30, child: Text('30s Ramp')),
                                      DropdownMenuItem(value: 60, child: Text('60s Ramp')),
                                    ],
                                    onChanged: (val) {
                                      if (val != null) setModalState(() => ramp = val);
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
                                final updatedTitle = titleController.text.trim().isNotEmpty
                                    ? titleController.text.trim()
                                    : 'Alarm';
                                final updatedDesc = descController.text.trim();

                                item.title = updatedTitle;
                                item.description = updatedDesc;
                                item.dateTime = selectedTime;
                                item.soundTone = tone;
                                item.rampSeconds = ramp;

                                await IdMapper.saveMapping(
                                  item.id,
                                  item.uuid ?? 'local_${item.id}',
                                  label: updatedTitle,
                                  description: updatedDesc,
                                  targetTime: selectedTime,
                                );
                                await IdMapper.setSoundTone(item.id, tone);
                                await IdMapper.setRampSeconds(item.id, ramp);

                                if (item.isEnabled) {
                                  // Reschedule
                                  await _toggleAlarmEnabled(item, true);
                                } else {
                                  await _loadAllAlarms();
                                }

                                if (bottomSheetContext.mounted) {
                                  Navigator.pop(bottomSheetContext);
                                }
                                _showToast('Adjustments saved');
                              },
                              child: const Text(
                                'Save Adjustments',
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
                            child: const Text('Delete'),
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
                          'Settings & Configuration',
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
                      'ALARM CONFIGURATION',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Sound Tone Dropdown
                    _buildModalDropdown<String>(
                      label: 'Default Sound Profile',
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
                      label: 'Volume Ramp Duration',
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
                      'DISPLAY & FORMATTING RULES',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Time Format
                    _buildModalDropdown<String>(
                      label: 'Time Format Convention',
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
                      label: 'Date Format Convention',
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
                      'CALENDAR SUBSCRIPTION (RFC 5545)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy_rounded, size: 14),
                        label: const Text('Copy iCal Feed URL', style: TextStyle(fontSize: 12)),
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
                          _showToast('Copied iCal URL to clipboard');
                        },
                      ),
                    ),

                    const SizedBox(height: 24),

                    // SECTION 4: SERVER & DEVICE TELEMETRY
                    const Text(
                      'SERVER & HARDWARE TELEMETRY',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.8,
                      ),
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
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: const Color(0xFF16181B),
                          foregroundColor: const Color(0xFFF7F8F8),
                          side: const BorderSide(color: Color(0xFF26282E)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                          _telemetryRow('Phone Model', 'Android Device'),
                          const Divider(color: Color(0xFF26282E), height: 16),
                          _telemetryRow(
                            'Battery',
                            _batteryLevel != null
                                ? '$_batteryLevel% (${_isCharging ? 'Charging' : 'On Battery'})'
                                : 'Checking...',
                          ),
                          const Divider(color: Color(0xFF26282E), height: 16),
                          _telemetryRow(
                            'Push Token',
                            _fcmToken != null && _fcmToken!.length > 16
                                ? '${_fcmToken!.substring(0, 8)}...${_fcmToken!.substring(_fcmToken!.length - 6)}'
                                : 'Acquiring...',
                          ),
                        ],
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
          _showToast('Previewing $label audio');
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
                          'Schedule New Alarm',
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

                    // Label Input
                    const Text(
                      'ALARM TITLE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.8,
                      ),
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
                        controller: labelController,
                        style: const TextStyle(fontSize: 14, color: Color(0xFFF7F8F8)),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'e.g. Quick catchup',
                          hintStyle: TextStyle(color: Color(0xFF565A61)),
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // Description / Rich Notes
                    const Text(
                      'DESCRIPTION & NOTES (RICH TEXT)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF16181B),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF26282E)),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: descController,
                        maxLines: 2,
                        style: const TextStyle(fontSize: 13, color: Color(0xFFF7F8F8), height: 1.4),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Optional notes, checklist, or routine...',
                          hintStyle: TextStyle(color: Color(0xFF565A61)),
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // Time Picker
                    const Text(
                      'TRIGGER TIME',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.8,
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
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF16181B),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF26282E)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              formattedTime,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFF7F8F8),
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            const Icon(Icons.access_time_rounded, size: 20, color: Color(0xFF8A8F98)),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // Tone & Ramp
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
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF16181B),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFF26282E)),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: selectedTone,
                                    isExpanded: true,
                                    dropdownColor: const Color(0xFF16181B),
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
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF16181B),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFF26282E)),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<int>(
                                    value: selectedRampSeconds,
                                    isExpanded: true,
                                    dropdownColor: const Color(0xFF16181B),
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
                          final cleanTime = DateTime(
                            selectedTime.year,
                            selectedTime.month,
                            selectedTime.day,
                            selectedTime.hour,
                            selectedTime.minute,
                            0,
                            0,
                          );

                          String assetAudio = AlarmService.getAudioPathForTone(selectedTone);
                          final title = labelController.text.trim().isNotEmpty
                              ? labelController.text.trim()
                              : 'Alarm';
                          final desc = descController.text.trim();

                          // First create on backend to establish sync with dashboard
                          String? remoteId = await BackendClient.createRemoteAlarm(
                            targetTime: cleanTime,
                            label: title,
                            description: desc,
                            soundTone: selectedTone,
                            rampSeconds: selectedRampSeconds,
                          );

                          final assignedUuid = remoteId ?? 'local_${DateTime.now().millisecondsSinceEpoch}';
                          final intId = IdMapper.uuidToInt(assignedUuid);

                          final settings = AlarmSettings(
                            id: intId,
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
                              title: title,
                              body: 'Tap to open alarm',
                              stopButton: 'Stop',
                            ),
                          );

                          await Alarm.set(alarmSettings: settings);
                          await IdMapper.saveMapping(
                            intId,
                            assignedUuid,
                            label: title,
                            description: desc,
                            targetTime: cleanTime,
                          );
                          await IdMapper.setSoundTone(intId, selectedTone);
                          await IdMapper.setRampSeconds(intId, selectedRampSeconds);
                          await IdMapper.setEnabled(intId, true);

                          if (bottomSheetContext.mounted) {
                            Navigator.pop(bottomSheetContext);
                          }
                          _showToast('Alarm armed for $formattedTime');
                          _loadAllAlarms();
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
    // Filtered list based on search query
    final filteredAlarms = _allAlarms.where((item) {
      if (_searchQuery.isEmpty) return true;
      final query = _searchQuery.toLowerCase();
      return item.title.toLowerCase().contains(query) ||
          item.description.toLowerCase().contains(query);
    }).toList();

    // Hero alarm: earliest upcoming enabled alarm
    final enabledAlarms = _allAlarms.where((a) => a.isEnabled).toList();
    final upcomingHeroAlarm = enabledAlarms.isNotEmpty ? enabledAlarms.first : null;

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
                      const SizedBox(width: 4),
                      const Icon(Icons.unfold_more_rounded, size: 14, color: Color(0xFF8A8F98)),
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
                    // Hero Upcoming Alarm Card (Linear Active Cycle style with soft shadows & textures)
                    if (upcomingHeroAlarm != null && _searchQuery.isEmpty) ...[
                      _buildUpcomingHeroCard(upcomingHeroAlarm),
                      const SizedBox(height: 24),
                    ],

                    // Section Header: ALL ALARMS (Renamed from active alarms)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'ALL ALARMS',
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
                                '${filteredAlarms.length}',
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

                    // List of All Alarms
                    if (filteredAlarms.isEmpty)
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
                    else
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: filteredAlarms.length,
                        separatorBuilder: (context, index) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final alarm = filteredAlarms[index];
                          return _buildAlarmRowCard(alarm);
                        },
                      ),

                    const SizedBox(height: 80), // Space for FAB
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: GestureDetector(
        onTap: _showCreateAlarmModal,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration: BoxDecoration(
            color: const Color(0xFF5E6AD2),
            borderRadius: BorderRadius.circular(21),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 16,
                offset: Offset(0, 6),
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
  }

  // Hero Upcoming Alarm Card with rich textured styling & relative countdown
  Widget _buildUpcomingHeroCard(_AlarmItem alarm) {
    final formattedTime = _formatTime(alarm.dateTime);
    final countdown = _getRelativeCountdown(alarm.dateTime);

    return InkWell(
      onTap: () => _showAlarmDetailModal(alarm),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1D22), Color(0xFF121417)],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF2C2F36), width: 1),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 20,
              spreadRadius: -2,
              offset: Offset(0, 8),
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
                    _formatRepeatDays(alarm.repeatDays),
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
    );
  }

  // Individual Alarm Row Card with smooth slider & click for rich details
  Widget _buildAlarmRowCard(_AlarmItem alarm) {
    final timeStr = _formatTime(alarm.dateTime);
    final textColor = alarm.isEnabled ? const Color(0xFFF7F8F8) : const Color(0xFF565A61);
    final subtextColor = alarm.isEnabled ? const Color(0xFF8A8F98) : const Color(0xFF45484F);

    return InkWell(
      onTap: () => _showAlarmDetailModal(alarm),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: alarm.isEnabled
                ? [const Color(0xFF16181C), const Color(0xFF121417)]
                : [const Color(0xFF111215), const Color(0xFF0D0E10)],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: alarm.isEnabled ? const Color(0xFF262930) : const Color(0xFF1C1D21),
            width: 1,
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
            // Left Status Icon
            Icon(
              Icons.access_time_rounded,
              size: 18,
              color: alarm.isEnabled
                  ? (alarm.isSnoozed ? const Color(0xFFE5A158) : const Color(0xFF5E6AD2))
                  : const Color(0xFF45484F),
            ),
            const SizedBox(width: 14),

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
                          _formatRepeatDays(alarm.repeatDays),
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

            // Smooth Slider Switch (Linear style)
            Switch.adaptive(
              value: alarm.isEnabled,
              activeColor: const Color(0xFFFFFFFF),
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
}
