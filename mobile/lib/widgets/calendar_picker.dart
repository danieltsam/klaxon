import 'package:flutter/material.dart';
import '../services/haptic_service.dart';

/// Shows the bespoke Linear/Swiss dark-mode calendar picker modal sheet
Future<DateTime?> showCustomCalendarPicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    // Cap the sheet at 85% of screen height so the modal can never balloon to
    // full-screen (e.g. when a software keyboard appears) regardless of state.
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.85,
    ),
    backgroundColor: const Color(0xFF14161C),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      side: BorderSide(color: Color(0xFF262932)),
    ),
    builder: (ctx) {
      return CustomCalendarPickerSheet(
        initialDate: initialDate,
        firstDate: firstDate,
        lastDate: lastDate,
      );
    },
  );
}

class CustomCalendarPickerSheet extends StatefulWidget {
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  const CustomCalendarPickerSheet({
    super.key,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<CustomCalendarPickerSheet> createState() => _CustomCalendarPickerSheetState();
}

class _CustomCalendarPickerSheetState extends State<CustomCalendarPickerSheet> {
  late DateTime _selectedDate;
  late DateTime _viewMonth;
  bool _isExpanded = false;
  late ScrollController _ribbonScrollController;

  // Inline footer date typing
  late final TextEditingController _dayTypeController;
  late final TextEditingController _monthTypeController;
  late final TextEditingController _yearTypeController;
  late final FocusNode _dayFocusNode;
  late final FocusNode _monthFocusNode;
  late final FocusNode _yearFocusNode;
  bool _isSyncingType = false;
  bool _isFooterEditing = false;
  // Tracks the last known text of each field so _onTypeChanged can distinguish
  // real keystrokes from selection-only controller notifications.
  String _prevDayText = '';
  String _prevMonthText = '';
  String _prevYearText = '';
  String? _dayError;
  String? _monthError;
  String? _yearError;
  String? _typeErrorText;

  // Matrix swipe navigation
  late final PageController _matrixPageController;
  late int _matrixCurrentIndex;
  double _matrixDragAccumulated = 0;
  // Guards that a single continuous swipe flips at most one month.
  bool _matrixSwipedThisGesture = false;

  // A 300px physical swipe flips exactly one month. On the target device
  // (DPR 2.8125, 1220x2712 screen) 300 physical px ≈ 107 logical px of total
  // travel, but the horizontal drag recognizer consumes kTouchSlop (~18
  // logical px) before onHorizontalDragStart fires, so the deltas accumulated
  // here start ~18 logical px later. 107 − 18 ≈ 89, and 96 sits just above
  // that so a full ~300px swipe reliably flips one month while shorter swipes
  // (~150px, which accumulate roughly 35 logical px) flip nothing.
  static const double _matrixSwipeThreshold = 96;

  // The matrix card stacks 12px padding + 20px header + 8px gap above the
  // swipable grid but only 12px of padding below it, so the grid's vertical
  // center sits 14px below the card's center. Shifting the screen-edge chevron
  // buttons down by this keeps them centered on the grid (matching the
  // alignment they had when overlaid on the PageView) instead of the card.
  static const double _matrixChevronVerticalShift = 14;

  static const List<String> _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
  ];

  static const List<String> _dowNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const List<String> _dowNamesFull = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
  ];

  @override
  void initState() {
    super.initState();

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final initialDateOnly = DateTime(
      widget.initialDate.year,
      widget.initialDate.month,
      widget.initialDate.day,
    );

    // Default to tomorrow if the caller passed today or a past date, otherwise
    // respect an explicit future date (e.g. editing an existing custom alarm).
    DateTime effectiveInitial = initialDateOnly.isAfter(today)
        ? initialDateOnly
        : tomorrow;

    // Clamp to the allowed range just in case.
    if (effectiveInitial.isBefore(widget.firstDate)) {
      effectiveInitial = widget.firstDate;
    }
    if (effectiveInitial.isAfter(widget.lastDate)) {
      effectiveInitial = widget.lastDate;
    }

    _selectedDate = effectiveInitial;
    _viewMonth = DateTime(_selectedDate.year, _selectedDate.month, 1);

    // Initial scroll offset aligns the effective date (Tomorrow) at the LEFT
    // edge of the ribbon viewport so the previous day (Today) is fully
    // off-screen. Previously the offset was reduced by half a card width to
    // center the selected card, which left a sliver of Today visible.
    final initialOffset = _computeRibbonOffset(effectiveInitial);
    _ribbonScrollController = ScrollController(
      initialScrollOffset: initialOffset,
    );

    // Matrix page index tracks the currently viewed month.
    _matrixCurrentIndex = _indexForMonth(_viewMonth);
    _matrixPageController = PageController(initialPage: _matrixCurrentIndex);

    _dayTypeController = TextEditingController(
      text: _selectedDate.day.toString().padLeft(2, '0'),
    );
    _monthTypeController = TextEditingController(
      text: _selectedDate.month.toString().padLeft(2, '0'),
    );
    _yearTypeController = TextEditingController(
      text: _selectedDate.year.toString(),
    );

    _prevDayText = _dayTypeController.text;
    _prevMonthText = _monthTypeController.text;
    _prevYearText = _yearTypeController.text;

    _dayFocusNode = FocusNode();
    _monthFocusNode = FocusNode();
    _yearFocusNode = FocusNode();
    // When the YYYY field loses focus (e.g. tapped away or keyboard "done"),
    // treat it as an intent to commit the typed date.
    _yearFocusNode.addListener(_onYearFocusChanged);

    _dayTypeController.addListener(_onTypeChanged);
    _monthTypeController.addListener(_onTypeChanged);
    _yearTypeController.addListener(_onTypeChanged);
  }

  @override
  void dispose() {
    _ribbonScrollController.dispose();
    _matrixPageController.dispose();

    _dayTypeController.removeListener(_onTypeChanged);
    _monthTypeController.removeListener(_onTypeChanged);
    _yearTypeController.removeListener(_onTypeChanged);
    _dayTypeController.dispose();
    _monthTypeController.dispose();
    _yearTypeController.dispose();

    _dayFocusNode.dispose();
    _monthFocusNode.dispose();
    _yearFocusNode.removeListener(_onYearFocusChanged);
    _yearFocusNode.dispose();

    super.dispose();
  }

  // --- Range helpers for the matrix PageView ---

  int _totalMonths() {
    final firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month, 1);
    final lastMonth = DateTime(widget.lastDate.year, widget.lastDate.month, 1);
    return (lastMonth.year - firstMonth.year) * 12 + (lastMonth.month - firstMonth.month) + 1;
  }

  DateTime _monthAtIndex(int index) {
    final firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month, 1);
    return DateTime(firstMonth.year, firstMonth.month + index, 1);
  }

  int _indexForMonth(DateTime month) {
    final firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month, 1);
    return (month.year - firstMonth.year) * 12 + (month.month - firstMonth.month);
  }

  // True when a month exists before the currently viewed one within the
  // allowed [firstDate, lastDate] range. Drives the left chevron enabled state.
  bool get _canNavigateToPreviousMonth {
    final prev = DateTime(_viewMonth.year, _viewMonth.month - 1, 1);
    final firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month, 1);
    return !prev.isBefore(firstMonth);
  }

  // True when a month exists after the currently viewed one within the
  // allowed [firstDate, lastDate] range. Drives the right chevron enabled state.
  bool get _canNavigateToNextMonth {
    final next = DateTime(_viewMonth.year, _viewMonth.month + 1, 1);
    final lastMonth = DateTime(widget.lastDate.year, widget.lastDate.month, 1);
    return !next.isAfter(lastMonth);
  }

  double _computeRibbonOffset(DateTime date) {
    const totalDays = 60;
    final diffDays = date.difference(widget.firstDate).inDays;
    final index = diffDays.clamp(0, totalDays - 1);
    return index * 74.0;
  }

  void _onDateSelected(DateTime dt) {
    HapticService.selectionClick();
    setState(() {
      _selectedDate = DateTime(dt.year, dt.month, dt.day);
      _viewMonth = DateTime(dt.year, dt.month, 1);
      _isFooterEditing = false;
      _clearTypeErrors();
    });
    // Dismiss the software keyboard when leaving the inline editor. Ordering
    // matters: _isFooterEditing must already be false so _onYearFocusChanged
    // does not attempt a second commit.
    _unfocusTypeFields();
    _syncTypeControllers();
    _updateMatrixPage();
    _scrollRibbonToSelected();
  }

  void _updateMatrixPage() {
    if (!_matrixPageController.hasClients) return;
    final newIndex = _indexForMonth(_viewMonth);
    if (newIndex != _matrixCurrentIndex) {
      _matrixCurrentIndex = newIndex;
      _matrixPageController.animateToPage(
        newIndex,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  // Advances the matrix by [direction] months (-1 prev / +1 next) with a
  // short animated page flip. Used by the custom swipe detector in the matrix
  // so a ~100px drag changes month instead of PageView's default ~50%-width
  // threshold.
  void _navigateMatrix(int direction) {
    final newIndex = (_matrixCurrentIndex + direction)
        .clamp(0, _totalMonths() - 1);
    if (newIndex == _matrixCurrentIndex) return;
    _matrixCurrentIndex = newIndex;
    HapticService.selectionClick();
    setState(() {
      _viewMonth = _monthAtIndex(newIndex);
    });
    if (_matrixPageController.hasClients) {
      _matrixPageController.animateToPage(
        newIndex,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _scrollRibbonToSelected() {
    if (!_ribbonScrollController.hasClients) return;
    final offset = _computeRibbonOffset(_selectedDate);
    // Align the selected card at the LEFT edge, matching the initial scroll
    // position (no half-card centering offset).
    _ribbonScrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeInOutCubic,
    );
  }

  void _toggleExpanded() {
    HapticService.selectionClick();
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _viewMonth = DateTime(_selectedDate.year, _selectedDate.month, 1);
        _matrixCurrentIndex = _indexForMonth(_viewMonth);
      }
    });
    // The matrix PageView is only built when _isExpanded flips true inside the
    // AnimatedSwitcher, so jumpToPage must wait until after that frame is
    // laid out (otherwise "PageController is not attached to a PageView").
    if (_isExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_matrixPageController.hasClients) {
          _matrixPageController.jumpToPage(_matrixCurrentIndex);
        }
      });
    }
  }

  // --- Inline footer typing handlers ---

  void _syncTypeControllers() {
    if (_isSyncingType) return;
    _isSyncingType = true;
    _dayTypeController.text = _selectedDate.day.toString().padLeft(2, '0');
    _monthTypeController.text = _selectedDate.month.toString().padLeft(2, '0');
    _yearTypeController.text = _selectedDate.year.toString();
    _prevDayText = _dayTypeController.text;
    _prevMonthText = _monthTypeController.text;
    _prevYearText = _yearTypeController.text;
    _isSyncingType = false;
  }

  void _clearTypeErrors() {
    _dayError = null;
    _monthError = null;
    _yearError = null;
    _typeErrorText = null;
  }

  void _onTypeChanged() {
    if (_isSyncingType) return;

    final dayText = _dayTypeController.text;
    final monthText = _monthTypeController.text;
    final yearText = _yearTypeController.text;

    final dayChanged = dayText != _prevDayText;
    final monthChanged = monthText != _prevMonthText;
    final yearChanged = yearText != _prevYearText;

    _prevDayText = dayText;
    _prevMonthText = monthText;
    _prevYearText = yearText;

    // TextField notifies its controller whenever the selection moves (e.g.
    // when the field gains focus), even though the text itself is unchanged.
    // Auto-advancing on those selection-only events made focus cascade
    // day → month → year the instant the editor opened (all fields are
    // pre-filled and "complete"), which is the "keyboard flashes and closes"
    // bug. Only react to real keystrokes.
    if (!dayChanged && !monthChanged && !yearChanged) {
      return;
    }

    // Auto-advance focus when a field is filled by typing.
    if (dayChanged && dayText.length == 2 && _dayFocusNode.hasFocus) {
      HapticService.selectionClick();
      _monthFocusNode.requestFocus();
    } else if (monthChanged && monthText.length == 2 && _monthFocusNode.hasFocus) {
      HapticService.selectionClick();
      _yearFocusNode.requestFocus();
    }

    _validateTypeDate();
  }

  // Live-validates the typed fields and surfaces errors (red borders + helper
  // text). It deliberately does NOT apply/close the editor — that only happens
  // on an explicit commit (Done, keyboard action, or YYYY focus loss). Applying
  // on every keystroke was the cause of the "keyboard flashes and reverts" bug,
  // because the fields are pre-populated and already "complete".
  void _validateTypeDate() {
    final d = int.tryParse(_dayTypeController.text);
    final m = int.tryParse(_monthTypeController.text);
    final y = int.tryParse(_yearTypeController.text);

    setState(() {
      _dayError = null;
      _monthError = null;
      _yearError = null;
      _typeErrorText = null;

      if (_dayTypeController.text.isNotEmpty && (d == null || d < 1 || d > 31)) {
        _dayError = 'Invalid day';
      }
      if (_monthTypeController.text.isNotEmpty && (m == null || m < 1 || m > 12)) {
        _monthError = 'Invalid month';
      }
      if (_yearTypeController.text.isNotEmpty && (y == null || y < 1000)) {
        _yearError = 'Invalid year';
      }
    });

    // Wait until all fields are complete before attempting to apply a date.
    if (d == null ||
        m == null ||
        y == null ||
        _dayTypeController.text.length < 2 ||
        _monthTypeController.text.length < 2 ||
        _yearTypeController.text.length < 4) {
      return;
    }

    try {
      final candidate = DateTime(y, m, d);
      if (candidate.year != y || candidate.month != m || candidate.day != d) {
        setState(() {
          _typeErrorText = 'Date does not exist';
          _dayError = ' ';
        });
        return;
      }

      if (candidate.isBefore(widget.firstDate)) {
        setState(() {
          _typeErrorText = 'Date is before the allowed range';
        });
        return;
      }
      if (candidate.isAfter(widget.lastDate)) {
        setState(() {
          _typeErrorText = 'Date is after the allowed range';
        });
        return;
      }
    } catch (_) {
      setState(() {
        _typeErrorText = 'Invalid date';
      });
    }
  }

  void _startFooterEdit() {
    HapticService.selectionClick();
    _syncTypeControllers();
    setState(() {
      _isFooterEditing = true;
      _clearTypeErrors();
    });
    // Focus must be requested AFTER the build completes so the freshly created
    // TextFields are mounted — otherwise the keyboard can flash open/closed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dayFocusNode.requestFocus();
      final dayContext = _dayFocusNode.context;
      if (dayContext != null) {
        Scrollable.ensureVisible(
          dayContext,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOutCubic,
          alignment: 0.5,
        );
      }
    });
  }

  /// Commits the typed date. Returns true when the date was valid and applied
  /// (editor closes), false when invalid (editor stays open showing an error).
  bool _commitFooterEdit() {
    final d = int.tryParse(_dayTypeController.text);
    final m = int.tryParse(_monthTypeController.text);
    final y = int.tryParse(_yearTypeController.text);

    if (d == null ||
        m == null ||
        y == null ||
        _dayTypeController.text.length < 2 ||
        _monthTypeController.text.length < 2 ||
        _yearTypeController.text.length < 4) {
      setState(() {
        _typeErrorText = 'Enter a valid date';
      });
      return false;
    }

    try {
      final candidate = DateTime(y, m, d);
      if (candidate.year != y || candidate.month != m || candidate.day != d) {
        setState(() {
          _typeErrorText = 'Date does not exist';
          _dayError = ' ';
        });
        return false;
      }

      if (candidate.isBefore(widget.firstDate)) {
        setState(() {
          _typeErrorText = 'Date is before the allowed range';
        });
        return false;
      }
      if (candidate.isAfter(widget.lastDate)) {
        setState(() {
          _typeErrorText = 'Date is after the allowed range';
        });
        return false;
      }

      HapticService.selectionClick();
      _onDateSelected(candidate);
      return true;
    } catch (_) {
      setState(() {
        _typeErrorText = 'Invalid date';
      });
      return false;
    }
  }

  void _unfocusTypeFields() {
    _dayFocusNode.unfocus();
    _monthFocusNode.unfocus();
    _yearFocusNode.unfocus();
  }

  void _exitFooterEdit() {
    _unfocusTypeFields();
    if (_isFooterEditing) {
      setState(() {
        _isFooterEditing = false;
      });
    }
  }

  void _onYearFocusChanged() {
    if (!_isFooterEditing) return;
    if (_yearFocusNode.hasFocus) return;
    // YYYY lost focus while editing (tapped away / keyboard done). Commit if
    // valid, otherwise revert to the label without applying anything.
    if (!_commitFooterEdit()) {
      _exitFooterEdit();
    }
  }

  String _getRelativeLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    if (dt.isAtSameMomentAs(today)) return 'Today';
    if (dt.isAtSameMomentAs(tomorrow)) return 'Tomorrow';
    final diff = dt.difference(today).inDays;
    if (diff > 1 && diff <= 7) return 'in $diff days';
    if (diff > 7) return 'in ${(diff / 7).round()} wks';
    return '';
  }

  String _formatFullDate(DateTime dt) {
    final weekday = _dowNamesFull[dt.weekday - 1];
    final ordinal = _ordinal(dt.day);
    final month = _monthNames[dt.month - 1];
    return '$weekday, $ordinal $month ${dt.year}';
  }

  String _ordinal(int day) {
    if (day >= 11 && day <= 13) return '${day}th';
    switch (day % 10) {
      case 1:
        return '${day}st';
      case 2:
        return '${day}nd';
      case 3:
        return '${day}rd';
      default:
        return '${day}th';
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    return Padding(
      // Fixed breathing room. Crucially this does NOT include viewInsets: the
      // sheet must not grow/shrink with the keyboard (it is already capped by
      // the maxHeight constraint on showModalBottomSheet). The body below is
      // scrollable so the user can bring the fields above the keyboard.
      //
      // Horizontal insets are applied per-child instead of here so the
      // expanded month matrix can bleed to the full sheet width: its chevron
      // buttons anchor to the outermost screen edges, outside the day grid.
      padding: const EdgeInsets.only(top: 14, bottom: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF3A3F4A),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Header: Month & Year + Expand/Collapse toggle
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_monthNames[_viewMonth.month - 1]} ${_viewMonth.year}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFF7F8F8),
                    letterSpacing: -0.3,
                  ),
                ),
                _buildExpandToggle(),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Scrollable picker body (ribbon/matrix + footer). When the software
          // keyboard appears, the modal stays put and this region scrolls so
          // the typing fields stay reachable.
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Mode-dependent picker body with crossfade. The matrix is
                  // full-bleed so its chevrons sit at the screen edges; the
                  // ribbon keeps the 18px side breathing room.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    switchInCurve: Curves.easeInOutCubic,
                    switchOutCurve: Curves.easeInOutCubic,
                    child: _isExpanded
                        ? _buildMonthMatrix(today)
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: _buildHorizontalRibbon(today),
                          ),
                  ),

                  const SizedBox(height: 16),

                  // Bottom Summary & Confirm Action
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: _buildFooter(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandToggle() {
    final label = _isExpanded ? 'Collapse' : 'Expand';
    final icon = _isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _toggleExpanded,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1B1E26),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF2B2F3B)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF8A8F98),
                ),
              ),
              const SizedBox(width: 2),
              Icon(icon, size: 14, color: const Color(0xFF8A8F98)),
            ],
          ),
        ),
      ),
    );
  }

  // --- Horizontal Infinite Date Ribbon ---
  Widget _buildHorizontalRibbon(DateTime today) {
    // Generate next 60 days
    const totalDays = 60;
    return SizedBox(
      height: 78,
      child: ListView.separated(
        key: const ValueKey('horizontalRibbon'),
        controller: _ribbonScrollController,
        scrollDirection: Axis.horizontal,
        itemCount: totalDays,
        separatorBuilder: (context, index) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final dt = widget.firstDate.add(Duration(days: index));
          final isSelected = dt.isAtSameMomentAs(_selectedDate);
          final isToday = dt.isAtSameMomentAs(today);
          final relLabel = _getRelativeLabel(dt);

          return GestureDetector(
            onTap: () => _onDateSelected(dt),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 68,
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF5E6AD2) : const Color(0xFF171920),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFF818CF8)
                      : (isToday ? const Color(0xFF5E6AD2) : const Color(0xFF252832)),
                  width: (isSelected || isToday) ? 1.5 : 1.0,
                ),
                boxShadow: isSelected
                    ? const [
                        BoxShadow(
                          color: Color(0x335E6AD2),
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _dowNames[dt.weekday - 1].toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: isSelected ? Colors.white.withValues(alpha: 0.9) : const Color(0xFF8A8F98),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    dt.day.toString().padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: isSelected ? Colors.white : const Color(0xFFF7F8F8),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    relLabel.isNotEmpty ? relLabel : '${dt.month}/${dt.day}',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: isSelected ? Colors.white : const Color(0xFF818CF8),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // --- High-Density Month Grid Matrix with horizontal swipe ---
  Widget _buildMonthMatrix(DateTime today) {
    return Stack(
      // The matrix card is inset ~50px on each side so the chevron buttons
      // live in the gutters at the outermost screen edges instead of
      // overlaying the first/last day cells of the grid.
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 50),
          child: Container(
            key: const ValueKey('monthMatrix'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101215),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF22252C)),
            ),
            child: Column(
              children: [
                // DOW Header Row
                SizedBox(
                  height: 20,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: _dowNames.map((d) {
                      return Expanded(
                        child: Center(
                          child: Text(
                            d,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF565B66),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 8),

                // Swipeable month pages
                LayoutBuilder(
                  builder: (context, constraints) {
                    final cellWidth = (constraints.maxWidth - 6 * 4) / 7;
                    final cellHeight = cellWidth / 1.25;
                    final gridHeight = 6 * cellHeight + 5 * 4;
                    final pageHeight = gridHeight + 28;

                    return SizedBox(
                      height: pageHeight,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (_) => true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (_) {
                            _matrixDragAccumulated = 0;
                            _matrixSwipedThisGesture = false;
                          },
                          onHorizontalDragUpdate: (details) {
                            // Tactile swipe: ~96 logical px of accumulated post-slop travel
                            // (~300px physical at DPR 2.8125 on this device, minus
                            // the ~18px touch slop consumed before drag start)
                            // flips one month. Shorter swipes don't flip; at most
                            // one month flips per gesture, so longer swipes never
                            // chain multiple months. Finger left (negative dx)
                            // advances to the next month; finger right (positive
                            // dx) goes back.
                            if (_matrixSwipedThisGesture) return;
                            _matrixDragAccumulated += details.delta.dx;
                            const double threshold = _matrixSwipeThreshold;
                            if (_matrixDragAccumulated <= -threshold) {
                              _matrixSwipedThisGesture = true;
                              _matrixDragAccumulated = 0;
                              _navigateMatrix(1);
                            } else if (_matrixDragAccumulated >= threshold) {
                              _matrixSwipedThisGesture = true;
                              _matrixDragAccumulated = 0;
                              _navigateMatrix(-1);
                            }
                          },
                          onHorizontalDragEnd: (_) {
                            _matrixDragAccumulated = 0;
                            _matrixSwipedThisGesture = false;
                          },
                          child: PageView.builder(
                            controller: _matrixPageController,
                            physics: const NeverScrollableScrollPhysics(),
                            onPageChanged: (index) {
                              setState(() {
                                _viewMonth = _monthAtIndex(index);
                                _matrixCurrentIndex = index;
                              });
                            },
                            itemCount: _totalMonths(),
                            itemBuilder: (context, index) {
                              return _buildMonthGridForMonth(_monthAtIndex(index), today);
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        // Left chevron anchored to the outermost left edge of the sheet,
        // vertically centered on the swipable pages (not the date cells).
        // Disabled at the first allowed month.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: Center(
            child: Transform.translate(
              offset: const Offset(0, _matrixChevronVerticalShift),
              child: _buildMatrixNavButton(
                icon: Icons.chevron_left_rounded,
                isEnabled: _canNavigateToPreviousMonth,
                onTap: () => _navigateMatrix(-1),
              ),
            ),
          ),
        ),
        // Right chevron anchored to the outermost right edge of the sheet.
        // Disabled at the last allowed month.
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: Center(
            child: Transform.translate(
              offset: const Offset(0, _matrixChevronVerticalShift),
              child: _buildMatrixNavButton(
                icon: Icons.chevron_right_rounded,
                isEnabled: _canNavigateToNextMonth,
                onTap: () => _navigateMatrix(1),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Small circular chevron button for matrix month navigation. Sits in the
  // gutter at the outermost screen edge, clear of the day grid, to offer
  // click-to-navigate and signal that the matrix can be swiped. Rendered as a
  // translucent dark disc; greyed out when the direction is disabled.
  Widget _buildMatrixNavButton({
    required IconData icon,
    required bool isEnabled,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isEnabled ? onTap : null,
        customBorder: const CircleBorder(),
        child: Ink(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xCC0F1013),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF2B2F3B)),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isEnabled ? const Color(0xFFF7F8F8) : const Color(0xFF4A4E58),
          ),
        ),
      ),
    );
  }

  Widget _buildMonthGridForMonth(DateTime month, DateTime today) {
    final firstDayOfMonth = DateTime(month.year, month.month, 1);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // 1-based weekday (1=Mon, 7=Sun)
    final startingWeekday = firstDayOfMonth.weekday;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 42,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 1.25,
      ),
      itemBuilder: (context, index) {
        final dayOffset = index - (startingWeekday - 1);
        if (dayOffset < 0 || dayOffset >= daysInMonth) {
          return const SizedBox();
        }

        final dayNum = dayOffset + 1;
        final cellDate = DateTime(month.year, month.month, dayNum);
        final isPast = cellDate.isBefore(today);
        final isSelected = cellDate.isAtSameMomentAs(_selectedDate);
        final isToday = cellDate.isAtSameMomentAs(today);

        return GestureDetector(
          onTap: isPast ? null : () => _onDateSelected(cellDate),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFF5E6AD2)
                  : (isToday ? const Color(0x1F5E6AD2) : Colors.transparent),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isSelected
                    ? const Color(0xFF5E6AD2)
                    : (isToday ? const Color(0xFF5E6AD2) : Colors.transparent),
                width: 1.2,
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  dayNum.toString(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w700 : (isToday ? FontWeight.w600 : FontWeight.w500),
                    color: isSelected
                        ? Colors.white
                        : (isPast ? const Color(0xFF333740) : const Color(0xFFF7F8F8)),
                  ),
                ),
                if (isPast)
                  Container(
                    width: 18,
                    height: 1.2,
                    color: const Color(0xFF3A3F4A),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- Footer with tappable full date + inline typing ---
  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF101215),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF22252C)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeInOutCubic,
              switchOutCurve: Curves.easeInOutCubic,
              child: _isFooterEditing
                  ? _buildFooterEditor()
                  : _buildFooterDateLabel(),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5E6AD2),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              HapticService.selectionClick();
              Navigator.pop(context, _selectedDate);
            },
            child: const Text('Confirm Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _buildFooterDateLabel() {
    return GestureDetector(
      key: const ValueKey('footerDateLabel'),
      onTap: _startFooterEdit,
      child: Text(
        _formatFullDate(_selectedDate),
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Color(0xFFF7F8F8),
        ),
      ),
    );
  }

  Widget _buildFooterEditor() {
    return Column(
      key: const ValueKey('footerEditor'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _buildTypeField(
                'DD',
                _dayTypeController,
                _dayFocusNode,
                _dayError,
                maxLength: 2,
                fieldKey: const ValueKey('dayField'),
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _monthFocusNode.requestFocus(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildTypeField(
                'MM',
                _monthTypeController,
                _monthFocusNode,
                _monthError,
                maxLength: 2,
                fieldKey: const ValueKey('monthField'),
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _yearFocusNode.requestFocus(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: _buildTypeField(
                'YYYY',
                _yearTypeController,
                _yearFocusNode,
                _yearError,
                maxLength: 4,
                fieldKey: const ValueKey('yearField'),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _commitFooterEdit(),
              ),
            ),
          ],
        ),
        if (_typeErrorText != null) ...[
          const SizedBox(height: 6),
          Text(
            _typeErrorText!,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFFEB5757),
            ),
          ),
        ],
        const SizedBox(height: 6),
        GestureDetector(
          key: const ValueKey('doneButton'),
          onTap: _commitFooterEdit,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF5E6AD2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'Done',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTypeField(
    String hint,
    TextEditingController controller,
    FocusNode focusNode,
    String? error, {
    required int maxLength,
    Key? fieldKey,
    ValueChanged<String>? onSubmitted,
    TextInputAction? textInputAction,
  }) {
    return TextField(
      key: fieldKey,
      controller: controller,
      focusNode: focusNode,
      autofocus: false,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      maxLength: maxLength,
      buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Color(0xFFF7F8F8),
        fontFeatures: [FontFeature.tabularFigures()],
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: Color(0xFF4A4E58),
        ),
        filled: true,
        fillColor: const Color(0xFF171920),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF262932)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: error != null ? const Color(0xFFEB5757) : const Color(0xFF262932),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: error != null ? const Color(0xFFEB5757) : const Color(0xFF5E6AD2),
          ),
        ),
      ),
    );
  }
}
