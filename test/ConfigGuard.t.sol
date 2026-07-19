// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConfigGuard} from "../src/ConfigGuard.sol";
import {HeirloomTypes as T} from "../src/HeirloomTypes.sol";

/// @notice Minimal concrete ConfigGuard so the timelock machinery can be tested
///         in isolation from the vault. `guardedValue` stands in for any piece
///         of config (heirs, guardians, timings) — the point is that NOTHING can
///         change it except a ripe, un-vetoed proposal.
contract GuardHarness is ConfigGuard {
    bytes32 internal constant KIND_SET = keccak256("SET_VALUE");

    uint256 public guardedValue;
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function _configOwner() internal view override returns (address) {
        return owner;
    }

    function _applyProposal(uint256, bytes32 kind, bytes memory data) internal override {
        if (kind == KIND_SET) {
            guardedValue = abi.decode(data, (uint256));
        }
    }

    /// @dev The ONLY way to alter `guardedValue`. Note it merely queues.
    function proposeValue(uint256 v) external returns (uint256) {
        if (msg.sender != owner) revert T.NotOwner();
        return _queue(KIND_SET, abi.encode(v), msg.sender);
    }
}

/// @notice INVARIANT 2 — every config mutation routes propose → 7-day timelock →
///         execute, with an event on propose and owner veto available at ANY
///         point before execute. No direct setters, ever.
/// @dev This is the load-bearing anti-theft property (PRD §2): a thief holding
///      the owner key cannot silently redirect the safety net, because every
///      change is announced and the real owner has a week to cancel.
/// @dev UNAUDITED TESTNET CODE.
contract ConfigGuardTest is Test {
    GuardHarness internal guard;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    uint64 internal constant TIMELOCK = 7 days;

    function setUp() public {
        vm.warp(1_000_000); // avoid timestamp 0 edge cases
        guard = new GuardHarness(owner);
    }

    function _propose(uint256 v) internal returns (uint256 id) {
        vm.prank(owner);
        id = guard.proposeValue(v);
    }

    // -----------------------------------------------------------------
    // propose → event + eta
    // -----------------------------------------------------------------

    function test_ProposeEmitsEventWithSevenDayEta() public {
        uint64 expectedEta = uint64(block.timestamp) + TIMELOCK;

        vm.expectEmit(true, true, true, true);
        emit T.ProposalQueued(0, keccak256("SET_VALUE"), owner, expectedEta, abi.encode(uint256(42)));

        vm.prank(owner);
        guard.proposeValue(42);

        (,, uint64 eta,,,) = guard.proposals(0);
        assertEq(eta, expectedEta, "timelock is not exactly 7 days");
    }

    function test_ProposeDoesNotMutateAnything() public {
        _propose(42);
        assertEq(guard.guardedValue(), 0, "propose mutated config immediately");
    }

    function test_TimelockIsSevenDays() public view {
        assertEq(guard.TIMELOCK(), TIMELOCK);
    }

    // -----------------------------------------------------------------
    // The delay is real
    // -----------------------------------------------------------------

    function test_CannotExecuteBeforeEta() public {
        uint256 id = _propose(42);
        vm.warp(block.timestamp + TIMELOCK - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                T.ProposalNotRipe.selector, id, uint64(block.timestamp + 1), uint64(block.timestamp)
            )
        );
        guard.execute(id);
        assertEq(guard.guardedValue(), 0);
    }

    /// @dev Arc: timestamps are non-decreasing, so a block can land exactly ON
    ///      the eta. Ripeness must be inclusive or such a block would stall.
    function test_ExecutesAtExactlyEta() public {
        uint256 id = _propose(42);
        vm.warp(block.timestamp + TIMELOCK);

        guard.execute(id);
        assertEq(guard.guardedValue(), 42, "inclusive eta boundary not honoured");
    }

    function test_ExecutesAfterEta() public {
        uint256 id = _propose(42);
        vm.warp(block.timestamp + TIMELOCK + 1 days);
        guard.execute(id);
        assertEq(guard.guardedValue(), 42);
    }

    /// @notice Any delay short of the full week must fail; the full week must work.
    function testFuzz_Invariant2_DelayIsAlwaysEnforced(uint256 wait) public {
        wait = bound(wait, 0, 30 days);
        uint256 id = _propose(7);
        uint256 start = block.timestamp;
        vm.warp(start + wait);

        if (wait < TIMELOCK) {
            vm.expectRevert();
            guard.execute(id);
            assertEq(guard.guardedValue(), 0, "config changed before the timelock elapsed");
        } else {
            guard.execute(id);
            assertEq(guard.guardedValue(), 7);
        }
    }

    // -----------------------------------------------------------------
    // Veto — available at ANY point before execute
    // -----------------------------------------------------------------

    function test_OwnerCanVetoBeforeEta() public {
        uint256 id = _propose(42);
        vm.warp(block.timestamp + 3 days);

        vm.prank(owner);
        guard.veto(id);

        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(T.ProposalDead.selector, id));
        guard.execute(id);
        assertEq(guard.guardedValue(), 0, "vetoed proposal still mutated config");
    }

    /// @notice "At any point before execute" includes AFTER the timelock has
    ///         elapsed — a ripe-but-unexecuted proposal is still vetoable. An
    ///         owner who returns from a trek on day 8 must still be protected.
    function test_OwnerCanVetoAfterEtaButBeforeExecute() public {
        uint256 id = _propose(42);
        vm.warp(block.timestamp + TIMELOCK + 30 days);

        vm.prank(owner);
        guard.veto(id);

        vm.expectRevert(abi.encodeWithSelector(T.ProposalDead.selector, id));
        guard.execute(id);
        assertEq(guard.guardedValue(), 0);
    }

    /// @notice Fuzz the veto moment across the whole pre-execute lifetime.
    function testFuzz_Invariant2_VetoWorksAtAnyMomentBeforeExecute(uint256 vetoAt) public {
        vetoAt = bound(vetoAt, 0, 365 days);
        uint256 id = _propose(42);
        vm.warp(block.timestamp + vetoAt);

        vm.prank(owner);
        guard.veto(id);

        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(abi.encodeWithSelector(T.ProposalDead.selector, id));
        guard.execute(id);
        assertEq(guard.guardedValue(), 0, "veto failed to kill the proposal");
    }

    function test_VetoEmitsEvent() public {
        uint256 id = _propose(42);
        vm.expectEmit(true, true, true, true);
        emit T.ProposalVetoed(id, keccak256("SET_VALUE"), owner);
        vm.prank(owner);
        guard.veto(id);
    }

    function test_StrangerCannotVeto() public {
        uint256 id = _propose(42);
        vm.prank(stranger);
        vm.expectRevert(T.NotOwner.selector);
        guard.veto(id);
    }

    function test_CannotVetoAfterExecute() public {
        uint256 id = _propose(42);
        vm.warp(block.timestamp + TIMELOCK);
        guard.execute(id);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(T.ProposalDead.selector, id));
        guard.veto(id);
    }

    // -----------------------------------------------------------------
    // Replay / lifecycle hygiene
    // -----------------------------------------------------------------

    function test_CannotExecuteTwice() public {
        uint256 id = _propose(42);
        vm.warp(block.timestamp + TIMELOCK);
        guard.execute(id);

        vm.expectRevert(abi.encodeWithSelector(T.ProposalDead.selector, id));
        guard.execute(id);
    }

    function test_CannotExecuteUnknownProposal() public {
        vm.expectRevert(abi.encodeWithSelector(T.ProposalMissing.selector, uint256(99)));
        guard.execute(99);
    }

    function test_ExecuteEmitsEvent() public {
        uint256 id = _propose(42);
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectEmit(true, true, true, true);
        emit T.ProposalExecuted(id, keccak256("SET_VALUE"));
        guard.execute(id);
    }

    /// @notice Proposals are independent — vetoing one must not disturb another.
    function test_ProposalsAreIndependent() public {
        uint256 a = _propose(1);
        uint256 b = _propose(2);
        assertTrue(a != b, "proposal ids collided");

        vm.prank(owner);
        guard.veto(a);

        vm.warp(block.timestamp + TIMELOCK);
        guard.execute(b);
        assertEq(guard.guardedValue(), 2);
    }

    // -----------------------------------------------------------------
    // "No direct setters, ever"
    // -----------------------------------------------------------------

    /// @notice The guarded value must be unreachable except through a ripe
    ///         proposal. If a direct setter is ever added, this fails.
    function test_Invariant2_NoDirectSetterExists() public {
        string[6] memory candidates = [
            "setValue(uint256)",
            "setGuardedValue(uint256)",
            "updateValue(uint256)",
            "forceSet(uint256)",
            "emergencySet(uint256)",
            "applyProposal(bytes32,bytes)"
        ];

        for (uint256 i = 0; i < candidates.length; i++) {
            (bool ok,) = address(guard).call(abi.encodeWithSignature(candidates[i], uint256(1337)));
            assertFalse(ok, string.concat("a direct setter is reachable: ", candidates[i]));
        }
        assertEq(guard.guardedValue(), 0, "config mutated without a proposal");
    }

    /// @notice Even the owner cannot shortcut the delay.
    function test_Invariant2_OwnerCannotBypassTimelock() public {
        uint256 id = _propose(42);
        vm.prank(owner);
        vm.expectRevert();
        guard.execute(id);
        assertEq(guard.guardedValue(), 0, "owner bypassed the timelock");
    }
}
