/**
 * Off-chain mirror of the on-chain liveness ladder.
 *
 * Ported from src/LivenessLadder.sol:30-48 and HeirloomVault.sol:145-148.
 * Line citations are exact as of the deployed build; if the contract changes,
 * change this and the citation together or the service will quietly disagree
 * with the chain.
 *
 * This exists so the API and the reminder pipeline can answer "what rung is
 * this vault on, and when does it move" WITHOUT an RPC round trip per query.
 * The chain stays the source of truth: `state()` is read on refresh, and this
 * only ever projects forward from `(lastActivity, ladder)`.
 */

export enum VaultState {
  Active = 0,
  Nagging = 1,
  GuardianAlert = 2,
  CareMode = 3,
  Claimable = 4,
  Claimed = 5,
  Recovered = 6,
}

export const STATE_NAMES: Record<VaultState, string> = {
  [VaultState.Active]: 'Active',
  [VaultState.Nagging]: 'Nagging',
  [VaultState.GuardianAlert]: 'GuardianAlert',
  [VaultState.CareMode]: 'CareMode',
  [VaultState.Claimable]: 'Claimable',
  [VaultState.Claimed]: 'Claimed',
  [VaultState.Recovered]: 'Recovered',
};

export interface LadderConfig {
  nagAfter: bigint;
  guardianAlertAfter: bigint;
  careModeAfter: bigint;
  claimableAfter: bigint;
}

/**
 * Port of LivenessLadder.stateAt — src/LivenessLadder.sol:30-48.
 *
 * Boundaries are INCLUSIVE (`>=`), matching the contract, because Arc block
 * timestamps are non-decreasing rather than strictly increasing: two blocks can
 * share a timestamp, and a rung must be entered the moment its threshold is met.
 */
export function stateAt(
  lastActivity: bigint,
  now: bigint,
  cfg: LadderConfig,
): VaultState {
  // :38 — a non-advancing or backwards clock reads as "present".
  if (now <= lastActivity) return VaultState.Active;

  const elapsed = now - lastActivity; // :40

  // Checked high-to-low so the deepest satisfied rung wins.
  if (elapsed >= cfg.claimableAfter) return VaultState.Claimable; // :43
  if (elapsed >= cfg.careModeAfter) return VaultState.CareMode; // :44
  if (elapsed >= cfg.guardianAlertAfter) return VaultState.GuardianAlert; // :45
  if (elapsed >= cfg.nagAfter) return VaultState.Nagging; // :46
  return VaultState.Active; // :47
}

/**
 * Vault-level state — HeirloomVault.sol:145-148.
 * `Claimed` is the one lifecycle fact that overrides the clock.
 */
export function vaultState(
  isClaimed: boolean,
  lastActivity: bigint,
  now: bigint,
  cfg: LadderConfig,
): VaultState {
  if (isClaimed) return VaultState.Claimed;
  return stateAt(lastActivity, now, cfg);
}

/** Port of LivenessLadder.secondsUntilNextRung — src/LivenessLadder.sol:53-65. */
export function secondsUntilNextRung(
  lastActivity: bigint,
  now: bigint,
  cfg: LadderConfig,
): bigint {
  const elapsed = now <= lastActivity ? 0n : now - lastActivity;
  if (elapsed < cfg.nagAfter) return cfg.nagAfter - elapsed;
  if (elapsed < cfg.guardianAlertAfter) return cfg.guardianAlertAfter - elapsed;
  if (elapsed < cfg.careModeAfter) return cfg.careModeAfter - elapsed;
  if (elapsed < cfg.claimableAfter) return cfg.claimableAfter - elapsed;
  return 0n;
}

/** The rung after the current one, or null once the ladder has topped out. */
export function nextRung(
  lastActivity: bigint,
  now: bigint,
  cfg: LadderConfig,
): VaultState | null {
  const s = stateAt(lastActivity, now, cfg);
  if (s >= VaultState.Claimable) return null;
  return (s + 1) as VaultState;
}

/** Absolute timestamp at which a given rung is entered. */
export function rungEntersAt(
  lastActivity: bigint,
  rung: VaultState,
  cfg: LadderConfig,
): bigint | null {
  switch (rung) {
    case VaultState.Nagging:
      return lastActivity + cfg.nagAfter;
    case VaultState.GuardianAlert:
      return lastActivity + cfg.guardianAlertAfter;
    case VaultState.CareMode:
      return lastActivity + cfg.careModeAfter;
    case VaultState.Claimable:
      return lastActivity + cfg.claimableAfter;
    default:
      return null;
  }
}

export function formatDuration(seconds: bigint): string {
  const s = seconds < 0n ? 0n : seconds;
  const d = s / 86400n;
  if (d > 0n) return `${d} day${d === 1n ? '' : 's'}`;
  const h = s / 3600n;
  if (h > 0n) return `${h} hour${h === 1n ? '' : 's'}`;
  const m = s / 60n;
  if (m > 0n) return `${m} minute${m === 1n ? '' : 's'}`;
  return `${s} second${s === 1n ? '' : 's'}`;
}

/** USDC is 6dp on Arc's ERC-20 surface. No floats on a money path. */
export function formatUsdc(units: bigint): string {
  const neg = units < 0n;
  const v = neg ? -units : units;
  const whole = v / 1_000_000n;
  const frac = (v % 1_000_000n).toString().padStart(6, '0');
  return `${neg ? '-' : ''}${whole.toLocaleString('en-US')}.${frac}`;
}
