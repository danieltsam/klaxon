/**
 * Natural-language time parser — browser port.
 *
 * This is a faithful port of `clients/core/src/time.ts` (parseTime /
 * parseLeadingTime) plus the `formatInterpretation` echo it depends on from
 * `clients/core/src/format.ts` and the `TimeParseError` from
 * `clients/core/src/errors.ts`. It is a verbatim translation, not a redesign:
 * any behavioural divergence from the TypeScript source is a bug.
 *
 * Why a hand port rather than a build step: the dashboard at
 * `backend/public/index.html` is a static single file served by
 * `@fastify/static` with no bundler. Loading the TypeScript module directly is
 * impossible, so the grammar is duplicated here — pinned by the shared fixture
 * `fixtures/time-parse-cases.json`, which the TypeScript test and the port test
 * both assert.
 *
 * Loads as a plain `<script src="/nl-time.js"></script>` (no modules, no
 * bundler) and exposes `window.NLTime = { parseTime, parseLeadingTime,
 * TimeParseError }`. Also works under CommonJS (`module.exports`) so a node
 * test can `require()` it. `now` can be injected as a `Date` exactly like the
 * TypeScript version, which is what makes the tests deterministic.
 *
 * The parser produces a LOCAL WALL-CLOCK `Date`; conversion to UTC happens only
 * at the client boundary via `.toISOString()`.
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module && module.exports) {
    // CommonJS (node test harness). `backend/public/package.json` pins this
    // directory to CommonJS so a plain `require()` works under bare node too.
    module.exports = api;
  } else {
    // Browser / classic <script>. `globalThis` is `window` in a browser, but
    // prefer an explicit `window` when one exists.
    root.NLTime = api;
  }
})(
  typeof window !== "undefined" ? window : typeof globalThis !== "undefined" ? globalThis : this,
  function () {
    "use strict";

    /** Invalid natural-language time input. Carries the offending token in `token`. */
    class TimeParseError extends Error {
      constructor(message, token, reason) {
        super(message);
        this.name = "TimeParseError";
        this.token = token;
        this.reason = reason === undefined ? "unparseable" : reason;
      }
    }

    var ALL_DAYS = [1, 2, 3, 4, 5, 6, 7];
    var WEEKDAYS = [1, 2, 3, 4, 5];
    var WEEKENDS = [6, 7];

    var WEEKDAY_NAMES = {
      mon: 1,
      monday: 1,
      tue: 2,
      tues: 2,
      tuesday: 2,
      wed: 3,
      weds: 3,
      wednesday: 3,
      thu: 4,
      thur: 4,
      thurs: 4,
      thursday: 4,
      fri: 5,
      friday: 5,
      sat: 6,
      saturday: 6,
      sun: 7,
      sunday: 7,
    };

    var CONNECTORS = new Set(["at", "in"]);

    /** Month name (short and full) -> 1-based calendar month (spec §6.4). */
    var MONTH_NAMES = {
      jan: 1,
      january: 1,
      feb: 2,
      february: 2,
      mar: 3,
      march: 3,
      apr: 4,
      april: 4,
      may: 5,
      jun: 6,
      june: 6,
      jul: 7,
      july: 7,
      aug: 8,
      august: 8,
      sep: 9,
      september: 9,
      oct: 10,
      october: 10,
      nov: 11,
      november: 11,
      dec: 12,
      december: 12,
    };

    /**
     * Day-period word -> its fixed clock anchor (spec §6.2). A period is a clock:
     * it resolves to this time and, like any passed clock, rolls forward a day.
     */
    var DAY_PERIODS = {
      morning: { hours: 9, minutes: 0 },
      afternoon: { hours: 15, minutes: 0 },
      evening: { hours: 19, minutes: 0 },
      tonight: { hours: 21, minutes: 0 },
      noon: { hours: 12, minutes: 0 },
      midnight: { hours: 0, minutes: 0 },
    };

    /** ISO weekday: 1 = Monday … 7 = Sunday. */
    function isoWeekday(date) {
      var day = date.getDay();
      return day === 0 ? 7 : day;
    }

    function dedupe(days) {
      var seen = {};
      var out = [];
      for (var i = 0; i < days.length; i++) {
        var day = days[i];
        if (!seen[day]) {
          seen[day] = true;
          out.push(day);
        }
      }
      return out;
    }

    function expandRange(start, end) {
      var out = [];
      var current = start;
      // Inclusive, wrapping forward (e.g. fri-mon -> 5,6,7,1).
      for (var guard = 0; guard < 7; guard++) {
        out.push(current);
        if (current === end) break;
        current = current === 7 ? 1 : current + 1;
      }
      return out;
    }

    /**
     * Read a weekday list/range beginning at `i`. Handles `mon-fri`,
     * `mon,wed,fri`, and comma-separated multi-token forms (`mon, wed, fri`).
     * A lone weekday name is intentionally read as a single entry; callers
     * decide whether that means a recurring set or a one-off day qualifier.
     */
    function readWeekdayGroup(toks, i) {
      var days = [];
      var j = i;

      while (j < toks.length) {
        var raw = toks[j];
        var token = raw.replace(/,+$/, "");
        if (token.length === 0) break;

        if (token.indexOf("-") !== -1) {
          var parts = token.split("-");
          var start = WEEKDAY_NAMES[parts[0]];
          var end = WEEKDAY_NAMES[parts[1]];
          if (!start || !end) return null;
          days = days.concat(expandRange(start, end));
          j++;
          if (raw.endsWith(",")) continue;
          break;
        }

        if (token.indexOf(",") !== -1) {
          var pieces = token.split(",").filter(function (p) {
            return p.length > 0;
          });
          var mapped = pieces.map(function (p) {
            return WEEKDAY_NAMES[p];
          });
          if (
            mapped.length === 0 ||
            mapped.some(function (d) {
              return d === undefined;
            })
          ) {
            return null;
          }
          days = days.concat(mapped);
          j++;
          if (raw.endsWith(",")) continue;
          break;
        }

        var weekday = WEEKDAY_NAMES[token];
        if (!weekday) break;
        days.push(weekday);
        j++;
        if (raw.endsWith(",")) continue;
        break;
      }

      if (days.length === 0) return null;
      return { days: days, next: j };
    }

    function matchRecurrencePrefix(toks, i) {
      var first = toks[i];
      if (first === "daily") return { repeatDays: ALL_DAYS, next: i + 1 };
      if (first === "weekdays") return { repeatDays: WEEKDAYS, next: i + 1 };
      if (first === "weekends") return { repeatDays: WEEKENDS, next: i + 1 };

      if (first === "every") {
        var after = toks[i + 1];
        if (after === "day") return { repeatDays: ALL_DAYS, next: i + 2 };
        var group = readWeekdayGroup(toks, i + 1);
        if (group) return { repeatDays: dedupe(group.days), next: group.next };
        return null;
      }

      if (first && (first.indexOf("-") !== -1 || first.indexOf(",") !== -1)) {
        var group2 = readWeekdayGroup(toks, i);
        if (group2) return { repeatDays: dedupe(group2.days), next: group2.next };
      }

      return null;
    }

    function matchDayQualifier(toks, i) {
      var first = toks[i];
      if (first === "tomorrow" || first === "tmr") {
        return { qualifier: { kind: "tomorrow" }, next: i + 1 };
      }
      if (first === "today") {
        return { qualifier: { kind: "today" }, next: i + 1 };
      }
      var weekday = WEEKDAY_NAMES[first];
      if (weekday) {
        return { qualifier: { kind: "weekday", weekday: weekday }, next: i + 1 };
      }
      return null;
    }

    function makeClock(hour, minute, meridiem, next, bare) {
      if (!Number.isInteger(minute) || minute < 0 || minute > 59) return null;
      if (meridiem) {
        // A meridiem implies a 1–12 hour; `13pm` / `0am` are invalid.
        if (hour < 1 || hour > 12) return null;
        var hours = hour % 12;
        if (meridiem === "pm") hours += 12;
        return { hours: hours, minutes: minute, next: next, bare: bare };
      }
      // Bare / colon times without a meridiem are read as 24-hour.
      if (hour < 0 || hour > 23) return null;
      return { hours: hour, minutes: minute, next: next, bare: bare };
    }

    /** Parse a clock token (possibly spread over two tokens, e.g. `7 am`). */
    function parseClock(toks, i) {
      var first = toks[i];
      if (first === undefined) return null;

      // 7am / 12pm / 13pm (invalid)
      var match = /^(\d{1,2})(am|pm)$/.exec(first);
      if (match) {
        return makeClock(parseInt(match[1], 10), 0, match[2], i + 1, false);
      }

      // 7:30am / 07:00 / 19:00 / 7:30
      match = /^(\d{1,2}):(\d{2})(am|pm)?$/.exec(first);
      if (match) {
        var meridiem = match[3];
        var next = i + 1;
        if (!meridiem && next < toks.length && (toks[next] === "am" || toks[next] === "pm")) {
          meridiem = toks[next];
          next++;
        }
        return makeClock(parseInt(match[1], 10), parseInt(match[2], 10), meridiem, next, false);
      }

      // Bare hour: `7` -> 07:00, `19` -> 19:00, optionally followed by am/pm.
      match = /^(\d{1,2})$/.exec(first);
      if (match) {
        if (i + 1 < toks.length && (toks[i + 1] === "am" || toks[i + 1] === "pm")) {
          return makeClock(parseInt(match[1], 10), 0, toks[i + 1], i + 2, false);
        }
        return makeClock(parseInt(match[1], 10), 0, undefined, i + 1, true);
      }

      return null;
    }

    /**
     * Read a day period beginning at `i` (spec §6.2), optionally prefixed `this`
     * (`this morning`). Returns it as a `Clock` — never `bare`, so it is never
     * mistaken for the bare-integer trap — or `null` when no period is present.
     * Mirrors `parseDayPeriod` in clients/core/src/time.ts.
     */
    function parseDayPeriod(toks, i) {
      var j = i;
      if (toks[j] === "this") j++;
      var period = DAY_PERIODS[toks[j]];
      if (!period) return null;
      return { hours: period.hours, minutes: period.minutes, next: j + 1, bare: false };
    }

    /** Parse one or more duration components consuming the rest of the tokens. */
    function parseDuration(toks, i) {
      var joined = toks.slice(i).join("");
      var match =
        /^(?:(\d+)(?:h|hr|hrs|hour|hours))?(?:(\d+)(?:m|min|mins|minute|minutes))?(?:(\d+)(?:s|sec|secs|second|seconds))?$/.exec(
          joined
        );
      if (!match) return null;
      var h = match[1];
      var m = match[2];
      var s = match[3];
      if (h === undefined && m === undefined && s === undefined) return null;
      var hours = h ? parseInt(h, 10) : 0;
      var minutes = m ? parseInt(m, 10) : 0;
      var seconds = s ? parseInt(s, 10) : 0;
      return { ms: ((hours * 60 + minutes) * 60 + seconds) * 1000 };
    }

    /**
     * Read a whole-day offset beginning at `i`: `<n> days|day`, `<n> weeks|week`,
     * `<n>d`, `<n>w`, concatenated (`1w 2d`, `1w2d`), optionally led by the `in`
     * connector and optionally followed by `from now`. Returns the total whole
     * days (`weeks*7 + days`) and the index just past the offset, or `null`.
     *
     * Day/week units are deliberately kept out of `parseDuration`: an offset
     * lands on a wall-clock day, not a fixed millisecond span (spec §6.6), so the
     * caller resolves it with `setDate(getDate() + days)` rather than ms
     * arithmetic. Mirrors `parseDayWeekOffset` in clients/core/src/time.ts.
     */
    function parseDayWeekOffset(toks, i) {
      var j = i;
      if (toks[j] === "in") j++;
      var joined = toks.slice(j).join("");
      var match = /^(?:(\d+)(?:w|week|weeks))?(?:(\d+)(?:d|day|days))?(?:fromnow)?$/.exec(
        joined
      );
      if (!match) return null;
      var w = match[1];
      var d = match[2];
      if (w === undefined && d === undefined) return null;
      var weeks = w ? parseInt(w, 10) : 0;
      var days = d ? parseInt(d, 10) : 0;
      return { days: weeks * 7 + days, next: toks.length };
    }

    /**
     * Read a day-of-month, tolerating an English ordinal suffix (`4th` -> `4`).
     * Returns `null` for anything that is not a 1–31 number.
     */
    function parseDayNumber(token) {
      var stripped = token.replace(/(st|nd|rd|th)$/, "");
      if (!/^\d{1,2}$/.test(stripped)) return null;
      var day = parseInt(stripped, 10);
      if (day < 1 || day > 31) return null;
      return day;
    }

    /**
     * Read a `<d>/<m>` numeric date (spec §6.5). The reading is day/month when
     * unambiguous: a first field over 12 must be the day, a second field over 12
     * makes the first the month. When both fields are ≤ 12 the default is
     * **day/month** (`03/04` = 3 Apr).
     */
    function parseNumericDate(token) {
      var match = /^(\d{1,2})\/(\d{1,2})$/.exec(token);
      if (!match) return null;
      var a = parseInt(match[1], 10);
      var b = parseInt(match[2], 10);
      if (a < 1 || a > 31 || b < 1 || b > 31) return null;

      var month;
      var day;
      if (a > 12) {
        day = a;
        month = b;
      } else if (b > 12) {
        month = a;
        day = b;
      } else {
        day = a;
        month = b;
      }
      if (month < 1 || month > 12) return null;
      return { month: month, day: day };
    }

    /**
     * Read an absolute date beginning at `i` (spec §6.4): `<month> <day>` (`dec 25`,
     * `december 25`), `<day> <month>` (`25 dec`, `25th december`), `<month>
     * <ordinal>` (`jan 4th`), `<d>/<m>` numeric (`25/12`), or ISO (`2026-12-31`).
     * Returns the date and the index just past it, or `null`.
     */
    function parseAbsoluteDate(toks, i) {
      var first = toks[i];
      if (first === undefined) return null;

      // ISO `YYYY-MM-DD`.
      var iso = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(first);
      if (iso) {
        var year = parseInt(iso[1], 10);
        var month = parseInt(iso[2], 10);
        var day = parseInt(iso[3], 10);
        if (month < 1 || month > 12 || day < 1 || day > 31) return null;
        return { date: { month: month, day: day, year: year }, next: i + 1 };
      }

      // `<d>/<m>` numeric.
      var numeric = parseNumericDate(first);
      if (numeric) {
        return { date: { month: numeric.month, day: numeric.day }, next: i + 1 };
      }

      var second = toks[i + 1];
      var firstMonth = MONTH_NAMES[first];
      if (firstMonth !== undefined) {
        // `<month> <day>` / `<month> <ordinal>`.
        if (second === undefined) return null;
        var dayOfMonth = parseDayNumber(second);
        if (dayOfMonth === null) return null;
        return { date: { month: firstMonth, day: dayOfMonth }, next: i + 2 };
      }

      // `<day> <month>` / `<ordinal> <month>`.
      var dayNumber = parseDayNumber(first);
      var secondMonth = second !== undefined ? MONTH_NAMES[second] : undefined;
      if (dayNumber !== null && secondMonth !== undefined) {
        return { date: { month: secondMonth, day: dayNumber }, next: i + 2 };
      }

      return null;
    }

    /**
     * Resolve a calendar date at `hours:minutes` to a local wall-clock instant
     * (spec §6.4). An explicit year is honoured verbatim, including a **past** year
     * (the §9 futurity check is a later concern). With no year the next occurrence
     * is used: a resolved instant at or before `now` rolls to the next year.
     */
    function resolveAbsoluteDate(now, date, hours, minutes) {
      var candidate = new Date(now.getTime());
      candidate.setHours(hours, minutes, 0, 0);
      if (date.year !== undefined) {
        candidate.setFullYear(date.year, date.month - 1, date.day);
        return candidate;
      }
      candidate.setMonth(date.month - 1, date.day);
      if (candidate.getTime() <= now.getTime()) {
        candidate.setFullYear(candidate.getFullYear() + 1);
      }
      return candidate;
    }

    function buildAbsolute(ctx, hours, minutes, targetDays) {
      // Today counts if the time has not passed; otherwise the next matching day.
      for (var offset = 0; offset <= 7; offset++) {
        var candidate = new Date(ctx.now.getTime());
        candidate.setDate(candidate.getDate() + offset);
        candidate.setHours(hours, minutes, 0, 0);
        if (candidate.getTime() <= ctx.now.getTime()) continue;
        if (targetDays.indexOf(isoWeekday(candidate)) !== -1) return candidate;
      }
      // Unreachable for a non-empty targetDays set, but keep a total function.
      var fallback = new Date(ctx.now.getTime());
      fallback.setDate(fallback.getDate() + 7);
      fallback.setHours(hours, minutes, 0, 0);
      return fallback;
    }

    function buildClockTime(ctx, qualifier, repeatDays, hours, minutes) {
      if (qualifier && qualifier.kind === "tomorrow") {
        var candidate = new Date(ctx.now.getTime());
        candidate.setDate(candidate.getDate() + 1);
        candidate.setHours(hours, minutes, 0, 0);
        return candidate;
      }
      if (qualifier && qualifier.kind === "today") {
        var candidate2 = new Date(ctx.now.getTime());
        candidate2.setHours(hours, minutes, 0, 0);
        // A passed "today" rolls forward rather than scheduling in the past.
        if (candidate2.getTime() <= ctx.now.getTime()) {
          candidate2.setDate(candidate2.getDate() + 1);
        }
        return candidate2;
      }
      if (qualifier && qualifier.kind === "weekday") {
        return buildAbsolute(ctx, hours, minutes, [qualifier.weekday]);
      }
      if (repeatDays.length > 0) {
        return buildAbsolute(ctx, hours, minutes, repeatDays);
      }
      return buildAbsolute(ctx, hours, minutes, ALL_DAYS);
    }

    function finalize(targetTime, repeatDays, now) {
      return {
        targetTime: targetTime,
        repeatDays: repeatDays,
        interpretation: formatInterpretation(targetTime, now),
      };
    }

    /**
     * Try to parse a sequence of tokens as exactly one complete time expression.
     * Returns `null` if the tokens are not a single valid expression.
     *
     * `allowBareIntegerClock` is true only when `toks` is the entire input: a
     * bare-integer clock (`7`) is otherwise a trap, silently swallowing a number
     * that belongs to the label (spec §5.4/§11 #6).
     */
    function tryParseExpression(toks, now, allowBareIntegerClock) {
      var ctx = { now: now };
      var i = 0;

      var skipConnectors = function () {
        while (i < toks.length && CONNECTORS.has(toks[i])) i++;
      };

      skipConnectors();
      if (i >= toks.length) return null;

      var repeatDays = [];
      var qualifier = null;

      var recurrence = matchRecurrencePrefix(toks, i);
      if (recurrence) {
        repeatDays = recurrence.repeatDays;
        i = recurrence.next;
      } else {
        var day = matchDayQualifier(toks, i);
        if (day) {
          qualifier = day.qualifier;
          i = day.next;
        }
      }

      skipConnectors();

      if (i >= toks.length) {
        // No clock: a bare day qualifier means midnight; recurrence needs a time.
        if (repeatDays.length > 0) return null;
        if (qualifier) {
          return finalize(buildClockTime(ctx, qualifier, [], 0, 0), [], ctx.now);
        }
        return null;
      }

      // Absolute-date anchor (spec §6.4), standalone or joined to a clock in
      // either order (spec §5.4). A lone date resolves to 00:00 on that day.
      if (!qualifier && repeatDays.length === 0) {
        // Date → clock/period: `dec 25 7am`, `2026-12-31 9am`, `dec 25 noon`.
        var date = parseAbsoluteDate(toks, i);
        if (date) {
          var dj = date.next;
          while (dj < toks.length && CONNECTORS.has(toks[dj])) dj++;
          if (dj === toks.length) {
            return finalize(resolveAbsoluteDate(ctx.now, date.date, 0, 0), [], ctx.now);
          }
          var dateClock = parseClock(toks, dj) ?? parseDayPeriod(toks, dj);
          if (
            dateClock &&
            dateClock.next === toks.length &&
            (!dateClock.bare || allowBareIntegerClock)
          ) {
            return finalize(
              resolveAbsoluteDate(ctx.now, date.date, dateClock.hours, dateClock.minutes),
              [],
              ctx.now
            );
          }
        }

        // Clock → date: `5pm 10/31`.
        var leadClock = parseClock(toks, i);
        if (leadClock) {
          var cj = leadClock.next;
          while (cj < toks.length && CONNECTORS.has(toks[cj])) cj++;
          if (cj < toks.length) {
            var trailingDate = parseAbsoluteDate(toks, cj);
            if (trailingDate && trailingDate.next === toks.length) {
              return finalize(
                resolveAbsoluteDate(
                  ctx.now,
                  trailingDate.date,
                  leadClock.hours,
                  leadClock.minutes
                ),
                [],
                ctx.now
              );
            }
          }
        }
      }

      // Duration form: only ever standalone (no day/recurrence qualifier).
      if (!qualifier && repeatDays.length === 0) {
        var duration = parseDuration(toks, i);
        if (duration) {
          var targetTime = new Date(ctx.now.getTime() + duration.ms);
          return finalize(targetTime, [], ctx.now);
        }

        // Day/week offset form: also standalone, and resolved on the wall clock.
        var offset = parseDayWeekOffset(toks, i);
        if (offset) {
          var offsetTime = new Date(ctx.now.getTime());
          offsetTime.setDate(offsetTime.getDate() + offset.days);
          return finalize(offsetTime, [], ctx.now);
        }
      }

      var clock = parseClock(toks, i);
      if (clock && clock.next === toks.length && (!clock.bare || allowBareIntegerClock)) {
        var targetTime2 = buildClockTime(ctx, qualifier, repeatDays, clock.hours, clock.minutes);
        return finalize(targetTime2, repeatDays, ctx.now);
      }

      // Day period as a clock (spec §6.2): `afternoon`, `this morning`,
      // `tomorrow noon`. Never `bare`, so it always passes the trap guard above.
      var period = parseDayPeriod(toks, i);
      if (period && period.next === toks.length) {
        var periodTime = buildClockTime(ctx, qualifier, repeatDays, period.hours, period.minutes);
        return finalize(periodTime, repeatDays, ctx.now);
      }

      return null;
    }

    /**
     * Parse a complete time expression. Throws `TimeParseError` if the whole
     * input is not one valid expression.
     */
    function parseTime(input, now) {
      var nowDate = now ?? new Date();
      var raw = input.trim().split(/\s+/).filter(Boolean);
      if (raw.length === 0) {
        throw new TimeParseError("Empty time expression.", "");
      }

      var toks = raw.map(function (t) {
        return t.toLowerCase();
      });
      var parsed = tryParseExpression(toks, nowDate, true);
      if (parsed) return parsed;

      // Name the offending (first unconsumed) token when a valid prefix exists.
      for (var end = toks.length - 1; end >= 1; end--) {
        if (tryParseExpression(toks.slice(0, end), nowDate, false)) {
          throw new TimeParseError('Could not parse time expression: "' + raw[end] + '".', raw[end]);
        }
      }

      throw new TimeParseError('Could not parse time expression: "' + raw[0] + '".', raw[0]);
    }

    /**
     * When no leading prefix parses, locate a complete time expression *inside*
     * the input and treat the surrounding tokens as the label. A trailing span is
     * preferred (the natural "label first" phrasing, e.g. `gym tomorrow 7am`),
     * falling back to the longest span anywhere. Returns `null` when nothing
     * parses. Mirrors `findTimeSpan` in clients/core/src/time.ts.
     */
    function findTimeSpan(raw, toks, now) {
      // Prefer the longest trailing span: label first, time last. Iterating
      // `start` upward returns the smallest start (longest suffix) that parses.
      for (var start = 0; start < toks.length; start++) {
        var trailing = tryParseExpression(toks.slice(start), now, false);
        if (trailing) {
          return { parsed: trailing, rest: raw.slice(0, start).join(" ") };
        }
      }
      // Otherwise the longest span anywhere; the surrounding tokens form the label.
      for (var len = toks.length; len >= 1; len--) {
        for (var start2 = 0; start2 + len <= toks.length; start2++) {
          var inner = tryParseExpression(toks.slice(start2, start2 + len), now, false);
          if (inner) {
            var label = raw.slice(0, start2).concat(raw.slice(start2 + len));
            return { parsed: inner, rest: label.join(" ") };
          }
        }
      }
      return null;
    }

    /**
     * Longest leading prefix that parses as a single time expression, plus the
     * unconsumed remainder. When no prefix parses, falls back to the longest
     * parseable span anywhere in the input (trailing spans preferred) so
     * label-first phrasing like `uni meeting tomorrow at 8pm` still splits into a
     * time and a label. Returns `null` only when no span parses at all.
     */
    function parseLeadingTime(input, now) {
      var nowDate = now ?? new Date();
      var raw = input.trim().split(/\s+/).filter(Boolean);
      if (raw.length === 0) return null;

      var toks = raw.map(function (t) {
        return t.toLowerCase();
      });
      for (var end = toks.length; end >= 1; end--) {
        // Only the whole input may carry a bare-integer clock; shorter prefixes
        // are slices, where a bare integer would swallow part of the label.
        var parsed = tryParseExpression(toks.slice(0, end), nowDate, end === toks.length);
        if (parsed) {
          return { parsed: parsed, rest: raw.slice(end).join(" ") };
        }
      }
      // No leading time prefix: fall back to a span anywhere in the input.
      return findTimeSpan(raw, toks, nowDate);
    }

    // ── Display formatters (ported verbatim from clients/core/src/format.ts) ──
    // Only the pieces `formatInterpretation` needs are included; the parser's
    // `interpretation` echo must match the CLI/dashboard byte-for-byte.

    var WEEKDAYS_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    var MONTHS_SHORT = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec",
    ];

    /** 12-hour clock, lower-case meridiem: `7:00am`, `12:00am`, `7:05pm`. */
    function formatClock(date) {
      var hours = date.getHours();
      var minutes = date.getMinutes();
      var suffix = hours < 12 ? "am" : "pm";
      var hour12 = hours % 12 === 0 ? 12 : hours % 12;
      return hour12 + ":" + String(minutes).padStart(2, "0") + suffix;
    }

    /** `Tue 22 Sep` (local). */
    function formatDate(date) {
      return (
        WEEKDAYS_SHORT[date.getDay()] + " " + date.getDate() + " " + MONTHS_SHORT[date.getMonth()]
      );
    }

    /** `Tue 22 Sep, 7:00am` (local). */
    function formatLocal(date) {
      return formatDate(date) + ", " + formatClock(date);
    }

    var MINUTE_SECONDS = 60;
    var HOUR_SECONDS = 60 * MINUTE_SECONDS;
    var DAY_SECONDS = 24 * HOUR_SECONDS;
    var MONTH_SECONDS = 30 * DAY_SECONDS;
    var YEAR_SECONDS = 365 * DAY_SECONDS;

    var COMPACT_SUFFIX = {
      min: "m",
      hour: "h",
      day: "d",
      month: "mo",
      year: "y",
    };

    function relativeComponents(totalSeconds) {
      var parts = [];

      if (totalSeconds < MINUTE_SECONDS) {
        return parts;
      } else if (totalSeconds < HOUR_SECONDS) {
        parts.push({ value: Math.floor(totalSeconds / MINUTE_SECONDS), unit: "min" });
      } else if (totalSeconds < DAY_SECONDS) {
        parts.push({ value: Math.floor(totalSeconds / HOUR_SECONDS), unit: "hour" });
        parts.push({
          value: Math.floor((totalSeconds % HOUR_SECONDS) / MINUTE_SECONDS),
          unit: "min",
        });
      } else if (totalSeconds < MONTH_SECONDS) {
        parts.push({ value: Math.floor(totalSeconds / DAY_SECONDS), unit: "day" });
        parts.push({
          value: Math.floor((totalSeconds % DAY_SECONDS) / HOUR_SECONDS),
          unit: "hour",
        });
        parts.push({
          value: Math.floor((totalSeconds % HOUR_SECONDS) / MINUTE_SECONDS),
          unit: "min",
        });
      } else if (totalSeconds < YEAR_SECONDS) {
        parts.push({ value: Math.floor(totalSeconds / MONTH_SECONDS), unit: "month" });
        parts.push({
          value: Math.floor((totalSeconds % MONTH_SECONDS) / DAY_SECONDS),
          unit: "day",
        });
        parts.push({
          value: Math.floor((totalSeconds % DAY_SECONDS) / HOUR_SECONDS),
          unit: "hour",
        });
      } else {
        parts.push({ value: Math.floor(totalSeconds / YEAR_SECONDS), unit: "year" });
        parts.push({
          value: Math.floor((totalSeconds % YEAR_SECONDS) / MONTH_SECONDS),
          unit: "month",
        });
        parts.push({
          value: Math.floor(((totalSeconds % YEAR_SECONDS) % MONTH_SECONDS) / DAY_SECONDS),
          unit: "day",
        });
      }

      return parts.filter(function (part) {
        return part.value > 0;
      });
    }

    /** Compact body without the caller's direction: `13h 40m`, `1mo`, `less than a minute`. */
    function formatRelativeBody(totalSeconds) {
      if (totalSeconds < MINUTE_SECONDS) {
        return "less than a minute";
      }
      return relativeComponents(totalSeconds)
        .map(function (part) {
          return "" + part.value + COMPACT_SUFFIX[part.unit];
        })
        .join(" ");
    }

    function formatRelative(from, to) {
      var diffMs = to.getTime() - from.getTime();
      var future = diffMs >= 0;
      var totalSeconds = Math.floor(Math.abs(diffMs) / 1000);
      var body = formatRelativeBody(totalSeconds);

      return future ? "in " + body : body + " ago";
    }

    /** `Tue 22 Sep, 7:00am (in 13h 40m)` — the absolute-local echo required by spec §6.5. */
    function formatInterpretation(date, now) {
      return formatLocal(date) + " (" + formatRelative(now, date) + ")";
    }

    return {
      parseTime: parseTime,
      parseLeadingTime: parseLeadingTime,
      TimeParseError: TimeParseError,
    };
  }
);
