// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {HeirloomTypes as T} from "../src/HeirloomTypes.sol";

/// @notice Cascading claims (PRD §4 MUST-3): ordered beneficiaries, per-tier
///         claim windows, automatic cascade on expiry, charity terminal sink.
///
///         INVARIANT 4 — claims pay ONLY pre-registered beneficiary addresses.
///         INVARIANT 6 — funds never dead-end: an unclaimed tier cascades to the
///         next, and the terminal tier is always claimable, forever.
/// @dev UNAUDITED TESTNET CODE.
contract ClaimsTest is Base {
    // Tier boundaries, measured from the moment the vault becomes claimable:
    //   tier 0 (cold backup): [0, W0)
    //   tier 1 (spouse):      [W0, W0+W1)
    //   tier 2 (charity):     [W0+W1, ∞)   <- never expires

    function _claimableAt() internal view returns (uint64) {
        return vault.lastActivity() + CLAIMABLE;
    }

    function _warpIntoTier(uint256 offset) internal {
        vm.warp(_claimableAt() + offset);
    }

    // -----------------------------------------------------------------
    // Ordering and windows
    // -----------------------------------------------------------------

    function test_Tier0ClaimsDuringItsWindow() public {
        _warpIntoTier(0);
        assertEq(vault.activeTier(), 0);

        vm.prank(coldBackup);
        vault.claim(0);

        assertEq(usdc.balanceOf(coldBackup), FUNDED, "heir was not paid");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault retained funds after claim");
        _assertState(T.VaultState.Claimed);
    }

    function test_CannotClaimBeforeClaimable() public {
        _silenceFor(CLAIMABLE - 1);
        vm.prank(coldBackup);
        vm.expectRevert();
        vault.claim(0);
        assertEq(usdc.balanceOf(coldBackup), 0);
    }

    /// @dev Arc: inclusive boundary — the vault is claimable AT the threshold.
    function test_ClaimableAtExactBoundary() public {
        _silenceFor(CLAIMABLE);
        _assertState(T.VaultState.Claimable);
        vm.prank(coldBackup);
        vault.claim(0);
        assertEq(usdc.balanceOf(coldBackup), FUNDED);
    }

    function test_Tier0WindowClosesAndCascadesToTier1() public {
        _warpIntoTier(W0); // tier 0's window has just expired
        assertEq(vault.activeTier(), 1, "cascade did not advance");

        vm.prank(coldBackup);
        vm.expectRevert(abi.encodeWithSelector(T.TierNotOpen.selector, uint256(0)));
        vault.claim(0);

        vm.prank(spouse);
        vault.claim(1);
        assertEq(usdc.balanceOf(spouse), FUNDED, "cascade tier could not claim");
    }

    function test_CascadeReachesCharityTerminal() public {
        _warpIntoTier(uint256(W0) + W1);
        assertEq(vault.activeTier(), 2, "did not cascade to terminal tier");

        vm.prank(charity);
        vault.claim(2);
        assertEq(usdc.balanceOf(charity), FUNDED, "charity sink could not claim");
    }

    /// @notice A later tier cannot jump the queue while an earlier window is open.
    function test_LaterTierCannotClaimEarly() public {
        _warpIntoTier(0);
        vm.prank(spouse);
        vm.expectRevert(abi.encodeWithSelector(T.TierNotOpen.selector, uint256(1)));
        vault.claim(1);

        vm.prank(charity);
        vm.expectRevert(abi.encodeWithSelector(T.TierNotOpen.selector, uint256(2)));
        vault.claim(2);
    }

    function test_CannotClaimTwice() public {
        _warpIntoTier(0);
        vm.prank(coldBackup);
        vault.claim(0);

        _warpIntoTier(W0);
        vm.prank(spouse);
        vm.expectRevert();
        vault.claim(1);
        assertEq(usdc.balanceOf(spouse), 0, "vault paid out twice");
    }

    // -----------------------------------------------------------------
    // INVARIANT 4 — only pre-registered payees, no free-text destinations
    // -----------------------------------------------------------------

    /// @notice `claim` takes a tier index and nothing else. There is no address
    ///         parameter anywhere on the claim path, so a destination cannot be
    ///         supplied — funds can only ever reach the registered payee.
    function test_Invariant4_NoFreeTextDestinationInAbi() public {
        _warpIntoTier(0);

        // Any signature that would let a caller name a destination must not exist.
        string[4] memory forbidden = [
            "claim(uint256,address)",
            "claimTo(uint256,address)",
            "claim(address)",
            "withdrawTo(address,uint256)"
        ];

        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(vault).call(abi.encodeWithSignature(forbidden[i], uint256(0), stranger));
            assertFalse(ok, string.concat("a free-text destination exists: ", forbidden[i]));
        }
        assertEq(usdc.balanceOf(stranger), 0);
    }

    /// @notice A stranger MAY trigger the payout — and gains nothing by it.
    ///         This is the assisted-claim path (Q11): who calls and where the
    ///         money goes are separate questions, and only the second is a
    ///         security property.
    function test_Invariant4_StrangerMayTriggerButIsNeverPaid() public {
        _warpIntoTier(0);

        vm.prank(stranger);
        vault.claim(0);

        assertEq(usdc.balanceOf(stranger), 0, "the caller was paid");
        assertEq(usdc.balanceOf(coldBackup), FUNDED, "registered payee was not paid");
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// @notice The helper pays gas and receives nothing — it is strictly worse
    ///         off for having helped, which is what makes the path safe to
    ///         expose to anyone at all.
    function test_AssistedClaim_CallerGainsNothing() public {
        _warpIntoTier(0);

        uint256 strangerBefore = usdc.balanceOf(stranger);
        uint256 heirBefore = usdc.balanceOf(coldBackup);

        vm.prank(stranger);
        vault.claim(0);

        assertEq(usdc.balanceOf(stranger), strangerBefore, "caller balance changed");
        assertEq(usdc.balanceOf(coldBackup) - heirBefore, FUNDED, "heir did not receive the full balance");
    }

    /// @notice Every kind of actor can trigger it, and none of them can be paid.
    function testFuzz_AssistedClaim_AnyCallerPaysOnlyTheRegisteredPayee(address caller) public {
        vm.assume(caller != address(0));
        vm.assume(caller != coldBackup);
        vm.assume(caller != address(vault));
        vm.assume(caller.code.length == 0); // EOAs only; a contract may reject the token

        _warpIntoTier(0);
        uint256 callerBefore = usdc.balanceOf(caller);

        vm.prank(caller);
        vault.claim(0);

        assertEq(usdc.balanceOf(caller), callerBefore, "an arbitrary caller was paid");
        assertEq(usdc.balanceOf(coldBackup), FUNDED, "registered payee was not paid");
    }

    function test_AssistedClaim_EmitsClaimTriggeredWithBothParties() public {
        _warpIntoTier(0);
        vm.expectEmit(true, true, true, true);
        emit T.ClaimTriggered(0, coldBackup, stranger, FUNDED);
        vm.prank(stranger);
        vault.claim(0);
    }

    /// @notice A helper still cannot open a tier that is not open, so assisted
    ///         claiming cannot be used to jump the cascade order.
    function test_AssistedClaim_CannotJumpTheQueue() public {
        _warpIntoTier(0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(T.TierNotOpen.selector, uint256(1)));
        vault.claim(1);
        assertEq(usdc.balanceOf(spouse), 0);
    }

    /// @notice Nor before the vault is claimable at all.
    function test_AssistedClaim_CannotClaimEarly() public {
        _silenceFor(CLAIMABLE - 1);
        vm.prank(stranger);
        vm.expectRevert();
        vault.claim(0);
        assertEq(usdc.balanceOf(address(vault)), FUNDED);
    }

    /// @notice Even the registered payee of a CLOSED tier cannot pull funds —
    ///         the gate is which tier is open, not who is asking.
    function test_Invariant4_PayeeOfInactiveTierCannotClaim() public {
        _warpIntoTier(0);
        vm.prank(charity);
        vm.expectRevert(abi.encodeWithSelector(T.TierNotOpen.selector, uint256(2)));
        vault.claim(2);
    }

    /// @notice Funds always land at the registered address, whatever the tier.
    function testFuzz_Invariant4_PayoutAlwaysGoesToRegisteredPayee(uint256 offset) public {
        offset = bound(offset, 0, 10_000);
        _warpIntoTier(offset);

        uint256 tier = vault.activeTier();
        (address payee,) = vault.beneficiaries(tier);

        vm.prank(payee);
        vault.claim(tier);

        assertEq(usdc.balanceOf(payee), FUNDED, "registered payee was not paid");
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // -----------------------------------------------------------------
    // INVARIANT 6 — funds never dead-end
    // -----------------------------------------------------------------

    /// @notice At EVERY instant from the moment the vault becomes claimable and
    ///         forever after, some tier must be open and its registered payee
    ///         must be able to take the funds. No gap, no expiry, no dead end.
    function testFuzz_Invariant6_SomeTierIsAlwaysClaimable(uint256 offset) public {
        offset = bound(offset, 0, type(uint32).max);
        _warpIntoTier(offset);

        _assertState(T.VaultState.Claimable);

        uint256 tier = vault.activeTier();
        (address payee,) = vault.beneficiaries(tier);
        assertTrue(payee != address(0), "active tier has no payee -- funds stranded");

        uint256 balance = usdc.balanceOf(address(vault));
        vm.prank(payee);
        vault.claim(tier);

        assertEq(usdc.balanceOf(payee), balance, "open tier could not extract the funds");
        assertEq(usdc.balanceOf(address(vault)), 0, "funds stranded in the vault");
    }

    /// @notice The terminal tier never expires — arbitrarily far in the future,
    ///         the charity sink is still open.
    function testFuzz_Invariant6_TerminalTierNeverExpires(uint32 farFuture) public {
        uint256 offset = uint256(W0) + W1 + farFuture;
        _warpIntoTier(offset);

        assertEq(vault.activeTier(), 2, "terminal tier expired");
        vm.prank(charity);
        vault.claim(2);
        assertEq(usdc.balanceOf(charity), FUNDED);
    }

    /// @notice The tier sequence must be monotonic in time — cascade only ever
    ///         moves forward, so no tier can be skipped or revisited.
    function testFuzz_Invariant6_CascadeIsMonotonic(uint32 a, uint32 b) public {
        if (a > b) (a, b) = (b, a);

        _warpIntoTier(a);
        uint256 tierA = vault.activeTier();
        _warpIntoTier(b);
        uint256 tierB = vault.activeTier();

        assertLe(tierA, tierB, "cascade moved backwards");
        assertLe(tierB, 2, "cascade ran past the terminal tier");
    }

    /// @notice Configuration can never leave the vault without a terminal sink.
    function test_Invariant6_TerminalBeneficiaryIsMandatory() public {
        T.Beneficiary[] memory none = new T.Beneficiary[](0);
        vm.prank(owner);
        vm.expectRevert(T.NoTerminalBeneficiary.selector);
        vault.proposeBeneficiaries(none);
    }

    function test_Invariant6_TerminalBeneficiaryCannotBeZeroAddress() public {
        T.Beneficiary[] memory bad = new T.Beneficiary[](2);
        bad[0] = T.Beneficiary({payee: spouse, window: 10});
        bad[1] = T.Beneficiary({payee: address(0), window: 0});

        vm.prank(owner);
        vm.expectRevert(T.ZeroAddress.selector);
        vault.proposeBeneficiaries(bad);
    }

    // -----------------------------------------------------------------
    // Interaction with the ladder (INVARIANT 1 at the vault level)
    // -----------------------------------------------------------------

    /// @notice The false-death path: the owner surfaces during the claim window
    ///         and everything unwinds. This is the single most important
    ///         non-catastrophe in the product.
    function test_OwnerHeartbeatDuringClaimWindowCancelsEverything() public {
        _warpIntoTier(0);
        _assertState(T.VaultState.Claimable);

        vm.prank(owner);
        vault.heartbeat();

        _assertState(T.VaultState.Active);

        vm.prank(coldBackup);
        vm.expectRevert();
        vault.claim(0);
        assertEq(usdc.balanceOf(address(vault)), FUNDED, "heir claimed after the owner returned");
    }

    function test_ClaimEmitsEvent() public {
        _warpIntoTier(0);
        vm.expectEmit(true, true, true, true);
        emit T.Claimed_(0, coldBackup, FUNDED);
        vm.prank(coldBackup);
        vault.claim(0);
    }

    function test_CannotClaimEmptyVault() public {
        vm.prank(owner);
        vault.withdraw(FUNDED);

        _warpIntoTier(0);
        vm.prank(coldBackup);
        vm.expectRevert(T.NothingToClaim.selector);
        vault.claim(0);
    }
}
