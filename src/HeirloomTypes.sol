// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HeirloomTypes
/// @notice Shared enums, structs, errors and events for the Heirloom vault family.
/// @dev UNAUDITED TESTNET CODE — do not use with real funds. See README.
///
/// Arc notes that shape these types:
///  - USDC exposes 6 decimals on the ERC-20 surface; every amount here is 6dp.
///  - Block timestamps are non-decreasing, NOT strictly increasing: two blocks
///    may share a timestamp. All comparisons that consume these types must use
///    inclusive boundaries so an equal timestamp never flips a decision midway.
library HeirloomTypes {
    /// @notice The vault lifecycle, exactly as PRD §5.
    /// @dev `Claimed` is absorbing. `Recovered` is modelled as a transition, not a
    ///      resting state — see docs/OPEN-QUESTIONS.md Q8. Ordinals are ordered by
    ///      escalation so tests can assert monotonicity over elapsed time.
    enum VaultState {
        Active, // 0 — owner is demonstrably present
        Nagging, // 1 — tier 1: reminders fire
        GuardianAlert, // 2 — tier 2: guardians notified, fast-track available
        CareMode, // 3 — tier 3: capped guardian spending
        Claimable, // 4 — tier 4: beneficiaries may claim in order
        Claimed, // 5 — terminal: funds distributed
        Recovered // 6 — control rotated to a new owner key
    }

    /// @notice Tier thresholds, in seconds of silence since `lastActivity`.
    /// @dev Defaults are 90/180/270/365 days; tests use seconds-scale values.
    ///      Must be strictly increasing — enforced by `validate`.
    struct LadderConfig {
        uint32 nagAfter;
        uint32 guardianAlertAfter;
        uint32 careModeAfter;
        uint32 claimableAfter;
    }

    /// @notice One rung of the cascading beneficiary list (PRD §2, §5).
    /// @param payee     Pre-registered destination. Claims can pay nobody else —
    ///                  there is no free-text destination anywhere in the ABI
    ///                  (invariant 4).
    /// @param window    Seconds this tier may claim for, measured from the tier's
    ///                  own start. Ignored for the terminal tier, which never
    ///                  expires (invariant 6 — funds cannot dead-end).
    struct Beneficiary {
        address payee;
        uint32 window;
    }

    /// @notice A pending config mutation under the 7-day guard (invariant 2).
    /// @param kind     Discriminator for the payload.
    /// @param data     ABI-encoded arguments, decoded only at execute time.
    /// @param eta      Earliest execution timestamp. Inclusive: `now >= eta` is
    ///                 ripe, so an equal-timestamp Arc block still executes.
    /// @param proposer Who queued it (owner or guardian, depending on `kind`).
    struct Proposal {
        bytes32 kind;
        bytes data;
        uint64 eta;
        address proposer;
        bool executed;
        bool vetoed;
    }

    /// @notice Care-mode spending budget (PRD §4 SHOULD-6, §6).
    /// @param cap       Per-period ceiling, 6dp.
    /// @param spent     Consumed in the current period, 6dp.
    /// @param periodEnd Timestamp the current period rolls over at.
    struct Budget {
        uint128 cap;
        uint128 spent;
        uint64 periodEnd;
    }

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error NotGuardian();
    error NotCareGuardian();
    error ZeroAddress();
    error LadderNotMonotonic();
    error WrongState(VaultState actual, VaultState required);
    error ProposalMissing(uint256 id);
    error ProposalNotRipe(uint256 id, uint64 eta, uint64 nowTs);
    error ProposalDead(uint256 id);
    error ThresholdUnreachable(uint256 threshold, uint256 guardianCount);
    error DuplicateGuardian(address guardian);
    error AlreadyApproved(address guardian);
    error NotEnoughApprovals(uint256 have, uint256 need);
    error NoTerminalBeneficiary();
    error TierNotOpen(uint256 tier);
    error NothingToClaim();
    error CapExceeded(uint256 requested, uint256 remaining);
    error CategoryNotAllowed(bytes32 category);

    // ---------------------------------------------------------------------
    // Events — PRD §5 requires a full trail; off-chain services observe only.
    // ---------------------------------------------------------------------

    event Heartbeat(address indexed owner, uint64 at, VaultState from);
    event ProposalQueued(
        uint256 indexed id, bytes32 indexed kind, address indexed proposer, uint64 eta, bytes data
    );
    event ProposalExecuted(uint256 indexed id, bytes32 indexed kind);
    event ProposalVetoed(uint256 indexed id, bytes32 indexed kind, address indexed by);
    event RotationApproved(uint256 indexed id, address indexed guardian, uint256 approvals);
    event OwnerRotated(address indexed from, address indexed to);
    event Claimed_(uint256 indexed tier, address indexed payee, uint256 amount);
    event CareSpend(
        address indexed guardian, address indexed payee, bytes32 indexed category, uint256 amount
    );
    event CareModeRevoked(uint64 at);
}
