import 'package:flutter/material.dart';

/// Row-level recurrence chip variants for the schedule sheet.
///
/// Each row widget renders the WHOLE recurrence chip row in a different
/// visual style while keeping the same tap contract:
///   [labels] + [selectedIndex] + [onSelect(index)].
///
/// The per-chip treatments are public so the recurrence lab and the live
/// schedule sheet share a single source of truth. No new color tokens are
/// introduced — every value mirrors the existing recurrence lab palette.
///
/// Variant map:
///   '0' Default       — delegates to the host's existing chip builder
///   '1' Glassmorphic  — translucent fill + soft purple bloom on active
///   '2' SoftGlow      — gradient + outer glow on active
///   '4' Outline       — border only, no fill
///   '5' TwoRow        — main label + tiny frequency subtitle
///   '6' Segmented     — single connected bar with internal cells

// ---------------------------------------------------------------------------
// Tokens (mirror recurrence_lab.dart — no new palette entries)
// ---------------------------------------------------------------------------

const Color _surface = Color(0xFF16181B);
const Color _surface2 = Color(0xFF1B1E26);
const Color _textMain = Color(0xFFF7F8F8);
const Color _textMuted = Color(0xFF8A8F98);
const Color _textDisabled = Color(0xFF4A4E58);

/// Subtitles used by the two-row stacked variant, aligned with the recurrence
/// modes in order: Once, Daily, Weekdays, Fortnightly, Custom.
const List<String> _twoRowSubs = ['single', 'every day', 'M–F', '2 wks', 'pick'];

// ---------------------------------------------------------------------------
// Per-chip treatments
// ---------------------------------------------------------------------------

/// Variant 0 — default chip. Mirrors `_buildPresetChip` in main.dart so the
/// lab can preview it; the live sheet keeps using its own builder.
class DefaultChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const DefaultChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF5E6AD2) : const Color(0xFF20232A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? const Color(0xFF5E6AD2) : const Color(0xFF2E323D),
          ),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? Colors.white : const Color(0xFF8A8F98),
            ),
          ),
        ),
      ),
    );
  }
}

/// Variant 1 — glassmorphic chip.
class GlassmorphicChip extends StatelessWidget {
  final String label;
  final bool active;
  const GlassmorphicChip({super.key, required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: active ? const Color(0x2E5E6AD2) : const Color(0x08FFFFFF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? const Color(0x805E6AD2) : const Color(0xFF26282E),
          width: 1,
        ),
        boxShadow: active
            ? const [BoxShadow(color: Color(0x4D5E6AD2), blurRadius: 12)]
            : null,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: active ? _textMain : _textMuted,
          ),
        ),
      ),
    );
  }
}

/// Variant 2 — soft-glow gradient chip.
class SoftGlowChip extends StatelessWidget {
  final String label;
  final bool active;
  const SoftGlowChip({super.key, required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        gradient: active
            ? const LinearGradient(
                colors: [Color(0xFF717DE2), Color(0xFF5E6AD2)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              )
            : null,
        color: active ? null : _surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? const Color(0x995E6AD2) : const Color(0xFF26282E),
          width: active ? 1.5 : 1,
        ),
        boxShadow: active
            ? const [BoxShadow(color: Color(0x4D5E6AD2), blurRadius: 16)]
            : null,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: active ? Colors.white : _textMuted,
          ),
        ),
      ),
    );
  }
}

/// Variant 4 — outline-only chip.
class OutlineChip extends StatelessWidget {
  final String label;
  final bool active;
  const OutlineChip({super.key, required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? const Color(0xFF5E6AD2) : const Color(0xFF26282E),
          width: 1.5,
        ),
        boxShadow: active
            ? const [
                BoxShadow(
                  color: Color(0x335E6AD2),
                  blurRadius: 0,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: active ? const Color(0xFF5E6AD2) : _textMuted,
          ),
        ),
      ),
    );
  }
}

/// Variant 5 — two-row stacked chip.
class TwoRowChip extends StatelessWidget {
  final String label;
  final String sub;
  final bool active;
  const TwoRowChip({
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
        color: active ? const Color(0xFF5E6AD2) : _surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? const Color(0xFF5E6AD2) : const Color(0xFF26282E),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : _textMuted,
              ),
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              sub,
              style: TextStyle(
                fontSize: 8,
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

/// Variant 6 — a single cell inside the segmented control.
class SegmentedCell extends StatelessWidget {
  final String label;
  final bool active;
  const SegmentedCell({super.key, required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF5E6AD2) : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        boxShadow: active
            ? const [BoxShadow(color: Color(0x4D5E6AD2), blurRadius: 6)]
            : null,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : _textMuted,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Row-level variants
// ---------------------------------------------------------------------------

/// Variant 0 — default row. [chipBuilder] is the host's existing per-chip
/// builder (it is responsible for its own `Expanded` wrapper).
class DefaultChipRow extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final void Function(int index) onSelect;
  final Widget Function(String label, bool active, VoidCallback onTap)
      chipBuilder;
  const DefaultChipRow({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelect,
    required this.chipBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          chipBuilder(labels[i], i == selectedIndex, () => onSelect(i)),
        ],
      ],
    );
  }
}

/// Variant 1 — glassmorphic row.
class GlassmorphicChipRow extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final void Function(int index) onSelect;
  const GlassmorphicChipRow({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => onSelect(i),
              behavior: HitTestBehavior.opaque,
              child: GlassmorphicChip(
                label: labels[i],
                active: i == selectedIndex,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Variant 2 — soft-glow gradient row.
class SoftGlowChipRow extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final void Function(int index) onSelect;
  const SoftGlowChipRow({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => onSelect(i),
              behavior: HitTestBehavior.opaque,
              child: SoftGlowChip(label: labels[i], active: i == selectedIndex),
            ),
          ),
        ],
      ],
    );
  }
}

/// Variant 4 — outline-only row.
class OutlineChipRow extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final void Function(int index) onSelect;
  const OutlineChipRow({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => onSelect(i),
              behavior: HitTestBehavior.opaque,
              child: OutlineChip(label: labels[i], active: i == selectedIndex),
            ),
          ),
        ],
      ],
    );
  }
}

/// Variant 5 — two-row stacked row.
class TwoRowChipRow extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final void Function(int index) onSelect;
  const TwoRowChipRow({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => onSelect(i),
              behavior: HitTestBehavior.opaque,
              child: TwoRowChip(
                label: labels[i],
                sub: i < _twoRowSubs.length ? _twoRowSubs[i] : '',
                active: i == selectedIndex,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Variant 6 — segmented control row: a single connected bar whose cells each
/// keep their own tap behaviour.
class SegmentedChipRow extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final void Function(int index) onSelect;
  const SegmentedChipRow({
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
                child: SegmentedCell(
                  label: labels[i],
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
