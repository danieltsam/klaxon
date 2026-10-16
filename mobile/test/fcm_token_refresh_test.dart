import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart' as app;

void main() {
  test('registerToken forwards the token to the registrar seam', () async {
    String? seen;
    app.registerTokenForTest = (t) async { seen = t; };
    await app.registerToken('tok-123');
    expect(seen, 'tok-123');
  });
}
