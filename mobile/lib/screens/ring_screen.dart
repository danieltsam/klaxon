import 'dart:async';
import 'package:flutter/material.dart';
import 'package:alarm/alarm.dart';
import '../services/alarm_service.dart';
import '../utils/id_mapper.dart';

class RingScreen extends StatefulWidget {
  final AlarmSettings alarmSettings;

  const RingScreen({super.key, required this.alarmSettings});

  @override
  State<RingScreen> createState() => _RingScreenState();
}

class _RingScreenState extends State<RingScreen> with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _rampController;
  late Timer _clockTimer;
  StreamSubscription<int>? _remoteDismissSub;
  DateTime _now = DateTime.now();
  DateTime _rampStartTime = DateTime.now();
  bool _isProcessing = false;
  int _rampDurationSeconds = 30;
  String _soundTone = 'alarm';

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _rampController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    );
    _rampStartTime = DateTime.now();
    _rampController.forward();

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _now = DateTime.now();
        });
      }
    });

    _loadToneAndRamp();

    // Automatically pop when silenced remotely from dashboard
    _remoteDismissSub = AlarmService.onRemoteDismissed.stream.listen((dismissedId) {
      if (dismissedId == widget.alarmSettings.id && mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _loadToneAndRamp() async {
    final ramp = await IdMapper.getRampSeconds(widget.alarmSettings.id);
    final tone = await IdMapper.getSoundTone(widget.alarmSettings.id);
    if (mounted) {
      setState(() {
        _rampDurationSeconds = ramp;
        _soundTone = tone;
      });

      final newDuration = Duration(seconds: _rampDurationSeconds);
      final elapsed = DateTime.now().difference(_rampStartTime);
      _rampController.duration = newDuration;

      if (_rampDurationSeconds <= 0) {
        _rampController.value = 1.0;
      } else {
        final targetValue = (elapsed.inMilliseconds / newDuration.inMilliseconds).clamp(0.0, 1.0);
        _rampController.value = targetValue;
        if (!_rampController.isAnimating && _rampController.value < 1.0) {
          _rampController.forward(from: _rampController.value);
        }
      }
    }
  }

  @override
  void dispose() {
    _remoteDismissSub?.cancel();
    _pulseController.dispose();
    _rampController.dispose();
    _clockTimer.cancel();
    super.dispose();
  }

  Future<void> _handleDismiss() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      await AlarmService.dismissAlarm(widget.alarmSettings);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      // Never leave the ring screen with disabled buttons over a live alarm.
      // ignore: avoid_print
      print('[RingScreen] dismiss failed: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('could not dismiss — try again')),
        );
      }
    }
  }

  Future<void> _handleSnooze() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      await AlarmService.snoozeAlarm(widget.alarmSettings);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[RingScreen] snooze failed: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('could not snooze — try again')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.alarmSettings.notificationSettings.title.isNotEmpty
        ? widget.alarmSettings.notificationSettings.title
        : 'Alarm';

    final hourStr = _now.hour.toString().padLeft(2, '0');
    final minuteStr = _now.minute.toString().padLeft(2, '0');
    final amPmStr = _now.hour >= 12 ? 'PM' : 'AM';

    return PopScope(
      canPop: false, // Prevent accidental back gesture
      child: Scaffold(
        backgroundColor: const Color(0xFF08090A),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Top Status Pill (Linear style)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121316),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF222326)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ScaleTransition(
                        scale: _pulseAnimation,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Color(0xFFEB5757),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'alarm active • listening for remote silence',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8A8F98),
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Giant Digital Clock (Linear high contrast)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$hourStr:$minuteStr',
                      style: const TextStyle(
                        fontSize: 64,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFF7F8F8),
                        letterSpacing: -1.5,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      amPmStr,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF8A8F98),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // Alarm Title
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFFF7F8F8),
                    letterSpacing: -0.3,
                  ),
                ),

                const SizedBox(height: 32),

                // Gentle Wake Ramp Progress Card (Linear style)
                AnimatedBuilder(
                  animation: _rampController,
                  builder: (context, child) {
                    final rampGain = AlarmService.perceivedVolumeProgress(_rampController.value);
                    final rampProgress = AlarmService.perceivedLoudnessProgress(rampGain);
                    final rampPercentage = (rampProgress * 100).toInt();

                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
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
                                '$_soundTone sound',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFFF7F8F8),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                _rampDurationSeconds > 0
                                    ? '$_rampDurationSeconds' 's gentle wake ramp'
                                    : 'immediate full volume',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF8A8F98),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: rampProgress,
                              minHeight: 4,
                              backgroundColor: const Color(0xFF1C1D21),
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF5E6AD2)),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              '$rampPercentage%',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF8A8F98),
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                const Spacer(),

                // Action Buttons (Linear style: Stark White Primary + Border Ghost Secondary)
                Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF7F8F8),
                          foregroundColor: const Color(0xFF08090A),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: _isProcessing ? null : _handleDismiss,
                        child: _isProcessing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text(
                                '[ dismiss ]',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.3,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: const Color(0xFF121316),
                          foregroundColor: const Color(0xFFF7F8F8),
                          side: const BorderSide(color: Color(0xFF222326)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: _isProcessing ? null : _handleSnooze,
                        child: const Text(
                          '[ snooze +9m ]',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF8A8F98),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
