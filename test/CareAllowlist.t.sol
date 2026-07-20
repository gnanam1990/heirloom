// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {HeirloomTypes as T} from "../src/HeirloomTypes.sol";

/// @notice Resolves docs/OPEN-QUESTIONS.md Q3 — care-mode categories are now
///         enforced by DESTINATION, not by a label the spending guardian asserts.
///
///         The old model: a guardian passed `categoryId = MEDICAL` and the chain
///         believed it. Nothing stopped a colluding guardian from labelling a
///         personal withdrawal as medical; only the amount caps bit.
///
///         The new model: each category carries an owner-approved payee list. A
///         care payment can only reach an address the owner registered under that
///         exact category, and the list itself is mutable only through the same
///         propose → 7-day timelock → execute → owner-vetoable path as every
///         other config change (invariant 2). A thief cannot quietly add their
///         own address, and a guardian cannot invent a destination.
/// @dev UNAUDITED TESTNET CODE.
contract CareAllowlistTest is Base {
    address internal fakeClinic = makeAddr("fakeClinic"); // never approved
    address internal guardianSelf = makeAddr("guardianSelfWallet"); // the collusion target

    function _enterCareMode() internal {
        _silenceFor(CARE);
        _assertState(T.VaultState.CareMode);
    }

    // -----------------------------------------------------------------
    // The happy path still works
    // -----------------------------------------------------------------

    function test_ApprovedPayeeWithinCapsSucceeds() public {
        _enterCareMode();
        vm.prank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, 120e6);

        assertEq(usdc.balanceOf(utilityCo), 120e6, "approved payee was not paid");
        assertEq(usdc.balanceOf(address(vault)), FUNDED - 120e6);
    }

    function test_FixtureApprovesTheExpectedPayees() public view {
        assertTrue(vault.isApprovedCarePayee(CAT_BILLS, utilityCo), "utility should be a BILLS payee");
        assertTrue(vault.isApprovedCarePayee(CAT_MEDICAL, hospital), "hospital should be a MEDICAL payee");
        assertFalse(vault.isApprovedCarePayee(CAT_BILLS, fakeClinic), "fakeClinic must not be approved");
        assertEq(vault.carePayees(CAT_BILLS).length, 2);
    }

    // -----------------------------------------------------------------
    // The fix: an unapproved destination is rejected outright
    // -----------------------------------------------------------------

    /// @notice The core of Q3. The amount is trivially within every cap; the ONLY
    ///         thing rejecting it is that the owner never approved this address.
    function test_UnapprovedPayeeRevertsEvenWellWithinCaps() public {
        _enterCareMode();

        vm.prank(careGuardian);
        vm.expectRevert(abi.encodeWithSelector(T.NotAllowedPayee.selector, CAT_BILLS, fakeClinic));
        vault.careSpend(fakeClinic, CAT_BILLS, 1e6); // 1 USDC — nowhere near any cap

        assertEq(usdc.balanceOf(fakeClinic), 0, "an unapproved address was paid");
        assertEq(usdc.balanceOf(address(vault)), FUNDED, "vault balance moved");
    }

    /// @notice The exact collusion scenario from PRD §6: the care guardian tries
    ///         to pay their own wallet and calls it medical.
    function test_GuardianCannotPayThemselvesUnderAnyLabel() public {
        _enterCareMode();

        vm.startPrank(careGuardian);
        vm.expectRevert(abi.encodeWithSelector(T.NotAllowedPayee.selector, CAT_MEDICAL, guardianSelf));
        vault.careSpend(guardianSelf, CAT_MEDICAL, 50e6);

        vm.expectRevert(abi.encodeWithSelector(T.NotAllowedPayee.selector, CAT_BILLS, guardianSelf));
        vault.careSpend(guardianSelf, CAT_BILLS, 50e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(guardianSelf), 0, "guardian paid themselves");
    }

    /// @notice Categories do not leak into one another: a MEDICAL-only payee
    ///         cannot be paid from the BILLS budget, and vice versa.
    function test_PayeeApprovedForOneCategoryIsRejectedUnderAnother() public {
        _enterCareMode();

        vm.prank(careGuardian);
        vm.expectRevert(abi.encodeWithSelector(T.NotAllowedPayee.selector, CAT_BILLS, hospital));
        vault.careSpend(hospital, CAT_BILLS, 10e6);

        // ...but the same address under its own category is fine.
        vm.prank(careGuardian);
        vault.careSpend(hospital, CAT_MEDICAL, 10e6);
        assertEq(usdc.balanceOf(hospital), 10e6);
    }

    /// @notice Both layers still apply — the allowlist did not replace the caps.
    function test_ApprovedPayeeStillBoundByCaps() public {
        _enterCareMode();
        vm.startPrank(careGuardian);
        vault.careSpend(utilityCo, CAT_BILLS, CARE_BILLS_CAP);

        vm.expectRevert(abi.encodeWithSelector(T.CapExceeded.selector, uint256(1e6), uint256(0)));
        vault.careSpend(utilityCo, CAT_BILLS, 1e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(utilityCo), CARE_BILLS_CAP, "cap was breached");
    }

    // -----------------------------------------------------------------
    // Allowlist changes go through the full ConfigGuard path (invariant 2)
    // -----------------------------------------------------------------

    function test_AddingAPayeeRequiresTheFullTimelock() public {
        // Owner queues fakeClinic as a legitimate new BILLS payee.
        address[] memory next = new address[](3);
        next[0] = utilityCo;
        next[1] = waterBoard;
        next[2] = fakeClinic;

        vm.prank(owner);
        uint256 id = vault.proposeCarePayees(CAT_BILLS, next);

        // Not yet approved — the proposal has only been announced.
        assertFalse(vault.isApprovedCarePayee(CAT_BILLS, fakeClinic), "payee active before execute");

        _enterCareMode();
        vm.prank(careGuardian);
        vm.expectRevert(abi.encodeWithSelector(T.NotAllowedPayee.selector, CAT_BILLS, fakeClinic));
        vault.careSpend(fakeClinic, CAT_BILLS, 1e6);

        // One second short of the eta is still short. Anchor to the proposal's
        // own eta — entering care mode above already moved the clock, so a
        // relative warp from "now" would overshoot it.
        (,, uint64 eta,,,) = vault.proposals(id);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(T.ProposalNotRipe.selector, id, eta, uint64(eta - 1)));
        vault.execute(id);
        assertFalse(vault.isApprovedCarePayee(CAT_BILLS, fakeClinic), "payee active before eta");
    }

    function test_PayeeWorksOnlyAfterTheTimelockMatures() public {
        address[] memory next = new address[](1);
        next[0] = fakeClinic;

        vm.prank(owner);
        uint256 id = vault.proposeCarePayees(CAT_BILLS, next);

        vm.warp(block.timestamp + _timelock());
        vault.execute(id);
        assertTrue(vault.isApprovedCarePayee(CAT_BILLS, fakeClinic), "payee not active after execute");

        // The replacement is wholesale: the old list is gone.
        assertFalse(vault.isApprovedCarePayee(CAT_BILLS, utilityCo), "old payee survived replacement");

        _enterCareMode();
        vm.prank(careGuardian);
        vault.careSpend(fakeClinic, CAT_BILLS, 5e6);
        assertEq(usdc.balanceOf(fakeClinic), 5e6);
    }

    /// @notice The anti-theft property, applied to the new surface: a stolen key
    ///         queues its own address as an approved destination, and the real
    ///         owner kills it. Even after the eta matures, the veto holds.
    function test_Attack_ThiefCannotAddOwnAddressAsPayee() public {
        address[] memory evil = new address[](1);
        evil[0] = thief;

        vm.prank(owner); // the stolen key IS the owner key
        uint256 id = vault.proposeCarePayees(CAT_MEDICAL, evil);

        // The ProposalQueued event fires; the real owner notices and cancels.
        vm.prank(owner);
        vault.veto(id);

        vm.warp(block.timestamp + _timelock() + 30 days);
        vm.expectRevert(abi.encodeWithSelector(T.ProposalDead.selector, id));
        vault.execute(id);

        assertFalse(vault.isApprovedCarePayee(CAT_MEDICAL, thief), "thief became an approved payee");

        _enterCareMode();
        vm.prank(careGuardian);
        vm.expectRevert(abi.encodeWithSelector(T.NotAllowedPayee.selector, CAT_MEDICAL, thief));
        vault.careSpend(thief, CAT_MEDICAL, 1e6);
        assertEq(usdc.balanceOf(thief), 0);
    }

    function test_OnlyOwnerMayProposePayees() public {
        address[] memory next = new address[](1);
        next[0] = fakeClinic;

        vm.prank(careGuardian);
        vm.expectRevert(T.NotOwner.selector);
        vault.proposeCarePayees(CAT_BILLS, next);

        vm.prank(g1);
        vm.expectRevert(T.NotOwner.selector);
        vault.proposeCarePayees(CAT_BILLS, next);
    }

    /// @notice No direct setter, on this surface either (invariant 2).
    function test_NoDirectPayeeSetterExists() public {
        string[4] memory forbidden = [
            "setCarePayees(bytes32,address[])",
            "addCarePayee(bytes32,address)",
            "approveCarePayee(bytes32,address)",
            "setApprovedCarePayee(bytes32,address)"
        ];

        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(vault).call(abi.encodeWithSignature(forbidden[i], CAT_BILLS, fakeClinic));
            assertFalse(ok, string.concat("a direct payee setter is reachable: ", forbidden[i]));
        }
        assertFalse(vault.isApprovedCarePayee(CAT_BILLS, fakeClinic));
    }

    function test_ProposingEmptyOrZeroPayeeIsRejectedUpFront() public {
        address[] memory empty = new address[](0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(T.PayeeListEmpty.selector, CAT_BILLS));
        vault.proposeCarePayees(CAT_BILLS, empty);

        address[] memory withZero = new address[](2);
        withZero[0] = utilityCo;
        withZero[1] = address(0); // Arc reverts on transfers to zero
        vm.prank(owner);
        vm.expectRevert(T.ZeroAddress.selector);
        vault.proposeCarePayees(CAT_BILLS, withZero);
    }

    /// @notice Dropping a category must drop its destinations too, so re-adding
    ///         the category later cannot silently resurrect old payees.
    function test_RemovingACategoryClearsItsPayees() public {
        bytes32[] memory onlyMedical = new bytes32[](1);
        onlyMedical[0] = CAT_MEDICAL;
        uint128[] memory caps = new uint128[](1);
        caps[0] = CARE_MEDICAL_CAP;

        vm.prank(owner);
        uint256 id = vault.proposeCareConfig(careGuardian, CARE_MONTHLY_CAP, CARE_PERIOD, onlyMedical, caps);
        vm.warp(block.timestamp + _timelock());
        vault.execute(id);

        assertFalse(vault.isApprovedCarePayee(CAT_BILLS, utilityCo), "payees survived category removal");
        assertEq(vault.carePayees(CAT_BILLS).length, 0, "payee list survived category removal");
    }

    // -----------------------------------------------------------------
    // Fuzz — the property Q3 actually needed
    // -----------------------------------------------------------------

    /// @notice NO (category, payee) pair outside the allowlist can move a single
    ///         unit in care mode, at any amount, under any label. This is the
    ///         property that makes the category real.
    function testFuzz_UnapprovedPairCanNeverMoveFunds(address payee, uint256 amount, bool medical) public {
        bytes32 category = medical ? CAT_MEDICAL : CAT_BILLS;

        // Only consider pairs the owner never approved.
        vm.assume(payee != address(0));
        vm.assume(!vault.isApprovedCarePayee(category, payee));
        vm.assume(payee != address(vault));
        amount = bound(amount, 1, FUNDED);

        _enterCareMode();
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 payeeBefore = usdc.balanceOf(payee);

        vm.prank(careGuardian);
        vm.expectRevert(abi.encodeWithSelector(T.NotAllowedPayee.selector, category, payee));
        vault.careSpend(payee, category, amount);

        assertEq(usdc.balanceOf(address(vault)), vaultBefore, "vault lost funds to an unapproved payee");
        assertEq(usdc.balanceOf(payee), payeeBefore, "unapproved payee received funds");
    }

    /// @notice Mirror of the above: an approved pair is bounded by the caps and
    ///         nothing else, so the two layers compose rather than conflict.
    function testFuzz_ApprovedPairIsStillCapBounded(uint256 amount) public {
        amount = bound(amount, 1, FUNDED);
        _enterCareMode();

        vm.prank(careGuardian);
        if (amount > CARE_BILLS_CAP) {
            vm.expectRevert();
            vault.careSpend(utilityCo, CAT_BILLS, amount);
            assertEq(usdc.balanceOf(utilityCo), 0);
        } else {
            vault.careSpend(utilityCo, CAT_BILLS, amount);
            assertEq(usdc.balanceOf(utilityCo), amount);
        }
        assertLe(usdc.balanceOf(utilityCo), CARE_BILLS_CAP, "cap breached");
    }
}
