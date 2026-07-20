/**
 * Arc testnet chain access. Read-only — this service never holds a key that
 * can move funds, and there is no write path in here by design.
 */
import {createPublicClient, http, defineChain, type PublicClient} from 'viem';
import {chain as cfg} from './config.js';
import {vaultAbi} from './abi.js';
import {type LadderConfig, VaultState, vaultState} from './ladder.js';
import {
  type OrderedEvent,
  sortEvents,
  blockPages,
} from './ordering.js';

export const arcTestnet = defineChain({
  id: cfg.chainId,
  name: 'Arc Testnet',
  // Native gas token is USDC. On Arc the native (18dp) and ERC-20 (6dp)
  // surfaces are the SAME underlying balance — verified on-chain, see
  // docs/addresses.md. Do not treat them as two pots.
  nativeCurrency: {name: 'USD Coin', symbol: 'USDC', decimals: 18},
  rpcUrls: {default: {http: [cfg.rpcUrl]}},
  blockExplorers: {default: {name: 'Arcscan', url: cfg.explorer}},
  // Multicall3 is deployed at the canonical address on Arc testnet (verified
  // on-chain). Batching the ~11 view calls per vault into ONE request is not a
  // micro-optimisation here: firing them individually reliably trips the public
  // RPC's rate limit and leaves the indexer with partial state.
  contracts: {
    multicall3: {address: '0xcA11bde05977b3631167028862bE2a173976CA11' as const},
  },
});

export function makeClient(): PublicClient {
  return createPublicClient({
    chain: arcTestnet,
    // The public Arc RPC rate-limits by REQUEST RATE, not payload size — even a
    // single batched multicall gets refused if it arrives too soon after the
    // last call. Retry with backoff rather than letting the indexer record a
    // partial snapshot and fire reminders off it.
    transport: http(cfg.rpcUrl, {retryCount: 6, retryDelay: 400, timeout: 20_000}),
    batch: {multicall: true},
  });
}

/** Small pause between vaults, for the same rate limit. */
export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Retries on Arc's "request limit reached".
 *
 * viem's transport-level retry does not help here: the RPC answers 200 with a
 * JSON-RPC error body, which is a successful transport round trip as far as the
 * transport is concerned. This catches it by message and backs off.
 */
export async function withRateLimitRetry<T>(
  fn: () => Promise<T>,
  attempts = 6,
  baseDelayMs = 500,
): Promise<T> {
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      const msg = (err as Error).message ?? '';
      if (!/request limit|rate limit|too many requests|429/i.test(msg)) throw err;
      await sleep(baseDelayMs * 2 ** i);
    }
  }
  throw lastErr;
}

export interface VaultSnapshot {
  address: string;
  owner: string;
  asset: string;
  state: VaultState;
  isClaimed: boolean;
  lastActivity: bigint;
  ladder: LadderConfig;
  totalAssets: bigint;
  secondsUntilNextRung: bigint;
  activeTier: bigint | null;
  beneficiaries: Array<{tier: number; payee: string; window: bigint}>;
  guardianThreshold: bigint;
  guardians: readonly string[];
  blockNumber: bigint;
  blockTimestamp: bigint;
}

/**
 * Reads a vault's full state from chain.
 *
 * Note it reads `state()` from the contract AND recomputes it locally from
 * (lastActivity, ladder, blockTimestamp). If those ever disagree the mirror in
 * ladder.ts has drifted from the deployed contract, which is a bug worth
 * shouting about rather than silently preferring one.
 */
export async function readVault(
  client: PublicClient,
  address: `0x${string}`,
): Promise<VaultSnapshot> {
  const block = await withRateLimitRetry(() => client.getBlock({blockTag: 'latest'}));

  const base = {address, abi: vaultAbi} as const;

  // ONE request for the whole snapshot. Two multicalls in quick succession is
  // enough to trip Arc's public rate limit, so beneficiary slots are probed
  // speculatively in the same batch with allowFailure rather than fetched in a
  // second round trip after reading beneficiaryCount.
  const MAX_TIERS = 8;
  // viem's multicall generics infer the whole array from its first entry, so a
  // heterogeneous call list has to be assembled untyped and cast once here.
  // The `need()` accessor below re-establishes types at the point of use.
  const calls: unknown[] = [
    {...base, functionName: 'owner'},
    {...base, functionName: 'asset'},
    {...base, functionName: 'state'},
    {...base, functionName: 'isClaimed'},
    {...base, functionName: 'lastActivity'},
    {...base, functionName: 'ladder'},
    {...base, functionName: 'totalAssets'},
    {...base, functionName: 'secondsUntilNextRung'},
    {...base, functionName: 'beneficiaryCount'},
    {...base, functionName: 'guardianThreshold'},
    {...base, functionName: 'guardians'},
    ...Array.from({length: MAX_TIERS}, (_v, i) => ({
      ...base,
      functionName: 'beneficiaries',
      args: [BigInt(i)],
    })),
  ];

  type MulticallResult =
    | {status: 'success'; result: unknown}
    | {status: 'failure'; error: unknown};

  const results = (await withRateLimitRetry(() =>
    client.multicall({allowFailure: true, contracts: calls as never}),
  )) as unknown as MulticallResult[];

  const need = <T,>(i: number, what: string): T => {
    const r = results[i];
    if (!r || r.status !== 'success') {
      const detail = r && r.status === 'failure' ? (r.error as Error)?.message : 'no result';
      throw new Error(`reading ${what} from ${address} failed: ${detail}`);
    }
    return r.result as T;
  };

  const owner = need<string>(0, 'owner');
  const asset = need<string>(1, 'asset');
  const onChainState = need<number>(2, 'state');
  const isClaimed = need<boolean>(3, 'isClaimed');
  const lastActivity = need<bigint>(4, 'lastActivity');
  const ladderRaw = need<readonly [number, number, number, number]>(5, 'ladder');
  const totalAssets = need<bigint>(6, 'totalAssets');
  const untilNext = need<bigint>(7, 'secondsUntilNextRung');
  const benCount = need<bigint>(8, 'beneficiaryCount');
  const threshold = need<bigint>(9, 'guardianThreshold');
  const guardians = need<readonly string[]>(10, 'guardians');

  const ladder: LadderConfig = {
    nagAfter: BigInt(ladderRaw[0]),
    guardianAlertAfter: BigInt(ladderRaw[1]),
    careModeAfter: BigInt(ladderRaw[2]),
    claimableAfter: BigInt(ladderRaw[3]),
  };

  const beneficiaries: VaultSnapshot['beneficiaries'] = [];
  for (let i = 0; i < Number(benCount) && i < MAX_TIERS; i++) {
    const r = results[11 + i];
    if (!r || r.status !== 'success') break;
    const b = r.result as readonly [string, number];
    beneficiaries.push({tier: i, payee: b[0], window: BigInt(b[1])});
  }
  if (beneficiaries.length !== Number(benCount)) {
    console.warn(
      `[chain] ${address}: read ${beneficiaries.length} of ${benCount} beneficiaries ` +
        `(MAX_TIERS=${MAX_TIERS}). Claim-link minting for higher tiers will be incomplete.`,
    );
  }

  const derived = vaultState(isClaimed, lastActivity, block.timestamp, ladder);
  if (derived !== (onChainState as VaultState)) {
    console.warn(
      `[chain] MIRROR DRIFT on ${address}: contract says ${onChainState}, ` +
        `services/src/ladder.ts computed ${derived}. Trusting the chain. ` +
        `Re-check the port against src/LivenessLadder.sol.`,
    );
  }

  let activeTier: bigint | null = null;
  if ((onChainState as VaultState) === VaultState.Claimable) {
    activeTier = (await withRateLimitRetry(() =>
      client.readContract({...base, functionName: 'activeTier'}),
    )) as bigint;
  }

  return {
    address,
    owner,
    asset,
    state: onChainState as VaultState,
    isClaimed,
    lastActivity,
    ladder,
    totalAssets,
    secondsUntilNextRung: untilNext,
    activeTier,
    beneficiaries,
    guardianThreshold: threshold,
    guardians,
    blockNumber: block.number,
    blockTimestamp: block.timestamp,
  };
}

/**
 * Fetches vault events across a block range, returned in (blockNumber,
 * logIndex) order.
 *
 * Timestamps are attached for display only. Nothing downstream may order or
 * page on them — see ordering.ts for why.
 */
export async function fetchEvents(
  client: PublicClient,
  addresses: readonly `0x${string}`[],
  fromBlock: bigint,
  toBlock: bigint,
  pageSize: number,
): Promise<OrderedEvent[]> {
  if (addresses.length === 0) return [];
  const out: OrderedEvent[] = [];
  const tsCache = new Map<bigint, bigint>();

  for (const page of blockPages(fromBlock, toBlock, pageSize)) {
    const logs = await withRateLimitRetry(() =>
      client.getLogs({
        address: addresses as `0x${string}`[],
        fromBlock: page.from,
        toBlock: page.to, // inclusive at both ends
      }),
    );

    for (const log of logs) {
      if (log.blockNumber === null || log.logIndex === null) continue;

      let decoded: {eventName: string; args: Record<string, unknown>} | null = null;
      try {
        const {decodeEventLog} = await import('viem');
        const d = decodeEventLog({
          abi: vaultAbi,
          data: log.data,
          topics: log.topics,
        });
        decoded = {
          eventName: d.eventName as string,
          args: (d.args ?? {}) as Record<string, unknown>,
        };
      } catch {
        continue; // not one of ours, or an ABI we do not carry
      }

      let ts = tsCache.get(log.blockNumber);
      if (ts === undefined) {
        const b = await withRateLimitRetry(() =>
          client.getBlock({blockNumber: log.blockNumber as bigint}),
        );
        ts = b.timestamp;
        tsCache.set(log.blockNumber, ts);
      }

      out.push({
        blockNumber: log.blockNumber,
        logIndex: log.logIndex,
        transactionHash: log.transactionHash ?? '',
        address: log.address,
        eventName: decoded.eventName,
        args: decoded.args,
        blockTimestamp: ts,
      });
    }
  }

  return sortEvents(out);
}
