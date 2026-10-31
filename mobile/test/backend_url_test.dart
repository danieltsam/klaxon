import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/backend_client.dart';

void main() {
  group('BackendClient.normalizeBaseUrl', () {
    test('assumes http for a bare host and port', () {
      expect(BackendClient.normalizeBaseUrl('baymax:8001'), 'http://baymax:8001');
    });

    test('keeps an explicit scheme and strips trailing slashes', () {
      expect(BackendClient.normalizeBaseUrl(' https://klaxon.example:8443/ '), 'https://klaxon.example:8443');
      expect(BackendClient.normalizeBaseUrl('http://100.101.102.103:8001//'), 'http://100.101.102.103:8001');
    });

    test('leaves an empty value alone so the caller can refuse it', () {
      expect(BackendClient.normalizeBaseUrl('   '), '');
    });
  });
}
