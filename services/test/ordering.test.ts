/**
 * Event ordering under Arc's non-decreasing timestamps.
 *
 * These are the tests that matter most in this service. A wrong cursor here
 * does not crash — it silently drops events, and the first symptom is an heir
 * who never got told, months later.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  compareEvents,
  sortEvents,
  unprocessed,
  advanceCursor,
  isAfterCursor,
  blockPages,
  GENESIS_CURSOR,
  type Cursor,
} from '../src/ordering.js';

const ev = (blockNumber: bigint, logIndex: number, blockTimestamp: bigint) => ({
  blockNumber,
  logIndex,
  blockTimestamp,
  transactionHash: `0x${blockNumber}${logIndex}`,
  address: '0xvault',
  eventName: 'Heartbeat',
  args: {},
});

test('orders by (blockNumber, logIndex), not timestamp', () => {
  // Three blocks sharing ONE timestamp — legal on Arc, and fatal to a
  // timestamp sort.
  const shared = 1_784_521_406n;
  const events = [
    ev(102n, 0, shared),
    ev(100n, 1, shared),
    ev(101n, 5, shared),
    ev(100n, 0, shared),
  ];

  const sorted = sortEvents(events);
  assert.deepEqual(
    sorted.map((e) => `${e.blockNumber}/${e.logIndex}`),
    ['100/0', '100/1', '101/5', '102/0'],
  );
});

test('logIndex breaks ties within a block', () => {
  const t = 5n;
  const sorted = sortEvents([ev(1n, 3, t), ev(1n, 0, t), ev(1n, 2, t)]);
  assert.deepEqual(sorted.map((e) => e.logIndex), [0, 2, 3]);
});

test('compareEvents is a total order', () => {
  assert.ok(compareEvents(ev(1n, 0, 0n), ev(2n, 0, 0n)) < 0);
  assert.ok(compareEvents(ev(2n, 0, 0n), ev(1n, 9, 0n)) > 0);
  assert.equal(compareEvents(ev(1n, 4, 0n), ev(1n, 4, 9n)), 0);
});

test('REGRESSION: same-timestamp events are not dropped by the cursor', () => {
  // The bug this guards: using `timestamp > lastSeen` as the resume condition.
  // Every event below shares a timestamp; a strict timestamp cursor keeps none
  // of them after the first.
  const t = 1_784_521_406n;
  const batch = [ev(200n, 0, t), ev(200n, 1, t), ev(201n, 0, t), ev(201n, 1, t)];

  const cursor: Cursor = {blockNumber: 200n, logIndex: 0};
  const fresh = unprocessed(batch, cursor);

  assert.equal(fresh.length, 3, 'same-timestamp events after the cursor were dropped');
  assert.deepEqual(
    fresh.map((e) => `${e.blockNumber}/${e.logIndex}`),
    ['200/1', '201/0', '201/1'],
  );
});

test('cursor is exclusive — the event at the cursor is not reprocessed', () => {
  const t = 1n;
  const batch = [ev(10n, 0, t), ev(10n, 1, t)];
  const fresh = unprocessed(batch, {blockNumber: 10n, logIndex: 1});
  assert.equal(fresh.length, 0);
});

test('genesis cursor yields everything', () => {
  const batch = [ev(0n, 0, 1n), ev(1n, 0, 1n)];
  assert.equal(unprocessed(batch, GENESIS_CURSOR).length, 2);
});

test('advanceCursor lands on the last position, regardless of input order', () => {
  const t = 7n;
  const batch = [ev(5n, 2, t), ev(9n, 0, t), ev(5n, 9, t)];
  const next = advanceCursor(batch, GENESIS_CURSOR);
  assert.equal(next.blockNumber, 9n);
  assert.equal(next.logIndex, 0);
});

test('advanceCursor never moves backwards', () => {
  const cursor: Cursor = {blockNumber: 100n, logIndex: 5};
  const next = advanceCursor([ev(50n, 0, 1n)], cursor);
  assert.deepEqual(next, cursor);
});

test('isAfterCursor respects logIndex within the cursor block', () => {
  const c: Cursor = {blockNumber: 10n, logIndex: 3};
  assert.equal(isAfterCursor(ev(10n, 3, 0n), c), false);
  assert.equal(isAfterCursor(ev(10n, 4, 0n), c), true);
  assert.equal(isAfterCursor(ev(10n, 0, 0n), c), false);
  assert.equal(isAfterCursor(ev(11n, 0, 0n), c), true);
});

test('blockPages covers the range inclusively with no gaps or overlaps', () => {
  const pages = blockPages(0n, 9n, 4);
  // reconstruct every block covered
  const covered: bigint[] = [];
  for (const p of pages) for (let b = p.from; b <= p.to; b++) covered.push(b);
  assert.deepEqual(covered, [0n, 1n, 2n, 3n, 4n, 5n, 6n, 7n, 8n, 9n]);
});

test('blockPages handles a single-block range and an empty range', () => {
  assert.deepEqual(blockPages(7n, 7n, 100), [{from: 7n, to: 7n}]);
  assert.deepEqual(blockPages(9n, 8n, 100), []);
});

test('paging then ordering reproduces a strict sequence across page seams', () => {
  // Events split across pages must still come out in one clean order.
  const t = 42n;
  const page1 = [ev(1n, 1, t), ev(1n, 0, t)];
  const page2 = [ev(2n, 0, t)];
  const merged = sortEvents([...page2, ...page1]);
  assert.deepEqual(
    merged.map((e) => `${e.blockNumber}/${e.logIndex}`),
    ['1/0', '1/1', '2/0'],
  );
});
