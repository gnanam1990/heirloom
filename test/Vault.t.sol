// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {HeirloomTypes as T} from "../src/HeirloomTypes.sol";
import {HeirloomVault} from "../src/HeirloomVault.sol";

/// @notice Vault-level behaviour: the ladder wired to real state, INVARIANT 1
///         end-to-end, and care mode (INVARIANT 5) — amount- and category-capped,
///         instantly revoked by any owner activity.
/// @dev UNAUDITED TESTNET CODE.
contract VaultTest is Base {
    // -----------------------------------------------------------------
    // Ladder, wired up
    // -----------------------------------------------------------------

    function test_FreshVaultIsActive() public view {
        _assertState(T.VaultState.Active);
    }

    function test_LadderClimbsThroughEveryRung() public {
        _silenceFor(NAG - 1);
        _assertState(T.VaultState.Active);
        _silenceFor(NAG);
        _assertState(T.VaultState.Nagging);
        _silenceFor(ALERT);
        _assertState(T.VaultState.GuardianAlert);
        _silenceFor(CARE);
        _assertState(T.VaultState.CareMode);
        _silenceFor(CLAIMABLE);
        _assertState(T.VaultState.Claimable);
    }

    // -----------------------------------------------------------------
    // INVARIANT 1 — any owner signature resets to Active from ANY state
    // -----------------------------------------------------------------

    function test_Invariant1_HeartbeatResetsFromEveryRung() public {
        uint32[5] memory rungs = [uint32(0), NAG, ALERT, CARE, CLAIMABLE];

        for (uint256 i = 0; i < rungs.length; i++) {
            _silenceFor(rungs[i]);
            vm.prank(owner);
            vault.heartbeat();
            _assertState(T.VaultState.Active);
        }
    }

    /// @notice Not just `heartbeat()` — ANY owner signature counts. A deposit, a
    ///         withdrawal, or a config proposal all prove the owner is present.
    function test_Invariant1_AnyOwnerActionCountsAsHeartbeat() public {
        // withdraw
        _silenceFor(CLAIMABLE);
        vm.prank(owner);
        vault.withdraw(1e6);
        _assertState(T.VaultState.Active);

        // deposit
        _silenceFor(CLAIMABLE);
        vm.startPrank(owner);
        usdc.approve(address(vault), 1e6);
        vault.deposit(1e6);
        vm.stopPrank();
        _assertState(T.VaultState.Active);

        // config proposal
        _silenceFor(CLAIMABLE);
        vm.prank(owner);
        vault.proposeLadder(T.LadderConfig(NAG, ALERT, CARE, CLAIMABLE));
        _assertState(T.VaultState.Active);

        // veto
        _silenceFor(CLAIMABLE);
        vm.prank(owner);
        vault.veto(0);
        _assertState(T.VaultState.Active);
    }

    function testFuzz_Invariant1_ResetsFromArbitrarySilence(uint32 silence) public {
        _silenceFor(silence);
        vm.prank(owner);
        vault.heartbeat();
        _assertState(T.VaultState.Active);
        assertEq(vault.lastActivity(), uint64(block.timestamp));
    }

    function test_HeartbeatEmitsEventWithOriginRung() public {
        _silenceFor(CARE);
        vm.expectEmit(true, true, true, true);
        emit T.Heartbeat(owner, uint64(block.timestamp), T.VaultState.CareMode);
        vm.prank(owner);
        vault.heartbeat();
    }

    function test_StrangerCannotHeartbeat() public {
        _silenceFor(CARE);
        vm.prank(stranger);
        vm.expectRevert(T.NotOwner.selector);
        vault.heartbeat();
        _assertState(T.VaultState.CareMode);
    }

    /// @notice Once funds are distributed there is nothing left to protect;
    ///         a heartbeat must not imply a clawback. See OPEN-QUESTIONS Q9.
    function test_Invariant1_HeartbeatRevertsOnceClaimed() public {
        _silenceFor(CLAIMABLE);
        vm.prank(coldBackup);
        vault.claim(0);
        _assertState(T.VaultState.Claimed);

        vm.prank(owner);
        vm.expectRevert();
        vault.heartbeat();
        _assertState(T.VaultState.Claimed);
    }

    // -----------------------------------------------------------------
    // INVARIANT 5 — care mode is amount- AND category-capped
    // -----------------------------------------------------------------

    function _enterCareMode() internal {
        _silenceFor(CARE);
        _assertState(T.VaultState.CareMode);
    }

    function test_CareSpendPaysABill() public {
        _enterCareMode();
        vm.prank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, 120e6);

        assertEq(usdc.balanceOf(utilityCo), 120e6, "bill was not paid");
        assertEq(usdc.balanceOf(address(vault)), FUNDED - 120e6);
    }

    function test_CareSpendEmitsEvent() public {
        _enterCareMode();
        vm.expectEmit(true, true, true, true);
        emit T.CareSpend(careGuardian, utilityCo, CAT_BILLS, 120e6);
        vm.prank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, 120e6);
    }

    function test_Invariant5_MonthlyCapIsEnforced() public {
        _enterCareMode();
        vm.startPrank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, CARE_BILLS_CAP);
        vault.careSpend(utilityCo, CAT_MEDICAL, 200e6);

        // 300 + 200 = 500 = the global monthly cap. One more unit must fail.
        vm.expectRevert(abi.encodeWithSelector(T.CapExceeded.selector, uint256(1e6), uint256(0)));
        vault.careSpend(utilityCo, CAT_MEDICAL, 1e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(utilityCo), CARE_MONTHLY_CAP, "monthly cap was breached");
    }

    function test_Invariant5_PerCategoryCapIsEnforced() public {
        _enterCareMode();
        vm.startPrank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, CARE_BILLS_CAP);

        vm.expectRevert();
        vault.careSpend(utilityCo, CAT_BILLS, 1e6);
        vm.stopPrank();
    }

    function test_Invariant5_UnknownCategoryIsRejected() public {
        _enterCareMode();
        vm.prank(careGuardian);
        vm.expectRevert(abi.encodeWithSelector(T.CategoryNotAllowed.selector, CAT_LUXURY));
        vault.careSpend(utilityCo, CAT_LUXURY, 1e6);
        assertEq(usdc.balanceOf(utilityCo), 0);
    }

    /// @notice The cap is the real defence against guardian collusion (PRD §6):
    ///         no sequence of care spends can drain the vault in one period.
    function testFuzz_Invariant5_CannotExceedCapInOnePeriod(uint256 a, uint256 b, uint256 c) public {
        _enterCareMode();
        a = bound(a, 0, FUNDED);
        b = bound(b, 0, FUNDED);
        c = bound(c, 0, FUNDED);

        vm.startPrank(careGuardian);
        try vault.careSpend(utilityCo, CAT_BILLS, a) {} catch {}
        try vault.careSpend(utilityCo, CAT_MEDICAL, b) {} catch {}
        try vault.careSpend(utilityCo, CAT_BILLS, c) {} catch {}
        vm.stopPrank();

        assertLe(usdc.balanceOf(utilityCo), CARE_MONTHLY_CAP, "care mode exceeded its period cap");
    }

    /// @notice Full transfer happens ONLY via the full ladder — care mode can
    ///         never be escalated into a complete drain.
    function test_Invariant5_CareModeCannotDrainTheVault() public {
        _enterCareMode();
        vm.prank(careGuardian);
        vm.expectRevert();
        vault.careSpend(utilityCo, CAT_BILLS, FUNDED);
        assertEq(usdc.balanceOf(address(vault)), FUNDED);
    }

    function test_CareBudgetRollsOverNextPeriod() public {
        _enterCareMode();
        vm.prank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, CARE_BILLS_CAP);

        vm.warp(block.timestamp + CARE_PERIOD);
        vm.prank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, CARE_BILLS_CAP);

        assertEq(usdc.balanceOf(utilityCo), uint256(CARE_BILLS_CAP) * 2, "budget did not roll over");
    }

    // -----------------------------------------------------------------
    // Care mode gating
    // -----------------------------------------------------------------

    function test_CareSpendRejectedOutsideCareMode() public {
        // Too early.
        _silenceFor(ALERT);
        vm.prank(careGuardian);
        vm.expectRevert();
        vault.careSpend(utilityCo, CAT_BILLS, 1e6);

        // Too late — past care mode, the ladder has moved on to claims.
        _silenceFor(CLAIMABLE);
        vm.prank(careGuardian);
        vm.expectRevert();
        vault.careSpend(utilityCo, CAT_BILLS, 1e6);

        assertEq(usdc.balanceOf(utilityCo), 0);
    }

    function test_OnlyCareGuardianMaySpend() public {
        _enterCareMode();
        address[3] memory notCare = [g1, stranger, owner];
        for (uint256 i = 0; i < notCare.length; i++) {
            vm.prank(notCare[i]);
            vm.expectRevert();
            vault.careSpend(utilityCo, CAT_BILLS, 1e6);
        }
    }

    /// @notice INVARIANT 5's revoke clause: any owner activity instantly ends
    ///         care mode. The guardian's spending rights vanish mid-period.
    function test_Invariant5_OwnerActivityInstantlyRevokesCareMode() public {
        _enterCareMode();
        vm.prank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, 100e6);

        vm.prank(owner);
        vault.heartbeat();

        _assertState(T.VaultState.Active);
        vm.prank(careGuardian);
        vm.expectRevert();
        vault.careSpend(utilityCo, CAT_BILLS, 1e6);

        assertEq(usdc.balanceOf(utilityCo), 100e6, "guardian spent after revocation");
    }

    /// @notice The budget must reset on revocation, so a guardian cannot bank an
    ///         unspent allowance across an owner's return and reuse it later.
    function test_Invariant5_RevocationResetsTheBudget() public {
        _enterCareMode();
        vm.prank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, 100e6);

        vm.prank(owner);
        vault.heartbeat();
        _enterCareMode(); // owner goes quiet again

        (, uint128 spent,) = vault.careBudget();
        assertEq(spent, 0, "budget survived revocation");
    }

    /// @notice Care spending is a GUARDIAN acting, not the owner — it must not
    ///         reset the ladder, or a guardian could hold the vault in care mode
    ///         forever and block the cascade to heirs. See OPEN-QUESTIONS Q4.
    function test_CareSpendDoesNotResetTheLadder() public {
        _enterCareMode();
        uint64 activityBefore = vault.lastActivity();

        vm.prank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, 10e6);

        assertEq(vault.lastActivity(), activityBefore, "guardian spending reset the ladder");
        _assertState(T.VaultState.CareMode);
    }

    function test_CareSpendRejectsZeroAddressPayee() public {
        _enterCareMode();
        vm.prank(careGuardian);
        vm.expectRevert(T.ZeroAddress.selector);
        vault.careSpend(address(0), CAT_BILLS, 1e6);
    }

    // -----------------------------------------------------------------
    // Ownership / funds basics
    // -----------------------------------------------------------------

    function test_OnlyOwnerCanWithdraw() public {
        vm.prank(stranger);
        vm.expectRevert(T.NotOwner.selector);
        vault.withdraw(1e6);
    }

    function test_AssetUsesSixDecimals() public view {
        assertEq(usdc.decimals(), 6, "Arc USDC must expose 6 decimals");
        assertEq(vault.totalAssets(), FUNDED);
    }

    function test_ConstructorRejectsUnreachableThreshold() public {
        HeirloomVaultInitHelper helper = new HeirloomVaultInitHelper();
        vm.expectRevert();
        helper.deployWithThreshold(_params(), 4); // 4-of-3 is unreachable
    }
}

/// @dev Deploys through an external call so constructor reverts are observable
///      by `vm.expectRevert`.
contract HeirloomVaultInitHelper {
    function deployWithThreshold(HeirloomVault.InitParams memory p, uint256 threshold)
        external
        returns (address)
    {
        p.threshold = threshold;
        return address(new HeirloomVault(p));
    }
}
