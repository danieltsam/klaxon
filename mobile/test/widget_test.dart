import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart';

void main() {
  testWidgets('AlarmApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AlarmApp());
    expect(find.text('alarmcore / mobile'), findsOneWidget);
    expect(find.text('ALL ALARMS'), findsOneWidget);
  });
}
