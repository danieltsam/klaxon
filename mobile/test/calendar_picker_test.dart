import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/widgets/calendar_picker.dart';

const _dayKey = ValueKey('dayField');
const _monthKey = ValueKey('monthField');
const _yearKey = ValueKey('yearField');
const _doneKey = ValueKey('doneButton');
const _labelKey = ValueKey('footerDateLabel');
const _editorKey = ValueKey('footerEditor');

// A stable future date well beyond "now" so the default-to-tomorrow logic
// never kicks in regardless of when the suite runs.
final _initialDate = DateTime(2030, 5, 15);
final _firstDate = DateTime(2026, 1, 1);
final _lastDate = DateTime(2035, 12, 31);

Future<void> _openPicker(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () {
                showCustomCalendarPicker(
                  context: context,
                  initialDate: _initialDate,
                  firstDate: _firstDate,
                  lastDate: _lastDate,
                );
              },
              child: const Text('Pick Date'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Pick Date'));
  await tester.pumpAndSettle();
}

Future<void> _enterTypeDate(WidgetTester tester, String day, String month, String year) async {
  await tester.enterText(find.byKey(_dayKey), day);
  await tester.pump();
  await tester.enterText(find.byKey(_monthKey), month);
  await tester.pump();
  await tester.enterText(find.byKey(_yearKey), year);
  await tester.pump();
}

String _fieldText(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.byKey(key)).controller!.text;

void main() {
  testWidgets('tapping the date label opens the editor with fields pre-filled '
      'to the current selection', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    await _openPicker(tester);

    // Editor is closed initially.
    expect(find.byKey(_editorKey), findsNothing);

    await tester.tap(find.byKey(_labelKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_editorKey), findsOneWidget);
    expect(_fieldText(tester, _dayKey), '15');
    expect(_fieldText(tester, _monthKey), '05');
    expect(_fieldText(tester, _yearKey), '2030');

    // Day field owns focus after opening, so the keyboard stays up.
    final dayField = tester.widget<TextField>(find.byKey(_dayKey));
    expect(dayField.focusNode!.hasFocus, isTrue);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('typing a valid date and tapping Done updates the selection and '
      'the footer label', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    await _openPicker(tester);

    await tester.tap(find.byKey(_labelKey));
    await tester.pumpAndSettle();

    await _enterTypeDate(tester, '25', '12', '2026');

    // Live validation passes; the editor stays open until explicitly committed.
    expect(find.byKey(_editorKey), findsOneWidget);
    expect(find.text('Date does not exist'), findsNothing);

    await tester.tap(find.byKey(_doneKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_editorKey), findsNothing);
    expect(find.text('Friday, 25th December 2026'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('invalid dates (31/02/2026) show a red border and are rejected',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    await _openPicker(tester);

    await tester.tap(find.byKey(_labelKey));
    await tester.pumpAndSettle();

    await _enterTypeDate(tester, '31', '02', '2026');

    expect(find.text('Date does not exist'), findsOneWidget);

    // The day field shows the red error border.
    final dayField = tester.widget<TextField>(find.byKey(_dayKey));
    final enabledBorder = dayField.decoration!.enabledBorder as OutlineInputBorder;
    expect(enabledBorder.borderSide.color, const Color(0xFFEB5757));

    // Commit is rejected: the editor stays open and the label is unchanged.
    await tester.tap(find.byKey(_doneKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_editorKey), findsOneWidget);
    expect(find.text('Date does not exist'), findsOneWidget);
    expect(find.text('Wednesday, 15th May 2030'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('tapping Done without changes closes the editor with no state '
      'change', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    await _openPicker(tester);

    final labelBefore = tester.widget<Text>(
      find.descendant(of: find.byKey(_labelKey), matching: find.byType(Text)),
    ).data!;

    await tester.tap(find.byKey(_labelKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_editorKey), findsOneWidget);

    await tester.tap(find.byKey(_doneKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_editorKey), findsNothing);
    expect(find.text(labelBefore), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('inline editing works in both the ribbon and the matrix view',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    await _openPicker(tester);

    // Ribbon view supports the editor.
    expect(find.byKey(const ValueKey('horizontalRibbon')), findsOneWidget);
    await tester.tap(find.byKey(_labelKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_editorKey), findsOneWidget);
    await tester.tap(find.byKey(_doneKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_editorKey), findsNothing);

    // Switch to matrix view.
    await tester.tap(find.text('expand'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('monthMatrix')), findsOneWidget);
    expect(find.byKey(const ValueKey('horizontalRibbon')), findsNothing);

    // The footer editor is still reachable in matrix view.
    await tester.ensureVisible(find.byKey(_labelKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_labelKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_editorKey), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('matrix swipe flips a month only past the ~178px threshold',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    await _openPicker(tester);

    await tester.tap(find.text('expand'));
    await tester.pumpAndSettle();

    final headerBefore = tester.widget<Text>(find.text('May 2030')).data!;
    expect(headerBefore, 'May 2030');

    // Short swipe (~60 logical px, below the ~178px month-flip threshold,
    // proportional to a ~150px physical swipe) → must NOT advance the month.
    await tester.drag(find.byKey(const ValueKey('monthMatrix')), const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(find.text('May 2030'), findsOneWidget);

    // Long swipe (~250 logical px, above the ~178px threshold) → advances
    // exactly one month.
    await tester.drag(find.byKey(const ValueKey('monthMatrix')), const Offset(-250, 0));
    await tester.pumpAndSettle();

    expect(find.text('June 2030'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });
}