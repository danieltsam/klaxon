import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/utils/relative_time.dart';

/// Locates `fixtures/relative-time-cases.json` by walking upward from
/// [Directory.current]. `flutter test` runs with the working directory set to
/// the mobile package, so the fixture lives one level up; searching upward
/// keeps this robust without a fragile hard-coded relative path.
File _findFixture() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    final candidate = File('${dir.path}/fixtures/relative-time-cases.json');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    'Could not find fixtures/relative-time-cases.json by searching upward from '
    '${Directory.current.path}. Run `flutter test` from the mobile package.',
  );
}

void main() {
  final fixture =
      jsonDecode(_findFixture().readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  group('formatRelativeDuration matches the shared fixture', () {
    for (final testCase in cases) {
      final seconds = testCase['seconds'] as int;
      test('$seconds s prose -> "${testCase['prose']}"', () {
        expect(
          formatRelativeDuration(Duration(seconds: seconds)),
          testCase['prose'],
        );
      });
      test('$seconds s compact -> "${testCase['compact']}"', () {
        expect(
          formatRelativeDuration(Duration(seconds: seconds), compact: true),
          testCase['compact'],
        );
      });
    }
  });

  group('formatRelativeDuration tier boundaries', () {
    test('59 seconds falls in the lowest tier', () {
      expect(
        formatRelativeDuration(const Duration(seconds: 59)),
        'less than a minute',
      );
    });

    test('exactly 60 seconds is 1 min', () {
      expect(
        formatRelativeDuration(const Duration(seconds: 60)),
        '1 min',
      );
    });

    test('exactly 24 hours is 1 day', () {
      expect(
        formatRelativeDuration(const Duration(hours: 24)),
        '1 day',
      );
    });

    test('exactly 30 days is 1 month', () {
      expect(
        formatRelativeDuration(const Duration(days: 30)),
        '1 month',
      );
    });

    test('exactly 365 days is 1 year', () {
      expect(
        formatRelativeDuration(const Duration(days: 365)),
        '1 year',
      );
    });

    test('negative duration falls in the lowest tier', () {
      expect(
        formatRelativeDuration(const Duration(seconds: -90)),
        'less than a minute',
      );
    });
  });
}
