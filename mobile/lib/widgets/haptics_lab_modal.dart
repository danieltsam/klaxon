import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/haptic_service.dart';
import 'time_pickers.dart';

class HapticsLabModal extends StatefulWidget {
  const HapticsLabModal({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F1013),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF26282E)),
      ),
      builder: (_) => const HapticsLabModal(),
    );
  }

  @override
  State<HapticsLabModal> createState() => _HapticsLabModalState();
}

class _HapticsLabModalState extends State<HapticsLabModal> {
  static const MethodChannel _permissionsChannel = MethodChannel('com.remotealarm.mobile/permissions');

  bool _testSwitchState = true;
  double _interactiveScrubValue = 25.0;
  int _lastScrubInt = 25;
  bool? _canUseFullScreenIntent;

  // Live Tumbler Demo State
  int _demoHour = 7;
  int _demoMinute = 30;
  late final FixedExtentScrollController _demoHourController;
  late final FixedExtentScrollController _demoMinuteController;
  late final FixedExtentScrollController _demoAmPmController;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _demoHourController = FixedExtentScrollController(initialItem: 6);
    _demoMinuteController = FixedExtentScrollController(initialItem: 30);
    _demoAmPmController = FixedExtentScrollController(initialItem: 0);
  }

  @override
  void dispose() {
    _demoHourController.dispose();
    _demoMinuteController.dispose();
    _demoAmPmController.dispose();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    try {
      final allowed = await _permissionsChannel.invokeMethod<bool>('canUseFullScreenIntent');
      if (mounted) {
        setState(() => _canUseFullScreenIntent = allowed);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Handle Bar
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
          const SizedBox(height: 14),

          // Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF5E6AD2).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF5E6AD2).withValues(alpha: 0.3)),
                        ),
                        child: const Icon(Icons.vibration_rounded, size: 16, color: Color(0xFF5E6AD2)),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'haptic testing lab',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFF7F8F8),
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Live tumbler, mechanical clacks & soft decoupling cadences',
                    style: TextStyle(fontSize: 11, color: Color(0xFF8A8F98)),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF8A8F98)),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Scrollable Sections
          Expanded(
            child: ListView(
              children: [
                // ANDROID 14 FULL SCREEN INTENT DIAGNOSTIC BANNER
                if (_canUseFullScreenIntent == false) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE66432).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE66432).withValues(alpha: 0.4)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, color: Color(0xFFE66432), size: 18),
                            SizedBox(width: 8),
                            Text(
                              'full-screen intent restricted (Android 14+)',
                              style: TextStyle(color: Color(0xFFE66432), fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Your phone requires explicit permission to pop the alarm screen over the lockscreen from memory.',
                          style: TextStyle(color: Color(0xFF8A8F98), fontSize: 11, height: 1.3),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE66432),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            minimumSize: Size.zero,
                          ),
                          onPressed: () async {
                            await _permissionsChannel.invokeMethod('openFullScreenIntentSettings');
                          },
                          child: const Text('open settings & allow', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ],

                // SECTION 1: LIVE INTERACTIVE ACTION BUTTONS
                _buildSectionHeader('interactive buttons & toggles', 'Test active arming, disarming & snooze on actual controls'),
                const SizedBox(height: 8),

                Container(
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16181B),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF26282E)),
                  ),
                  child: Column(
                    children: [
                      // Switch Row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'alarm toggle switch',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFF7F8F8)),
                              ),
                              Text(
                                _testSwitchState ? 'armed (plays active arm style)' : 'disarmed (plays active disarm style)',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _testSwitchState ? const Color(0xFF5E6AD2) : const Color(0xFF8A8F98),
                                ),
                              ),
                            ],
                          ),
                          Switch(
                            value: _testSwitchState,
                            activeThumbColor: const Color(0xFF5E6AD2),
                            activeTrackColor: const Color(0xFF5E6AD2).withValues(alpha: 0.35),
                            inactiveThumbColor: const Color(0xFF8A8F98),
                            inactiveTrackColor: const Color(0xFF26282E),
                            onChanged: (val) async {
                              setState(() => _testSwitchState = val);
                              if (val) {
                                await HapticService.playArm();
                              } else {
                                await HapticService.playDisarm();
                              }
                            },
                          ),
                        ],
                      ),
                      const Divider(color: Color(0xFF26282E), height: 20),

                      // Interactive Alarm Action Buttons
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF5E6AD2),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () => HapticService.playArm(),
                              icon: const Icon(Icons.alarm_on, size: 15),
                              label: const Text('arm', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF26282E),
                                foregroundColor: const Color(0xFFF7F8F8),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () => HapticService.playDisarm(),
                              icon: const Icon(Icons.alarm_off, size: 15),
                              label: const Text('disarm', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFE66432).withValues(alpha: 0.15),
                                foregroundColor: const Color(0xFFE66432),
                                side: BorderSide(color: const Color(0xFFE66432).withValues(alpha: 0.4)),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () => HapticService.playPreset(),
                              icon: const Icon(Icons.snooze, size: 15),
                              label: const Text('snooze', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // SECTION 2: LIVE CIRCULAR DRUM TUMBLER DEMO
                _buildSectionHeader('live drum tumbler demo', 'Spin our circular tumbler to test scroll / crown haptics'),
                const SizedBox(height: 8),

                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16181B),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF5E6AD2).withValues(alpha: 0.35)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'active: ${HapticService.scrollStyleTitle(HapticService.activeScrollStyle)}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF5E6AD2)),
                          ),
                          Text(
                            '${_demoHour.toString().padLeft(2, '0')}:${_demoMinute.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              fontFeatures: [FontFeature.tabularFigures()],
                              color: Color(0xFFF7F8F8),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Embedded Real DrumTumblerPicker
                      DrumTumblerPicker(
                        curHour: _demoHour,
                        curMinute: _demoMinute,
                        is12h: true,
                        hourController: _demoHourController,
                        minuteController: _demoMinuteController,
                        amPmController: _demoAmPmController,
                        onHourChanged: (h) => setState(() => _demoHour = h),
                        onMinuteChanged: (m) => setState(() => _demoMinute = m),
                        onAmPmChanged: (isPm) {},
                      ),

                      const SizedBox(height: 10),
                      // Interactive Continuous Scrub Slider
                      Row(
                        children: [
                          const Icon(Icons.linear_scale, size: 14, color: Color(0xFF8A8F98)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                activeTrackColor: const Color(0xFF5E6AD2),
                                inactiveTrackColor: const Color(0xFF26282E),
                                thumbColor: const Color(0xFF717DF0),
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                              ),
                              child: Slider(
                                value: _interactiveScrubValue,
                                min: 0,
                                max: 60,
                                onChanged: (val) {
                                  final currentInt = val.round();
                                  if (currentInt != _lastScrubInt) {
                                    final isMajor = currentInt % 5 == 0;
                                    final isSuperMajor = currentInt % 15 == 0;
                                    HapticService.playScrollTick(
                                      isMajor: isMajor,
                                      isSuperMajor: isSuperMajor,
                                      unit: currentInt,
                                    );
                                    _lastScrubInt = currentInt;
                                  }
                                  setState(() => _interactiveScrubValue = val);
                                },
                              ),
                            ),
                          ),
                          Text(
                            ':${_interactiveScrubValue.round().toString().padLeft(2, '0')}',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF8A8F98)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // SECTION 3: SCROLL / TUMBLER HAPTIC STYLES
                _buildSectionHeader('tumbler haptic styles', 'Select your preferred detent feel for the wheels'),
                const SizedBox(height: 8),

                ...ScrollHapticStyle.values.map((style) {
                  final isActive = HapticService.activeScrollStyle == style;
                  return _buildHapticCard(
                    title: HapticService.scrollStyleTitle(style),
                    description: HapticService.scrollStyleDesc(style),
                    isActive: isActive,
                    onTest: () {
                      HapticService.playScrollTick(isSuperMajor: true, overrideStyle: style);
                    },
                    onSelect: () async {
                      await HapticService.setScrollStyle(style);
                      HapticService.playScrollTick(isSuperMajor: true, overrideStyle: style);
                      setState(() {});
                    },
                  );
                }),

                const SizedBox(height: 20),

                // SECTION 4: ARMING ALARMS (Dual Clack Variations)
                _buildSectionHeader('arming cadences (dual clack focus)', 'Rhythmic mechanical relay cadences (>60ms spacing)'),
                const SizedBox(height: 8),

                ...ArmHapticStyle.values.map((style) {
                  final isActive = HapticService.activeArmStyle == style;
                  return _buildHapticCard(
                    title: HapticService.armStyleTitle(style),
                    description: HapticService.armStyleDesc(style),
                    isActive: isActive,
                    onTest: () => HapticService.playArm(style),
                    onSelect: () async {
                      await HapticService.setArmStyle(style);
                      await HapticService.playArm(style);
                      setState(() {});
                    },
                  );
                }),

                const SizedBox(height: 20),

                // SECTION 5: DISARMING ALARMS (Double Soft Tap Variations)
                _buildSectionHeader('disarming cadences (soft tap focus)', 'Gentle decoupling, dissolving releases & soft rebounds'),
                const SizedBox(height: 8),

                ...DisarmHapticStyle.values.map((style) {
                  final isActive = HapticService.activeDisarmStyle == style;
                  return _buildHapticCard(
                    title: HapticService.disarmStyleTitle(style),
                    description: HapticService.disarmStyleDesc(style),
                    isActive: isActive,
                    onTest: () => HapticService.playDisarm(style),
                    onSelect: () async {
                      await HapticService.setDisarmStyle(style);
                      await HapticService.playDisarm(style);
                      setState(() {});
                    },
                  );
                }),

                const SizedBox(height: 20),

                // SECTION 6: CONTINUOUS URGENT ALARM PATTERNS
                _buildSectionHeader('continuous urgent alarm patterns', 'Rhythmic multi-beat emergency motor cadences'),
                const SizedBox(height: 8),

                _buildUrgentCard(
                  'siren wave (5-pulse ascending)',
                  'Progressive build-up: light → medium → peak heavy → medium → light (90-120ms)',
                  UrgentHapticStyle.sirenWave,
                ),
                _buildUrgentCard(
                  'double heartbeat (repeat cycle)',
                  'Authoritative lub-dub pair with 350ms rest interval',
                  UrgentHapticStyle.doubleHeartbeat,
                ),
                _buildUrgentCard(
                  'sos morse rhythm',
                  '3 short (80ms) → 3 long (140ms) → 3 short (80ms) rhythmic sequence',
                  UrgentHapticStyle.sosMorse,
                ),
                _buildUrgentCard(
                  'rapid alert (4 heavy pulses)',
                  '4 authoritative heavy thuds spaced at 120ms intervals',
                  UrgentHapticStyle.rapidAlert4,
                ),

                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Color(0xFF8A8F98),
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 11, color: Color(0xFF565A61)),
        ),
      ],
    );
  }

  Widget _buildHapticCard({
    required String title,
    required String description,
    required bool isActive,
    required VoidCallback onTest,
    required VoidCallback onSelect,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF5E6AD2).withValues(alpha: 0.08) : const Color(0xFF16181B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive ? const Color(0xFF5E6AD2) : const Color(0xFF26282E),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isActive ? const Color(0xFF9AA5FF) : const Color(0xFFF7F8F8),
                      ),
                    ),
                    if (isActive) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFF5E6AD2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'active',
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF8A8F98), height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.play_arrow_rounded, size: 20, color: Color(0xFFF7F8F8)),
                tooltip: 'test haptic pattern',
                onPressed: onTest,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF26282E),
                  padding: const EdgeInsets.all(8),
                ),
              ),
              const SizedBox(width: 4),
              if (!isActive)
                TextButton(
                  onPressed: onSelect,
                  child: const Text(
                    'Use',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF5E6AD2)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUrgentCard(String title, String description, UrgentHapticStyle style) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFF16181B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF26282E)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFF7F8F8)),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF8A8F98), height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.play_arrow_rounded, size: 20, color: Color(0xFFE66432)),
            tooltip: 'play urgent pattern',
            onPressed: () => HapticService.playUrgent(style),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFE66432).withValues(alpha: 0.15),
              padding: const EdgeInsets.all(8),
            ),
          ),
        ],
      ),
    );
  }
}

