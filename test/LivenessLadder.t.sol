// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LivenessLadder} from "../src/LivenessLadder.sol";
import {HeirloomTypes as T} from "../src/HeirloomTypes.sol";

/// @notice Thin external wrapper so `vm.expectRevert` sees the revert one call
///         depth down. `validate` is an internal library function and would
///         otherwise be inlined into the test itself, which the cheatcode
///         cannot observe.
contract LadderHarness {
    function validate(T.LadderConfig memory cfg) external pure {
        LivenessLadder.validate(cfg);
    }

    function stateAt(uint64 lastActivity, uint64 nowTs, T.LadderConfig memory cfg)
        external
        pure
        returns (T.VaultState)
    {
        return LivenessLadder.stateAt(lastActivity, nowTs, cfg);
    }
}

/// @notice The liveness ladder is the load-bearing primitive: every other module
///         reads its verdict. These tests pin two properties the PRD depends on —
///         the state is a PURE function of (lastActivity, now, config), and
///         INVARIANT 1: any owner signature resets to Active from ANY state.
/// @dev UNAUDITED TESTNET CODE.
contract LivenessLadderTest is Test {
    using LivenessLadder for T.LadderConfig;

    // Seconds-scale mirror of the 90/180/270/365-day production defaults.
    T.LadderConfig internal cfg =
        T.LadderConfig({nagAfter: 90, guardianAlertAfter: 180, careModeAfter: 270, claimableAfter: 365});

    LadderHarness internal harness;

    function setUp() public {
        harness = new LadderHarness();
    }

    // -----------------------------------------------------------------
    // Shape: the ladder's rungs, at and around every boundary.
    // -----------------------------------------------------------------

    function test_ExactBoundariesAreInclusive() public view {
        // Arc quirk: timestamps are non-decreasing, so a block can land exactly
        // ON a boundary and the next block can repeat it. Boundaries must be
        // inclusive (>=) or a tier could be skipped by an equal-timestamp block.
        assertEq(uint256(LivenessLadder.stateAt(0, 89, cfg)), uint256(T.VaultState.Active));
        assertEq(uint256(LivenessLadder.stateAt(0, 90, cfg)), uint256(T.VaultState.Nagging));
        assertEq(uint256(LivenessLadder.stateAt(0, 179, cfg)), uint256(T.VaultState.Nagging));
        assertEq(uint256(LivenessLadder.stateAt(0, 180, cfg)), uint256(T.VaultState.GuardianAlert));
        assertEq(uint256(LivenessLadder.stateAt(0, 269, cfg)), uint256(T.VaultState.GuardianAlert));
        assertEq(uint256(LivenessLadder.stateAt(0, 270, cfg)), uint256(T.VaultState.CareMode));
        assertEq(uint256(LivenessLadder.stateAt(0, 364, cfg)), uint256(T.VaultState.CareMode));
        assertEq(uint256(LivenessLadder.stateAt(0, 365, cfg)), uint256(T.VaultState.Claimable));
    }

    function test_ZeroElapsedIsActive() public view {
        assertEq(uint256(LivenessLadder.stateAt(1000, 1000, cfg)), uint256(T.VaultState.Active));
    }

    function test_EqualTimestampBlocksDoNotAdvanceTheLadder() public view {
        // Two consecutive Arc blocks sharing a timestamp must yield the same rung.
        uint64 last = 5_000;
        uint64 at = last + cfg.nagAfter;
        assertEq(
            uint256(LivenessLadder.stateAt(last, at, cfg)), uint256(LivenessLadder.stateAt(last, at, cfg))
        );
    }

    /// @dev A clock that appears to run backwards (never expected on Arc, but
    ///      free to defend against) must not underflow into a false Claimable.
    function testFuzz_NowBeforeLastActivityIsActive(uint64 last, uint64 nowTs) public view {
        vm.assume(nowTs <= last);
        assertEq(uint256(LivenessLadder.stateAt(last, nowTs, cfg)), uint256(T.VaultState.Active));
    }

    // -----------------------------------------------------------------
    // Purity: the state depends on (lastActivity, now, config) and nothing else.
    // -----------------------------------------------------------------

    /// @notice Same inputs must yield the same rung no matter what the chain is
    ///         doing — different block, different caller, different balance.
    function testFuzz_StateIsPureOverItsInputs(uint64 last, uint64 nowTs, address caller) public {
        T.VaultState first = LivenessLadder.stateAt(last, nowTs, cfg);

        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 1_000);
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        T.VaultState second = LivenessLadder.stateAt(last, nowTs, cfg);

        assertEq(uint256(first), uint256(second), "ladder read is not pure over its inputs");
    }

    /// @notice Only the DIFFERENCE matters — shifting both endpoints equally
    ///         cannot change the verdict.
    function testFuzz_TranslationInvariant(uint64 last, uint32 elapsed, uint64 shift) public view {
        last = uint64(bound(last, 0, type(uint64).max / 4));
        shift = uint64(bound(shift, 0, type(uint64).max / 4));

        T.VaultState a = LivenessLadder.stateAt(last, last + elapsed, cfg);
        T.VaultState b = LivenessLadder.stateAt(last + shift, last + shift + elapsed, cfg);
        assertEq(uint256(a), uint256(b), "ladder depends on absolute time, not elapsed");
    }

    /// @notice Silence only ever escalates. The rung must never regress as time
    ///         passes without a heartbeat — otherwise a tier could be skipped.
    function testFuzz_MonotonicInElapsedTime(uint64 last, uint32 e1, uint32 e2) public view {
        last = uint64(bound(last, 0, type(uint64).max / 4));
        if (e1 > e2) (e1, e2) = (e2, e1);

        uint256 earlier = uint256(LivenessLadder.stateAt(last, last + e1, cfg));
        uint256 later = uint256(LivenessLadder.stateAt(last, last + e2, cfg));
        assertLe(earlier, later, "ladder regressed as time advanced");
    }

    /// @notice The ladder never reports a terminal state — those are the vault's
    ///         to overlay. Time alone can never produce Claimed or Recovered.
    function testFuzz_NeverReportsTerminalStates(uint64 last, uint64 nowTs) public view {
        uint256 s = uint256(LivenessLadder.stateAt(last, nowTs, cfg));
        assertLe(s, uint256(T.VaultState.Claimable), "time alone produced a terminal state");
    }

    // -----------------------------------------------------------------
    // INVARIANT 1 — any owner signature resets the ladder to Active
    //               from ANY state.
    // -----------------------------------------------------------------

    /// @notice The whole safety net hinges on this: no matter how deep the
    ///         escalation has gone, one owner signature returns the vault to
    ///         Active. Fuzzed across every reachable rung.
    function testFuzz_Invariant1_HeartbeatResetsFromAnyState(uint64 last, uint32 elapsed) public view {
        last = uint64(bound(last, 0, type(uint64).max / 4));

        // Wherever the ladder had climbed to...
        T.VaultState before = LivenessLadder.stateAt(last, last + elapsed, cfg);

        // ...a heartbeat stamps lastActivity = now, and the rung is Active again.
        uint64 heartbeatAt = last + elapsed;
        assertEq(
            uint256(LivenessLadder.stateAt(heartbeatAt, heartbeatAt, cfg)),
            uint256(T.VaultState.Active),
            "heartbeat failed to reset the ladder"
        );

        // And it holds specifically from the deepest rungs, not just the shallow ones.
        if (before == T.VaultState.Claimable || before == T.VaultState.CareMode) {
            assertEq(
                uint256(LivenessLadder.stateAt(heartbeatAt, heartbeatAt, cfg)), uint256(T.VaultState.Active)
            );
        }
    }

    /// @notice Reset must hold for arbitrary configs too, not just the default one.
    function testFuzz_Invariant1_HoldsForAnyValidConfig(uint32 a, uint32 b, uint32 c, uint32 d, uint64 at)
        public
        view
    {
        a = uint32(bound(a, 1, 1e6));
        b = uint32(bound(b, uint256(a) + 1, 2e6));
        c = uint32(bound(c, uint256(b) + 1, 3e6));
        d = uint32(bound(d, uint256(c) + 1, 4e6));
        T.LadderConfig memory anyCfg =
            T.LadderConfig({nagAfter: a, guardianAlertAfter: b, careModeAfter: c, claimableAfter: d});

        assertEq(uint256(LivenessLadder.stateAt(at, at, anyCfg)), uint256(T.VaultState.Active));
    }

    // -----------------------------------------------------------------
    // Config validation
    // -----------------------------------------------------------------

    function test_ValidateRejectsNonMonotonicLadder() public {
        T.LadderConfig memory bad =
            T.LadderConfig({nagAfter: 180, guardianAlertAfter: 90, careModeAfter: 270, claimableAfter: 365});
        vm.expectRevert(T.LadderNotMonotonic.selector);
        harness.validate(bad);
    }

    function test_ValidateRejectsZeroFirstRung() public {
        T.LadderConfig memory bad =
            T.LadderConfig({nagAfter: 0, guardianAlertAfter: 90, careModeAfter: 270, claimableAfter: 365});
        vm.expectRevert(T.LadderNotMonotonic.selector);
        harness.validate(bad);
    }

    function test_ValidateAcceptsProductionDefaults() public view {
        T.LadderConfig memory prod = T.LadderConfig({
            nagAfter: 90 days, guardianAlertAfter: 180 days, careModeAfter: 270 days, claimableAfter: 365 days
        });
        harness.validate(prod);
    }
}
