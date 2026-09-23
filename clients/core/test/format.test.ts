import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  toLocalDate,
  formatClock,
  formatDate,
  formatLocal,
  formatRelative,
  formatAlarm,
  formatInterpretation,
  formatMissedReason,
  formatStatus,
} from "../src/index.js";
import type { Alarm, AlarmStatus, MissedReason } from "../src/index.js";

function at(y: number, mo: number, d: number, h: number, mi: number): Date {
  return new Date(y, mo - 1, d, h, mi, 0, 0);
}

function alarmAt(local: Date): Alarm {
  return {
    id: "a1",
    target_time: local.toISOString(),
    label: "Standup",
    status: "pending",
  };
}

describe("toLocalDate", () => {
  it("derives the local wall clock from the raw UTC string", () => {
    const local = at(2026, 9, 22, 7, 30);
    const derived = toLocalDate(alarmAt(local));
    assert.equal(derived.getFullYear(), 2026);
    assert.equal(derived.getMonth() + 1, 9);
    assert.equal(derived.getDate(), 22);
    assert.equal(derived.getHours(), 7);
    assert.equal(derived.getMinutes(), 30);
    assert.equal(derived.getTime(), local.getTime());
  });
});

describe("formatClock", () => {
  const cases: Array<[Date, string]> = [
    [at(2026, 9, 22, 7, 0), "7:00am"],
    [at(2026, 9, 22, 0, 0), "12:00am"],
    [at(2026, 9, 22, 12, 0), "12:00pm"],
    [at(2026, 9, 22, 19, 5), "7:05pm"],
    [at(2026, 9, 22, 13, 45), "1:45pm"],
    [at(2026, 9, 22, 23, 59), "11:59pm"],
  ];
  for (const [date, expected] of cases) {
    it(`formats ${date.getHours()}:${date.getMinutes()} as ${expected}`, () => {
      assert.equal(formatClock(date), expected);
    });
  }
});

describe("formatDate / formatLocal", () => {
  it("formats a short weekday and month", () => {
    assert.equal(formatDate(at(2026, 9, 22, 7, 0)), "Tue 22 Sep");
    assert.equal(formatLocal(at(2026, 9, 22, 7, 0)), "Tue 22 Sep, 7:00am");
  });
});

describe("formatRelative", () => {
  it("formats the spec example", () => {
    assert.equal(formatRelative(at(2026, 9, 21, 17, 20), at(2026, 9, 22, 7, 0)), "in 13h 40m");
  });

  it("formats minutes only", () => {
    assert.equal(formatRelative(at(2026, 9, 21, 10, 0), at(2026, 9, 21, 10, 25)), "in 25m");
  });

  it("formats zero as under a minute", () => {
    assert.equal(
      formatRelative(at(2026, 9, 21, 10, 0), at(2026, 9, 21, 10, 0)),
      "in less than a minute"
    );
  });

  it("formats days and hours", () => {
    assert.equal(formatRelative(at(2026, 9, 21, 10, 0), at(2026, 9, 23, 13, 0)), "in 2d 3h");
  });

  it("formats the past with an 'ago' suffix", () => {
    assert.equal(formatRelative(at(2026, 9, 21, 10, 0), at(2026, 9, 21, 9, 0)), "1h ago");
  });
});

describe("formatAlarm / formatInterpretation", () => {
  it("renders an alarm in local time", () => {
    assert.equal(formatAlarm(alarmAt(at(2026, 9, 22, 7, 30))), "Tue 22 Sep, 7:30am");
  });

  it("combines the local echo with the relative offset", () => {
    const now = at(2026, 9, 21, 17, 20);
    const target = at(2026, 9, 22, 7, 0);
    assert.equal(formatInterpretation(target, now), "Tue 22 Sep, 7:00am (in 13h 40m)");
  });
});

describe("formatMissedReason", () => {
  it("labels every known reason readably", () => {
    const everyReason: MissedReason[] = [
      "no_device_registered",
      "delivery_failed",
      "dispatched_not_reported",
      "device_reported_stale",
      "device_reported_failed",
      "unknown",
    ];
    for (const reason of everyReason) {
      assert.equal(typeof formatMissedReason(reason), "string");
      assert.ok(formatMissedReason(reason).length > 0, `${reason} has no label`);
    }
  });

  it("does not claim delivery for dispatched_not_reported", () => {
    const text = formatMissedReason("dispatched_not_reported");
    assert.match(text, /sent/);
    assert.match(text, /never reported/);
    assert.doesNotMatch(text, /received|delivered/i);
  });

  it("falls back to the raw token for an unrecognised value", () => {
    assert.equal(
      formatMissedReason("something_a_newer_backend_added"),
      "unrecognised reason (something_a_newer_backend_added)"
    );
  });
});

describe("formatStatus", () => {
  it("labels every status, so a future one cannot render as a raw token", () => {
    const everyStatus: AlarmStatus[] = [
      "pending",
      "ringing",
      "dismissed",
      "snoozed",
      "canceled",
      "disabled",
      "missed",
    ];
    for (const status of everyStatus) {
      assert.equal(typeof formatStatus(status), "string");
      assert.ok(formatStatus(status).length > 0, `${status} has no label`);
    }
  });

  it("adds 'missed' without restyling the statuses that already existed", () => {
    // Lower case on purpose: this is the CLI's established register, and
    // adding a status must not change how the others read.
    assert.equal(formatStatus("missed"), "missed");
    assert.equal(formatStatus("pending"), "pending");
    assert.equal(formatStatus("ringing"), "ringing");
    assert.equal(formatStatus("dismissed"), "dismissed");
    assert.equal(formatStatus("snoozed"), "snoozed");
    assert.equal(formatStatus("canceled"), "canceled");
    assert.equal(formatStatus("disabled"), "disabled");
  });
});
