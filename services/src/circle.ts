/**
 * Circle Programmable Wallets — heir onboarding.
 *
 * ============================ NOT WIRED UP ============================
 * This module is deliberately INERT. Every function throws
 * MissingCredentialError until CIRCLE_API_KEY and CIRCLE_ENTITY_SECRET are
 * provisioned. Nothing here fakes a wallet, a balance, or a transaction.
 * ======================================================================
 *
 * ===================== READ THIS BEFORE WIRING IT =====================
 * Q11 (permissionless claim) solved HALF of the heir-onboarding problem, and
 * it is important not to mistake it for the whole thing.
 *
 *   SOLVED by Q11:   the heir no longer needs gas, a wallet app, or the ability
 *                    to send a transaction. A helper triggers `claim(tier)` for
 *                    them (see relayer.ts).
 *
 *   NOT SOLVED:      the DESTINATION is still `_beneficiaries[tier].payee`,
 *                    read from storage at HeirloomVault.sol:253. It is fixed
 *                    when the owner registers heirs, and no caller can change
 *                    it — that is exactly what keeps invariant 4 true.
 *
 * So a Circle Wallet created AT CLAIM TIME still cannot receive the funds. Its
 * address was never registered, so the payout goes to whatever address the
 * owner recorded, not to the shiny new wallet. The naive flow "heir clicks
 * link -> wallet created -> funds land in it" remains impossible, and would
 * silently pay the wrong address rather than erroring.
 *
 * The flow that DOES work, and which this module is written for:
 *
 *   AT SETUP  (owner is alive, configuring the vault)
 *     1. Owner supplies each heir's EMAIL.
 *     2. We create an email-bound Circle Wallet per heir now, and hand back the
 *        addresses.
 *     3. Owner registers those addresses as beneficiaries, through the normal
 *        7-day config timelock like any other config change.
 *
 *   AT CLAIM  (owner is gone, vault is Claimable)
 *     4. Heir opens the emailed link.
 *     5. The service, as helper, calls `claim(tier)` — no gas or wallet needed
 *        from the heir (this is the Q11 win).
 *     6. Funds land in the wallet that was already registered for them.
 *     7. Heir authenticates to that wallet by email to see and move the money.
 *
 * The heir still never sees a seed phrase, still needs no crypto knowledge, and
 * now also needs no gas. The one hard requirement is that the owner set their
 * heirs up with wallets in advance — which is inherent to a product whose whole
 * premise is "configure this before you need it".
 * ======================================================================
 *
 * A second constraint that survives Q11 only partially: the heir's wallet needs
 * gas ONLY if the heir later wants to move the funds themselves. Receiving is
 * free. `estimateGasFundingNeeded` is kept for that case.
 */
import {secrets} from './config.js';

const CIRCLE_API_BASE = 'https://api.circle.com/v1/w3s';

export interface HeirWallet {
  walletId: string;
  address: `0x${string}`;
  email: string;
}

/** True when both Circle credentials are present. */
export function isConfigured(): boolean {
  try {
    secrets.circleApiKey();
    secrets.circleEntitySecret();
    return true;
  } catch {
    return false;
  }
}

function authHeaders(): Record<string, string> {
  return {
    Authorization: `Bearer ${secrets.circleApiKey()}`,
    'Content-Type': 'application/json',
  };
}

/**
 * Creates an email-bound wallet for an heir on Arc testnet.
 *
 * MUST be called at SETUP time, not claim time — see the header. The returned
 * address is what the owner registers as a beneficiary, and registering it goes
 * through the 7-day config timelock. Calling this at claim time produces an
 * address that can never receive the payout.
 *
 * @throws MissingCredentialError until Circle credentials are provisioned.
 */
export async function createHeirWallet(email: string): Promise<HeirWallet> {
  const apiKey = secrets.circleApiKey();
  const entitySecret = secrets.circleEntitySecret();

  // Intentionally unimplemented beyond the credential gate. The exact request
  // shape (wallet set id, blockchain identifier for Arc testnet, entity secret
  // ciphertext rotation) must be confirmed against Circle's current API docs
  // with a real key in hand. Guessing it would produce code that looks right
  // and fails on first contact.
  void apiKey;
  void entitySecret;
  void email;
  throw new Error(
    'Circle wallet creation is not implemented yet.\n' +
      'Credentials are present, but the request shape must be confirmed against\n' +
      "Circle's Programmable Wallets API (wallet set, Arc testnet blockchain id,\n" +
      'entity-secret ciphertext) before this is written. Ask the maintainer to\n' +
      'finish this against a live sandbox key rather than shipping a guess.',
  );
}

/**
 * How much native gas to seed an heir wallet with so it can send one claim.
 *
 * Arc gas is USDC (18dp native surface). A claim cost ~68,918 gas at ~20.9 gwei
 * on the live run recorded in docs/addresses.md; this pads that generously
 * because an underfunded heir wallet is a silently broken inheritance.
 */
export function estimateGasFundingNeeded(): {wei: bigint; human: string} {
  const claimGas = 120_000n; // ~1.7x the observed 68,918
  const gasPriceWei = 60_000_000_000n; // ~3x the observed 20.9 gwei
  const wei = claimGas * gasPriceWei;
  return {wei, human: `${Number(wei) / 1e18} USDC`};
}

export const CIRCLE_SETUP_NOTES = `
Circle Programmable Wallets — what must be provisioned:

  CIRCLE_API_KEY        console.circle.com -> Developer Controlled Wallets ->
                        create a TESTNET API key.
  CIRCLE_ENTITY_SECRET  console.circle.com -> register an entity secret and
                        store the ciphertext.

Also confirm before wiring:
  - Which blockchain identifier Circle uses for Arc testnet.
  - That a wallet address can be obtained at SETUP time and handed back, since
    the beneficiary address must be registered on-chain in advance. This is the
    load-bearing requirement: if Circle cannot give an address until the heir
    first authenticates, the whole email-onboarding design needs rethinking.
  - How an heir authenticates to a wallet created for them months earlier.
  - Gas sponsorship is NOT needed to receive (Q11 covers that via the relayer),
    only if the heir later moves funds themselves.
`.trim();
