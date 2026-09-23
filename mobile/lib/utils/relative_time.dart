/// Shared relative-time rule.
///
/// This is the single implementation of the rule described in
/// `fixtures/relative-time-cases.json`. The same rule is implemented by the
/// dashboard and the clients core (CLI / Raycast), so the strings produced here
/// must stay byte-for-byte identical to that fixture.
///
/// The result never includes an `in ` prefix; callers add that themselves.
///
/// Tiers (largest three components only, zero-valued components omitted):
///   under 1 minute -> less than a minute
///   under 1 hour   -> M mins
///   under 24 hours -> H hours M mins
///   under 30 days  -> D days H hours M mins
///   under 1 year   -> MO months D days H hours
///   1 year or more -> Y years MO months D days
///
/// Months are a fixed 30 days and years a fixed 365 days, so the rule stays
/// pure arithmetic. Singular forms are used for exactly 1 unit. Negative and
/// sub-minute spans both fall in the lowest tier.
///
/// [compact] selects the short style used by the CLI and Raycast
/// (`13d 19h 23m`) instead of the prose style used by the phone and dashboard
/// (`13 days 19 hours 23 mins`).
String formatRelativeDuration(Duration span, {bool compact = false}) {
  const secondsPerMinute = 60;
  const secondsPerHour = 60 * secondsPerMinute;
  const secondsPerDay = 24 * secondsPerHour;
  const secondsPerMonth = 30 * secondsPerDay;
  const secondsPerYear = 365 * secondsPerDay;

  final seconds = span.inSeconds;
  if (seconds < secondsPerMinute) return 'less than a minute';

  final totalMinutes = span.inMinutes;

  if (seconds < secondsPerHour) {
    return _render([(totalMinutes, 'min')], compact);
  }
  if (seconds < secondsPerDay) {
    return _render([
      (totalMinutes ~/ 60, 'hour'),
      (totalMinutes % 60, 'min'),
    ], compact);
  }
  if (seconds < secondsPerMonth) {
    final days = totalMinutes ~/ (24 * 60);
    final remainder = totalMinutes % (24 * 60);
    return _render([
      (days, 'day'),
      (remainder ~/ 60, 'hour'),
      (remainder % 60, 'min'),
    ], compact);
  }
  if (seconds < secondsPerYear) {
    final months = totalMinutes ~/ (30 * 24 * 60);
    final remainder = totalMinutes % (30 * 24 * 60);
    return _render([
      (months, 'month'),
      (remainder ~/ (24 * 60), 'day'),
      ((remainder % (24 * 60)) ~/ 60, 'hour'),
    ], compact);
  }
  final years = totalMinutes ~/ (365 * 24 * 60);
  final remainder = totalMinutes % (365 * 24 * 60);
  return _render([
    (years, 'year'),
    (remainder ~/ (30 * 24 * 60), 'month'),
    ((remainder % (30 * 24 * 60)) ~/ (24 * 60), 'day'),
  ], compact);
}

const Map<String, String> _compactSuffixes = {
  'min': 'm',
  'hour': 'h',
  'day': 'd',
  'month': 'mo',
  'year': 'y',
};

String _render(List<(int, String)> parts, bool compact) {
  final rendered = <String>[];
  for (final (value, unit) in parts) {
    if (value == 0) continue; // Zero-valued components are omitted.
    if (compact) {
      rendered.add('$value${_compactSuffixes[unit]}');
    } else {
      rendered.add(value == 1 ? '1 $unit' : '$value ${unit}s');
    }
  }
  return rendered.join(' ');
}
