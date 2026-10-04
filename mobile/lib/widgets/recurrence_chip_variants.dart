import 'package:flutter/material.dart';

/// Production recurrence chip row for the schedule sheet.
///
/// [SegmentedStackedChipRow] renders the whole recurrence chip row as a single
/// connected segmented bar (bg `0xFF1B1E26`, radius 10, hairline border, 3px
/// inner padding, 2px inter-cell gaps). Each cell stacks a bold main label over
/// a tiny frequency subtitle — no per-cell borders, so the active pill reads as
/// the same plain segmented control as variant 6, just with two-row content.
///
/// Tap contract: [labels] + [selectedIndex] + [onSelect(index)].
class SegmentedStackedCell extends StatelessWidget {
  final String label;
  final String sub;
  final bool active;
  const SegmentedStackedCell({
    super.key,
    required this.label,
    required this.sub,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF5E6AD2) : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        boxShadow: active
            ? const [BoxShadow(color: Color(0x4D5E6AD2), blurRadius: 6)]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : _textMuted,
              ),
            ),
          ),
          const SizedBox(height: 1),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              sub,
              style: TextStyle(
                fontSize: 7,
                fontWeight: FontWeight.w500,
                color: active ? const Color(0xCCDDE0FF) : _textDisabled,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Segmented shell with two-row stacked cells.
class SegmentedStackedChipRow extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final void Function(int index) onSelect;
  const SegmentedStackedChipRow({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1E26),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF26282E), width: 1),
      ),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: GestureDetector(
                onTap: () => onSelect(i),
                behavior: HitTestBehavior.opaque,
                child: SegmentedStackedCell(
                  label: labels[i],
                  sub: i < _twoRowSubs.length ? _twoRowSubs[i] : '',
                  active: i == selectedIndex,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

const Color _textMuted = Color(0xFF8A8F98);
const Color _textDisabled = Color(0xFF4A4E58);

/// Subtitles used by the two-row stacked row, aligned with the recurrence
/// modes in order: Once, Daily, Weekdays, Fortnightly, Custom.
const List<String> _twoRowSubs = ['single', 'every day', 'M–F', 'every 2 wks', 'you pick'];
