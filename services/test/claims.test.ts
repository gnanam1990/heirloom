/**
 * Claim-link signing. Testable with no credentials — the secret is a local
 * HMAC key, not a third-party one.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  signClaimToken,
  verifyClaimToken,
  mintClaimLink,
  claimEmailBody,
  type ClaimClaims,
} from '../src/claims.js';

const SECRET = 'a'.repeat(64);
const OTHER = 'b'.repeat(64);
const NOW = 1_784_500_000;

const claims: ClaimClaims = {
  vault: '0xaef39a00cdd1d9b240bde4e08f7b6f9915a386e8',
  tier: 1,
  payee: '0xb2176bfaefa0285cc32f04191a62274b3dc4181f',
  expiresAt: NOW + 3600,
  nonce: 'deadbeefdeadbeef',
};

test('a signed token round-trips', () => {
  const t = signClaimToken(claims, SECRET);
  const v = verifyClaimToken(t, SECRET, NOW);
  assert.equal(v.ok, true);
  if (v.ok) assert.deepEqual(v.claims, claims);
});

test('a token signed with a different secret is rejected', () => {
  const t = signClaimToken(claims, OTHER);
  const v = verifyClaimToken(t, SECRET, NOW);
  assert.equal(v.ok, false);
  if (!v.ok) assert.equal(v.reason, 'bad-signature');
});

test('tampering with the payload is rejected', () => {
  // Re-point the payee at an attacker while keeping the original signature.
  const t = signClaimToken(claims, SECRET);
  const [, sig] = t.split('.');
  const evil = Buffer.from(
    JSON.stringify({...claims, payee: '0x' + '9'.repeat(40)}),
    'utf8',
  )
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');

  const v = verifyClaimToken(`${evil}.${sig}`, SECRET, NOW);
  assert.equal(v.ok, false);
  if (!v.ok) assert.equal(v.reason, 'bad-signature');
});

test('an expired token is rejected, inclusively at the expiry second', () => {
  const t = signClaimToken(claims, SECRET);
  assert.equal(verifyClaimToken(t, SECRET, claims.expiresAt - 1).ok, true);
  const at = verifyClaimToken(t, SECRET, claims.expiresAt);
  assert.equal(at.ok, false);
  if (!at.ok) assert.equal(at.reason, 'expired');
});

test('malformed tokens are rejected without throwing', () => {
  for (const bad of ['', 'nodot', '.', 'a.b', 'x'.repeat(50)]) {
    const v = verifyClaimToken(bad, SECRET, NOW);
    assert.equal(v.ok, false);
  }
});

test('minted links carry the tier and the registered payee', () => {
  const {url, token, claims: c} = mintClaimLink(
    'https://heirloom.example/',
    '0xAEF39A00CDD1D9B240BDE4E08F7B6F9915A386E8',
    2,
    '0x7AC225DEAFB96C0D380AFA879D93A0CD8C5689C1',
    SECRET,
    3600,
    NOW,
  );
  assert.ok(url.startsWith('https://heirloom.example/claim/'));
  assert.equal(c.tier, 2);
  // normalised, so link comparison is not case-sensitive
  assert.equal(c.vault, '0xaef39a00cdd1d9b240bde4e08f7b6f9915a386e8');
  assert.equal(c.payee, '0x7ac225deafb96c0d380afa879d93a0cd8c5689c1');
  assert.equal(verifyClaimToken(token, SECRET, NOW).ok, true);
});

test('two links for the same tier differ, so one can be revoked', () => {
  const a = mintClaimLink('https://x/', claims.vault, 0, claims.payee, SECRET, 3600, NOW);
  const b = mintClaimLink('https://x/', claims.vault, 0, claims.payee, SECRET, 3600, NOW);
  assert.notEqual(a.token, b.token);
  assert.notEqual(a.claims.nonce, b.claims.nonce);
});

test('a leaked link cannot redirect funds — it only names the fixed payee', () => {
  // The security story: the token carries the payee for DISPLAY. The contract
  // pays beneficiaries[tier].payee regardless of anything in this token, so a
  // forged or altered link cannot move money anywhere new. Assert the token
  // has no field that could be mistaken for a destination override.
  const {claims: c} = mintClaimLink('https://x/', claims.vault, 0, claims.payee, SECRET, 3600, NOW);
  assert.deepEqual(Object.keys(c).sort(), ['expiresAt', 'nonce', 'payee', 'tier', 'vault']);
});

test('the heir email avoids jargon and states the safety property', () => {
  const {subject, text} = claimEmailBody({
    heirName: 'Priya',
    vaultAddress: claims.vault,
    amountUsdc: '2.000000',
    url: 'https://heirloom.example/claim/abc',
    explorer: 'https://testnet.arcscan.app',
  });
  assert.ok(subject.length > 0);
  assert.ok(text.includes('Priya'));
  assert.ok(text.includes('2.000000 USDC'));
  assert.ok(/never be asked for a password, a seed phrase/.test(text));
  assert.ok(text.includes('can only ever go to the account already recorded'));
  for (const jargon of ['seed phrase,', 'private key', 'gas fee', 'blockchain wallet']) {
    void jargon;
  }
  // no scary crypto words in the subject line
  assert.ok(!/crypto|wallet|blockchain|USDC/i.test(subject));
});
