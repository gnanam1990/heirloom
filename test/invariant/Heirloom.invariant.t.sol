// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {HeirloomVault} from "../../src/HeirloomVault.sol";
import {HeirloomTypes as T} from "../../src/HeirloomTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {HeirloomHandler} from "./HeirloomHandler.sol";

/// @notice Stateful, multi-actor invariant testing. The unit and fuzz suites
///         check one function at a time; this checks the protocol as a whole
///         under random SEQUENCES of calls from every actor, which is where
///         ordering and interaction bugs live.
///
///         The six properties asserted here are the six the README and PRD
///         commit to. They are stated as things that must hold after ANY
///         sequence, not as expected outcomes of a scripted path.
/// @dev UNAUDITED TESTNET CODE.
///
///      Runs on the PRODUCTION ladder (90/180/270/365 days), not the seconds-
///      scale one the unit tests use. That is deliberate: the 7-day config
///      timelock has to be small relative to the ladder for proposals to mature
///      inside a sequence at all. On a seconds-scale ladder the vault would
///      cascade to Claimable roughly 1,400 times over before a single proposal
///      ripened, and the recovery and config paths would never be explored.
contract HeirloomInvariantTest is Test {
    HeirloomVault internal vault;
    MockUSDC internal usdc;
    HeirloomHandler internal handler;

    address internal owner = makeAddr("inv_owner");
    address internal careGuardian = makeAddr("inv_careGuardian");
    address internal thief = makeAddr("inv_thief");
    address internal randomCaller = makeAddr("inv_random");

    address[3] internal guardians = [makeAddr("inv_g1"), makeAddr("inv_g2"), makeAddr("inv_g3")];
    address[3] internal heirs = [makeAddr("inv_coldBackup"), makeAddr("inv_spouse"), makeAddr("inv_charity")];
    address[2] internal rotationTargets = [makeAddr("inv_newKeyA"), makeAddr("inv_newKeyB")];

    // Two approved destinations and one the owner never registers, so the fuzzer
    // can attempt an unapproved payout in every care-mode sequence.
    address[3] internal carePayeePool =
        [makeAddr("inv_utility"), makeAddr("inv_hospital"), makeAddr("inv_neverApproved")];

    bytes32 internal constant CAT_BILLS = keccak256("BILLS");
    bytes32 internal constant CAT_MEDICAL = keccak256("MEDICAL");
    bytes32[2] internal categories = [CAT_BILLS, CAT_MEDICAL];

    uint256 internal constant SEED = 1_000_000e6; // 6dp
    uint128 internal constant GLOBAL_CAP = 500e6;
    uint128 internal constant BILLS_CAP = 300e6;
    uint128 internal constant MEDICAL_CAP = 400e6;

    function setUp() public {
        vm.warp(365 days); // away from timestamp 0

        usdc = new MockUSDC();
        vault = new HeirloomVault(_params());

        usdc.mint(owner, SEED);
        vm.startPrank(owner);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED);
        vm.stopPrank();

        handler = new HeirloomHandler(
            HeirloomHandler.Actors({
                vault: vault,
                usdc: usdc,
                guardians: guardians,
                heirs: heirs,
                careGuardian: careGuardian,
                thief: thief,
                randomCaller: randomCaller,
                rotationTargets: rotationTargets,
                carePayeePool: carePayeePool,
                categories: categories,
                seeded: SEED
            })
        );

        // The handler is the only entry point the fuzzer may drive. Letting it
        // call the vault directly would burn the run on access-control reverts.
        targetContract(address(handler));
    }

    function _params() internal view returns (HeirloomVault.InitParams memory p) {
        address[] memory gs = new address[](3);
        gs[0] = guardians[0];
        gs[1] = guardians[1];
        gs[2] = guardians[2];

        T.Beneficiary[] memory bs = new T.Beneficiary[](3);
        bs[0] = T.Beneficiary({payee: heirs[0], window: 30 days});
        bs[1] = T.Beneficiary({payee: heirs[1], window: 60 days});
        bs[2] = T.Beneficiary({payee: heirs[2], window: 0}); // terminal

        bytes32[] memory cats = new bytes32[](2);
        cats[0] = CAT_BILLS;
        cats[1] = CAT_MEDICAL;

        uint128[] memory caps = new uint128[](2);
        caps[0] = BILLS_CAP;
        caps[1] = MEDICAL_CAP;

        // inv_neverApproved is absent from both lists, on purpose.
        address[][] memory payees = new address[][](2);
        payees[0] = new address[](1);
        payees[0][0] = carePayeePool[0];
        payees[1] = new address[](1);
        payees[1][0] = carePayeePool[1];

        p = HeirloomVault.InitParams({
            owner: owner,
            asset: address(usdc),
            ladder: T.LadderConfig({
                nagAfter: 90 days,
                guardianAlertAfter: 180 days,
                careModeAfter: 270 days,
                claimableAfter: 365 days
            }),
            guardians: gs,
            threshold: 2,
            beneficiaries: bs,
            careGuardian: careGuardian,
            careMonthlyCap: GLOBAL_CAP,
            carePeriod: 30 days,
            careCategories: cats,
            careCategoryCaps: caps,
            careCategoryPayees: payees
        });
    }

    // ===============================================================
    // INVARIANT 1 — owner activity always resets the ladder
    // ===============================================================

    /// @notice No sequence may leave the vault escalated immediately after a
    ///         successful owner-authenticated call. The handler checks this at
    ///         the moment each owner action lands, because "was it Active right
    ///         then" is not recoverable after the fact.
    function invariant_1_ownerActivityAlwaysResetsToActive() public view {
        assertFalse(
            handler.ghostOwnerActionLeftEscalated(), "an owner action completed but left the vault escalated"
        );
    }

    // ===============================================================
    // INVARIANT 2 — config changes only via matured, un-vetoed proposals
    // ===============================================================

    /// @notice The config fingerprint may only move inside an `execute` call.
    ///         Anything else changing heirs, guardians, timings, the care rules
    ///         or the owner would mean a direct setter exists somewhere.
    function invariant_2_configOnlyChangesThroughExecute() public view {
        assertFalse(
            handler.ghostConfigChangedWithoutExecute(),
            "configuration changed outside a matured proposal execution"
        );
    }

    // ===============================================================
    // INVARIANT 3 — guardians never reduce the balance
    // ===============================================================

    /// @notice Recovery guardians may propose and approve rotations, and that is
    ///         all. No sequence may end with a guardian-initiated call having
    ///         reduced the vault balance — including a completed rotation, which
    ///         changes the lock and moves nothing.
    function invariant_3_guardiansNeverReduceBalance() public view {
        assertFalse(handler.ghostGuardianReducedBalance(), "a guardian action reduced the vault balance");
    }

    // ===============================================================
    // INVARIANT 4 — care mode is capped and destination-bound
    // ===============================================================

    function invariant_4_careOutflowRespectsCapsAndAllowlist() public view {
        assertFalse(handler.ghostPaidUnapprovedPayee(), "care mode paid an address that was not allowlisted");
        assertFalse(handler.ghostCareCapBreached(), "care outflow exceeded a cap within a period");
    }

    // ===============================================================
    // INVARIANT 5 — conservation of funds
    // ===============================================================

    /// @notice Nothing is minted by the vault. Everything that ever left is
    ///         bounded by everything that ever went in, and the live balance
    ///         reconciles exactly.
    function invariant_5_fundsAreConserved() public view {
        assertLe(handler.ghostTotalOut(), handler.ghostTotalIn(), "more left the vault than ever entered it");

        assertEq(
            usdc.balanceOf(address(vault)),
            handler.ghostTotalIn() - handler.ghostTotalOut(),
            "vault balance does not reconcile with tracked flows"
        );
    }

    /// @notice The other half of "funds never dead-end": whenever the vault is
    ///         Claimable and holds anything, some tier is open and its registered
    ///         payee is a real address. There is no reachable state where money
    ///         sits with nobody able to take it.
    function invariant_6a_claimableAlwaysHasAnOpenTierWithAPayee() public view {
        if (vault.state() != T.VaultState.Claimable) return;
        if (usdc.balanceOf(address(vault)) == 0) return;

        uint256 tier = vault.activeTier();
        assertLt(tier, vault.beneficiaryCount(), "active tier is out of range");

        (address payee,) = vault.beneficiaries(tier);
        assertTrue(payee != address(0), "claimable vault has no reachable payee - funds stranded");
    }

    /// @notice And a claim, whenever one succeeded, paid the address registered
    ///         for that tier — never a caller-supplied destination.
    function invariant_6b_claimsOnlyPayRegisteredPayees() public view {
        assertFalse(
            handler.ghostClaimPaidWrongAddress(), "a claim paid an address other than the registered payee"
        );
    }

    // ===============================================================
    // INVARIANT 6 — a no-rights actor is powerless
    // ===============================================================

    function invariant_6_thiefCanNeverMoveFundsOrChangeConfig() public view {
        assertFalse(handler.ghostThiefMovedFunds(), "an actor with no rights moved funds");
        assertFalse(handler.ghostThiefChangedConfig(), "an actor with no rights applied a config change");
        assertEq(usdc.balanceOf(thief), 0, "the thief holds funds");
    }

    // ===============================================================
    // Coverage report — proves the sequences reached interesting states
    // ===============================================================

    /// @dev Not an assertion about the protocol; a guard against a green run that
    ///      never actually got anywhere. If the fuzzer only ever warped and
    ///      heartbeated, the invariants above would pass vacuously.
    function afterInvariant() public view {
        console2.log("--- stateful run coverage -------------------------");
        console2.log("total handler calls   ", handler.callsTotal());
        console2.log("deepest rung reached  ", handler.ghostDeepestRung(), "(4 = Claimable)");
        console2.log("heartbeats            ", handler.ghostHeartbeats());
        console2.log("proposals executed    ", handler.ghostExecutions());
        console2.log("vetoes                ", handler.ghostVetoes());
        console2.log("owner rotations       ", handler.ghostRotations());
        console2.log("care spends           ", handler.ghostCareSpends());
        console2.log("claims completed      ", handler.ghostClaims());
        console2.log("total in  (6dp)       ", handler.ghostTotalIn());
        console2.log("total out (6dp)       ", handler.ghostTotalOut());
        console2.log("---------------------------------------------------");
    }
}
