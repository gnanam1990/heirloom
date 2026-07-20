// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HeirloomVault} from "../../src/HeirloomVault.sol";
import {HeirloomTypes as T} from "../../src/HeirloomTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @title HeirloomHandler
/// @notice Bounded action surface for stateful invariant testing. The fuzzer
///         calls these in random order, with random arguments, standing in for
///         many actors at once — owner, three recovery guardians, a care
///         guardian, three heirs, and a no-rights thief.
/// @dev UNAUDITED TESTNET CODE.
///
///      Why a handler rather than fuzzing the vault directly: unconstrained
///      calls are almost all reverts (wrong caller, wrong state, wrong tier), so
///      the fuzzer would spend its budget bouncing off access control instead of
///      exploring orderings. Every action here clamps its inputs into the band
///      where something interesting can happen, and pranks a plausible actor.
///
///      Every action is wrapped in `tracked`, which snapshots the balance and a
///      config fingerprint around the call. That is how the protocol-level
///      properties get observed: the invariants do not re-derive what the vault
///      should have done, they check ghosts recorded at the moment each call
///      landed.
///
///      Calls are wrapped in try/catch on purpose. A reverting handler action
///      would end that sequence early; swallowing the revert lets the fuzzer
///      keep going and reach deep states, and the ghosts only record successes.
contract HeirloomHandler is Test {
    // ---------------------------------------------------------------
    // Actors
    // ---------------------------------------------------------------

    /// @dev Role tags, used to attribute a balance drop or config change to the
    ///      kind of actor that caused it.
    uint8 internal constant ROLE_OWNER = 0;
    uint8 internal constant ROLE_GUARDIAN = 1;
    uint8 internal constant ROLE_CARE = 2;
    uint8 internal constant ROLE_HEIR = 3;
    uint8 internal constant ROLE_THIEF = 4;
    uint8 internal constant ROLE_ANY = 5;

    HeirloomVault public vault;
    MockUSDC public usdc;

    address[3] public guardians;
    address[3] public heirs;
    address public careGuardian;
    address public thief;
    address public randomCaller;

    /// @dev Rotation targets are deliberately NOT guardians. If a guardian could
    ///      become the owner, a later legitimate owner withdrawal would look like
    ///      "a guardian reduced the balance" and invariant 3 would false-positive.
    address[2] public rotationTargets;

    address[3] public carePayeePool; // two approved, one never approved
    bytes32[2] public categories;

    // ---------------------------------------------------------------
    // Ghost state — what the invariants actually assert on
    // ---------------------------------------------------------------

    uint256 public ghostTotalIn; // everything ever deposited, incl. seed
    uint256 public ghostTotalOut; // everything that ever left the vault

    bool public ghostConfigChangedWithoutExecute;
    /// @dev Since Q11 anyone may TRIGGER a claim, so "reduced the balance" is no
    ///      longer a violation on its own — a guardian or a stranger paying an
    ///      heir is the feature working. What must never happen is an actor
    ///      being PAID, or funds reaching an address the owner never designated.
    bool public ghostGuardianGainedFunds;
    bool public ghostThiefGainedFunds;
    bool public ghostUnauthorizedRecipient;
    bool public ghostThiefChangedConfig;
    bool public ghostPaidUnapprovedPayee;
    bool public ghostCareCapBreached;
    bool public ghostOwnerActionLeftEscalated;
    bool public ghostClaimPaidWrongAddress;

    bool public ghostRotated;
    uint256 public ghostRotations;
    uint256 public ghostClaims;
    uint256 public ghostAssistedClaims;
    uint256 public ghostCareSpends;
    uint256 public ghostExecutions;
    uint256 public ghostVetoes;
    uint256 public ghostHeartbeats;
    uint256 public ghostDeepestRung;

    /// @dev care outflow per (epoch, category). The vault bumps its epoch on
    ///      every budget reset and period rollover, and a cap change also forces
    ///      a reset — so a cap is constant within an epoch and this is a fair
    ///      comparison.
    mapping(uint64 => mapping(bytes32 => uint256)) public ghostCareSpentByEpochCat;
    mapping(uint64 => uint256) public ghostCareSpentByEpoch;

    uint256 public callsTotal;
    mapping(string => uint256) public callsByAction;

    /// @dev Packed into a struct because eleven constructor parameters overflow
    ///      the stack on the legacy pipeline, and turning on via_ir for the whole
    ///      project to work around one test constructor is the wrong trade.
    struct Actors {
        HeirloomVault vault;
        MockUSDC usdc;
        address[3] guardians;
        address[3] heirs;
        address careGuardian;
        address thief;
        address randomCaller;
        address[2] rotationTargets;
        address[3] carePayeePool;
        bytes32[2] categories;
        uint256 seeded;
    }

    constructor(Actors memory a) {
        vault = a.vault;
        usdc = a.usdc;
        guardians = a.guardians;
        heirs = a.heirs;
        careGuardian = a.careGuardian;
        thief = a.thief;
        randomCaller = a.randomCaller;
        rotationTargets = a.rotationTargets;
        carePayeePool = a.carePayeePool;
        categories = a.categories;
        ghostTotalIn = a.seeded;
    }

    // ---------------------------------------------------------------
    // Bookkeeping
    // ---------------------------------------------------------------

    /// @notice A hash over everything that may only change through a matured,
    ///         un-vetoed proposal. Deliberately excludes `lastActivity`, the care
    ///         budget counters and the epoch — those move on ordinary activity.
    function configFingerprint() public view returns (bytes32) {
        bytes memory acc = abi.encodePacked(vault.owner(), vault.guardianThreshold(), vault.careGuardian());

        address[] memory gs = vault.guardians();
        for (uint256 i = 0; i < gs.length; i++) {
            acc = abi.encodePacked(acc, gs[i]);
        }

        uint256 n = vault.beneficiaryCount();
        for (uint256 i = 0; i < n; i++) {
            (address payee, uint32 window) = vault.beneficiaries(i);
            acc = abi.encodePacked(acc, payee, window);
        }

        (uint32 a, uint32 b, uint32 c, uint32 d) = vault.ladder();
        (uint128 cap,,) = vault.careBudget();
        acc = abi.encodePacked(acc, a, b, c, d, cap, vault.carePeriod());

        bytes32[] memory cats = vault.careCategories();
        for (uint256 i = 0; i < cats.length; i++) {
            acc = abi.encodePacked(acc, cats[i], vault.careCategoryCap(cats[i]));
            address[] memory ps = vault.carePayees(cats[i]);
            for (uint256 j = 0; j < ps.length; j++) {
                acc = abi.encodePacked(acc, ps[j]);
            }
        }
        return keccak256(acc);
    }

    /// @notice Addresses the OWNER has designated in some role: the owner
    ///         themselves, every registered beneficiary, and every care payee in
    ///         the pool. Guardians and the thief are deliberately absent, so any
    ///         gain by them shows up as an unauthorized recipient.
    function _authorizedRecipients() internal view returns (address[] memory out) {
        out = new address[](1 + heirs.length + carePayeePool.length);
        uint256 k;
        out[k++] = vault.owner();
        for (uint256 i = 0; i < heirs.length; i++) {
            out[k++] = heirs[i];
        }
        for (uint256 i = 0; i < carePayeePool.length; i++) {
            out[k++] = carePayeePool[i];
        }
    }

    function _sumBalances(address[] memory who) internal view returns (uint256 total) {
        for (uint256 i = 0; i < who.length; i++) {
            total += usdc.balanceOf(who[i]);
        }
    }

    struct Snap {
        bytes32 fingerprint;
        uint256 vaultBal;
        uint256 authorizedBal;
        uint256 guardianBal;
        uint256 thiefBal;
    }

    function _snap() internal view returns (Snap memory) {
        return Snap({
            fingerprint: configFingerprint(),
            vaultBal: usdc.balanceOf(address(vault)),
            authorizedBal: _sumBalances(_authorizedRecipients()),
            guardianBal: usdc.balanceOf(guardians[0]) + usdc.balanceOf(guardians[1])
                + usdc.balanceOf(guardians[2]),
            thiefBal: usdc.balanceOf(thief)
        });
    }

    /// @dev `role` attributes a gain to the kind of actor that caused it.
    ///      `mayChangeConfig` is true only for `execute`, the one entry point
    ///      allowed to apply a matured proposal.
    modifier tracked(uint8 role, bool mayChangeConfig, string memory action) {
        Snap memory before = _snap();

        _;

        Snap memory nowSnap = _snap();

        if (nowSnap.vaultBal < before.vaultBal) {
            uint256 moved = before.vaultBal - nowSnap.vaultBal;
            ghostTotalOut += moved;

            // Every unit that left must have landed on an owner-designated
            // address. If the sums do not reconcile, something else was paid.
            if (
                nowSnap.authorizedBal < before.authorizedBal
                    || nowSnap.authorizedBal - before.authorizedBal != moved
            ) {
                ghostUnauthorizedRecipient = true;
            }
        } else if (nowSnap.vaultBal > before.vaultBal) {
            ghostTotalIn += nowSnap.vaultBal - before.vaultBal;
        }

        // Nobody with a mere trigger capability may profit from using it.
        if (nowSnap.guardianBal > before.guardianBal) ghostGuardianGainedFunds = true;
        if (nowSnap.thiefBal > before.thiefBal) ghostThiefGainedFunds = true;
        if (role == ROLE_GUARDIAN && nowSnap.guardianBal > before.guardianBal) {
            ghostGuardianGainedFunds = true;
        }

        if (nowSnap.fingerprint != before.fingerprint) {
            if (!mayChangeConfig) {
                ghostConfigChangedWithoutExecute = true;
                if (role == ROLE_THIEF) ghostThiefChangedConfig = true;
            }
        }

        uint256 rung = uint256(vault.state());
        if (rung <= uint256(T.VaultState.Claimable) && rung > ghostDeepestRung) ghostDeepestRung = rung;

        callsTotal++;
        callsByAction[action]++;
    }

    /// @dev Every owner-authenticated action must leave the vault Active — that
    ///      is invariant 1 observed at the moment it should hold, rather than
    ///      inferred later.
    function _assertOwnerActionReset() internal {
        if (vault.state() != T.VaultState.Active) ghostOwnerActionLeftEscalated = true;
    }

    function _owner() internal view returns (address) {
        return vault.owner();
    }

    function _guardian(uint256 seed) internal view returns (address) {
        return guardians[seed % 3];
    }

    function _category(uint256 seed) internal view returns (bytes32) {
        return categories[seed % 2];
    }

    // ===============================================================
    // Time
    // ===============================================================

    /// @notice Advance the clock. The band spans "nothing matures" to "several
    ///         rungs at once", so sequences hit both the 7-day timelock edge and
    ///         the 90-day ladder edges.
    function warp(uint256 secs) external tracked(ROLE_ANY, false, "warp") {
        secs = bound(secs, 1 hours, 200 days);
        vm.warp(block.timestamp + secs);
    }

    /// @notice Jump straight to a chosen rung (plus jitter). Without this the
    ///         fuzzer almost never reaches CareMode or Claimable: most actions are
    ///         owner actions, every one of them resets the clock by design, and
    ///         the odds of a long enough run of non-owner calls are poor. This is
    ///         a coverage device, not a shortcut — it only moves `block.timestamp`,
    ///         which anyone can wait for in reality.
    function warpToRung(uint256 rungSeed, uint256 jitter) external tracked(ROLE_ANY, false, "warpToRung") {
        (uint32 nag, uint32 alert, uint32 care, uint32 claimable) = vault.ladder();
        uint256 target;
        uint256 pick = rungSeed % 4;
        if (pick == 0) target = nag;
        else if (pick == 1) target = alert;
        else if (pick == 2) target = care;
        else target = claimable;

        // Land at, just before, or well past the boundary.
        uint256 j = bound(jitter, 0, 120 days);
        vm.warp(vault.lastActivity() + target + j);
    }

    // ===============================================================
    // Owner
    // ===============================================================

    function ownerHeartbeat() external tracked(ROLE_OWNER, false, "ownerHeartbeat") {
        vm.prank(_owner());
        try vault.heartbeat() {
            ghostHeartbeats++;
            _assertOwnerActionReset();
        } catch {}
    }

    function ownerWithdraw(uint256 amount) external tracked(ROLE_OWNER, false, "ownerWithdraw") {
        uint256 bal = usdc.balanceOf(address(vault));
        if (bal == 0) return;
        // Cap a single withdrawal at a tenth of the balance. A full drain is
        // legal, but a fuzzer that empties the vault early explores nothing
        // afterwards — every claim and care spend then dies on NothingToClaim.
        amount = bound(amount, 1, bal / 10 + 1);

        vm.prank(_owner());
        try vault.withdraw(amount) {
            _assertOwnerActionReset();
        } catch {}
    }

    function ownerDeposit(uint256 amount) external tracked(ROLE_OWNER, false, "ownerDeposit") {
        amount = bound(amount, 1e6, 50_000e6);
        address o = _owner();
        usdc.mint(o, amount);

        vm.startPrank(o);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount) {
            _assertOwnerActionReset();
        } catch {}
        vm.stopPrank();
    }

    function ownerProposeCarePayees(uint256 catSeed, uint256 payeeSeed)
        external
        tracked(ROLE_OWNER, false, "ownerProposeCarePayees")
    {
        address[] memory next = new address[](1);
        next[0] = carePayeePool[payeeSeed % 3];

        vm.prank(_owner());
        try vault.proposeCarePayees(_category(catSeed), next) {
            _assertOwnerActionReset();
        } catch {}
    }

    function ownerProposeLadder(uint32 nag, uint32 alert, uint32 care, uint32 claimable)
        external
        tracked(ROLE_OWNER, false, "ownerProposeLadder")
    {
        // Keep it monotonic most of the time so the proposal is queueable; the
        // validator rejects the rest, which is itself worth exercising.
        nag = uint32(bound(nag, 1 days, 100 days));
        alert = uint32(bound(alert, uint256(nag) + 1, 200 days));
        care = uint32(bound(care, uint256(alert) + 1, 300 days));
        claimable = uint32(bound(claimable, uint256(care) + 1, 400 days));

        vm.prank(_owner());
        try vault.proposeLadder(
            T.LadderConfig({
                nagAfter: nag, guardianAlertAfter: alert, careModeAfter: care, claimableAfter: claimable
            })
        ) {
            _assertOwnerActionReset();
        } catch {}
    }

    function ownerProposeBeneficiaries(uint256 seed)
        external
        tracked(ROLE_OWNER, false, "ownerProposeBeneficiaries")
    {
        T.Beneficiary[] memory next = new T.Beneficiary[](3);
        next[0] = T.Beneficiary({payee: heirs[seed % 3], window: uint32(bound(seed, 1 days, 90 days))});
        next[1] = T.Beneficiary({payee: heirs[(seed + 1) % 3], window: uint32(bound(seed, 1 days, 90 days))});
        next[2] = T.Beneficiary({payee: heirs[(seed + 2) % 3], window: 0});

        vm.prank(_owner());
        try vault.proposeBeneficiaries(next) {
            _assertOwnerActionReset();
        } catch {}
    }

    function ownerVeto(uint256 idSeed) external tracked(ROLE_OWNER, false, "ownerVeto") {
        uint256 count = vault.proposalCount();
        if (count == 0) return;
        uint256 id = bound(idSeed, 0, count - 1);

        vm.prank(_owner());
        try vault.veto(id) {
            ghostVetoes++;
            _assertOwnerActionReset();
        } catch {}
    }

    // ===============================================================
    // Recovery guardians — may propose and approve, nothing else
    // ===============================================================

    function guardianProposeRotation(uint256 gSeed, uint256 targetSeed)
        external
        tracked(ROLE_GUARDIAN, false, "guardianProposeRotation")
    {
        vm.prank(_guardian(gSeed));
        try vault.proposeRotation(rotationTargets[targetSeed % 2]) {} catch {}
    }

    function guardianApproveRotation(uint256 gSeed, uint256 idSeed)
        external
        tracked(ROLE_GUARDIAN, false, "guardianApproveRotation")
    {
        uint256 count = vault.proposalCount();
        if (count == 0) return;
        uint256 id = bound(idSeed, 0, count - 1);

        vm.prank(_guardian(gSeed));
        try vault.approveRotation(id) {} catch {}
    }

    /// @notice A guardian trying to move money directly, every way the ABI
    ///         allows. All of these must fail; the tracker notices if one does not.
    function guardianTriesToMoveFunds(uint256 gSeed, uint256 amount, uint256 tierSeed)
        external
        tracked(ROLE_GUARDIAN, false, "guardianTriesToMoveFunds")
    {
        address g = _guardian(gSeed);
        amount = bound(amount, 1, 100_000e6);

        vm.startPrank(g);
        try vault.withdraw(amount) {} catch {}
        // A guardian MAY succeed here since Q11 — and must still gain nothing.
        try vault.claim(bound(tierSeed, 0, 2)) {} catch {}
        try vault.careSpend(g, _category(gSeed), amount) {} catch {}
        vm.stopPrank();
    }

    /// @dev Books a landed care spend against the epoch it was charged to and
    ///      checks both ceilings. Shared so neither care action has to hold these
    ///      locals in its own frame.
    function _recordCareSpend(bytes32 cat, uint256 amount, bool approvedAtCallTime) internal {
        ghostCareSpends++;
        if (!approvedAtCallTime) ghostPaidUnapprovedPayee = true;

        uint64 epoch = vault.careEpoch();
        ghostCareSpentByEpochCat[epoch][cat] += amount;
        ghostCareSpentByEpoch[epoch] += amount;

        (uint128 globalCap,,) = vault.careBudget();
        if (ghostCareSpentByEpochCat[epoch][cat] > vault.careCategoryCap(cat)) ghostCareCapBreached = true;
        if (ghostCareSpentByEpoch[epoch] > globalCap) ghostCareCapBreached = true;
    }

    // ===============================================================
    // Care guardian
    // ===============================================================

    function careSpend(uint256 catSeed, uint256 payeeSeed, uint256 amount)
        external
        tracked(ROLE_CARE, false, "careSpend")
    {
        bytes32 cat = _category(catSeed);
        address payee = carePayeePool[payeeSeed % 3];
        amount = bound(amount, 1, 600e6); // straddles the 500e6 period cap

        bool approvedAtCallTime = vault.isApprovedCarePayee(cat, payee);

        // A payment landing on an address the owner never approved would be a
        // direct violation of the Q3 fix; charged to the epoch it books against,
        // since the call may roll the period forward on its way in.
        vm.prank(careGuardian);
        try vault.careSpend(payee, cat, amount) {
            _recordCareSpend(cat, amount, approvedAtCallTime);
        } catch {}
    }

    // ===============================================================
    // Heirs
    // ===============================================================

    function heirClaim(uint256 heirSeed, uint256 tierSeed) external tracked(ROLE_HEIR, false, "heirClaim") {
        uint256 tier = bound(tierSeed, 0, 2);
        address caller = heirs[heirSeed % 3];

        (address registered,) = vault.beneficiaries(tier);
        uint256 beforeBal = usdc.balanceOf(registered);
        uint256 vaultBal = usdc.balanceOf(address(vault));

        vm.prank(caller);
        try vault.claim(tier) {
            ghostClaims++;
            // Funds may only ever land on the address registered for that tier.
            if (usdc.balanceOf(registered) != beforeBal + vaultBal) ghostClaimPaidWrongAddress = true;
        } catch {}
    }

    // ===============================================================
    // Execution — permissionless by design
    // ===============================================================

    function anyoneExecute(uint256 idSeed, uint256 actorSeed)
        external
        tracked(ROLE_ANY, true, "anyoneExecute")
    {
        uint256 count = vault.proposalCount();
        if (count == 0) return;
        uint256 id = bound(idSeed, 0, count - 1);

        address ownerBefore = vault.owner();
        address caller = actorSeed % 2 == 0 ? randomCaller : _guardian(actorSeed);

        vm.prank(caller);
        try vault.execute(id) {
            ghostExecutions++;
            if (vault.owner() != ownerBefore) {
                ghostRotated = true;
                ghostRotations++;
            }
        } catch {}
    }

    /// @notice The thief executing a matured proposal is legitimate — execution is
    ///         permissionless on purpose, and the proposal was still owner-queued
    ///         and could have been vetoed. Tracked separately so invariant 6 can
    ///         allow exactly this and nothing else.
    function thiefExecute(uint256 idSeed) external tracked(ROLE_ANY, true, "thiefExecute") {
        uint256 count = vault.proposalCount();
        if (count == 0) return;
        uint256 id = bound(idSeed, 0, count - 1);

        vm.prank(thief);
        try vault.execute(id) {
            ghostExecutions++;
        } catch {}
    }

    /// @notice The assisted-claim path (Q11): an actor with no role at all
    ///         triggers the payout so a non-transacting heir still receives.
    ///         Sometimes the thief tries it, which is the interesting case —
    ///         they pay the gas and the heir gets the money.
    function helperTriggersClaim(uint256, uint256 whoSeed, uint256 jitter)
        external
        tracked(ROLE_ANY, false, "helperTriggersClaim")
    {
        // Land in the claim window first. Without this the helper almost always
        // meets a non-Claimable vault, the call reverts, and the assisted path
        // is never actually exercised — the invariants guarding it would pass
        // while never having seen a successful assisted claim.
        (,,, uint32 claimable) = vault.ladder();
        vm.warp(vault.lastActivity() + claimable + bound(jitter, 0, 200 days));

        uint256 tier = vault.activeTier();
        address helper = whoSeed % 2 == 0 ? randomCaller : thief;

        (address registered,) = vault.beneficiaries(tier);
        uint256 beforeBal = usdc.balanceOf(registered);
        uint256 vaultBal = usdc.balanceOf(address(vault));

        vm.prank(helper);
        try vault.claim(tier) {
            ghostClaims++;
            ghostAssistedClaims++;
            if (usdc.balanceOf(registered) != beforeBal + vaultBal) {
                ghostClaimPaidWrongAddress = true;
            }
        } catch {}
    }

    // ===============================================================
    // Composite flows
    // ---------------------------------------------------------------
    // The atomic actions above explore arbitrary interleavings, but some states
    // are only reachable through a specific ORDER — a rotation needs propose,
    // approve, wait seven days, execute, in that sequence. Uniform random
    // selection produces that ordering vanishingly rarely, so those states stay
    // unvisited and the invariants guarding them pass vacuously.
    //
    // These assemble the legal flow so the deep states are actually reached.
    // They assert nothing themselves; the same ghosts and the same invariants
    // apply, and the atomic actions remain available to interleave around them.
    // ===============================================================

    /// @notice Drive a full M-of-N rotation to completion.
    function completeRotationFlow(uint256 targetSeed, uint256 extraWait)
        external
        tracked(ROLE_ANY, true, "completeRotationFlow")
    {
        address target = rotationTargets[targetSeed % 2];
        address ownerBefore = vault.owner();

        vm.prank(guardians[0]);
        uint256 id;
        try vault.proposeRotation(target) returns (uint256 newId) {
            id = newId;
        } catch {
            return;
        }

        vm.prank(guardians[1]);
        try vault.approveRotation(id) {} catch {}

        vm.warp(block.timestamp + 7 days + bound(extraWait, 0, 30 days));

        vm.prank(randomCaller);
        try vault.execute(id) {
            ghostExecutions++;
            if (vault.owner() != ownerBefore) {
                ghostRotated = true;
                ghostRotations++;
            }
        } catch {}
    }

    /// @notice Land inside the care-mode window and spend there.
    function careSpendInCareMode(uint256 catSeed, uint256 payeeSeed, uint256 amount, uint256 jitter)
        external
        tracked(ROLE_CARE, false, "careSpendInCareMode")
    {
        (,, uint32 care, uint32 claimable) = vault.ladder();
        // Stay strictly inside [careModeAfter, claimableAfter) so the state is
        // CareMode when the call lands.
        uint256 j = bound(jitter, 0, uint256(claimable) - uint256(care) - 1);
        vm.warp(vault.lastActivity() + care + j);

        _spendAs(_category(catSeed), carePayeePool[payeeSeed % 3], bound(amount, 1, 600e6));
    }

    function _spendAs(bytes32 cat, address payee, uint256 amount) internal {
        bool approvedAtCallTime = vault.isApprovedCarePayee(cat, payee);
        vm.prank(careGuardian);
        try vault.careSpend(payee, cat, amount) {
            _recordCareSpend(cat, amount, approvedAtCallTime);
        } catch {}
    }

    /// @notice Land in the claim window and let the tier that is actually open
    ///         claim. Sometimes the right payee calls, sometimes the wrong one.
    function claimWhenClaimable(uint256 jitter, uint256 wrongCaller)
        external
        tracked(ROLE_HEIR, false, "claimWhenClaimable")
    {
        (,,, uint32 claimable) = vault.ladder();
        vm.warp(vault.lastActivity() + claimable + bound(jitter, 0, 200 days));

        uint256 tier = vault.activeTier();
        (address registered,) = vault.beneficiaries(tier);

        address caller = wrongCaller % 4 == 0 ? thief : registered;
        uint256 beforeBal = usdc.balanceOf(registered);
        uint256 vaultBal = usdc.balanceOf(address(vault));

        vm.prank(caller);
        try vault.claim(tier) {
            ghostClaims++;
            if (usdc.balanceOf(registered) != beforeBal + vaultBal) ghostClaimPaidWrongAddress = true;
        } catch {}
    }

    // ===============================================================
    // Thief — an address holding no role whatsoever
    // ===============================================================

    /// @notice Every state-changing entry point on the vault, called by someone
    ///         with no rights. Not one of them may move funds or alter config.
    function thiefTriesEverything(uint256 amount, uint256 tierSeed, uint256 catSeed)
        external
        tracked(ROLE_THIEF, false, "thiefTriesEverything")
    {
        amount = bound(amount, 1, 100_000e6);
        uint256 tier = bound(tierSeed, 0, 2);
        bytes32 cat = _category(catSeed);

        address[] memory evil = new address[](1);
        evil[0] = thief;

        T.Beneficiary[] memory evilHeirs = new T.Beneficiary[](2);
        evilHeirs[0] = T.Beneficiary({payee: thief, window: 1 days});
        evilHeirs[1] = T.Beneficiary({payee: thief, window: 0});

        vm.startPrank(thief);
        try vault.heartbeat() {} catch {}
        try vault.withdraw(amount) {} catch {}
        try vault.claim(tier) {} catch {}
        try vault.careSpend(thief, cat, amount) {} catch {}
        try vault.proposeCarePayees(cat, evil) {} catch {}
        try vault.proposeBeneficiaries(evilHeirs) {} catch {}
        try vault.proposeRotation(thief) {} catch {}
        try vault.approveRotation(0) {} catch {}
        try vault.veto(0) {} catch {}
        vm.stopPrank();
    }
}
