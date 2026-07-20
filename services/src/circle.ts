/**
 * Circle Programmable Wallets — heir onboarding.
 *
 * ============================ NOT WIRED UP ============================
 * This module is deliberately INERT. Every function throws
 * MissingCredentialError until CIRCLE_API_KEY and CIRCLE_ENTITY_SECRET are
 * provisioned. Nothing here fakes a wallet, a balance, or a transaction.
 * ======================================================================
 *
 * There is also a SEQUENCING CONSTRAINT that has to be understood before this
 * gets wired, because the obvious design does not work:
 *
 *   The PRD imagines "heir clicks link -> wallet is created -> funds land".
 *   That cannot work against the deployed contract. `claim()` reverts with
 *   NotBeneficiary unless msg.sender is the address the OWNER pre-registered
 *   (HeirloomVault.sol:219). A wallet created at claim time has a fresh
 *   address that was never registered, so its claim always reverts.
 *
 * Two ways to resolve it:
 *
 *   (A) PROVISION AT SETUP  — works with the contract as deployed.
 *       When the owner configures heirs, we create an email-bound Circle Wallet
 *       per heir THEN, and the owner registers those addresses as beneficiaries
 *       (through the 7-day config timelock, like any other config change). At
 *       claim time the heir authenticates to a wallet that already exists and
 *       already is the registered payee. The email link becomes "sign in and
 *       press claim", which is still the non-crypto experience the PRD wants.
 *
 *   (B) PERMISSIONLESS ASSISTED CLAIM — needs a contract change.
 *       Let anyone call `claim(tier)` while funds still go only to the
 *       registered payee. Invariant 4 is untouched (the destination remains
 *       un-nameable by the caller) and invariant 6 gets stronger, because an
 *       heir who never manages to transact cannot strand the tier. This was
 *       already flagged as a possible strengthening in docs/OPEN-QUESTIONS.md.
 *
 * This module implements the client for (A). (B) is a contract decision, not
 * one this service should make unilaterally.
 *
 * A second constraint, easy to miss: the heir's wallet needs Arc gas to send
 * the claim transaction. On Arc gas is USDC and a fresh wallet has none. Either
 * the wallet is gas-sponsored, or something pre-funds it with a small amount.
 * `estimateGasFundingNeeded` exists to make that requirement explicit rather
 * than discovering it when a grieving spouse's claim fails.
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
 * address is what the owner registers as a beneficiary.
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
  - Whether gas sponsorship is available there, or whether heir wallets must be
    pre-funded (see estimateGasFundingNeeded).
  - That wallets can be created at SETUP time and their addresses handed back,
    since the beneficiary address must be registered on-chain in advance.
`.trim();
