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

    /**
     * Ramp keyword phrase -> seconds (spec §8). A bare `<n>s` is deliberately
     * absent: only `<n>s ramp` is a ramp, so `30s` stays a duration. Mirrors
     * `RAMP_PHRASES` in clients/core/src/time.ts.
     */
    var RAMP_PHRASES = {
      "no ramp": 0,
      "quick ramp": 15,
      "gentle ramp": 30,
      "deep ramp": 60,
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

    /**
     * Read an interval beginning at `i`, i.e. the tokens just after `every` (spec
     * §5.3): `<n> weeks|week` → a week interval; `<n> days|day` → a day interval;
     * `other <weekday>` / `<n>nd <weekday>` → that weekday, every 2 weeks. A number
     * with a unit is an interval and is **never** a clock; a named day is a weekday
     * set. `day` (all days) and a bare `<weekday-group>` are deliberately left to
     * the caller's existing fallback, so only the interval forms are returned here.
     * Mirrors `parseInterval` in clients/core/src/time.ts.
     */
    function parseInterval(toks, i) {
      var countMatch = /^(\d+)$/.exec(toks[i]);
      var unit = toks[i + 1];
      if (countMatch) {
        var count = parseInt(countMatch[1], 10);
        if (unit === "week" || unit === "weeks") {
          return { interval: { count: count, unit: "weeks" }, repeatDays: [], next: i + 2 };
        }
        if (unit === "day" || unit === "days") {
          return { interval: { count: count, unit: "days" }, repeatDays: [], next: i + 2 };
        }
      }

      // `every other <weekday>` / `every <n>nd <weekday>`: a weekday set every 2 weeks.
      var weekday = WEEKDAY_NAMES[toks[i + 1]];
      if (weekday && (toks[i] === "other" || /^\d+nd$/.test(toks[i]))) {
        return {
          interval: { count: 2, unit: "weeks" },
          repeatDays: [weekday],
          next: i + 2,
        };
      }

      return null;
    }

    /**
     * True when the token stream contains an `every` that does not begin a
     * recognized recurrence form. `every` is a strong recurrence signal, so an
     * `every <token>` the grammar cannot read must fail loudly rather than fall
     * through to a bare weekday and silently demote the recurrence to a one-time
     * alarm (spec §5.3/§10). The motivating case is `every 3rd monday`:
     * ordinal-of-month is not expressible and an interval of 3 is not storable,
     * so no reading is safe. Mirrors `hasOrphanEvery` in clients/core/src/time.ts.
     */
    function hasOrphanEvery(toks) {
      for (var i = 0; i < toks.length; i++) {
        if (toks[i] === "every" && !matchRecurrencePrefix(toks, i)) return true;
      }
      return false;
    }

    function matchRecurrencePrefix(toks, i) {
      var first = toks[i];
      if (first === "daily") return { repeatDays: ALL_DAYS, next: i + 1 };
      if (first === "weekdays") return { repeatDays: WEEKDAYS, next: i + 1 };
      if (first === "weekends") return { repeatDays: WEEKENDS, next: i + 1 };

      if (first === "every") {
        var interval = parseInterval(toks, i + 1);
        if (interval) return interval;
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

    /**
     * Read a `this` / `next` qualifier beginning at `i` (spec §6.3): `this
     * <weekday>`, `next <weekday>`, `this weekend`, `next week`, `next month`.
     * `last` is deliberately **not** a token (owner decision 3): `last friday` is
     * just the forward-only weekday `friday` with `last` left in the label.
     *
     * `this-weekday` records the matched phrase in `token` so a passed resolution
     * can name it in the `already_passed` refusal. Mirrors `matchNextThis` in
     * clients/core/src/time.ts.
     */
    function matchNextThis(toks, i) {
      var first = toks[i];
      if (first === "this") {
        var second = toks[i + 1];
        var weekday = WEEKDAY_NAMES[second];
        if (weekday) {
          return {
            qualifier: { kind: "this-weekday", weekday: weekday, token: first + " " + second },
            next: i + 2,
          };
        }
        if (second === "weekend") {
          return { qualifier: { kind: "this-weekend" }, next: i + 2 };
        }
        return null;
      }
      if (first === "next") {
        var second2 = toks[i + 1];
        var weekday2 = WEEKDAY_NAMES[second2];
        if (weekday2) {
          return { qualifier: { kind: "next-weekday", weekday: weekday2 }, next: i + 2 };
        }
        if (second2 === "week") {
          return { qualifier: { kind: "next-week" }, next: i + 2 };
        }
        if (second2 === "month") {
          return { qualifier: { kind: "next-month" }, next: i + 2 };
        }
        return null;
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
      if (qualifier && qualifier.kind === "this-weekday") {
        // That weekday in the current Monday-start ISO week. A resolved instant
        // at or before `now` (equality included) is a hard refusal — never
        // rolled forward (spec §6.3/§10).
        var thisDay = new Date(ctx.now.getTime());
        thisDay.setDate(
          thisDay.getDate() - (isoWeekday(thisDay) - 1) + (qualifier.weekday - 1)
        );
        thisDay.setHours(hours, minutes, 0, 0);
        if (thisDay.getTime() <= ctx.now.getTime()) {
          throw new TimeParseError(
            '"' + qualifier.token + '" has already passed.',
            qualifier.token,
            "already_passed"
          );
        }
        return thisDay;
      }
      if (qualifier && qualifier.kind === "next-weekday") {
        // That weekday in the next ISO week — always ahead of `now`.
        var nextDay = new Date(ctx.now.getTime());
        nextDay.setDate(
          nextDay.getDate() - (isoWeekday(nextDay) - 1) + 7 + (qualifier.weekday - 1)
        );
        nextDay.setHours(hours, minutes, 0, 0);
        return nextDay;
      }
      if (qualifier && qualifier.kind === "this-weekend") {
        // `this weekend` is `this saturday` at 00:00: the Saturday of the current
        // Monday-start ISO week. A resolved instant at or before `now` — Saturday
        // after 00:00, or all of Sunday, once that week's Saturday has gone — is a
        // hard `already_passed` refusal, mirroring `this <weekday>` (spec §6.3).
        // Never roll forward: that would silently skip to the next weekend.
        var weekend = new Date(ctx.now.getTime());
        weekend.setDate(weekend.getDate() - (isoWeekday(weekend) - 1) + (6 - 1));
        weekend.setHours(hours, minutes, 0, 0);
        if (weekend.getTime() <= ctx.now.getTime()) {
          throw new TimeParseError(
            '"this weekend" has already passed.',
            "this weekend",
            "already_passed"
          );
        }
        return weekend;
      }
      if (qualifier && qualifier.kind === "next-week") {
        // Same wall-clock time, one week ahead.
        var nextWeek = new Date(ctx.now.getTime());
        nextWeek.setDate(nextWeek.getDate() + 7);
        return nextWeek;
      }
      if (qualifier && qualifier.kind === "next-month") {
        // Same wall-clock time, one calendar month ahead. Clamp a month-end
        // overflow (e.g. 31 Jan -> 3 Mar) back to the last day of the intended
        // month.
        var nextMonth = new Date(ctx.now.getTime());
        var targetDay = nextMonth.getDate();
        nextMonth.setMonth(nextMonth.getMonth() + 1);
        if (nextMonth.getDate() !== targetDay) {
          nextMonth.setDate(0);
        }
        return nextMonth;
      }
      if (repeatDays.length > 0) {
        return buildAbsolute(ctx, hours, minutes, repeatDays);
      }
      return buildAbsolute(ctx, hours, minutes, ALL_DAYS);
    }

    /**
     * Anchor a weekday-less interval with no clock (spec §6.6): `now + interval`,
     * preserving the wall-clock time (day/week arithmetic on the calendar, never a
     * fixed millisecond span). Mirrors `anchorInterval` in clients/core/src/time.ts.
     */
    function anchorInterval(ctx, interval) {
      var target = new Date(ctx.now.getTime());
      target.setDate(target.getDate() + interval.count * (interval.unit === "weeks" ? 7 : 1));
      return target;
    }

    function finalize(targetTime, repeatDays, now, interval) {
      var parsed = {
        targetTime: targetTime,
        repeatDays: repeatDays,
        interpretation: formatInterpretation(targetTime, now),
      };
      if (interval) parsed.interval = interval;
      return parsed;
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
      var interval;

      var recurrence = matchRecurrencePrefix(toks, i);
      if (recurrence) {
        repeatDays = recurrence.repeatDays;
        interval = recurrence.interval;
        i = recurrence.next;
      } else {
        var nextThis = matchNextThis(toks, i);
        if (nextThis) {
          qualifier = nextThis.qualifier;
          i = nextThis.next;
        } else {
          var day = matchDayQualifier(toks, i);
          if (day) {
            qualifier = day.qualifier;
            i = day.next;
          }
        }
      }

      skipConnectors();

      if (i >= toks.length) {
        // No clock: a bare day qualifier means midnight; recurrence needs a time —
        // except an interval, which anchors to now + interval (weekday-less) or to
        // the weekday's next occurrence at midnight (spec §6.6).
        if (interval) {
          if (repeatDays.length > 0) {
            return finalize(
              buildClockTime(ctx, qualifier, repeatDays, 0, 0),
              repeatDays,
              ctx.now,
              interval
            );
          }
          return finalize(anchorInterval(ctx, interval), [], ctx.now, interval);
        }
        if (repeatDays.length > 0) return null;
        if (qualifier) {
          return finalize(buildClockTime(ctx, qualifier, [], 0, 0), [], ctx.now);
        }
        return null;
      }

      // Absolute-date anchor (spec §6.4), standalone or joined to a clock in
      // either order (spec §5.4). A lone date resolves to 00:00 on that day. Not an
      // interval anchor: an interval must not be silently dropped here.
      if (!qualifier && repeatDays.length === 0 && interval === undefined) {
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

        // Clock → date: `5pm 10/31`. The same bare-integer guard as the date → clock
        // branch above: a bare integer is a clock only as the whole expression, so a
        // stray integer before a date stays in the label (spec §5.4/§11 #6).
        var leadClock = parseClock(toks, i);
        if (leadClock && (!leadClock.bare || allowBareIntegerClock)) {
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

      // Duration form: only ever standalone (no day/recurrence qualifier). The
      // `interval === undefined` guard keeps an interval from being hijacked by the
      // day/week offset branch below, which would silently drop it (§5.3/§6.6).
      if (!qualifier && repeatDays.length === 0 && interval === undefined) {
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
        return finalize(targetTime2, repeatDays, ctx.now, interval);
      }

      // Day period as a clock (spec §6.2): `afternoon`, `this morning`,
      // `tomorrow noon`. Never `bare`, so it always passes the trap guard above.
      var period = parseDayPeriod(toks, i);
      if (period && period.next === toks.length) {
        var periodTime = buildClockTime(ctx, qualifier, repeatDays, period.hours, period.minutes);
        return finalize(periodTime, repeatDays, ctx.now, interval);
      }

      return null;
    }

    /**
     * Stage 0 metadata pre-pass (spec §5.1/§8). Recognizes metadata keywords as
     * standalone tokens anywhere in the input and removes them from the stream
     * before the time grammar runs, returning the cleaned `raw`/`toks` plus the
     * extracted `alarm` (absent when the input named none).
     *
     * `note:` is special: it consumes everything to the end of the input,
     * verbatim and with original casing, as the description — tokens after it
     * are never parsed as time. A bare `<n>s` is left alone on purpose: only
     * `<n>s ramp` (the number immediately followed by the literal word `ramp`)
     * is a ramp, so `30s` stays a duration (spec §8). Mirrors `extractMetadata`
     * in clients/core/src/time.ts.
     */
    function extractMetadata(raw, toks) {
      var alarm = {};
      var found = false;

      // `note:` swallows the rest of the input verbatim (original casing preserved).
      var limit = toks.length;
      var noteIndex = toks.indexOf("note:");
      if (noteIndex !== -1) {
        alarm.description = raw.slice(noteIndex + 1).join(" ");
        found = true;
        limit = noteIndex;
      }

      var keptRaw = [];
      var keptToks = [];
      for (var i = 0; i < limit; i++) {
        var token = toks[i];

        if (token === "chime") {
          alarm.sound_tone = "chime";
          found = true;
          continue;
        }
        if (token === "digital") {
          // Alias `digital pulse`; the trailing word is consumed with it.
          if (toks[i + 1] === "pulse") i++;
          alarm.sound_tone = "digital";
          found = true;
          continue;
        }

        var seconds = /^(\d+)s$/.exec(token);
        if (seconds && toks[i + 1] === "ramp") {
          alarm.ramp_seconds = parseInt(seconds[1], 10);
          found = true;
          i++;
          continue;
        }

        var phrase = RAMP_PHRASES[token + " " + toks[i + 1]];
        if (phrase !== undefined) {
          alarm.ramp_seconds = phrase;
          found = true;
          i++;
          continue;
        }

        keptRaw.push(raw[i]);
        keptToks.push(token);
      }

      return { alarm: found ? alarm : undefined, raw: keptRaw, toks: keptToks };
    }

    /**
     * Parse a complete time expression. Throws `TimeParseError` if the whole
     * input is not one valid expression.
     */
    function parseTime(input, now) {
      var nowDate = now ?? new Date();
      var inputRaw = input.trim().split(/\s+/).filter(Boolean);
      if (inputRaw.length === 0) {
        throw new TimeParseError("Empty time expression.", "");
      }

      var inputToks = inputRaw.map(function (t) {
        return t.toLowerCase();
      });
      var metadata = extractMetadata(inputRaw, inputToks);
      var raw = metadata.raw;
      var toks = metadata.toks;

      var parsed = tryParseExpression(toks, nowDate, true);
      if (parsed) {
        if (metadata.alarm) parsed.alarm = metadata.alarm;
        return parsed;
      }

      // Name the offending (first unconsumed) token when a valid prefix exists.
      for (var end = toks.length - 1; end >= 1; end--) {
        if (tryParseExpression(toks.slice(0, end), nowDate, false)) {
          throw new TimeParseError('Could not parse time expression: "' + raw[end] + '".', raw[end]);
        }
      }

      var offending = raw[0] ?? inputRaw[0];
      throw new TimeParseError('Could not parse time expression: "' + offending + '".', offending);
    }

    /**
     * When no leading prefix parses, locate a complete time expression *inside*
     * the input and treat the surrounding tokens as the label. A trailing span is
     * preferred (the natural "label first" phrasing, e.g. `gym tomorrow 7am`),
     * falling back to the longest span anywhere. Returns `null` when nothing
     * parses. The selected token range `[start, end)` is returned too, so the
     * caller can judge whether that expression carried an anchor (spec §5.4
     * stage 3). Mirrors `findTimeSpan` in clients/core/src/time.ts.
     */
    function findTimeSpan(raw, toks, now) {
      // Prefer the longest trailing span: label first, time last. Iterating
      // `start` upward returns the smallest start (longest suffix) that parses.
      for (var start = 0; start < toks.length; start++) {
        var trailing = speculative(function () {
          return tryParseExpression(toks.slice(start), now, false);
        });
        if (trailing) {
          return {
            parsed: trailing,
            rest: raw.slice(0, start).join(" "),
            start: start,
            end: toks.length,
          };
        }
      }
      // Otherwise the longest span anywhere; the surrounding tokens form the label.
      for (var len = toks.length; len >= 1; len--) {
        for (var start2 = 0; start2 + len <= toks.length; start2++) {
          var inner = speculative(function () {
            return tryParseExpression(toks.slice(start2, start2 + len), now, false);
          });
          if (inner) {
            var label = raw.slice(0, start2).concat(raw.slice(start2 + len));
            return {
              parsed: inner,
              rest: label.join(" "),
              start: start2,
              end: start2 + len,
            };
          }
        }
      }
      return null;
    }

    /**
     * True when the expression at `[start, end)` carries no recurrence, day
     * qualifier, `this`/`next`, or absolute-date anchor — i.e. the ladder selected
     * a bare clock/period. Mirrors the anchor dispatch at the head of
     * `tryParseExpression`; stage 3 overrides only such an unanchored selection.
     * Mirrors `spanIsUnanchored` in clients/core/src/time.ts.
     */
    function spanIsUnanchored(toks, start, end) {
      var i = start;
      while (i < end && CONNECTORS.has(toks[i])) i++;
      if (i >= end) return true;
      if (matchRecurrencePrefix(toks, i)) return false;
      if (matchNextThis(toks, i)) return false;
      if (matchDayQualifier(toks, i)) return false;
      if (parseAbsoluteDate(toks, i)) return false;
      // Clock → date (`5pm 10/31`): the clock is anchored by the trailing date.
      var clock = parseClock(toks, i);
      if (clock) {
        var j = clock.next;
        while (j < end && CONNECTORS.has(toks[j])) j++;
        if (j < end && parseAbsoluteDate(toks, j)) return false;
      }
      return true;
    }

    /** True when `[from, to)` holds any token that is not a connector. */
    function hasInteriorText(toks, from, to) {
      for (var k = from; k < to; k++) {
        if (!CONNECTORS.has(toks[k])) return true;
      }
      return false;
    }

    /**
     * Label for a split-anchor join: every original token except the anchor
     * `[aStart, aEnd)`, the clock `[cStart, cEnd)`, and the connector(s) directly
     * introducing the clock (e.g. the `at` in `at 8pm`), original order
     * preserved. Mirrors `splitLabel` in clients/core/src/time.ts.
     */
    function splitLabel(raw, toks, aStart, aEnd, cStart, cEnd) {
      var clockStart = cStart;
      while (clockStart > aEnd && CONNECTORS.has(toks[clockStart - 1])) clockStart--;
      var kept = [];
      for (var k = 0; k < raw.length; k++) {
        if (k >= aStart && k < aEnd) continue;
        if (k >= clockStart && k < cEnd) continue;
        kept.push(raw[k]);
      }
      return kept.join(" ");
    }

    /**
     * Stage 3 split-anchor fallback (spec §5.4). When the ladder selected an
     * unanchored clock/period but a recurrence or absolute-date anchor is stranded
     * in the label, join the anchor to the trailing clock and make the intervening
     * tokens part of the label, preserving order. This recovers
     * `dance practice every tuesday in the gym at 8pm` as `every tuesday` + `8pm`
     * with label `dance practice in the gym`. Returns `null` when no split applies.
     *
     * A bare integer is never joined here (§5.4 clock priority: bare is lowest and
     * only ever a clock as the whole expression), and the anchor must be separated
     * from the clock by interior label text — an anchor already adjacent to its
     * clock was consumed by stages 1–2 and is left to them. Mirrors
     * `findSplitAnchor` in clients/core/src/time.ts.
     */
    function findSplitAnchor(raw, toks, now) {
      // The clock stages 1–2 would select: the trailing clock/period.
      var c = -1;
      var clock = null;
      for (var k = 0; k < toks.length; k++) {
        var candidate = parseClock(toks, k) ?? parseDayPeriod(toks, k);
        if (candidate && candidate.next === toks.length && !candidate.bare) {
          c = k;
          clock = candidate;
          break;
        }
      }
      if (!clock) return null;

      // A recurrence anchor before the clock, separated by interior label text.
      for (var a = 0; a < c; a++) {
        var recurrence = matchRecurrencePrefix(toks, a);
        if (recurrence && recurrence.next < c && hasInteriorText(toks, recurrence.next, c)) {
          var joined = toks.slice(a, recurrence.next).concat(toks.slice(c, clock.next));
          var parsed = tryParseExpression(joined, now, false);
          if (parsed) {
            return { parsed: parsed, rest: splitLabel(raw, toks, a, recurrence.next, c, clock.next) };
          }
        }
      }

      // An absolute-date anchor before the clock, separated by interior label text.
      for (var a2 = 0; a2 < c; a2++) {
        var date = parseAbsoluteDate(toks, a2);
        if (date && date.next < c && hasInteriorText(toks, date.next, c)) {
          var joined2 = toks.slice(a2, date.next).concat(toks.slice(c, clock.next));
          var parsed2 = tryParseExpression(joined2, now, false);
          if (parsed2) {
            return { parsed: parsed2, rest: splitLabel(raw, toks, a2, date.next, c, clock.next) };
          }
        }
      }

      return null;
    }

    /**
     * Run a speculative parse probe, swallowing an `already_passed` refusal so
     * the caller can keep searching for a valid expression elsewhere in the
     * input. Only exploratory probes (shorter prefixes, the span search) use
     * this; the confident whole-input parse raises `already_passed` directly
     * (spec §10). Mirrors `speculative` in clients/core/src/time.ts.
     */
    function speculative(probe) {
      try {
        return probe();
      } catch (err) {
        if (err instanceof TimeParseError && err.reason === "already_passed") return null;
        throw err;
      }
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
      var inputRaw = input.trim().split(/\s+/).filter(Boolean);
      if (inputRaw.length === 0) return null;

      var inputToks = inputRaw.map(function (t) {
        return t.toLowerCase();
      });
      var metadata = extractMetadata(inputRaw, inputToks);
      var raw = metadata.raw;
      var toks = metadata.toks;

      // The confident whole-input parse. A passed `this <weekday>` / `this
      // weekend` here is a hard `already_passed` refusal the caller wants to
      // surface, so this throw is deliberately NOT swallowed (spec §10). Only the
      // whole input may carry a bare-integer clock.
      var whole = tryParseExpression(toks, nowDate, true);
      if (whole) {
        if (metadata.alarm) whole.alarm = metadata.alarm;
        return { parsed: whole, rest: "" };
      }

      // Speculative prefix probing: shorter prefixes are slices, so a passed
      // `this <weekday>` inside a longer phrase must not abort the search.
      // Swallow `already_passed` and keep looking, so the documented null
      // contract holds and a valid shorter prefix still wins. Shorter prefixes
      // never carry a bare-integer clock, where a bare integer would swallow part
      // of the label.
      for (var end = toks.length - 1; end >= 1; end--) {
        var parsed = speculative(function () {
          return tryParseExpression(toks.slice(0, end), nowDate, false);
        });
        if (parsed) {
          if (metadata.alarm) parsed.alarm = metadata.alarm;
          return { parsed: parsed, rest: raw.slice(end).join(" ") };
        }
      }

      // An `every` the grammar cannot read must not fall through to a bare
      // weekday (spec §5.3/§10): fail loudly by resolving nothing.
      if (hasOrphanEvery(toks)) return null;

      // No leading time prefix: fall back to a span anywhere in the input. This
      // too is speculative, so `already_passed` is swallowed here as well.
      var span = findTimeSpan(raw, toks, nowDate);
      if (span) {
        // Stage 3 (spec §5.4): when the span selected an unanchored clock/period
        // but a recurrence/date anchor is stranded in the label, the joined anchor
        // wins.
        if (spanIsUnanchored(toks, span.start, span.end)) {
          var split = findSplitAnchor(raw, toks, nowDate);
          if (split) {
            if (metadata.alarm) split.parsed.alarm = metadata.alarm;
            return split;
          }
        }
        if (metadata.alarm) span.parsed.alarm = metadata.alarm;
        return { parsed: span.parsed, rest: span.rest };
      }

      // Stages 1–2 produced nothing: the literal stage-3 fallback still applies.
      var split2 = findSplitAnchor(raw, toks, nowDate);
      if (split2 && metadata.alarm) split2.parsed.alarm = metadata.alarm;
      return split2;
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
