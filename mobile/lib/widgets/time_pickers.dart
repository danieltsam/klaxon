import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import '../services/haptic_service.dart';

/// Legacy enum kept for backward compatibility with existing preferences
enum TimePickerStyle { drum }

extension TimePickerStyleExt on TimePickerStyle {
  String get id => 'drum';
  String get displayName => 'Tumbler';
  static TimePickerStyle fromString(String? val) => TimePickerStyle.drum;
}

/// Custom ballistic scroll physics for the minute drum:
/// - Automatically gravitates and snaps to 5-minute milestones (:00, :05, :10, :15...)
///   on regular scrolls and flings (velocity > 80 px/s).
/// - Allows fine-grained single-minute micro adjustments (1-4, 6-9) when dragged slowly.
class FiveMinuteSnapScrollPhysics extends FixedExtentScrollPhysics {
  final double itemExtent;

  const FiveMinuteSnapScrollPhysics({super.parent, this.itemExtent = 44.0});

  @override
  FiveMinuteSnapScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return FiveMinuteSnapScrollPhysics(
      parent: buildParent(ancestor),
      itemExtent: itemExtent,
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final Simulation? baseSimulation = super.createBallisticSimulation(
      position,
      velocity,
    );
    final double naturalLandingPixels =
        baseSimulation?.x(double.infinity) ?? position.pixels;

    final double rawIndex = naturalLandingPixels / itemExtent;
    final int standardIndex = rawIndex.round();

    // If velocity is substantial or fling occurs, snap to nearest multiple of 5
    if (velocity.abs() > 80.0) {
      final int snappedIndex = (standardIndex / 5.0).round() * 5;
      final double targetPixels = snappedIndex * itemExtent;

      if ((targetPixels - position.pixels).abs() <
              toleranceFor(position).distance &&
          velocity.abs() < toleranceFor(position).velocity) {
        return null;
      }

      if (velocity.abs() < 140.0) {
        return SpringSimulation(
          spring,
          position.pixels,
          targetPixels,
          velocity,
          tolerance: toleranceFor(position),
        );
      } else {
        return FrictionSimulation.through(
          position.pixels,
          targetPixels,
          velocity,
          toleranceFor(position).velocity *
              (velocity == 0.0 ? 1.0 : velocity.sign),
        );
      }
    }

    return baseSimulation;
  }
}

/// Definitive 3D Drum Tumbler Time Picker
/// Features realistic cylindrical dial wells, metallic depth gradients,
/// aperture selection window, and 5-minute magnetic minute snapping.
class DrumTumblerPicker extends StatelessWidget {
  final int curHour;
  final int curMinute;
  final bool is12h;
  final FixedExtentScrollController hourController;
  final FixedExtentScrollController minuteController;
  final FixedExtentScrollController amPmController;
  final void Function(int newH) onHourChanged;
  final void Function(int newM) onMinuteChanged;
  final void Function(bool isPm) onAmPmChanged;

  const DrumTumblerPicker({
    super.key,
    required this.curHour,
    required this.curMinute,
    required this.is12h,
    required this.hourController,
    required this.minuteController,
    required this.amPmController,
    required this.onHourChanged,
    required this.onMinuteChanged,
    required this.onAmPmChanged,
  });

  @override
  Widget build(BuildContext context) {
    final bool isPm = curHour >= 12;

    return Container(
      height: 196,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0E11),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF22252C)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Dials Row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Hours Cylindrical Dial Well
              _buildDialWell(
                width: is12h ? 72 : 84,
                child: ListWheelScrollView.useDelegate(
                  controller: hourController,
                  itemExtent: 44,
                  perspective: 0.0045,
                  diameterRatio: 1.25,
                  magnification: 1.08,
                  useMagnifier: true,
                  physics: const FixedExtentScrollPhysics(),
                  onSelectedItemChanged: (idx) {
                    int newHour;
                    if (is12h) {
                      final val12 = (idx % 12) + 1;
                      newHour = isPm
                          ? (val12 == 12 ? 12 : val12 + 12)
                          : (val12 == 12 ? 0 : val12);
                    } else {
                      newHour = idx % 24;
                    }
                    HapticService.playScrollTick(
                      isMajor: true,
                      isSuperMajor: newHour % 12 == 0,
                      unit: newHour,
                    );
                    onHourChanged(newHour);
                  },
                  childDelegate: ListWheelChildLoopingListDelegate(
                    children: List.generate(is12h ? 12 : 24, (i) {
                      final val = is12h ? (i + 1) : i;
                      final isSelected = is12h
                          ? (val == (curHour % 12 == 0 ? 12 : curHour % 12))
                          : (val == curHour);
                      final isMilestone = is12h
                          ? (val % 3 == 0)
                          : (val % 6 == 0);
                      final str = val.toString().padLeft(2, '0');
                      return SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _MilledDiscRowPainter(
                                  isSelected: isSelected,
                                  isMilestone: isMilestone,
                                  isHour: true,
                                ),
                              ),
                            ),
                            Text(
                              str,
                              style: TextStyle(
                                fontSize: 27,
                                fontWeight: isSelected
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                color: isSelected
                                    ? const Color(0xFFFFFFFF)
                                    : const Color(0xFF4C515B),
                                letterSpacing: -0.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                shadows: isSelected
                                    ? const [
                                        Shadow(
                                          color: Color(0x665E6AD2),
                                          blurRadius: 10,
                                        ),
                                      ]
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ),

              // Chassis Groove & Colon Divider
              Container(
                width: 24,
                alignment: Alignment.center,
                child: const Text(
                  ':',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF727782),
                  ),
                ),
              ),

              // Minutes Cylindrical Dial Well with 5-Minute Magnetic Snapping
              _buildDialWell(
                width: is12h ? 72 : 84,
                child: ListWheelScrollView.useDelegate(
                  controller: minuteController,
                  itemExtent: 44,
                  perspective: 0.0045,
                  diameterRatio: 1.25,
                  magnification: 1.08,
                  useMagnifier: true,
                  physics: const FiveMinuteSnapScrollPhysics(itemExtent: 44),
                  onSelectedItemChanged: (idx) {
                    final newMin = idx % 60;
                    final isMajor = newMin % 5 == 0;
                    final isSuperMajor = newMin == 0;
                    HapticService.playScrollTick(
                      isMajor: isMajor,
                      isSuperMajor: isSuperMajor,
                      unit: newMin,
                    );
                    onMinuteChanged(newMin);
                  },
                  childDelegate: ListWheelChildLoopingListDelegate(
                    children: List.generate(60, (i) {
                      final isSelected = i == curMinute;
                      final isMilestone = i % 5 == 0;
                      final str = i.toString().padLeft(2, '0');
                      return SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _MilledDiscRowPainter(
                                  isSelected: isSelected,
                                  isMilestone: isMilestone,
                                  isHour: false,
                                ),
                              ),
                            ),
                            Text(
                              str,
                              style: TextStyle(
                                fontSize: 27,
                                fontWeight: isSelected
                                    ? FontWeight.w800
                                    : (isMilestone
                                          ? FontWeight.w600
                                          : FontWeight.w400),
                                color: isSelected
                                    ? const Color(0xFFFFFFFF)
                                    : (isMilestone
                                          ? const Color(0xFF6B7280)
                                          : const Color(0xFF444852)),
                                letterSpacing: -0.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                shadows: isSelected
                                    ? const [
                                        Shadow(
                                          color: Color(0x665E6AD2),
                                          blurRadius: 10,
                                        ),
                                      ]
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ),

              // AM/PM Cylindrical Dial Well
              if (is12h) ...[
                const SizedBox(width: 8),
                _buildDialWell(
                  width: 60,
                  child: ListWheelScrollView.useDelegate(
                    controller: amPmController,
                    itemExtent: 44,
                    perspective: 0.0045,
                    diameterRatio: 1.25,
                    magnification: 1.06,
                    useMagnifier: true,
                    physics: const FixedExtentScrollPhysics(),
                    onSelectedItemChanged: (idx) {
                      HapticService.playScrollTick(
                        isMajor: true,
                        isSuperMajor: true,
                        unit: 0,
                      );
                      onAmPmChanged(idx == 1);
                    },
                    childDelegate: ListWheelChildListDelegate(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          height: 44,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _MilledDiscRowPainter(
                                    isSelected: !isPm,
                                    isMilestone: true,
                                    isHour: false,
                                  ),
                                ),
                              ),
                              Text(
                                'AM',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: !isPm
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color: !isPm
                                      ? const Color(0xFFFFFFFF)
                                      : const Color(0xFF4C515B),
                                  letterSpacing: 0.5,
                                  shadows: !isPm
                                      ? const [
                                          Shadow(
                                            color: Color(0x665E6AD2),
                                            blurRadius: 8,
                                          ),
                                        ]
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: double.infinity,
                          height: 44,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _MilledDiscRowPainter(
                                    isSelected: isPm,
                                    isMilestone: true,
                                    isHour: false,
                                  ),
                                ),
                              ),
                              Text(
                                'PM',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: isPm
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color: isPm
                                      ? const Color(0xFFFFFFFF)
                                      : const Color(0xFF4C515B),
                                  letterSpacing: 0.5,
                                  shadows: isPm
                                      ? const [
                                          Shadow(
                                            color: Color(0x665E6AD2),
                                            blurRadius: 8,
                                          ),
                                        ]
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),

          // Center Aperture Selection Window Overlay (Machined Caliper Brackets)
          Positioned(
            left: 4,
            right: 4,
            height: 48,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: const Color(0x105E6AD2),
                  border: const Border.symmetric(
                    horizontal: BorderSide(
                      color: Color(0xFF424856),
                      width: 1.3,
                    ),
                  ),
                  boxShadow: const [
                    BoxShadow(color: Color(0x1F5E6AD2), blurRadius: 8),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 3),
                      child: CustomPaint(
                        size: const Size(5, 8),
                        painter: const _ApertureNotchPainter(isLeft: true),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: CustomPaint(
                        size: const Size(5, 8),
                        painter: const _ApertureNotchPainter(isLeft: false),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds a single 3D cylindrical dial chamber with machined metal finish
  Widget _buildDialWell({required double width, required Widget child}) {
    return Container(
      width: width,
      height: 180,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF08090B), // deep rim shadow
            Color(0xFF13151B), // curvature roll
            Color(0xFF1E2129), // apex specular reflection along center
            Color(0xFF13151B), // curvature roll
            Color(0xFF08090B), // deep rim shadow
          ],
          stops: [0.0, 0.28, 0.50, 0.72, 1.0],
        ),
        border: Border.all(color: const Color(0xFF262932)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 5,
            offset: Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          child,
          // Cylindrical depth vignettes on top and bottom edges
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xDD08090B),
                      Color(0x0008090B),
                      Color(0x0008090B),
                      Color(0xDD08090B),
                    ],
                    stops: [0.0, 0.24, 0.76, 1.0],
                  ),
                ),
              ),
            ),
          ),
          // Precision machined side slot bevel highlights
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 1,
            child: Container(color: const Color(0x18FFFFFF)),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 1,
            child: Container(color: const Color(0x28000000)),
          ),
        ],
      ),
    );
  }
}

/// Backwards compatibility alias
typedef ClassicDrumTimePicker = DrumTumblerPicker;

/// Custom painter for precision CNC-milled lathe ribbing and engraved flank index ticks
class _MilledDiscRowPainter extends CustomPainter {
  final bool isSelected;
  final bool isMilestone;
  final bool isHour;

  const _MilledDiscRowPainter({
    required this.isSelected,
    required this.isMilestone,
    this.isHour = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. CNC lathe ribbing strictly on outer lateral flanks (leaving the center 100% clean for numerals)
    final darkPaint = Paint()
      ..color = const Color(0x2E000000)
      ..strokeWidth = 1.3;
    final specularPaint = Paint()
      ..color = const Color(0x12FFFFFF)
      ..strokeWidth = 1.0;

    // Outer flank width is 4px on left and right (strictly outermost edges,
    // well clear of the centered numerals)
    const double flankWidth = 4.0;
    for (double y = 3; y < size.height; y += 10) {
      // Left outer flank rib
      canvas.drawLine(Offset(0.5, y), Offset(flankWidth, y), darkPaint);
      canvas.drawLine(
        Offset(0.5, y + 1.3),
        Offset(flankWidth, y + 1.3),
        specularPaint,
      );

      // Right outer flank rib
      canvas.drawLine(
        Offset(size.width - flankWidth, y),
        Offset(size.width - 0.5, y),
        darkPaint,
      );
      canvas.drawLine(
        Offset(size.width - flankWidth, y + 1.3),
        Offset(size.width - 0.5, y + 1.3),
        specularPaint,
      );
    }

    // 2. Precision engraved index tick marks on the disc outer perimeter
    final tickWidth = isMilestone ? 4.5 : 2.5;
    final tickHeight = isMilestone ? 1.8 : 1.0;
    final tickColor = isSelected
        ? const Color(0xFF818CF8)
        : (isMilestone ? const Color(0xFF5A6070) : const Color(0xFF282C35));

    final tickPaint = Paint()
      ..color = tickColor
      ..style = PaintingStyle.fill;

    // Left flank tick
    final leftRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5, (size.height - tickHeight) / 2, tickWidth, tickHeight),
      const Radius.circular(0.5),
    );
    canvas.drawRRect(leftRect, tickPaint);

    // Right flank tick
    final rightRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width - tickWidth - 0.5,
        (size.height - tickHeight) / 2,
        tickWidth,
        tickHeight,
      ),
      const Radius.circular(0.5),
    );
    canvas.drawRRect(rightRect, tickPaint);
  }

  @override
  bool shouldRepaint(covariant _MilledDiscRowPainter oldDelegate) {
    return oldDelegate.isSelected != isSelected ||
        oldDelegate.isMilestone != isMilestone ||
        oldDelegate.isHour != isHour;
  }
}

/// Custom painter for mechanical index arrow notches on the selection aperture
class _ApertureNotchPainter extends CustomPainter {
  final bool isLeft;
  const _ApertureNotchPainter({required this.isLeft});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF818CF8)
      ..style = PaintingStyle.fill;
    final path = Path();
    if (isLeft) {
      path.moveTo(0, 0);
      path.lineTo(size.width, size.height / 2);
      path.lineTo(0, size.height);
    } else {
      path.moveTo(size.width, 0);
      path.lineTo(0, size.height / 2);
      path.lineTo(size.width, size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ApertureNotchPainter oldDelegate) =>
      oldDelegate.isLeft != isLeft;
}
