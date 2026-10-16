import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/alarm_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a payload triggers the post-handle hook even for an unknown action', () async {
    var fired = 0;
    AlarmService.onPayloadHandledForTest = () async { fired++; };
    await AlarmService.handleAlarmPayload({'action': 'UNKNOWN'});
    expect(fired, 1);
  });
}
