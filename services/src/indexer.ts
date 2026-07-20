/**
 * Heartbeat listener / event indexer.
 *
 * Follows docs.arc.io/arc/tutorials/monitor-contract-events: poll getLogs over
 * inclusive block ranges, then order strictly by (blockNumber, logIndex).
 * See ordering.ts for why timestamps are never used for ordering or paging.
 *
 * The indexer also drives the reminder pipeline: when a watched vault crosses
 * into a new rung it notifies the linked owner exactly once per transition.
 * `lastNotifiedState` is persisted for that reason — a restart must not re-DM
 * someone about a tier they were already told about.
 */
import type {PublicClient} from 'viem';
import {indexer as cfg, watchedVaults, chain as chainCfg} from './config.js';
import {makeClient, readVault, fetchEvents, sleep, type VaultSnapshot} from './chain.js';
import {Store} from './store.js';
import {advanceCursor, unprocessed} from './ordering.js';
import {VaultState, STATE_NAMES} from './ladder.js';
import * as telegram from './telegram.js';

export class Indexer {
  private readonly client: PublicClient;
  readonly store: Store;
  private snapshots = new Map<string, VaultSnapshot>();
  private running = false;

  constructor(client?: PublicClient, store?: Store) {
    this.client = client ?? makeClient();
    this.store = store ?? new Store(cfg.dbPath);
  }

  snapshot(address: string): VaultSnapshot | undefined {
    return this.snapshots.get(address.toLowerCase());
  }

  allSnapshots(): VaultSnapshot[] {
    return [...this.snapshots.values()];
  }

  /** Reads current state for every watched vault and fires any due reminders. */
  async refreshStates(): Promise<void> {
    let first = true;
    for (const address of watchedVaults) {
      if (!first) await sleep(250); // pace the public RPC
      first = false;
      try {
        const snap = await readVault(this.client, address);
        this.snapshots.set(address.toLowerCase(), snap);
        await this.maybeNotify(snap);
      } catch (err) {
        console.error(`[indexer] failed reading ${address}:`, (err as Error).message);
      }
    }
  }

  /**
   * One reminder per transition. Only fires for rungs that mean something to an
   * owner, and only if they linked a chat.
   */
  private async maybeNotify(snap: VaultSnapshot): Promise<void> {
    const rec = this.store.vault(snap.address);
    if (rec.lastNotifiedState === snap.state) return;

    const notifiable =
      snap.state === VaultState.Nagging ||
      snap.state === VaultState.GuardianAlert ||
      snap.state === VaultState.CareMode ||
      snap.state === VaultState.Claimable;

    if (notifiable && rec.ownerChatId && telegram.isConfigured()) {
      try {
        await telegram.sendMessage(
          rec.ownerChatId,
          telegram.reminderMessage(
            snap.address,
            snap.state,
            snap.lastActivity,
            snap.ladder,
            snap.blockTimestamp,
          ),
        );
        console.log(`[reminder] ${snap.address} -> ${STATE_NAMES[snap.state]} (sent)`);
      } catch (err) {
        console.error('[reminder] send failed:', (err as Error).message);
        return; // leave lastNotifiedState alone so it retries
      }
    } else if (notifiable) {
      console.log(
        `[reminder] ${snap.address} -> ${STATE_NAMES[snap.state]} ` +
          `(no delivery: ${rec.ownerChatId ? 'telegram not configured' : 'no linked chat'})`,
      );
    }

    this.store.updateVault(snap.address, {lastNotifiedState: snap.state});
  }

  /** Pulls new events since the stored cursor and records them, in order. */
  async pump(): Promise<number> {
    const head = await this.client.getBlockNumber();
    const cursor = this.store.getCursor();

    const from = cursor.blockNumber < 0n ? cfg.startBlock : cursor.blockNumber;
    if (from > head) return 0;

    const events = await fetchEvents(
      this.client,
      watchedVaults,
      from,
      head,
      cfg.pageSize,
    );

    // Cursor is (blockNumber, logIndex) — re-scanning `from` is safe and
    // necessary, because the block the cursor sits in may contain later logs.
    const fresh = unprocessed(events, cursor);
    if (fresh.length > 0) {
      this.store.recordEvents(fresh);
      for (const e of fresh) {
        console.log(
          `[event] ${e.blockNumber}/${e.logIndex} ${e.eventName} ` +
            `${chainCfg.explorer}/tx/${e.transactionHash}`,
        );
      }
      this.store.setCursor(advanceCursor(fresh, cursor));
    } else if (cursor.blockNumber < 0n) {
      this.store.setCursor({blockNumber: head, logIndex: -1});
    }
    return fresh.length;
  }

  async start(): Promise<void> {
    this.running = true;
    console.log(
      `[indexer] watching ${watchedVaults.length} vault(s) on chain ${chainCfg.chainId}`,
    );
    while (this.running) {
      try {
        await this.pump();
        await this.refreshStates();
      } catch (err) {
        console.error('[indexer] cycle failed:', (err as Error).message);
      }
      await new Promise((r) => setTimeout(r, cfg.pollMs));
    }
  }

  stop(): void {
    this.running = false;
  }
}

// Standalone: npm run indexer
if (import.meta.url === `file://${process.argv[1]}`) {
  const ix = new Indexer();
  await ix.refreshStates();
  for (const s of ix.allSnapshots()) {
    console.log(
      `${s.address}  ${STATE_NAMES[s.state]}  assets=${s.totalAssets}  ` +
        `nextRung=${s.secondsUntilNextRung}s`,
    );
  }
  await ix.start();
}
