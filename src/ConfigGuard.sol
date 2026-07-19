// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HeirloomTypes as T} from "./HeirloomTypes.sol";

/// @title ConfigGuard
/// @notice The anti-theft spine (PRD §2, §6): every configuration mutation —
///         heirs, guardians, timings — routes `propose → 7-day timelock →
///         execute`, is announced by an event on propose, and is vetoable by the
///         owner at any point before execute.
/// @dev UNAUDITED TESTNET CODE — do not use with real funds.
///
///      Why this shape:
///        - A thief who steals the owner key cannot silently redirect the safety
///          net. The proposal is public the moment it is queued, and the real
///          owner has a full week to cancel it. Without this the product is
///          broken — the PRD calls it the load-bearing security property.
///        - There are NO direct setters. `_applyProposal` is `internal` and is
///          reached from exactly one place: `execute`, past the delay. Any
///          subclass that adds a public setter breaks invariant 2, and the test
///          suite probes for exactly that.
///        - Veto stays available even AFTER the eta, right up until execution.
///          An owner returning from a month offline is still protected; ripeness
///          is not a point of no return.
///
///      Arc: ripeness is `now >= eta`, inclusive, so a block landing exactly on
///      the eta executes rather than stalling on a repeated timestamp.
abstract contract ConfigGuard {
    /// @notice The mandated delay on every config mutation. Not configurable —
    ///         a timelock a thief could shorten is not a timelock.
    uint64 public constant TIMELOCK = 7 days;

    mapping(uint256 => T.Proposal) internal _proposals;

    /// @notice Monotonic proposal counter; also the id of the next proposal.
    uint256 public proposalCount;

    /// @notice Who may veto. Supplied by the inheriting vault so the guard has no
    ///         opinion about how ownership is tracked (it rotates, after all).
    function _configOwner() internal view virtual returns (address);

    /// @notice Applies a matured proposal. Implemented by the vault; only ever
    ///         called from `execute`, past the delay, once.
    function _applyProposal(bytes32 kind, bytes memory data) internal virtual;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Full proposal record. Off-chain reminder services read this to
    ///         notify the owner that a change is pending (PRD §5).
    function proposals(uint256 id)
        external
        view
        returns (bytes32 kind, bytes memory data, uint64 eta, address proposer, bool executed, bool vetoed)
    {
        T.Proposal storage p = _proposals[id];
        return (p.kind, p.data, p.eta, p.proposer, p.executed, p.vetoed);
    }

    /// @notice True when the proposal exists, is alive, and its delay has elapsed.
    function isRipe(uint256 id) public view returns (bool) {
        T.Proposal storage p = _proposals[id];
        if (p.eta == 0 || p.executed || p.vetoed) return false;
        return block.timestamp >= p.eta;
    }

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @notice Queues a mutation and announces it. Mutates nothing else.
    /// @dev Internal: subclasses gate WHO may propose WHAT. The guard only
    ///      guarantees that whatever is queued waits out the delay in public.
    function _queue(bytes32 kind, bytes memory data, address proposer) internal returns (uint256 id) {
        id = proposalCount++;
        uint64 eta = uint64(block.timestamp) + TIMELOCK;

        _proposals[id] = T.Proposal({
            kind: kind, data: data, eta: eta, proposer: proposer, executed: false, vetoed: false
        });

        // The notification hook: off-chain services turn this into the email /
        // Telegram alert that makes the veto window meaningful.
        emit T.ProposalQueued(id, kind, proposer, eta, data);
    }

    /// @notice Executes a matured, un-vetoed proposal.
    /// @dev Permissionless by design: the delay and the veto are the security
    ///      properties, not the identity of the executor. Gating execution on the
    ///      owner would let a thief's proposal be blocked only by the same key the
    ///      thief holds, and would strand legitimate guardian rotations when the
    ///      owner is genuinely gone — the exact scenario this product exists for.
    ///      Checks-effects-interactions: the proposal is marked spent BEFORE
    ///      `_applyProposal` runs, so a reentrant call finds it dead.
    function execute(uint256 id) external {
        T.Proposal storage p = _proposals[id];

        if (p.eta == 0) revert T.ProposalMissing(id);
        if (p.executed || p.vetoed) revert T.ProposalDead(id);
        if (block.timestamp < p.eta) revert T.ProposalNotRipe(id, p.eta, uint64(block.timestamp));

        // EFFECTS before INTERACTIONS.
        p.executed = true;

        bytes32 kind = p.kind;
        _applyProposal(kind, p.data);

        emit T.ProposalExecuted(id, kind);
    }

    /// @notice Cancels a pending proposal. The owner's escape hatch.
    /// @dev Available at ANY point before execution, including after the eta has
    ///      passed. Deliberately not restricted to the pre-eta window.
    function veto(uint256 id) external {
        if (msg.sender != _configOwner()) revert T.NotOwner();

        T.Proposal storage p = _proposals[id];
        if (p.eta == 0) revert T.ProposalMissing(id);
        if (p.executed || p.vetoed) revert T.ProposalDead(id);

        p.vetoed = true;
        emit T.ProposalVetoed(id, p.kind, msg.sender);
    }
}
