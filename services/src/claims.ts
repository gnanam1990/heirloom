/**
 * Heir claim links.
 *
 * A claim link is a signed capability to *see* a claim page — it is NOT a
 * bearer token for the money. Possession of a link never moves funds, because
 * the contract requires `msg.sender == beneficiaries[tier].payee`
 * (HeirloomVault.sol:219). Even a leaked link can at most show a stranger a
 * page saying "this vault is claimable by 0x…".
 *
 * That property is deliberate and worth preserving in any redesign: it means a
 * forwarded email, a leaked log line, or a shoulder-surfed URL is not a theft.
 */
import {createHmac, timingSafeEqual, randomBytes} from 'node:crypto';

export interface ClaimClaims {
  vault: string;
  tier: number;
  /** Address the funds will go to. Fixed by the contract, shown for transparency. */
  payee: string;
  /** Unix seconds. Links are time-boxed so an old inbox is not a live surface. */
  expiresAt: number;
  /** Random, so two links for the same (vault,tier) differ and can be revoked. */
  nonce: string;
}

function b64url(buf: Buffer): string {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function unb64url(s: string): Buffer {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  return Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/') + pad, 'base64');
}

/** Signs claims into a compact `<payload>.<sig>` token. */
export function signClaimToken(claims: ClaimClaims, secret: string): string {
  const payload = b64url(Buffer.from(JSON.stringify(claims), 'utf8'));
  const sig = b64url(createHmac('sha256', secret).update(payload).digest());
  return `${payload}.${sig}`;
}

export type VerifyResult =
  | {ok: true; claims: ClaimClaims}
  | {ok: false; reason: 'malformed' | 'bad-signature' | 'expired'};

/**
 * Verifies a token. Signature is checked with a constant-time compare before
 * expiry, so the failure mode does not leak whether a forged token was
 * otherwise well-formed.
 */
export function verifyClaimToken(
  token: string,
  secret: string,
  now = Math.floor(Date.now() / 1000),
): VerifyResult {
  const dot = token.lastIndexOf('.');
  if (dot <= 0) return {ok: false, reason: 'malformed'};

  const payload = token.slice(0, dot);
  const sig = token.slice(dot + 1);

  const expected = b64url(createHmac('sha256', secret).update(payload).digest());
  const a = Buffer.from(sig);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) {
    return {ok: false, reason: 'bad-signature'};
  }

  let claims: ClaimClaims;
  try {
    claims = JSON.parse(unb64url(payload).toString('utf8')) as ClaimClaims;
  } catch {
    return {ok: false, reason: 'malformed'};
  }

  if (
    typeof claims.vault !== 'string' ||
    typeof claims.tier !== 'number' ||
    typeof claims.expiresAt !== 'number'
  ) {
    return {ok: false, reason: 'malformed'};
  }

  if (now >= claims.expiresAt) return {ok: false, reason: 'expired'};
  return {ok: true, claims};
}

export const DEFAULT_TTL_SECONDS = 60 * 60 * 24 * 30; // 30 days

export function mintClaimLink(
  baseUrl: string,
  vault: string,
  tier: number,
  payee: string,
  secret: string,
  ttlSeconds = DEFAULT_TTL_SECONDS,
  now = Math.floor(Date.now() / 1000),
): {url: string; token: string; claims: ClaimClaims} {
  const claims: ClaimClaims = {
    vault: vault.toLowerCase(),
    tier,
    payee: payee.toLowerCase(),
    expiresAt: now + ttlSeconds,
    nonce: randomBytes(9).toString('hex'),
  };
  const token = signClaimToken(claims, secret);
  const url = `${baseUrl.replace(/\/$/, '')}/claim/${token}`;
  return {url, token, claims};
}

/**
 * Plain-language email body for a non-crypto heir.
 *
 * No jargon, no seed phrases, and an explicit statement that the money can only
 * reach the address already recorded — which is the honest reason the link is
 * safe to email in the first place.
 */
export function claimEmailBody(opts: {
  heirName?: string;
  vaultAddress: string;
  amountUsdc: string;
  url: string;
  explorer: string;
}): {subject: string; text: string} {
  const who = opts.heirName ? `${opts.heirName},` : 'Hello,';
  return {
    subject: 'Something has been left to you',
    text: [
      who,
      '',
      'Someone set aside funds for you and asked that you be told if they were',
      'ever unable to manage them themselves. That has now happened.',
      '',
      `Amount: ${opts.amountUsdc} USDC`,
      '',
      'You do not need to understand cryptocurrency, and you do not need to',
      'install anything. Open this link and follow the steps:',
      '',
      opts.url,
      '',
      'A few things worth knowing:',
      '  - You will never be asked for a password, a seed phrase, or a payment.',
      '  - The funds can only ever go to the account already recorded for you.',
      '    Nobody can redirect them, including us, and including anyone who',
      '    happens to see this email.',
      '  - Nobody will call you about this. If someone does, it is not us.',
      '',
      `The record is public and permanent: ${opts.explorer}/address/${opts.vaultAddress}`,
      '',
      'This is testnet software and the funds are test funds.',
    ].join('\n'),
  };
}
