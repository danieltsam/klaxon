import { describe, it } from 'node:test';
import assert from 'node:assert';
import { rollTargetTimeToFuture } from '../src/server.js';

describe('rollTargetTimeToFuture Unit Tests', () => {
  it('should return future target time as-is if already in future', () => {
    const mockNow = new Date('2026-09-19T01:00:00.000Z');
    const futureTime = '2026-09-19T05:48:00.000Z'; // 4 hours in the future
    const result = rollTargetTimeToFuture(futureTime, null, mockNow);
    assert.strictEqual(result, futureTime);
  });

  it('should roll a past one-time alarm to today if the time is later today', () => {
    // Current time: 10:00 UTC
    const mockNow = new Date('2026-09-19T10:00:00.000Z');
    // Stale alarm from yesterday at 15:00 UTC
    const yesterdayAlarm = '2026-09-18T15:00:00.000Z';
    const result = rollTargetTimeToFuture(yesterdayAlarm, null, mockNow);
    // Should roll to TODAY at 15:00 UTC
    assert.strictEqual(result, '2026-09-19T15:00:00.000Z');
  });

  it('should roll a past one-time alarm to tomorrow if the time already passed today', () => {
    // Current time: 16:00 UTC
    const mockNow = new Date('2026-09-19T16:00:00.000Z');
    // Stale alarm from yesterday at 15:00 UTC (15:00 has already passed today at 16:00)
    const yesterdayAlarm = '2026-09-18T15:00:00.000Z';
    const result = rollTargetTimeToFuture(yesterdayAlarm, null, mockNow);
    // Should roll to TOMORROW at 15:00 UTC
    assert.strictEqual(result, '2026-09-20T15:00:00.000Z');
  });

  it('should roll a recurring alarm to the next scheduled weekday', () => {
    // 2026-09-19 is a Saturday
    const saturdayNow = new Date('2026-09-19T10:00:00.000Z');
    // Alarm set for 07:00 UTC Mon-Fri (1,2,3,4,5)
    const oldAlarm = '2026-09-18T07:00:00.000Z';
    const result = rollTargetTimeToFuture(oldAlarm, '1,2,3,4,5', saturdayNow);
    // Next weekday after Saturday is Monday: 2026-09-21
    const rolledDate = new Date(result);
    assert.strictEqual(rolledDate.getUTCDay(), 1); // 1 = Monday
    assert.strictEqual(rolledDate.getUTCHours(), 7);
    assert.strictEqual(rolledDate.getUTCMinutes(), 0);
  });
});
