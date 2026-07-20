/**
 * Assisted-claim relayer.
 *
 * Since Q11 `claim(tier)` is callable by anyone, so the service can trigger a
 * payout on a non-crypto heir's behalf. The heir needs no wallet software, no
 * gas, and no understanding of what a transaction is — they click a link and
 * the money arrives at the address already registered for them.
 *
 * ------------------------------------------------------------------------
 * WHAT THIS KEY CAN AND CANNOT DO — read before provisioning it.
 *
 * The helper key is genuinely low-privilege, and that is a property of the
 * CONTRACT, not of this code being careful:
 *
 *   CAN:    pay gas to trigger `claim(tier)` on a vault that is already
 *           Claimable, sending funds to the tier's pre-registered payee.
 *   CANNOT: name or influence the destination — `claim` takes a tier index and
 *           reads the payee from storage (HeirloomVault.sol:253).
 *   CANNOT: claim early, jump the cascade order, move funds to itself, touch
 *           config, rotate ownership, or spend from care mode.
 *
 * Worst case if this key is stolen: the thief pays gas to send an heir their
 * inheritance slightly earlier than a helper otherwise would have. There is no
 * path from holding it to taking anything.
 *
 * That is the whole reason Option B was worth a contract change — it moves the
 * heir's gas problem onto a key that cannot be abused.
 * ------------------------------------------------------------------------
 */
import {createWalletClient, http, type Hash} from 'viem';
import {privateKeyToAccount} from 'viem/accounts';
import {arcTestnet, makeClient, withRateLimitRetry} from './chain.js';
import {chain, secrets} from './config.js';
import {vaultAbi} from './abi.js';
import {VaultState} from './ladder.js';

export function isConfigured(): boolean {
  try {
    secrets.helperPrivateKey();
    return true;
  } catch {
    return false;
  }
}

export function helperAddress(): `0x${string}` {
  return privateKeyToAccount(secrets.helperPrivateKey() as `0x${string}`).address;
}

export interface AssistedClaimResult {
  txHash: Hash;
  tier: number;
  beneficiary: `0x${string}`;
  amount: bigint;
  explorer: string;
}

/**
 * Triggers the payout for the open tier of `vault`.
 *
 * Pre-flighted deliberately: a revert here is a confusing failure for whoever
 * is on the other end of a claim link, so the reasons are checked and named
 * before spending gas.
 *
 * @throws MissingCredentialError if no helper key is provisioned.
 */
export async function triggerClaim(
  vault: `0x${string}`,
  expectedTier?: number,
): Promise<AssistedClaimResult> {
  const key = secrets.helperPrivateKey() as `0x${string}`;
  const account = privateKeyToAccount(key);
  const pub = makeClient();

  const [state, activeTier, balance] = (await withRateLimitRetry(() =>
    pub.multicall({
      allowFailure: false,
      contracts: [
        {address: vault, abi: vaultAbi, functionName: 'state'},
        {address: vault, abi: vaultAbi, functionName: 'activeTier'},
        {address: vault, abi: vaultAbi, functionName: 'totalAssets'},
      ] as never,
    }),
  )) as unknown as [number, bigint, bigint];

  if ((state as VaultState) !== VaultState.Claimable) {
    throw new Error(
      `vault ${vault} is not claimable (state ${state}). Nothing to trigger.`,
    );
  }
  if (balance === 0n) {
    throw new Error(`vault ${vault} holds nothing to claim.`);
  }
  const tier = Number(activeTier);
  if (expectedTier !== undefined && expectedTier !== tier) {
    throw new Error(
      `tier ${expectedTier} is not the open tier — tier ${tier} is. The cascade ` +
        `has moved on; this link is for an earlier heir.`,
    );
  }

  const beneficiary = (await withRateLimitRetry(() =>
    pub.readContract({
      address: vault,
      abi: vaultAbi,
      functionName: 'beneficiaries',
      args: [BigInt(tier)],
    }),
  )) as readonly [`0x${string}`, number];

  const wallet = createWalletClient({
    account,
    chain: arcTestnet,
    transport: http(chain.rpcUrl, {retryCount: 4, retryDelay: 500}),
  });

  const txHash = await wallet.writeContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'claim',
    args: [BigInt(tier)],
    chain: arcTestnet,
    account,
  });

  await pub.waitForTransactionReceipt({hash: txHash});

  return {
    txHash,
    tier,
    beneficiary: beneficiary[0],
    amount: balance,
    explorer: `${chain.explorer}/tx/${txHash}`,
  };
}
