// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {HeirloomTypes as T} from "../src/HeirloomTypes.sol";

/// @notice Social recovery (PRD §4 MUST-1): M-of-N guardians rotate vault control
///         to a NEW owner key. The lock changes, the house does not.
///
///         INVARIANT 3 — guardians can only PROPOSE key rotation. They can never
///         move funds. Every fund-moving entry point is probed against a guardian
///         caller, and the vault balance is asserted untouched across a full
///         successful rotation.
/// @dev UNAUDITED TESTNET CODE.
contract RecoveryTest is Base {
    address internal newKey = makeAddr("newOwnerKey");

    function _proposeAndApprove() internal returns (uint256 id) {
        vm.prank(g1);
        id = vault.proposeRotation(newKey);
        vm.prank(g2);
        vault.approveRotation(id);
    }

    // -----------------------------------------------------------------
    // Happy path — the key-loss story
    // -----------------------------------------------------------------

    function test_MofNRotationChangesOwnerOnly() public {
        uint256 balanceBefore = usdc.balanceOf(address(vault));
        uint256 id = _proposeAndApprove();

        vm.warp(block.timestamp + _timelock());
        vault.execute(id);

        assertEq(vault.owner(), newKey, "owner key did not rotate");
        assertEq(usdc.balanceOf(address(vault)), balanceBefore, "rotation moved funds");
        assertEq(usdc.balanceOf(newKey), 0, "rotation paid out to the new key");
    }

    function test_RotationEmitsOwnerRotated() public {
        uint256 id = _proposeAndApprove();
        vm.warp(block.timestamp + _timelock());

        vm.expectEmit(true, true, true, true);
        emit T.OwnerRotated(owner, newKey);
        vault.execute(id);
    }

    /// @notice After rotation the vault must be fully live again under the new
    ///         key — otherwise recovering once would permanently disarm the
    ///         safety net. See docs/OPEN-QUESTIONS.md Q8.
    function test_RotationReArmsTheLadder() public {
        _silenceFor(CARE); // let the ladder climb first
        uint256 id = _proposeAndApprove();
        vm.warp(block.timestamp + _timelock());
        vault.execute(id);

        _assertState(T.VaultState.Active);
        assertEq(vault.lastActivity(), uint64(block.timestamp), "ladder did not re-arm on rotation");
    }

    /// @notice The rotated-in key is a real owner: it can heartbeat and veto.
    function test_NewOwnerHasFullControl() public {
        uint256 id = _proposeAndApprove();
        vm.warp(block.timestamp + _timelock());
        vault.execute(id);

        vm.prank(newKey);
        vault.heartbeat();

        vm.prank(owner);
        vm.expectRevert(T.NotOwner.selector);
        vault.heartbeat();
    }

    /// @notice Rotation works even from deep in the ladder — that is the whole
    ///         point when the owner is genuinely gone.
    function test_RotationWorksFromClaimableState() public {
        _enterClaimable();
        _assertState(T.VaultState.Claimable);

        uint256 id = _proposeAndApprove();
        vm.warp(block.timestamp + _timelock());
        vault.execute(id);

        assertEq(vault.owner(), newKey);
        assertEq(usdc.balanceOf(address(vault)), FUNDED, "funds moved during recovery");
    }

    // -----------------------------------------------------------------
    // M-of-N threshold
    // -----------------------------------------------------------------

    function test_SingleGuardianCannotReachThreshold() public {
        vm.prank(g1);
        uint256 id = vault.proposeRotation(newKey);

        vm.warp(block.timestamp + _timelock());
        vm.expectRevert(abi.encodeWithSelector(T.NotEnoughApprovals.selector, 1, 2));
        vault.execute(id);

        assertEq(vault.owner(), owner, "rotation executed below threshold");
    }

    function test_ProposerCountsAsFirstApproval() public {
        vm.prank(g1);
        uint256 id = vault.proposeRotation(newKey);
        assertEq(vault.rotationApprovals(id), 1, "proposer did not count as an approver");
    }

    function test_GuardianCannotApproveTwice() public {
        vm.prank(g1);
        uint256 id = vault.proposeRotation(newKey);

        vm.prank(g1);
        vm.expectRevert(abi.encodeWithSelector(T.AlreadyApproved.selector, g1));
        vault.approveRotation(id);
    }

    function test_NonGuardianCannotPropose() public {
        vm.prank(stranger);
        vm.expectRevert(T.NotGuardian.selector);
        vault.proposeRotation(newKey);
    }

    function test_NonGuardianCannotApprove() public {
        vm.prank(g1);
        uint256 id = vault.proposeRotation(newKey);

        vm.prank(stranger);
        vm.expectRevert(T.NotGuardian.selector);
        vault.approveRotation(id);
    }

    function test_CannotRotateToZeroAddress() public {
        vm.prank(g1);
        vm.expectRevert(T.ZeroAddress.selector);
        vault.proposeRotation(address(0));
    }

    /// @notice Approvals may accrue during the timelock, not only before it.
    function test_ApprovalsCanAccrueDuringTimelock() public {
        vm.prank(g1);
        uint256 id = vault.proposeRotation(newKey);

        vm.warp(block.timestamp + 3 days);
        vm.prank(g3);
        vault.approveRotation(id);

        vm.warp(block.timestamp + _timelock());
        vault.execute(id);
        assertEq(vault.owner(), newKey);
    }

    // -----------------------------------------------------------------
    // PRD §6 — "Malicious guardians rotate ownership"
    // Defence: M-of-N threshold + timelock + old-key veto.
    // -----------------------------------------------------------------

    function test_Attack_MaliciousGuardiansDefeatedByOwnerVeto() public {
        uint256 id = _proposeAndApprove(); // two colluding guardians reach 2-of-3

        // The owner is alive and sees the queued proposal.
        vm.prank(owner);
        vault.veto(id);

        vm.warp(block.timestamp + _timelock() + 365 days);
        vm.expectRevert(abi.encodeWithSelector(T.ProposalDead.selector, id));
        vault.execute(id);

        assertEq(vault.owner(), owner, "malicious guardians captured the vault");
        assertEq(usdc.balanceOf(address(vault)), FUNDED, "funds moved during a vetoed rotation");
    }

    /// @notice Even all three guardians colluding cannot beat the veto.
    function test_Attack_UnanimousGuardianCollusionStillVetoable() public {
        vm.prank(g1);
        uint256 id = vault.proposeRotation(newKey);
        vm.prank(g2);
        vault.approveRotation(id);
        vm.prank(g3);
        vault.approveRotation(id);
        assertEq(vault.rotationApprovals(id), 3);

        vm.prank(owner);
        vault.veto(id);

        vm.warp(block.timestamp + _timelock());
        vm.expectRevert(abi.encodeWithSelector(T.ProposalDead.selector, id));
        vault.execute(id);
        assertEq(vault.owner(), owner);
    }

    /// @notice Guardians must not be able to rush the rotation through.
    function test_Attack_GuardiansCannotBypassTimelock() public {
        uint256 id = _proposeAndApprove();

        vm.prank(g1);
        vm.expectRevert();
        vault.execute(id);

        assertEq(vault.owner(), owner, "guardians bypassed the timelock");
    }

    // -----------------------------------------------------------------
    // PRD §6 — "Thief with owner key redirects heirs"
    // Defence: 7-day config timelock + notification + owner veto.
    // -----------------------------------------------------------------

    /// @notice A stolen device means thief and owner hold the SAME key, so the
    ///         thief can propose. What saves the owner is that the change is
    ///         announced and delayed, and the owner can cancel it.
    function test_Attack_StolenKeyRedirectingHeirsIsVetoable() public {
        T.Beneficiary[] memory evil = new T.Beneficiary[](2);
        evil[0] = T.Beneficiary({payee: thief, window: 10});
        evil[1] = T.Beneficiary({payee: thief, window: 0});

        // The thief, holding the stolen key, queues a redirect.
        vm.prank(owner);
        uint256 id = vault.proposeBeneficiaries(evil);

        // The real owner is notified by the ProposalQueued event and cancels.
        vm.prank(owner);
        vault.veto(id);

        vm.warp(block.timestamp + _timelock() + 30 days);
        vm.expectRevert(abi.encodeWithSelector(T.ProposalDead.selector, id));
        vault.execute(id);

        (address payee0,) = vault.beneficiaries(0);
        assertEq(payee0, coldBackup, "thief redirected the safety net");
    }

    /// @notice The redirect cannot land instantly — the delay is what creates the
    ///         window in which the owner can notice at all.
    function test_Attack_StolenKeyCannotRedirectInstantly() public {
        T.Beneficiary[] memory evil = new T.Beneficiary[](1);
        evil[0] = T.Beneficiary({payee: thief, window: 0});

        vm.prank(owner);
        uint256 id = vault.proposeBeneficiaries(evil);

        vm.warp(block.timestamp + _timelock() - 1);
        vm.expectRevert();
        vault.execute(id);

        (address payee0,) = vault.beneficiaries(0);
        assertEq(payee0, coldBackup, "heirs changed inside the veto window");
    }

    // -----------------------------------------------------------------
    // INVARIANT 3 — guardians can NEVER move funds
    // -----------------------------------------------------------------

    /// @notice Probe every value-moving entry point with a guardian caller.
    function test_Invariant3_GuardiansCannotMoveFunds() public {
        _enterClaimable(); // most permissive state for claims
        uint256 before = usdc.balanceOf(address(vault));

        address[3] memory guardians = [g1, g2, g3];
        for (uint256 i = 0; i < guardians.length; i++) {
            vm.startPrank(guardians[i]);

            vm.expectRevert();
            vault.withdraw(1e6);

            vm.expectRevert();
            vault.claim(0);

            vm.expectRevert();
            vault.careSpend(guardians[i], CAT_BILLS, 1e6);

            vm.stopPrank();
        }

        assertEq(usdc.balanceOf(address(vault)), before, "a guardian moved funds");
        assertEq(usdc.balanceOf(g1) + usdc.balanceOf(g2) + usdc.balanceOf(g3), 0, "a guardian received funds");
    }

    /// @notice A guardian cannot rotate the vault to themselves and then drain it
    ///         inside the same flow — and if they did rotate, the veto is the
    ///         defence, not the absence of the capability. This asserts the
    ///         balance is untouched throughout the entire rotation lifecycle.
    function test_Invariant3_FundsUntouchedAcrossEntireRotationLifecycle() public {
        uint256 before = usdc.balanceOf(address(vault));

        vm.prank(g1);
        uint256 id = vault.proposeRotation(g1); // guardian rotates to self
        assertEq(usdc.balanceOf(address(vault)), before, "propose moved funds");

        vm.prank(g2);
        vault.approveRotation(id);
        assertEq(usdc.balanceOf(address(vault)), before, "approve moved funds");

        vm.warp(block.timestamp + _timelock());
        vault.execute(id);
        assertEq(usdc.balanceOf(address(vault)), before, "execute moved funds");
        assertEq(usdc.balanceOf(g1), 0, "guardian was paid by the rotation");
    }

    /// @notice Guardians have no say over configuration — only rotation.
    function test_Invariant3_GuardiansCannotProposeConfigChanges() public {
        T.Beneficiary[] memory evil = new T.Beneficiary[](1);
        evil[0] = T.Beneficiary({payee: g1, window: 0});

        vm.startPrank(g1);
        vm.expectRevert(T.NotOwner.selector);
        vault.proposeBeneficiaries(evil);

        vm.expectRevert(T.NotOwner.selector);
        vault.proposeLadder(T.LadderConfig(1, 2, 3, 4));

        vm.expectRevert(T.NotOwner.selector);
        vault.veto(0);
        vm.stopPrank();
    }
}
