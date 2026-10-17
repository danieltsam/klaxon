import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart' as app;

/// Regression: toasts must not queue. A toast fired while another is on
/// screen has to pre-empt it (the old one is dismissed immediately), so the
/// message the user sees always describes the action they just took.
void main() {
  testWidgets('a new toast pre-empts the current one instead of queuing',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    // Two toasts fired back-to-back: the arm confirmation is immediately
    // superseded by the deactivate confirmation.
    app.showToast(ctx, 'alarm armed');
    app.showToast(ctx, 'alarm deactivated');
    // Let the entrance animation finish; the 3s dwell timer starts after it.
    await tester.pumpAndSettle();

    // Only the newest toast is visible; the first was dismissed, not queued.
    expect(find.text('alarm deactivated'), findsOneWidget);
    expect(
      find.text('alarm armed'),
      findsNothing,
      reason: 'the previous toast must be dismissed, never queued',
    );

    // And it fully clears with nothing left waiting behind it.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });
}
