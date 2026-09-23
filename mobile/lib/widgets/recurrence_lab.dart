import 'package:flutter/material.dart';

import '../services/haptic_service.dart';
import '../utils/id_mapper.dart';
import 'recurrence_chip_variants.dart';

/// Debug lab screen for recurrence chip variants.
///
/// Renders the chip treatments (concepts 0, 1, 2, 4, 5, 6 from the chip
/// variations mockup) plus 3 collapsed+expandable concept-C variants.
/// Hidden behind a long-press on the "REPEATS" section label in the
/// schedule sheet.
///
/// Tapping a variant persists it via [IdMapper.setRecurrenceChipVariant] so
/// the live schedule sheet picks it up on its next rebuild.
class RecurrenceLab extends StatefulWidget {
  const RecurrenceLab({super.key});

  @override
  State<RecurrenceLab> createState() => _RecurrenceLabState();
}

class _RecurrenceLabState extends State<RecurrenceLab> {
  String _activeVariant = '0';

  @override
  void initState() {
    super.initState();
    _loadActiveVariant();
  }

  Future<void> _loadActiveVariant() async {
    final stored = await IdMapper.getRecurrenceChipVariant();
    if (!mounted) return;
    setState(() => _activeVariant = stored ?? '0');
  }

  Future<void> _selectVariant(String variant) async {
    HapticService.selectionClick();
    await IdMapper.setRecurrenceChipVariant(variant);
    if (!mounted) return;
    setState(() => _activeVariant = variant);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'Chip style updated — it will appear in the schedule sheet when you go back',
          ),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDeep,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Recurrence Lab',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: _textMain,
          ),
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                'debug',
                style: TextStyle(fontSize: 10, color: _textDisabled),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(
              title: 'Chip Variants',
              subtitle: 'Tap a variant to apply it to the schedule sheet',
            ),
            _VariantSection(
              tag: '0',
              title: 'Default',
              desc: 'Current production chip row',
              active: _activeVariant == '0',
              onTap: () => _selectVariant('0'),
              child: DefaultChipRow(
                labels: _shortLabels,
                selectedIndex: _activeIndex,
                onSelect: (_) => _selectVariant('0'),
                chipBuilder: (label, active, onTap) => Expanded(
                  child: DefaultChip(
                    label: label,
                    active: active,
                    onTap: onTap,
                  ),
                ),
              ),
            ),
            _VariantSection(
              tag: '1',
              title: 'Glassmorphic',
              desc: 'Translucent fill + soft purple bloom on active',
              active: _activeVariant == '1',
              onTap: () => _selectVariant('1'),
              child: _ChipRow(
                builder: (label, active) => GlassmorphicChip(
                  label: label,
                  active: active,
                ),
              ),
            ),
            _VariantSection(
              tag: '2',
              title: 'Soft-Glow Gradient',
              desc: 'Vertical gradient + outer glow on active',
              active: _activeVariant == '2',
              onTap: () => _selectVariant('2'),
              child: _ChipRow(
                builder: (label, active) => SoftGlowChip(
                  label: label,
                  active: active,
                ),
              ),
            ),
            _VariantSection(
              tag: '4',
              title: 'Outline-Only',
              desc: 'Ghost state — border only, no fill',
              active: _activeVariant == '4',
              onTap: () => _selectVariant('4'),
              child: _ChipRow(
                builder: (label, active) => OutlineChip(
                  label: label,
                  active: active,
                ),
              ),
            ),
            _VariantSection(
              tag: '5',
              title: 'Two-Row Stacked',
              desc: 'Main label + tiny frequency subtitle',
              active: _activeVariant == '5',
              onTap: () => _selectVariant('5'),
              child: _ChipRow(
                builder: (label, active) {
                  final option = _options[_shortLabels.indexOf(label)];
                  return TwoRowChip(
                    label: option.label,
                    sub: option.sub,
                    active: active,
                  );
                },
              ),
            ),
            _VariantSection(
              tag: '6',
              title: 'Segmented Control',
              desc: 'Single connected bar, iOS-style',
              active: _activeVariant == '6',
              onTap: () => _selectVariant('6'),
              child: SegmentedChipRow(
                labels: _shortLabels,
                selectedIndex: _activeIndex,
                onSelect: (_) => _selectVariant('6'),
              ),
            ),
            const _SectionHeader(
              title: 'Concept C · Collapsed + Expandable',
              subtitle: 'Minimal at rest, expands inline to a list',
            ),
            _VariantSection(
              tag: 'C1',
              title: 'Collapsed Pill',
              desc: 'Tap to expand — collapsed & expanded side by side',
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _CaptionBlock(
                      caption: 'collapsed',
                      child: const _CollapsedPillC1(initiallyExpanded: false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _CaptionBlock(
                      caption: 'expanded',
                      child: const _CollapsedPillC1(initiallyExpanded: true),
                    ),
                  ),
                ],
              ),
            ),
            _VariantSection(
              tag: 'C2',
              title: 'Compact Dropdown',
              desc: 'Tiny button showing current selection — tap opens a menu',
              child: const _CompactDropdownC2(),
            ),
            _VariantSection(
              tag: 'C3',
              title: 'Sticky Compact',
              desc: 'Inline indicator, no expansion — tap cycles options',
              child: const _StickyCompactC3(),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

const Color _bgDeep = Color(0xFF0F1013);
const Color _surface = Color(0xFF16181B);
const Color _borderSubtle = Color(0xFF26282E);
const Color _accent = Color(0xFF5E6AD2);
const Color _textMain = Color(0xFFF7F8F8);
const Color _textMuted = Color(0xFF8A8F98);
const Color _textDisabled = Color(0xFF4A4E58);

const List<String> _shortLabels = ['Once', 'Daily', 'Weekdays', '2wks', 'Custom'];
const int _activeIndex = 1; // Daily

class _RecurrenceOption {
  final String label;
  final String sub;
  const _RecurrenceOption(this.label, this.sub);
}

const List<_RecurrenceOption> _options = [
  _RecurrenceOption('Once', 'single'),
  _RecurrenceOption('Daily', 'every day'),
  _RecurrenceOption('Weekdays', 'M–F'),
  _RecurrenceOption('Fortnightly', '2 wks'),
  _RecurrenceOption('Custom', 'pick'),
];

// ---------------------------------------------------------------------------
// Lab scaffolding
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const _SectionHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: _accent,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 11, color: _textMuted),
          ),
        ],
      ),
    );
  }
}

class _VariantSection extends StatelessWidget {
  final String tag;
  final String title;
  final String desc;
  final Widget child;
  final bool active;
  final VoidCallback? onTap;
  const _VariantSection({
    required this.tag,
    required this.title,
    required this.desc,
    required this.child,
    this.active = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final section = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: active
                    ? const Color(0x335E6AD2)
                    : const Color(0x1F5E6AD2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tag,
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: _accent,
                    ),
                  ),
                  if (active) ...[
                    const SizedBox(width: 3),
                    const Icon(Icons.check_rounded, size: 9, color: _accent),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _textMain,
                ),
              ),
            ),
            if (active)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0x335E6AD2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'Currently active',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: _accent,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          desc,
          style: const TextStyle(fontSize: 10, color: _textMuted),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? const Color(0xFF5E6AD2) : _borderSubtle,
            ),
          ),
          child: child,
        ),
        const SizedBox(height: 22),
      ],
    );

    if (onTap == null) return section;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: section,
    );
  }
}

class _CaptionBlock extends StatelessWidget {
  final String caption;
  final Widget child;
  const _CaptionBlock({required this.caption, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          caption,
          style: const TextStyle(fontSize: 9, color: _textDisabled),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// Shared row builder for the 5-option chip rows.
class _ChipRow extends StatelessWidget {
  final Widget Function(String label, bool active) builder;
  const _ChipRow({required this.builder});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int i = 0; i < _shortLabels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: builder(_shortLabels[i], i == _activeIndex)),
        ],
      ],
    );
  }
}


// ---------------------------------------------------------------------------
// Concept C1 — Collapsed pill, expands inline
// ---------------------------------------------------------------------------

class _CollapsedPillC1 extends StatefulWidget {
  final bool initiallyExpanded;
  const _CollapsedPillC1({this.initiallyExpanded = false});

  @override
  State<_CollapsedPillC1> createState() => _CollapsedPillC1State();
}

class _CollapsedPillC1State extends State<_CollapsedPillC1> {
  late bool _isExpanded;
  int _selected = _activeIndex;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: () => setState(() => _isExpanded = !_isExpanded),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _isExpanded ? const Color(0xFF5E6AD2) : _borderSubtle,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                const Text(
                  'Repeats',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _textMuted,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _options[_selected].label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _textMain,
                    ),
                  ),
                ),
                Icon(
                  _isExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: _textMuted,
                ),
              ],
            ),
          ),
        ),
        if (_isExpanded) ...[
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF5E6AD2), width: 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (int i = 0; i < _options.length; i++)
                  InkWell(
                    onTap: () => setState(() => _selected = i),
                    child: Container(
                      width: double.infinity,
                      color: i == _selected
                          ? const Color(0x1F5E6AD2)
                          : Colors.transparent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _options[i].label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: i == _selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: i == _selected
                                    ? _textMain
                                    : _textMuted,
                              ),
                            ),
                          ),
                          if (i == _selected)
                            const Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: Color(0xFF5E6AD2),
                            )
                          else
                            const SizedBox(width: 14),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Concept C2 — Compact dropdown (popup menu)
// ---------------------------------------------------------------------------

class _CompactDropdownC2 extends StatefulWidget {
  const _CompactDropdownC2();

  @override
  State<_CompactDropdownC2> createState() => _CompactDropdownC2State();
}

class _CompactDropdownC2State extends State<_CompactDropdownC2> {
  int _selected = _activeIndex;

  Future<void> _openMenu() async {
    final RenderBox box = context.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
      Offset.zero & overlay.size,
    );
    final int? result = await showMenu<int>(
      context: context,
      position: position,
      color: const Color(0xFF1B1E26),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFF26282E)),
      ),
      items: [
        for (int i = 0; i < _options.length; i++)
          PopupMenuItem<int>(
            value: i,
            height: 40,
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: i == _selected
                      ? const Icon(
                          Icons.check_rounded,
                          size: 13,
                          color: Color(0xFF5E6AD2),
                        )
                      : null,
                ),
                const SizedBox(width: 6),
                Text(
                  _options[i].label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        i == _selected ? FontWeight.w600 : FontWeight.w500,
                    color: i == _selected ? _textMain : _textMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (result != null && mounted) {
      setState(() => _selected = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onTap: _openMenu,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _borderSubtle, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _options[_selected].label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _textMain,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.arrow_drop_down_rounded,
                size: 16,
                color: _textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Concept C3 — Sticky compact (inline, cycles on tap)
// ---------------------------------------------------------------------------

class _StickyCompactC3 extends StatefulWidget {
  const _StickyCompactC3();

  @override
  State<_StickyCompactC3> createState() => _StickyCompactC3State();
}

class _StickyCompactC3State extends State<_StickyCompactC3> {
  int _selected = _activeIndex;

  void _cycle() {
    setState(() => _selected = (_selected + 1) % _options.length);
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onTap: _cycle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF20232A),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF2E323D), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.replay_rounded, size: 13, color: Color(0xFF5E6AD2)),
              const SizedBox(width: 5),
              Text(
                _options[_selected].label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _textMain,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}