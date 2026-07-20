/**
 * Durable-enough store for the indexer.
 *
 * A JSON file rather than SQLite: the whole point of the design is that the
 * chain is the source of truth and this layer only observes. If the file is
 * lost, the indexer re-scans from `INDEXER_START_BLOCK` and rebuilds. Nothing
 * here is authoritative, so a heavier database would be false precision.
 *
 * The one thing worth persisting carefully is the CURSOR, because replaying
 * events is what causes duplicate reminder DMs to real people.
 */
import {readFileSync, writeFileSync, renameSync} from 'node:fs';
import type {Cursor, OrderedEvent} from './ordering.js';
import {GENESIS_CURSOR} from './ordering.js';
import {VaultState} from './ladder.js';

export interface VaultRecord {
  address: string;
  /** Last state we NOTIFIED about, so reminders fire once per transition. */
  lastNotifiedState: VaultState | null;
  /** Telegram chat id linked by the owner, if any. */
  ownerChatId?: string;
  /** Beneficiary email addresses, keyed by tier index. */
  heirEmails?: Record<string, string>;
  /** Claim links already issued, keyed by tier, so we mint one per heir. */
  claimLinksIssued?: Record<string, string>;
}

export interface StoreShape {
  cursor: {blockNumber: string; logIndex: number};
  vaults: Record<string, VaultRecord>;
  /** Bounded ring of recent events, for the API and for debugging. */
  recentEvents: Array<{
    blockNumber: string;
    logIndex: number;
    transactionHash: string;
    address: string;
    eventName: string;
    blockTimestamp: string;
    args: Record<string, string>;
  }>;
}

const MAX_RECENT = 500;

export class Store {
  private data: StoreShape;

  constructor(private readonly path: string) {
    this.data = this.read();
  }

  private read(): StoreShape {
    try {
      const parsed = JSON.parse(readFileSync(this.path, 'utf8')) as StoreShape;
      if (!parsed.vaults) parsed.vaults = {};
      if (!parsed.recentEvents) parsed.recentEvents = [];
      return parsed;
    } catch {
      return {
        cursor: {blockNumber: GENESIS_CURSOR.blockNumber.toString(), logIndex: -1},
        vaults: {},
        recentEvents: [],
      };
    }
  }

  /** Atomic-ish write: temp file then rename, so a crash cannot truncate state. */
  private flush(): void {
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.data, null, 2));
    renameSync(tmp, this.path);
  }

  getCursor(): Cursor {
    return {
      blockNumber: BigInt(this.data.cursor.blockNumber),
      logIndex: this.data.cursor.logIndex,
    };
  }

  setCursor(c: Cursor): void {
    this.data.cursor = {blockNumber: c.blockNumber.toString(), logIndex: c.logIndex};
    this.flush();
  }

  vault(address: string): VaultRecord {
    const key = address.toLowerCase();
    let v = this.data.vaults[key];
    if (!v) {
      v = {address: key, lastNotifiedState: null};
      this.data.vaults[key] = v;
    }
    return v;
  }

  updateVault(address: string, patch: Partial<VaultRecord>): void {
    const v = this.vault(address);
    Object.assign(v, patch);
    this.flush();
  }

  allVaults(): VaultRecord[] {
    return Object.values(this.data.vaults);
  }

  /** Finds the vault an owner linked to a Telegram chat. */
  vaultByChatId(chatId: string): VaultRecord | undefined {
    return Object.values(this.data.vaults).find((v) => v.ownerChatId === chatId);
  }

  recordEvents(events: readonly OrderedEvent[]): void {
    for (const e of events) {
      this.data.recentEvents.push({
        blockNumber: e.blockNumber.toString(),
        logIndex: e.logIndex,
        transactionHash: e.transactionHash,
        address: e.address.toLowerCase(),
        eventName: e.eventName,
        blockTimestamp: e.blockTimestamp.toString(),
        args: Object.fromEntries(
          Object.entries(e.args).map(([k, v]) => [k, String(v)]),
        ),
      });
    }
    if (this.data.recentEvents.length > MAX_RECENT) {
      this.data.recentEvents = this.data.recentEvents.slice(-MAX_RECENT);
    }
    this.flush();
  }

  recentFor(address: string, limit = 50) {
    const key = address.toLowerCase();
    return this.data.recentEvents.filter((e) => e.address === key).slice(-limit).reverse();
  }
}
