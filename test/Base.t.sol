// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HeirloomVault} from "../src/HeirloomVault.sol";
import {HeirloomTypes as T} from "../src/HeirloomTypes.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Shared fixture: one funded vault wired exactly like the PRD's canonical
///         setup — heirs are (own cold backup → spouse → charity), three guardians
///         at 2-of-3, and a seconds-scale ladder so tests can fast-forward.
/// @dev UNAUDITED TESTNET CODE.
abstract contract Base is Test {
    HeirloomVault internal vault;
    MockUSDC internal usdc;

    address internal owner = makeAddr("owner");
    address internal thief = makeAddr("thief"); // holds a copy of the owner key
    address internal stranger = makeAddr("stranger");

    address internal g1 = makeAddr("guardian1");
    address internal g2 = makeAddr("guardian2");
    address internal g3 = makeAddr("guardian3");

    address internal coldBackup = makeAddr("coldBackup"); // tier 0 — self-recovery
    address internal spouse = makeAddr("spouse"); // tier 1 — inheritance
    address internal charity = makeAddr("charity"); // tier 2 — terminal sink

    address internal careGuardian = makeAddr("careGuardian");

    // Owner-approved care destinations. A category is only meaningful because
    // these addresses are registered under it (docs/OPEN-QUESTIONS.md Q3).
    address internal utilityCo = makeAddr("utilityCo"); // BILLS + MEDICAL
    address internal waterBoard = makeAddr("waterBoard"); // BILLS
    address internal hospital = makeAddr("hospital"); // MEDICAL

    // Seconds-scale mirror of the 90/180/270/365-day production ladder.
    uint32 internal constant NAG = 90;
    uint32 internal constant ALERT = 180;
    uint32 internal constant CARE = 270;
    uint32 internal constant CLAIMABLE = 365;

    // Claim windows for tiers 0 and 1; the terminal tier never expires.
    uint32 internal constant W0 = 100;
    uint32 internal constant W1 = 200;

    // 6dp — Arc USDC. 1e6 == $1.00.
    uint256 internal constant FUNDED = 10_000e6;

    bytes32 internal constant CAT_BILLS = keccak256("BILLS");
    bytes32 internal constant CAT_MEDICAL = keccak256("MEDICAL");
    bytes32 internal constant CAT_LUXURY = keccak256("LUXURY"); // never allowlisted

    uint128 internal constant CARE_MONTHLY_CAP = 500e6;
    uint128 internal constant CARE_BILLS_CAP = 300e6;
    uint128 internal constant CARE_MEDICAL_CAP = 400e6;
    /// @dev Seconds-scale, like the ladder above. It must be shorter than the
    ///      care-mode span (`CLAIMABLE - CARE` = 95s here) or the budget could
    ///      never roll over before the vault cascades to Claimable — mirroring
    ///      production, where a 30-day period sits inside a 95-day care window.
    uint32 internal constant CARE_PERIOD = 30;

    function setUp() public virtual {
        vm.warp(1_000_000); // keep away from timestamp-0 edge cases

        usdc = new MockUSDC();
        vault = new HeirloomVault(_params());

        usdc.mint(owner, FUNDED);
        vm.startPrank(owner);
        usdc.approve(address(vault), FUNDED);
        vault.deposit(FUNDED);
        vm.stopPrank();
    }

    function _params() internal view returns (HeirloomVault.InitParams memory p) {
        address[] memory guardians = new address[](3);
        guardians[0] = g1;
        guardians[1] = g2;
        guardians[2] = g3;

        T.Beneficiary[] memory heirs = new T.Beneficiary[](3);
        heirs[0] = T.Beneficiary({payee: coldBackup, window: W0});
        heirs[1] = T.Beneficiary({payee: spouse, window: W1});
        heirs[2] = T.Beneficiary({payee: charity, window: 0}); // terminal: never expires

        bytes32[] memory cats = new bytes32[](2);
        cats[0] = CAT_BILLS;
        cats[1] = CAT_MEDICAL;

        uint128[] memory caps = new uint128[](2);
        caps[0] = CARE_BILLS_CAP;
        caps[1] = CARE_MEDICAL_CAP;

        // Index-aligned with `cats`. utilityCo appears under both categories on
        // purpose — a real payee can legitimately serve two buckets, and the
        // tests lean on that to prove the categories still do not leak.
        address[][] memory payees = new address[][](2);
        payees[0] = new address[](2);
        payees[0][0] = utilityCo;
        payees[0][1] = waterBoard;
        payees[1] = new address[](2);
        payees[1][0] = utilityCo;
        payees[1][1] = hospital;

        p = HeirloomVault.InitParams({
            owner: owner,
            asset: address(usdc),
            ladder: T.LadderConfig({
                nagAfter: NAG, guardianAlertAfter: ALERT, careModeAfter: CARE, claimableAfter: CLAIMABLE
            }),
            guardians: guardians,
            threshold: 2, // 2-of-3
            beneficiaries: heirs,
            careGuardian: careGuardian,
            careMonthlyCap: CARE_MONTHLY_CAP,
            carePeriod: CARE_PERIOD,
            careCategories: cats,
            careCategoryCaps: caps,
            careCategoryPayees: payees
        });
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @notice Fast-forward to a given number of seconds past the last heartbeat.
    function _silenceFor(uint256 secs) internal {
        vm.warp(vault.lastActivity() + secs);
    }

    /// @notice Advance to the exact moment the vault becomes claimable.
    function _enterClaimable() internal {
        _silenceFor(CLAIMABLE);
    }

    function _timelock() internal view returns (uint64) {
        return vault.TIMELOCK();
    }

    function _assertState(T.VaultState expected) internal view {
        assertEq(uint256(vault.state()), uint256(expected), "unexpected vault state");
    }
}
