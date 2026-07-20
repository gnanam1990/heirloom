/**
 * Relayer credential gate and the safety argument for the helper key.
 *
 * Hermetic on purpose: these set placeholder values BEFORE importing config, so
 * the result does not depend on whether the developer happens to have a real
 * services/.env sitting there. A test that passes on a clean checkout and fails
 * on a configured machine is worse than no test.
 *
 * `<...>` is the shape `.env.example` ships, and `required()` treats it as
 * unset — so this is exactly the state a fresh clone is in.
 */
process.env.HELPER_PRIVATE_KEY = '<unset>';
process.env.CIRCLE_API_KEY = '<unset>';
process.env.CIRCLE_ENTITY_SECRET = '<unset>';

import test from 'node:test';
import assert from 'node:assert/strict';
import {MissingCredentialError, credentialStatus} from '../src/config.js';
import * as relayer from '../src/relayer.js';

test('relayer is disabled without a helper key', () => {
  assert.equal(relayer.isConfigured(), false);
});

test('triggerClaim throws a named, actionable error when unprovisioned', async () => {
  await assert.rejects(
    () => relayer.triggerClaim('0x0000000000000000000000000000000000000001'),
    (err: Error) => {
      assert.ok(err instanceof MissingCredentialError, 'wrong error type');
      assert.match(err.message, /HELPER_PRIVATE_KEY/);
      assert.match(err.message, /assisted claims/);
      assert.match(err.message, /services\/\.env/);
      return true;
    },
  );
});

test('helperAddress also refuses rather than returning a bogus address', () => {
  assert.throws(() => relayer.helperAddress(), MissingCredentialError);
});

/**
 * The load-bearing safety property, asserted structurally.
 *
 * `triggerClaim(vault, expectedTier?)` takes no recipient. If someone ever adds
 * one, this fails — because such a parameter would be a lie: the contract reads
 * the payee from storage (HeirloomVault.sol:253) and ignores anything a caller
 * passes. A destination argument in this layer could only mislead.
 */
test('triggerClaim exposes no destination parameter', () => {
  assert.equal(relayer.triggerClaim.length, 2, 'triggerClaim signature changed');
});

test('credentialStatus reports the relayer separately from Circle', () => {
  const s = credentialStatus();
  assert.equal(s.assistedClaimRelayer, false);
  assert.equal(s.circleWallets, false);
});
