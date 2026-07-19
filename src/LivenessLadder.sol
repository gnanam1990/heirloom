// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HeirloomTypes as T} from "./HeirloomTypes.sol";

/// @title LivenessLadder
/// @notice The one primitive the whole product rests on (PRD §2): how long the
///         owner has been silent, expressed as a rung on an escalating ladder.
/// @dev UNAUDITED TESTNET CODE — do not use with real funds.
///
///      Deliberately a `pure` library over `(lastActivity, now, config)`. No
///      storage, no keeper, no cron. Three consequences the product needs:
///        1. Nobody has to "advance" the ladder — escalation cannot be stalled
///           by an absent guardian, a dead relayer, or an unpaid keeper.
///        2. Any owner signature resets it by stamping `lastActivity = now`;
///           there is no other state to unwind (INVARIANT 1).
///        3. It is trivially fuzzable, which is how we prove the above.
///
///      Arc: block timestamps are non-decreasing, not strictly increasing. Every
///      boundary below is INCLUSIVE (`>=`), so a rung is entered the moment the
///      threshold is met and repeated timestamps are idempotent rather than
///      skipping a tier.
library LivenessLadder {
    /// @notice The rung the vault sits on given how long the owner has been quiet.
    /// @dev Returns only non-terminal rungs — `Claimed` and `Recovered` are
    ///      lifecycle facts the vault overlays, never something time alone causes.
    /// @param lastActivity Timestamp of the last owner signature.
    /// @param nowTs        Evaluation time (`block.timestamp` in production).
    /// @param cfg          Tier thresholds; assumed already `validate`d.
    function stateAt(uint64 lastActivity, uint64 nowTs, T.LadderConfig memory cfg)
        internal
        pure
        returns (T.VaultState)
    {
        // Defensive: a non-advancing or backwards clock reads as "present".
        // On Arc equal timestamps are normal, so this branch is load-bearing,
        // not paranoia — and it makes the subtraction below underflow-free.
        if (nowTs <= lastActivity) return T.VaultState.Active;

        uint256 elapsed = uint256(nowTs) - uint256(lastActivity);

        // Checked high-to-low so the deepest satisfied rung wins.
        if (elapsed >= cfg.claimableAfter) return T.VaultState.Claimable;
        if (elapsed >= cfg.careModeAfter) return T.VaultState.CareMode;
        if (elapsed >= cfg.guardianAlertAfter) return T.VaultState.GuardianAlert;
        if (elapsed >= cfg.nagAfter) return T.VaultState.Nagging;
        return T.VaultState.Active;
    }

    /// @notice Seconds of silence remaining before the next rung, or 0 if the
    ///         ladder has topped out. Read-only convenience for the reminder
    ///         pipeline — the chain stays the source of truth (PRD §5).
    function secondsUntilNextRung(uint64 lastActivity, uint64 nowTs, T.LadderConfig memory cfg)
        internal
        pure
        returns (uint256)
    {
        uint256 elapsed = nowTs <= lastActivity ? 0 : uint256(nowTs) - uint256(lastActivity);

        if (elapsed < cfg.nagAfter) return cfg.nagAfter - elapsed;
        if (elapsed < cfg.guardianAlertAfter) return cfg.guardianAlertAfter - elapsed;
        if (elapsed < cfg.careModeAfter) return cfg.careModeAfter - elapsed;
        if (elapsed < cfg.claimableAfter) return cfg.claimableAfter - elapsed;
        return 0;
    }

    /// @notice Rejects a ladder whose rungs are not strictly increasing.
    /// @dev A non-monotonic config would make a tier unreachable — e.g. care mode
    ///      set later than claimable means care mode never fires. Strictness also
    ///      guarantees `stateAt` is monotonic in elapsed time, which the fuzz
    ///      suite asserts. A zero first rung is rejected too: it would put a
    ///      freshly-active vault on the Nagging rung immediately.
    function validate(T.LadderConfig memory cfg) internal pure {
        if (
            cfg.nagAfter == 0 || cfg.guardianAlertAfter <= cfg.nagAfter
                || cfg.careModeAfter <= cfg.guardianAlertAfter || cfg.claimableAfter <= cfg.careModeAfter
        ) {
            revert T.LadderNotMonotonic();
        }
    }
}
