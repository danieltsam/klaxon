import { describe, it } from 'node:test';
import assert from 'node:assert';
import { isRecurring, stepOccurrence, firstOccurrenceAfter } from '../src/recurrence.js';

const BRISBANE = 600;

describe('skip arithmetic', () => {
  it('steps Friday to Monday on a weekday pattern, in Brisbane local time', () => {
    // Fri 30 Oct 2026, 09:00 Brisbane == Thu 29 Oct 23:00Z
    const friday = new Date('2026-10-29T23:00:00.000Z');
    const next = stepOccurrence(friday, { repeatDays: [1, 2, 3, 4, 5], intervalWeeks: 1 }, BRISBANE);
    assert.strictEqual(next.toISOString(), '2026-11-01T23:00:00.000Z'); // Mon 2 Nov 09:00 Brisbane
  });

  it('steps the same instant a day later when the offset is ignored', () => {
    const thursdayUtc = new Date('2026-10-29T23:00:00.000Z');
    const next = stepOccurrence(thursdayUtc, { repeatDays: [1, 2, 3, 4, 5], intervalWeeks: 1 }, 0);
    assert.strictEqual(next.toISOString(), '2026-10-30T23:00:00.000Z');
  });

  it('steps an interval pattern by 7 x interval days', () => {
    const base = new Date('2026-10-30T09:00:00.000Z');
    const next = stepOccurrence(base, { repeatDays: [5], intervalWeeks: 2 }, 0);
    assert.strictEqual(next.toISOString(), '2026-11-13T09:00:00.000Z');
  });

  it('rolls a past occurrence forward to the first one after now', () => {
    const monday = new Date('2026-10-26T09:00:00.000Z');
    const now = new Date('2026-10-28T12:00:00.000Z');
    const s = firstOccurrenceAfter(monday, { repeatDays: [1, 2, 3, 4, 5], intervalWeeks: 1 }, 0, now);
    assert.strictEqual(s.toISOString(), '2026-10-29T09:00:00.000Z');
  });

  it('keeps a future occurrence unchanged', () => {
    const tomorrow = new Date('2026-10-29T09:00:00.000Z');
    const now = new Date('2026-10-28T12:00:00.000Z');
    const s = firstOccurrenceAfter(tomorrow, { repeatDays: [1, 2, 3, 4, 5], intervalWeeks: 1 }, 0, now);
    assert.strictEqual(s.getTime(), tomorrow.getTime());
  });

  it('treats interval-with-anchor and repeat_days as recurring', () => {
    assert.strictEqual(isRecurring([1, 2], 1), true);
    assert.strictEqual(isRecurring([], 2, '2026-10-30'), true);
    assert.strictEqual(isRecurring([], 1, null), false);
  });
});
