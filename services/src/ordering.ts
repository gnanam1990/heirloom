/**
 * Event ordering and cursor logic.
 *
 * THE ARC RULE, and the reason this file exists on its own:
 *
 *   Arc block timestamps are NON-DECREASING, not strictly increasing. Two
 *   consecutive blocks can carry the SAME timestamp.
 *
 * Two consequences, both of which silently corrupt an indexer that gets them
 * wrong — no crash, no error, just missing or reordered history:
 *
 *   1. Never order events by timestamp. Order by (blockNumber, logIndex),
 *      which is a total order within a chain. A timestamp sort is not stable
 *      across same-timestamp blocks and will reshuffle events.
 *
 *   2. Never use `timestamp > lastSeen` as a resume cursor. A strict comparison
 *      drops every event in a block that shares the previous block's timestamp.
 *      The cursor must be (blockNumber, logIndex), and any timestamp window
 *      must be inclusive at both ends.
 *
 * Per docs.arc.io/arc/tutorials/monitor-contract-events.
 */

export interface OrderedEvent {
  blockNumber: bigint;
  logIndex: number;
  transactionHash: string;
  address: string;
  eventName: string;
  args: Record<string, unknown>;
  blockTimestamp: bigint;
}

/** A resume position. Exclusive: the next event to process is strictly after it. */
export interface Cursor {
  blockNumber: bigint;
  logIndex: number;
}

export const GENESIS_CURSOR: Cursor = {blockNumber: -1n, logIndex: -1};

/**
 * Total order over (blockNumber, logIndex).
 * Returns <0 if a precedes b, >0 if a follows b, 0 if identical position.
 */
export function compareEvents(
  a: {blockNumber: bigint; logIndex: number},
  b: {blockNumber: bigint; logIndex: number},
): number {
  if (a.blockNumber < b.blockNumber) return -1;
  if (a.blockNumber > b.blockNumber) return 1;
  return a.logIndex - b.logIndex;
}

/** Deterministic sort. Never sorts on timestamp — see the header. */
export function sortEvents<T extends {blockNumber: bigint; logIndex: number}>(
  events: readonly T[],
): T[] {
  return [...events].sort(compareEvents);
}

/** True when `e` is strictly after `cursor` and therefore still unprocessed. */
export function isAfterCursor(
  e: {blockNumber: bigint; logIndex: number},
  cursor: Cursor,
): boolean {
  return compareEvents(e, cursor) > 0;
}

/**
 * Filters to events not yet processed, in order.
 *
 * Note this deliberately takes no timestamp argument. Every same-timestamp
 * event in a block is retained, because position — not time — decides what has
 * been seen.
 */
export function unprocessed<T extends {blockNumber: bigint; logIndex: number}>(
  events: readonly T[],
  cursor: Cursor,
): T[] {
  return sortEvents(events).filter((e) => isAfterCursor(e, cursor));
}

/** The cursor to persist after processing a batch. Unchanged if empty. */
export function advanceCursor(
  events: readonly {blockNumber: bigint; logIndex: number}[],
  current: Cursor,
): Cursor {
  let next = current;
  for (const e of events) {
    if (compareEvents(e, next) > 0) {
      next = {blockNumber: e.blockNumber, logIndex: e.logIndex};
    }
  }
  return next;
}

/**
 * Splits a block range into inclusive pages.
 * Both ends inclusive — an off-by-one here drops a block's worth of events.
 */
export function blockPages(
  from: bigint,
  to: bigint,
  pageSize: number,
): Array<{from: bigint; to: bigint}> {
  const pages: Array<{from: bigint; to: bigint}> = [];
  if (to < from) return pages;
  const size = BigInt(Math.max(1, pageSize));
  let cur = from;
  while (cur <= to) {
    const end = cur + size - 1n > to ? to : cur + size - 1n;
    pages.push({from: cur, to: end});
    cur = end + 1n;
  }
  return pages;
}
