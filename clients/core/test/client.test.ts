import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  normalizeAlarm,
  RemoteAlarmClient,
  RemoteAlarmError,
  RemoteAlarmNetworkError,
  RemoteAlarmNotFoundError,
} from "../src/index.js";
import type { CreateAlarmInput, FetchLike } from "../src/index.js";

interface Call {
  url: string;
  init: RequestInit;
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function recordingFetch(response: Response | (() => Response)): {
  fn: FetchLike;
  calls: Call[];
} {
  const calls: Call[] = [];
  const fn = (async (input: unknown, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return typeof response === "function" ? response() : response;
  }) as unknown as FetchLike;
  return { fn, calls };
}

function aligned(date: Date): string {
  const d = new Date(date.getTime());
  d.setSeconds(0, 0);
  return d.toISOString();
}

describe("RemoteAlarmClient — createAlarm normalization", () => {
  it("encodes repeat_days array to a comma-string and zeroes seconds/ms", async () => {
    const now = new Date(2026, 8, 21, 6, 0, 0, 0);
    const { fn, calls } = recordingFetch(
      jsonResponse(201, {
        id: "a1",
        target_time: "2026-09-21T07:30:00.000Z",
        label: "Standup",
        status: "pending",
        repeat_days: "1,2,3,4,5",
        description: null,
      })
    );
    const client = new RemoteAlarmClient({
      baseUrl: "http://localhost:3000/",
      fetch: fn,
      now: () => now,
    });

    const result = await client.createAlarm({
      label: "Standup",
      when: "7:30am",
      repeat_days: [1, 2, 3, 4, 5],
    });

    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "http://localhost:3000/api/alarms");
    assert.equal(calls[0].init.method, "POST");
    assert.deepEqual(calls[0].init.headers, { "Content-Type": "application/json" });

    const body = JSON.parse(calls[0].init.body as string);
    assert.equal(body.target_time, aligned(new Date(2026, 8, 21, 7, 30)));
    assert.equal(body.label, "Standup");
    assert.equal(body.repeat_days, "1,2,3,4,5");

    assert.deepEqual(result.alarm.repeat_days, [1, 2, 3, 4, 5]);
    assert.equal(result.alarm.description, undefined);
    assert.equal(result.dispatch, undefined);
  });

  it("zeroes seconds and milliseconds supplied by a duration", async () => {
    const now = new Date(2026, 8, 21, 17, 20, 45, 123);
    const { fn, calls } = recordingFetch(
      jsonResponse(201, { id: "a1", target_time: "x", label: "Oven", status: "pending" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn, now: () => now });

    await client.createAlarm({ label: "Oven", when: "25m" });

    const body = JSON.parse(calls[0].init.body as string);
    assert.equal(body.target_time, aligned(new Date(now.getTime() + 25 * 60 * 1000)));
    assert.match(body.target_time, /:00\.000Z$/);
  });

  it("derives repeat_days from a recurring time expression", async () => {
    const now = new Date(2026, 8, 21, 6, 0, 0, 0);
    const { fn, calls } = recordingFetch(
      jsonResponse(201, { id: "a1", target_time: "x", label: "Standup", status: "pending" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn, now: () => now });

    await client.createAlarm({ label: "Standup", when: "daily 7am" });

    const body = JSON.parse(calls[0].init.body as string);
    assert.equal(body.repeat_days, "1,2,3,4,5,6,7");
  });

  it("omits repeat_days for a one-time alarm", async () => {
    const now = new Date(2026, 8, 21, 6, 0, 0, 0);
    const { fn, calls } = recordingFetch(
      jsonResponse(201, { id: "a1", target_time: "x", label: "Once", status: "pending" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn, now: () => now });

    await client.createAlarm({ label: "Once", when: "7am" });

    const body = JSON.parse(calls[0].init.body as string);
    assert.equal("repeat_days" in body, false);
  });

  it("rejects an invalid sound_tone client-side without sending a request", async () => {
    const { fn, calls } = recordingFetch(
      jsonResponse(201, { id: "a1", target_time: "x", label: "x", status: "pending" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });

    await assert.rejects(
      client.createAlarm({ label: "x", when: "7am", sound_tone: "bogus" as never }),
      (err: unknown) => {
        assert.ok(err instanceof RemoteAlarmError);
        assert.match(err.message, /Invalid sound_tone/);
        return true;
      }
    );
    assert.equal(calls.length, 0);
  });
});

describe("RemoteAlarmClient — createAlarm absolute targetTime", () => {
  it("sends targetTime as a UTC ISO whose local re-derivation equals the input", async () => {
    const input = new Date(2026, 8, 22, 7, 30, 45, 123);
    const { fn, calls } = recordingFetch(
      jsonResponse(201, { id: "a1", target_time: "x", label: "Form", status: "pending" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });

    await client.createAlarm({ label: "Form", targetTime: input });

    const body = JSON.parse(calls[0].init.body as string);
    // Same single conversion point as parsed times: local instant -> UTC ISO.
    assert.equal(body.target_time, aligned(input));

    const reDerived = new Date(body.target_time);
    assert.equal(reDerived.getFullYear(), input.getFullYear());
    assert.equal(reDerived.getMonth(), input.getMonth());
    assert.equal(reDerived.getDate(), input.getDate());
    assert.equal(reDerived.getHours(), input.getHours());
    assert.equal(reDerived.getMinutes(), input.getMinutes());
    assert.equal(reDerived.getSeconds(), 0);
    assert.equal(reDerived.getMilliseconds(), 0);
  });

  it("zeroes seconds and milliseconds on targetTime", async () => {
    const input = new Date(2026, 8, 22, 7, 30, 59, 999);
    const { fn, calls } = recordingFetch(
      jsonResponse(201, { id: "a1", target_time: "x", label: "Form", status: "pending" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });

    await client.createAlarm({ label: "Form", targetTime: input });

    const body = JSON.parse(calls[0].init.body as string);
    assert.equal(body.target_time, aligned(input));
    assert.match(body.target_time, /:30:00\.000Z$/);
    assert.equal(new Date(body.target_time).getSeconds(), 0);
    assert.equal(new Date(body.target_time).getMilliseconds(), 0);
    assert.equal("when" in body, false);
  });

  it("encodes repeat_days as a comma-string alongside targetTime", async () => {
    const input = new Date(2026, 8, 22, 7, 30, 0, 0);
    const { fn, calls } = recordingFetch(
      jsonResponse(201, { id: "a1", target_time: "x", label: "Form", status: "pending" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });

    await client.createAlarm({ label: "Form", targetTime: input, repeat_days: [1, 2, 3, 4, 5] });

    const body = JSON.parse(calls[0].init.body as string);
    assert.equal(body.target_time, aligned(input));
    assert.equal(body.repeat_days, "1,2,3,4,5");
  });

  it("accepts targetTime on updateAlarm and zeroes it", async () => {
    const input = new Date(2026, 8, 22, 7, 30, 45, 123);
    const { fn, calls } = recordingFetch(
      jsonResponse(200, { id: "x", target_time: "x", label: "Form", status: "pending" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });

    await client.updateAlarm("x", { targetTime: input });

    const body = JSON.parse(calls[0].init.body as string);
    assert.equal(calls[0].init.method, "PATCH");
    assert.equal(body.target_time, aligned(input));
    assert.equal("when" in body, false);
  });

  it("rejects when both when and targetTime are supplied to updateAlarm", async () => {
    const { fn, calls } = recordingFetch(
      jsonResponse(200, { id: "x", target_time: "x", label: "Form", status: "pending" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });

    await assert.rejects(
      client.updateAlarm("x", {
        when: "7am",
        targetTime: new Date(2026, 8, 22, 7, 30),
        label: "Form",
      }),
      (err: unknown) => {
        assert.ok(err instanceof RemoteAlarmError);
        assert.match(err.message, /at most one/i);
        return true;
      }
    );
    assert.equal(calls.length, 0);
  });

  it("rejects both supplied to createAlarm at runtime (type bypassed)", async () => {
    const { fn, calls } = recordingFetch(
      jsonResponse(201, { id: "a1", target_time: "x", label: "Form", status: "pending" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });

    await assert.rejects(
      client.createAlarm({
        label: "Form",
        when: "7am",
        targetTime: new Date(2026, 8, 22, 7, 30),
      } as unknown as CreateAlarmInput),
      (err: unknown) => {
        assert.ok(err instanceof RemoteAlarmError);
        assert.match(err.message, /exactly one/i);
        return true;
      }
    );
    assert.equal(calls.length, 0);
  });
});

describe("RemoteAlarmClient — responses and dispatch", () => {
  it("decodes a comma-string repeat_days and nulls into undefined", async () => {
    const { fn, calls } = recordingFetch(
      jsonResponse(200, [
        {
          id: "a1",
          target_time: "2026-09-22T07:00:00.000Z",
          label: "L",
          status: "pending",
          repeat_days: "1,3,7",
          description: null,
          sound_tone: null,
          ramp_seconds: null,
          created_at: null,
        },
      ])
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000/", fetch: fn });

    const alarms = await client.listAlarms("history");

    assert.equal(calls[0].url, "http://h:3000/api/alarms?view=history");
    assert.equal(calls[0].init.method, "GET");
    assert.equal(calls[0].init.body, undefined);
    assert.equal(alarms.length, 1);
    assert.deepEqual(alarms[0].repeat_days, [1, 3, 7]);
    assert.equal(alarms[0].description, undefined);
    assert.equal(alarms[0].sound_tone, undefined);
    assert.equal(alarms[0].ramp_seconds, undefined);
    assert.equal(alarms[0].created_at, undefined);
  });

  it("coerces explicit null missed_at and missed_reason to undefined", async () => {
    const { fn } = recordingFetch(
      jsonResponse(200, [
        {
          id: "a1",
          target_time: "2026-09-22T07:00:00.000Z",
          label: "L",
          status: "missed",
          missed_at: null,
          missed_reason: null,
        },
      ])
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000/", fetch: fn });

    const alarms = await client.listAlarms("all");

    assert.equal(alarms[0].missed_at, undefined);
    assert.equal(alarms[0].missed_reason, undefined);
    // `null` must not leak into the domain type as an own property.
    assert.equal("missed_at" in alarms[0], false);
    assert.equal("missed_reason" in alarms[0], false);
  });

  it("round-trips missed_at and missed_reason on a complete alarm", async () => {
    const { fn } = recordingFetch(
      jsonResponse(200, [
        {
          id: "a1",
          target_time: "2026-09-21T20:15:00.000Z",
          label: "Church",
          status: "missed",
          missed_at: "2026-09-21T20:20:00.000Z",
          missed_reason: "dispatched_not_reported",
        },
      ])
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000/", fetch: fn });

    const alarms = await client.listAlarms("all");

    assert.equal(alarms[0].missed_at, "2026-09-21T20:20:00.000Z");
    assert.equal(alarms[0].missed_reason, "dispatched_not_reported");
  });

  it("leaves an alarm with no missed fields unchanged", async () => {
    const { fn } = recordingFetch(
      jsonResponse(200, [
        {
          id: "a1",
          target_time: "2026-09-22T07:00:00.000Z",
          label: "L",
          status: "pending",
        },
      ])
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000/", fetch: fn });

    const alarms = await client.listAlarms();

    assert.deepEqual(alarms[0], {
      id: "a1",
      target_time: "2026-09-22T07:00:00.000Z",
      label: "L",
      status: "pending",
    });
  });

  it("discards out-of-range repeat_days entries", async () => {
    const { fn } = recordingFetch(
      jsonResponse(200, [
        { id: "a1", target_time: "x", label: "L", status: "pending", repeat_days: "0,1,8,3,9" },
      ])
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    const alarms = await client.listAlarms();
    assert.deepEqual(alarms[0].repeat_days, [1, 3]);
  });

  it("defaults listAlarms to the active view", async () => {
    const { fn, calls } = recordingFetch(jsonResponse(200, []));
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    const alarms = await client.listAlarms();
    assert.deepEqual(alarms, []);
    assert.equal(calls[0].url, "http://h:3000/api/alarms?view=active");
  });

  it("carries fcm_dispatch as a separate field, never a success boolean", async () => {
    const { fn } = recordingFetch(
      jsonResponse(201, {
        id: "a1",
        target_time: "x",
        label: "L",
        status: "pending",
        fcm_dispatch: { sent: 2, failed: 1 },
      })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    const result = await client.createAlarm({ label: "L", when: "7am" });
    assert.deepEqual(result.dispatch, { sent: 2, failed: 1 });
    assert.equal((result as Record<string, unknown>).success, undefined);
  });

  it("treats a missing fcm_dispatch as 'no dispatch report', not failure", async () => {
    const { fn } = recordingFetch(
      jsonResponse(200, { success: true, id: "a1", status: "dismissed" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    const result = await client.silenceAlarm("a1");
    assert.equal(result.alarm.status, "dismissed");
    assert.equal(result.dispatch, undefined);
  });

  it("extracts the devices array from the wrapped device response", async () => {
    const { fn, calls } = recordingFetch(
      jsonResponse(200, {
        count: 1,
        tokens: ["abc...xyz"],
        devices: [
          {
            token_masked: "abc...xyz",
            device_name: "Pixel",
            battery_level: 84,
            is_charging: true,
            updated_at: "2026-09-21 17:00:00",
          },
        ],
      })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    const devices = await client.listDevices();

    assert.equal(calls[0].url, "http://h:3000/api/devices");
    assert.equal(devices.length, 1);
    assert.equal(devices[0].device_name, "Pixel");
    assert.equal(devices[0].battery_level, 84);
    assert.equal(devices[0].is_charging, true);
    assert.equal(devices[0].updated_at, "2026-09-21 17:00:00");
  });

  it("returns settings verbatim", async () => {
    const settings = {
      sound_tone: "chime",
      ramp_seconds: 15,
      date_format: "yyyy-mm-dd",
      time_format: "24h",
    };
    const { fn, calls } = recordingFetch(jsonResponse(200, settings));
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    const result = await client.getSettings();
    assert.deepEqual(result, settings);
    assert.equal(calls[0].url, "http://h:3000/api/settings");
  });

  it("hits /api/health", async () => {
    const { fn, calls } = recordingFetch(
      jsonResponse(200, { status: "ok", timestamp: "2026-09-21T00:00:00.000Z" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    const health = await client.health();
    assert.equal(health.status, "ok");
    assert.equal(calls[0].url, "http://h:3000/api/health");
  });
});

describe("RemoteAlarmClient — write endpoints", () => {
  it("PATCHes an update with encoded fields", async () => {
    const now = new Date(2026, 8, 21, 10, 0, 0, 0);
    const { fn, calls } = recordingFetch(
      jsonResponse(200, {
        id: "id 1",
        target_time: "2026-09-22T18:00:00.000Z",
        label: "New",
        status: "disabled",
        repeat_days: "5,6",
      })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn, now: () => now });

    await client.updateAlarm("id 1", {
      label: "New",
      when: "tomorrow 6pm",
      repeat_days: [5, 6],
      sound_tone: "chime",
      ramp_seconds: 15,
      status: "disabled",
    });

    assert.equal(calls[0].url, "http://h:3000/api/alarms/id%201");
    assert.equal(calls[0].init.method, "PATCH");
    const body = JSON.parse(calls[0].init.body as string);
    assert.equal(body.target_time, aligned(new Date(2026, 8, 22, 18, 0)));
    assert.equal(body.repeat_days, "5,6");
    assert.equal(body.sound_tone, "chime");
    assert.equal(body.ramp_seconds, 15);
    assert.equal(body.status, "disabled");
  });

  it("DELETEs on cancel", async () => {
    const { fn, calls } = recordingFetch(
      jsonResponse(200, { success: true, id: "x", status: "canceled", fcm_dispatch: { sent: 1, failed: 0 } })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    const result = await client.cancelAlarm("x");
    assert.equal(calls[0].url, "http://h:3000/api/alarms/x");
    assert.equal(calls[0].init.method, "DELETE");
    assert.equal(result.alarm.status, "canceled");
    assert.deepEqual(result.dispatch, { sent: 1, failed: 0 });
  });

  it("POSTs to silence", async () => {
    const { fn, calls } = recordingFetch(
      jsonResponse(200, { success: true, id: "x", status: "dismissed" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    await client.silenceAlarm("x");
    assert.equal(calls[0].url, "http://h:3000/api/alarms/x/silence");
    assert.equal(calls[0].init.method, "POST");
  });

  it("POSTs state with an aligned target_time", async () => {
    const { fn, calls } = recordingFetch(
      jsonResponse(200, { success: true, id: "x", status: "snoozed", target_time: "2026-09-21T17:45:00.000Z" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    await client.setState("x", "snoozed", new Date("2026-09-21T17:45:45.123Z"));

    assert.equal(calls[0].url, "http://h:3000/api/alarms/x/state");
    assert.equal(calls[0].init.method, "POST");
    const body = JSON.parse(calls[0].init.body as string);
    assert.equal(body.status, "snoozed");
    assert.equal(body.target_time, "2026-09-21T17:45:00.000Z");
  });

  it("POSTs state without a target_time when omitted", async () => {
    const { fn, calls } = recordingFetch(
      jsonResponse(200, { success: true, id: "x", status: "disabled" })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    await client.setState("x", "disabled");
    const body = JSON.parse(calls[0].init.body as string);
    assert.equal("target_time" in body, false);
  });
});

describe("RemoteAlarmClient — baseUrl normalization", () => {
  it("strips trailing slashes once at construction", async () => {
    const { fn, calls } = recordingFetch(jsonResponse(200, { status: "ok", timestamp: "t" }));
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000///", fetch: fn });
    await client.health();
    assert.equal(calls[0].url, "http://h:3000/api/health");
  });
});

describe("RemoteAlarmClient — error mapping", () => {
  it("maps 400 to RemoteAlarmError with the server message preserved", async () => {
    const serverMessage =
      "Missing required fields: target_time and label are required.";
    const { fn } = recordingFetch(jsonResponse(400, { error: serverMessage }));
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });

    await assert.rejects(
      client.createAlarm({ label: "x", when: "7am" }),
      (err: unknown) => {
        assert.ok(err instanceof RemoteAlarmError);
        assert.equal(err instanceof RemoteAlarmNotFoundError, false);
        assert.equal(err.status, 400);
        assert.equal(err.serverMessage, serverMessage);
        assert.equal(err.message, serverMessage);
        return true;
      }
    );
  });

  it("maps unknown-alarm 404 to RemoteAlarmNotFoundError", async () => {
    const { fn } = recordingFetch(jsonResponse(404, { error: "Alarm not found" }));
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });

    await assert.rejects(client.cancelAlarm("nope"), (err: unknown) => {
      assert.ok(err instanceof RemoteAlarmNotFoundError);
      assert.equal(err.status, 404);
      assert.equal(err.serverMessage, "Alarm not found");
      assert.equal(err.message, "Alarm not found");
      return true;
    });
  });

  it("maps an unmatched-route 404 (Fastify default shape) to RemoteAlarmNotFoundError", async () => {
    const { fn } = recordingFetch(
      jsonResponse(404, {
        message: "Route GET:/api/nope not found",
        error: "Not Found",
        statusCode: 404,
      })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    await assert.rejects(client.health(), (err: unknown) => {
      assert.ok(err instanceof RemoteAlarmNotFoundError);
      assert.equal(err.status, 404);
      // `body.error` is preferred over `body.message` when both exist.
      assert.equal(err.serverMessage, "Not Found");
      assert.equal(err.message, "Not Found");
      return true;
    });
  });

  it("falls back to body.message when body.error is absent", async () => {
    const { fn } = recordingFetch(
      jsonResponse(404, { message: "Route GET:/x not found", statusCode: 404 })
    );
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    await assert.rejects(client.health(), (err: unknown) => {
      assert.ok(err instanceof RemoteAlarmNotFoundError);
      assert.equal(err.message, "Route GET:/x not found");
      return true;
    });
  });

  it("maps a transport failure to RemoteAlarmNetworkError", async () => {
    const fn = (() => Promise.reject(new Error("ECONNREFUSED 127.0.0.1:3000"))) as unknown as FetchLike;
    const client = new RemoteAlarmClient({ baseUrl: "http://h:3000", fetch: fn });
    await assert.rejects(client.health(), (err: unknown) => {
      assert.ok(err instanceof RemoteAlarmNetworkError);
      assert.match(err.message, /ECONNREFUSED/);
      return true;
    });
  });
});

describe("RemoteAlarmClient — timeout wiring", () => {
  it("passes an AbortSignal and honours a configured timeout", async () => {
    const fn = ((_input: unknown, init?: RequestInit) =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(init.signal?.reason));
      })) as unknown as FetchLike;
    const client = new RemoteAlarmClient({
      baseUrl: "http://h:3000",
      fetch: fn,
      timeouts: { health: 5 },
    });

    const start = Date.now();
    await assert.rejects(client.health(), RemoteAlarmNetworkError);
    assert.ok(Date.now() - start < 1000, "override should abort quickly, not at the 4s default");
  });
});

describe("RemoteAlarmClient — parsed interval and metadata carriage", () => {
  const now = new Date(2026, 8, 21, 6, 0, 0, 0);
  const make = (calls: Call[]) => {
    void calls;
    return new RemoteAlarmClient({
      baseUrl: "http://h:3000",
      fetch: ((input: unknown, init?: RequestInit) => {
        calls.push({ url: String(input), init: init ?? {} });
        return Promise.resolve(
          jsonResponse(201, { id: "a1", target_time: "x", label: "Gym", status: "pending" })
        );
      }) as unknown as FetchLike,
      now: () => now,
    });
  };

  it("sends a parsed fortnightly interval instead of dropping it", async () => {
    const calls: Call[] = [];
    await make(calls).createAlarm({ label: "Gym", when: "every 2 weeks 7am" });

    const body = JSON.parse(calls[0].init.body as string);
    assert.equal(body.recurrence_interval_weeks, 2);
  });

  it("keeps the weekday set of a fortnightly weekday rule", async () => {
    const calls: Call[] = [];
    await make(calls).createAlarm({ label: "Gym", when: "every other monday 7am" });

    const body = JSON.parse(calls[0].init.body as string);
    assert.equal(body.recurrence_interval_weeks, 2);
    assert.equal(body.repeat_days, "1");
  });

  it("refuses a day interval the backend cannot store, without sending", async () => {
    const calls: Call[] = [];
    await assert.rejects(
      make(calls).createAlarm({ label: "Gym", when: "every 3 days 7am" }),
      (err: unknown) => {
        assert.ok(err instanceof RemoteAlarmError);
        assert.match(err.message, /only weekly or fortnightly/);
        return true;
      }
    );
    assert.equal(calls.length, 0);
  });

  it("lets an explicit interval override the sentence", async () => {
    const calls: Call[] = [];
    await make(calls).createAlarm({
      label: "Gym",
      when: "every 2 weeks 7am",
      recurrence_interval_weeks: 1,
    });

    const body = JSON.parse(calls[0].init.body as string);
    assert.equal("recurrence_interval_weeks" in body, false);
  });

  it("carries a parsed tone and note, and lets explicit fields win", async () => {
    const calls: Call[] = [];
    const client = make(calls);

    await client.createAlarm({ label: "Gym", when: "chime tomorrow 7am" });
    assert.equal(JSON.parse(calls[0].init.body as string).sound_tone, "chime");

    await client.createAlarm({ label: "Gym", when: "tomorrow 7am note: bring towel" });
    assert.equal(
      JSON.parse(calls[1].init.body as string).description,
      "bring towel"
    );

    await client.createAlarm({
      label: "Gym",
      when: "chime tomorrow 7am",
      sound_tone: "alarm",
    });
    assert.equal(JSON.parse(calls[2].init.body as string).sound_tone, "alarm");
  });

  it("reads interval fields back from the wire", () => {
    const alarm = normalizeAlarm({
      id: "a",
      target_time: "2026-10-27T20:30:00.000Z",
      label: "Gym",
      status: "pending",
      recurrence_interval_weeks: "2",
      recurrence_anchor_date: null,
    });

    assert.equal(alarm.recurrence_interval_weeks, 2);
    assert.equal(alarm.recurrence_anchor_date, null);
  });
});

describe("RemoteAlarmClient — interval on update", () => {
  it("sends recurrence_interval_weeks on PATCH and leaves it alone when omitted", async () => {
    const calls: Call[] = [];
    const client = new RemoteAlarmClient({
      baseUrl: "http://h:3000",
      fetch: ((input: unknown, init?: RequestInit) => {
        calls.push({ url: String(input), init: init ?? {} });
        return Promise.resolve(
          jsonResponse(200, { id: "a1", target_time: "x", label: "Gym", status: "pending" })
        );
      }) as unknown as FetchLike,
    });

    await client.updateAlarm("a1", { label: "Gym", recurrence_interval_weeks: 2 });
    assert.equal(JSON.parse(calls[0].init.body as string).recurrence_interval_weeks, 2);

    await client.updateAlarm("a1", { label: "Gym" });
    assert.equal("recurrence_interval_weeks" in JSON.parse(calls[1].init.body as string), false);
  });
});

describe("RemoteAlarmClient — backend URL normalisation", () => {
  it("assumes http for a bare host and port", async () => {
    const calls: Call[] = [];
    const client = new RemoteAlarmClient({
      baseUrl: "baymax:8001",
      fetch: ((input: unknown, init?: RequestInit) => {
        calls.push({ url: String(input), init: init ?? {} });
        return Promise.resolve(jsonResponse(200, { status: "ok", timestamp: "x" }));
      }) as unknown as FetchLike,
    });

    await client.health();
    assert.equal(calls[0].url, "http://baymax:8001/api/health");
  });

  it("keeps an explicit https scheme and strips trailing slashes", async () => {
    const calls: Call[] = [];
    const client = new RemoteAlarmClient({
      baseUrl: "  https://klaxon.example:8443/  ",
      fetch: ((input: unknown, init?: RequestInit) => {
        calls.push({ url: String(input), init: init ?? {} });
        return Promise.resolve(jsonResponse(200, { status: "ok", timestamp: "x" }));
      }) as unknown as FetchLike,
    });

    await client.health();
    assert.equal(calls[0].url, "https://klaxon.example:8443/api/health");
  });

  it("refuses an empty URL and a scheme the client cannot speak", () => {
    assert.throws(() => new RemoteAlarmClient({ baseUrl: "   " }), RemoteAlarmError);
    assert.throws(
      () => new RemoteAlarmClient({ baseUrl: "ftp://host:21" }),
      /only http and https/
    );
  });
});

describe("RemoteAlarmClient — parsed fields on update", () => {
  it("carries an interval and metadata named in `when`", async () => {
    const calls: Call[] = [];
    const client = new RemoteAlarmClient({
      baseUrl: "http://h:3000",
      fetch: ((input: unknown, init?: RequestInit) => {
        calls.push({ url: String(input), init: init ?? {} });
        return Promise.resolve(
          jsonResponse(200, { id: "a1", target_time: "x", label: "Gym", status: "pending" })
        );
      }) as unknown as FetchLike,
    });

    await client.updateAlarm("a1", { when: "every 2 weeks 7am" });
    assert.equal(JSON.parse(calls[0].init.body as string).recurrence_interval_weeks, 2);

    await client.updateAlarm("a1", { when: "chime 7am" });
    assert.equal(JSON.parse(calls[1].init.body as string).sound_tone, "chime");
  });
});
