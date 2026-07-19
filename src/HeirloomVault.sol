// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ConfigGuard} from "./ConfigGuard.sol";
import {RecoveryModule} from "./RecoveryModule.sol";
import {ClaimsModule} from "./ClaimsModule.sol";
import {LivenessLadder} from "./LivenessLadder.sol";
import {HeirloomTypes as T} from "./HeirloomTypes.sol";

/// @title HeirloomVault
/// @notice A liveness-aware vault (PRD §5). Holds USDC on behalf of one owner and
///         escalates through `Active → Nagging → GuardianAlert → CareMode →
///         Claimable → Claimed/Recovered` as the owner goes quiet — so that lost
///         keys, lost people and lost agents do not strand money.
/// @dev UNAUDITED TESTNET CODE — DO NOT USE WITH REAL FUNDS. Not audited, not
///      reviewed, deployed to Arc testnet only.
///
///      Arc specifics honoured throughout:
///        - USDC exposes SIX decimals on its ERC-20 surface. Every amount in this
///          contract is 6dp; `1e6` is one dollar. No 18dp assumptions anywhere.
///        - Transfers to the zero address revert, so every configurable payee is
///          rejected at zero rather than discovered at payout time.
///        - Block timestamps are non-decreasing, not strictly increasing. Every
///          threshold here is inclusive, so two blocks sharing a timestamp are
///          idempotent instead of skipping a rung or stalling an execution.
///
///      Safety posture: OpenZeppelin `SafeERC20` and `ReentrancyGuard`, strict
///      checks-effects-interactions on every path that moves value, and a full
///      event trail — the off-chain services only ever observe, never custody.
contract HeirloomVault is RecoveryModule, ClaimsModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @param owner            Controller key. Rotatable by guardians, never by anyone else.
    /// @param asset            ERC-20 held by the vault (Arc USDC, 6dp).
    /// @param ladder           Tier thresholds in seconds.
    /// @param guardians        Recovery set.
    /// @param threshold        M in M-of-N.
    /// @param beneficiaries    Ordered heirs; the LAST entry is the terminal sink.
    /// @param careGuardian     Who may spend under care mode.
    /// @param careMonthlyCap   Global per-period ceiling, 6dp.
    /// @param carePeriod       Length of a care budgeting period, in seconds.
    /// @param careCategories   Allowlisted spend categories.
    /// @param careCategoryCaps Per-category ceiling, index-aligned with the above.
    struct InitParams {
        address owner;
        address asset;
        T.LadderConfig ladder;
        address[] guardians;
        uint256 threshold;
        T.Beneficiary[] beneficiaries;
        address careGuardian;
        uint128 careMonthlyCap;
        uint32 carePeriod;
        bytes32[] careCategories;
        uint128[] careCategoryCaps;
    }

    bytes32 internal constant KIND_LADDER = keccak256("SET_LADDER");
    bytes32 internal constant KIND_CARE = keccak256("SET_CARE_CONFIG");

    IERC20 public immutable asset;

    address public owner;

    /// @notice The single source of truth for the ladder. Every owner signature
    ///         stamps this, and nothing else resets it.
    uint64 public lastActivity;

    uint64 public lastRotationAt;

    T.LadderConfig public ladder;

    // --- Care mode -------------------------------------------------------

    address public careGuardian;
    uint32 public carePeriod;
    T.Budget internal _careBudget;

    /// @notice Bumped on every revoke and every period rollover. Category spend
    ///         is scoped to an epoch, so resetting the whole budget is one write
    ///         instead of a loop over categories.
    uint64 public careEpoch;

    bytes32[] internal _careCategories;
    mapping(bytes32 => bool) public careCategoryAllowed;
    mapping(bytes32 => uint128) public careCategoryCap;
    mapping(bytes32 => uint128) internal _careCategorySpent;
    mapping(bytes32 => uint64) internal _careCategoryEpoch;

    modifier onlyOwner() {
        if (msg.sender != owner) revert T.NotOwner();
        _;
    }

    constructor(InitParams memory p) {
        if (p.owner == address(0) || p.asset == address(0)) revert T.ZeroAddress();

        LivenessLadder.validate(p.ladder);
        _validateGuardians(p.guardians, p.threshold);
        _validateBeneficiaries(p.beneficiaries);

        owner = p.owner;
        asset = IERC20(p.asset);
        ladder = p.ladder;

        _setGuardians(p.guardians, p.threshold);
        _setBeneficiaries(p.beneficiaries);
        _setCareConfig(p.careGuardian, p.careMonthlyCap, p.carePeriod, p.careCategories, p.careCategoryCaps);

        lastActivity = uint64(block.timestamp);
    }

    // =====================================================================
    // State
    // =====================================================================

    /// @notice The vault's current rung.
    /// @dev `Claimed` is the one lifecycle fact that overrides the clock; it is
    ///      absorbing because distributed funds cannot be un-distributed.
    ///      Everything else is derived purely from elapsed silence.
    function state() public view returns (T.VaultState) {
        if (isClaimed) return T.VaultState.Claimed;
        return LivenessLadder.stateAt(lastActivity, uint64(block.timestamp), ladder);
    }

    function secondsUntilNextRung() external view returns (uint256) {
        return LivenessLadder.secondsUntilNextRung(lastActivity, uint64(block.timestamp), ladder);
    }

    function totalAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function careBudget() external view returns (uint128 cap, uint128 spent, uint64 periodEnd) {
        return (_careBudget.cap, _careBudget.spent, _careBudget.periodEnd);
    }

    function careCategories() external view returns (bytes32[] memory) {
        return _careCategories;
    }

    function careCategorySpent(bytes32 category) public view returns (uint128) {
        return _careCategoryEpoch[category] == careEpoch ? _careCategorySpent[category] : 0;
    }

    /// @notice Which beneficiary tier may claim right now.
    function activeTier() public view returns (uint256) {
        return activeTierAt(lastActivity + ladder.claimableAfter, uint64(block.timestamp));
    }

    // =====================================================================
    // INVARIANT 1 — any owner signature resets the ladder to Active
    // =====================================================================

    /// @notice The explicit "I'm alive" signal. Any other owner action does this
    ///         implicitly; this exists so proving liveness costs nothing but gas.
    function heartbeat() external onlyOwner {
        _touch();
    }

    /// @dev Called by EVERY owner-authenticated entry point. Centralising it is
    ///      what makes invariant 1 hold by construction rather than by
    ///      remembering to reset the clock in each function.
    ///
    ///      Reverts once `Claimed`: the funds are gone, there is nothing left to
    ///      protect, and accepting a heartbeat there would imply a clawback an
    ///      heir could never rely on. See docs/OPEN-QUESTIONS.md Q9.
    function _touch() internal {
        if (isClaimed) revert T.WrongState(T.VaultState.Claimed, T.VaultState.Active);

        T.VaultState from = state();
        lastActivity = uint64(block.timestamp);

        // Instant revoke (invariant 5): the guardian's allowance dies the moment
        // the owner reappears, and the unspent balance does not carry over.
        _resetCareBudget();
        if (from == T.VaultState.CareMode) emit T.CareModeRevoked(uint64(block.timestamp));

        emit T.Heartbeat(owner, uint64(block.timestamp), from);
    }

    // =====================================================================
    // Funds
    // =====================================================================

    /// @notice Deposit `amount` (6dp). Anyone may top the vault up; only the
    ///         owner's own deposit proves liveness.
    function deposit(uint256 amount) external nonReentrant {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (msg.sender == owner) _touch();
    }

    /// @notice Withdraw to the owner. There is no destination parameter — the
    ///         owner's own key is the only place this can go.
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        _touch(); // EFFECTS
        asset.safeTransfer(owner, amount); // INTERACTIONS
    }

    // =====================================================================
    // Claims — INVARIANT 4 and INVARIANT 6
    // =====================================================================

    /// @notice Claim the whole balance for the currently open tier.
    /// @dev Takes an INDEX, never an address: the destination is whatever the
    ///      owner pre-registered and cannot be influenced by the caller. Only
    ///      that registered payee may invoke it.
    function claim(uint256 tier) external nonReentrant {
        T.VaultState s = state();
        if (s != T.VaultState.Claimable) revert T.WrongState(s, T.VaultState.Claimable);

        if (tier != activeTier()) revert T.TierNotOpen(tier);

        address payee = _beneficiaries[tier].payee;
        if (msg.sender != payee) revert T.NotBeneficiary();

        uint256 amount = asset.balanceOf(address(this));
        if (amount == 0) revert T.NothingToClaim();

        // EFFECTS before INTERACTIONS — a reentrant claim finds the vault closed.
        isClaimed = true;

        emit T.Claimed_(tier, payee, amount);
        asset.safeTransfer(payee, amount);
    }

    // =====================================================================
    // Care mode — INVARIANT 5
    // =====================================================================

    /// @notice A capped, category-labelled payment made by the care guardian.
    /// @dev Deliberately does NOT call `_touch()`: this is a GUARDIAN acting, not
    ///      the owner. If it reset the ladder, a care guardian could hold the
    ///      vault in CareMode forever and block the cascade to the heirs
    ///      (docs/OPEN-QUESTIONS.md Q4).
    ///
    ///      Honest limitation: `category` is owner-allowlisted and auditable, but
    ///      it is asserted by the guardian, not proven. The AMOUNT caps — global
    ///      and per-category — are what actually bound a colluding guardian. See
    ///      docs/OPEN-QUESTIONS.md Q3.
    function careSpend(address payee, bytes32 category, uint256 amount) external nonReentrant {
        if (msg.sender != careGuardian) revert T.NotCareGuardian();
        if (payee == address(0)) revert T.ZeroAddress();

        T.VaultState s = state();
        if (s != T.VaultState.CareMode) revert T.WrongState(s, T.VaultState.CareMode);

        if (!careCategoryAllowed[category]) revert T.CategoryNotAllowed(category);

        _rollCarePeriodIfDue();

        // Global ceiling first: it is the binding constraint on total outflow.
        uint256 globalRemaining = _careBudget.cap - _careBudget.spent;
        if (amount > globalRemaining) revert T.CapExceeded(amount, globalRemaining);

        uint256 categoryRemaining = careCategoryCap[category] - careCategorySpent(category);
        if (amount > categoryRemaining) revert T.CapExceeded(amount, categoryRemaining);

        // EFFECTS
        // casting to 'uint128' is safe because `amount` was just bounded above by
        // `globalRemaining <= _careBudget.cap`, itself a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        _careBudget.spent += uint128(amount);
        // casting to 'uint128' is safe because `amount` was just bounded above by
        // `categoryRemaining <= careCategoryCap[category]`, itself a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        _careCategorySpent[category] = careCategorySpent(category) + uint128(amount);
        _careCategoryEpoch[category] = careEpoch;

        emit T.CareSpend(msg.sender, payee, category, amount);

        // INTERACTIONS
        asset.safeTransfer(payee, amount);
    }

    /// @dev Inclusive rollover (`>=`) for Arc's repeated timestamps.
    function _rollCarePeriodIfDue() internal {
        if (_careBudget.periodEnd == 0) {
            _careBudget.periodEnd = uint64(block.timestamp) + carePeriod;
            return;
        }
        // Timestamp comparison is intentional and safe here: a validator nudging
        // the clock by seconds can at most roll a spending period marginally
        // early. The ladder itself runs on 90-day rungs, where that drift is
        // meaningless.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= _careBudget.periodEnd) {
            careEpoch++;
            _careBudget.spent = 0;
            _careBudget.periodEnd = uint64(block.timestamp) + carePeriod;
        }
    }

    /// @dev Bumping the epoch invalidates every per-category tally at once.
    function _resetCareBudget() internal {
        careEpoch++;
        _careBudget.spent = 0;
        _careBudget.periodEnd = 0;
    }

    // =====================================================================
    // Config — INVARIANT 2: every mutation is proposed, delayed and vetoable
    // =====================================================================

    function proposeBeneficiaries(T.Beneficiary[] calldata next) external onlyOwner returns (uint256 id) {
        _validateBeneficiaries(next); // fail fast rather than after a week
        id = _queue(KIND_BENEFICIARIES, abi.encode(next), msg.sender);
        _touch();
    }

    function proposeGuardians(address[] calldata next, uint256 threshold)
        external
        onlyOwner
        returns (uint256 id)
    {
        _validateGuardians(next, threshold);
        id = _queue(KIND_GUARDIANS, abi.encode(next, threshold), msg.sender);
        _touch();
    }

    function proposeLadder(T.LadderConfig calldata next) external onlyOwner returns (uint256 id) {
        LivenessLadder.validate(next);
        id = _queue(KIND_LADDER, abi.encode(next), msg.sender);
        _touch();
    }

    function proposeCareConfig(
        address guardian,
        uint128 monthlyCap,
        uint32 period,
        bytes32[] calldata categories,
        uint128[] calldata caps
    ) external onlyOwner returns (uint256 id) {
        id = _queue(KIND_CARE, abi.encode(guardian, monthlyCap, period, categories, caps), msg.sender);
        _touch();
    }

    /// @notice Veto, plus the liveness signal that vetoing obviously implies.
    function veto(uint256 id) public override {
        super.veto(id);
        _touch();
    }

    /// @dev The single dispatch point for matured proposals. Reached only from
    ///      `ConfigGuard.execute`, past the delay, exactly once per proposal.
    function _applyProposal(uint256 id, bytes32 kind, bytes memory data) internal override {
        if (kind == KIND_ROTATE) {
            _applyRotation(id, data);
        } else if (kind == KIND_BENEFICIARIES) {
            _setBeneficiaries(abi.decode(data, (T.Beneficiary[])));
        } else if (kind == KIND_GUARDIANS) {
            (address[] memory next, uint256 threshold) = abi.decode(data, (address[], uint256));
            _setGuardians(next, threshold);
        } else if (kind == KIND_LADDER) {
            ladder = abi.decode(data, (T.LadderConfig));
        } else if (kind == KIND_CARE) {
            (
                address guardian,
                uint128 monthlyCap,
                uint32 period,
                bytes32[] memory categories,
                uint128[] memory caps
            ) = abi.decode(data, (address, uint128, uint32, bytes32[], uint128[]));
            _setCareConfig(guardian, monthlyCap, period, categories, caps);
        }
    }

    function _setCareConfig(
        address guardian,
        uint128 monthlyCap,
        uint32 period,
        bytes32[] memory categories,
        uint128[] memory caps
    ) internal {
        if (categories.length != caps.length) {
            revert T.CategoryNotAllowed(bytes32(0));
        }

        // Clear the previous allowlist so a removed category cannot be spent on.
        for (uint256 i = 0; i < _careCategories.length; i++) {
            careCategoryAllowed[_careCategories[i]] = false;
            careCategoryCap[_careCategories[i]] = 0;
        }
        delete _careCategories;

        for (uint256 i = 0; i < categories.length; i++) {
            careCategoryAllowed[categories[i]] = true;
            careCategoryCap[categories[i]] = caps[i];
            _careCategories.push(categories[i]);
        }

        careGuardian = guardian;
        carePeriod = period;
        _careBudget.cap = monthlyCap;

        // Any change to the care rules starts a clean period.
        _resetCareBudget();
        _careBudget.cap = monthlyCap;
    }

    // =====================================================================
    // Wiring
    // =====================================================================

    function _configOwner() internal view override returns (address) {
        return owner;
    }

    /// @dev Rotation re-arms the ladder so the vault is immediately live under the
    ///      new key. Recovering once must not permanently disarm the safety net
    ///      (docs/OPEN-QUESTIONS.md Q8). Funds are untouched — only the lock changes.
    function _setOwner(address newOwner) internal override {
        address previous = owner;
        owner = newOwner;
        lastRotationAt = uint64(block.timestamp);
        lastActivity = uint64(block.timestamp);
        _resetCareBudget();

        emit T.OwnerRotated(previous, newOwner);
    }
}
