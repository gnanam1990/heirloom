/**
 * The off-chain ladder mirror must agree with src/LivenessLadder.sol exactly.
 * These reuse the same boundary cases as the Foundry suite
 * (test/LivenessLadder.t.sol), so a drift shows up here too.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  VaultState,
  stateAt,
  vaultState,
  secondsUntilNextRung,
  nextRung,
  rungEntersAt,
  formatUsdc,
  formatDuration,
  type LadderConfig,
} from '../src/ladder.js';

// Seconds-scale mirror of the production 90/180/270/365-day ladder, matching
// the Foundry fixture.
const cfg: LadderConfig = {
  nagAfter: 90n,
  guardianAlertAfter: 180n,
  careModeAfter: 270n,
  claimableAfter: 365n,
};

// The real production ladder, as deployed.
const prod: LadderConfig = {
  nagAfter: 7_776_000n,
  guardianAlertAfter: 15_552_000n,
  careModeAfter: 23_328_000n,
  claimableAfter: 31_536_000n,
};

test('boundaries are inclusive, matching the contract', () => {
  const cases: Array<[bigint, VaultState]> = [
    [0n, VaultState.Active],
    [89n, VaultState.Active],
    [90n, VaultState.Nagging],
    [179n, VaultState.Nagging],
    [180n, VaultState.GuardianAlert],
    [269n, VaultState.GuardianAlert],
    [270n, VaultState.CareMode],
    [364n, VaultState.CareMode],
    [365n, VaultState.Claimable],
    [10_000n, VaultState.Claimable],
  ];
  for (const [elapsed, want] of cases) {
    assert.equal(stateAt(0n, elapsed, cfg), want, `elapsed ${elapsed}`);
  }
});

test('the deployed production ladder crosses at the right day counts', () => {
  const day = 86_400n;
  assert.equal(stateAt(0n, 89n * day, prod), VaultState.Active);
  assert.equal(stateAt(0n, 90n * day, prod), VaultState.Nagging);
  assert.equal(stateAt(0n, 180n * day, prod), VaultState.GuardianAlert);
  assert.equal(stateAt(0n, 270n * day, prod), VaultState.CareMode);
  assert.equal(stateAt(0n, 365n * day, prod), VaultState.Claimable);
});

test('equal timestamps are idempotent, never skipping a rung', () => {
  const last = 5_000n;
  const at = last + cfg.nagAfter;
  assert.equal(stateAt(last, at, cfg), stateAt(last, at, cfg));
  assert.equal(stateAt(last, at, cfg), VaultState.Nagging);
});

test('a non-advancing or backwards clock reads as Active', () => {
  assert.equal(stateAt(1000n, 1000n, cfg), VaultState.Active);
  assert.equal(stateAt(1000n, 999n, cfg), VaultState.Active);
  assert.equal(stateAt(1000n, 0n, cfg), VaultState.Active);
});

test('INVARIANT 1: a heartbeat resets to Active from every rung', () => {
  for (const elapsed of [0n, 90n, 180n, 270n, 365n, 99_999n]) {
    const at = 1_000n + elapsed;
    // heartbeat stamps lastActivity = now
    assert.equal(stateAt(at, at, cfg), VaultState.Active, `from elapsed ${elapsed}`);
  }
});

test('state is monotonic in elapsed time', () => {
  let prev = -1;
  for (let e = 0n; e <= 400n; e += 7n) {
    const s = stateAt(0n, e, cfg);
    assert.ok(s >= prev, `regressed at elapsed ${e}`);
    prev = s;
  }
});

test('only the difference matters, not absolute time', () => {
  assert.equal(stateAt(0n, 200n, cfg), stateAt(1_000_000n, 1_000_200n, cfg));
});

test('Claimed overlays the clock and is absorbing', () => {
  assert.equal(vaultState(true, 0n, 0n, cfg), VaultState.Claimed);
  assert.equal(vaultState(true, 0n, 999_999n, cfg), VaultState.Claimed);
  assert.equal(vaultState(false, 0n, 999_999n, cfg), VaultState.Claimable);
});

test('time alone never produces a terminal state', () => {
  for (let e = 0n; e <= 5_000n; e += 137n) {
    assert.ok(stateAt(0n, e, cfg) <= VaultState.Claimable);
  }
});

test('secondsUntilNextRung counts down to each boundary and then zero', () => {
  assert.equal(secondsUntilNextRung(0n, 0n, cfg), 90n);
  assert.equal(secondsUntilNextRung(0n, 89n, cfg), 1n);
  assert.equal(secondsUntilNextRung(0n, 90n, cfg), 90n); // now heading to 180
  assert.equal(secondsUntilNextRung(0n, 364n, cfg), 1n);
  assert.equal(secondsUntilNextRung(0n, 365n, cfg), 0n);
  assert.equal(secondsUntilNextRung(0n, 99_999n, cfg), 0n);
});

test('nextRung walks up and stops at Claimable', () => {
  assert.equal(nextRung(0n, 0n, cfg), VaultState.Nagging);
  assert.equal(nextRung(0n, 90n, cfg), VaultState.GuardianAlert);
  assert.equal(nextRung(0n, 270n, cfg), VaultState.Claimable);
  assert.equal(nextRung(0n, 365n, cfg), null);
});

test('rungEntersAt is the inverse of the boundary check', () => {
  const last = 1_000n;
  for (const rung of [
    VaultState.Nagging,
    VaultState.GuardianAlert,
    VaultState.CareMode,
    VaultState.Claimable,
  ]) {
    const at = rungEntersAt(last, rung, cfg);
    assert.ok(at !== null);
    assert.equal(stateAt(last, at!, cfg), rung, `rung ${rung}`);
    assert.ok(stateAt(last, at! - 1n, cfg) < rung, `rung ${rung} entered early`);
  }
});

test('USDC formatting is 6dp and never uses floats', () => {
  assert.equal(formatUsdc(0n), '0.000000');
  assert.equal(formatUsdc(1n), '0.000001');
  assert.equal(formatUsdc(1_000_000n), '1.000000');
  assert.equal(formatUsdc(5_000_000n), '5.000000');
  assert.equal(formatUsdc(2_098_566n), '2.098566');
  assert.equal(formatUsdc(25_000_000_000n), '25,000.000000');
  // a value that a float would round wrong
  assert.equal(formatUsdc(9_007_199_254_740_993n), '9,007,199,254.740993');
});

test('durations read naturally', () => {
  assert.equal(formatDuration(0n), '0 seconds');
  assert.equal(formatDuration(1n), '1 second');
  assert.equal(formatDuration(90n), '1 minute');
  assert.equal(formatDuration(7_200n), '2 hours');
  assert.equal(formatDuration(86_400n), '1 day');
  assert.equal(formatDuration(7_776_000n), '90 days');
});
