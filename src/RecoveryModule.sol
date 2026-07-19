// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigGuard} from "./ConfigGuard.sol";
import {HeirloomTypes as T} from "./HeirloomTypes.sol";

/// @title RecoveryModule
/// @notice Social recovery (PRD §4 MUST-1): an M-of-N guardian set may rotate the
///         vault to a NEW owner key. No seed phrase required. The lock changes,
///         the house does not.
/// @dev UNAUDITED TESTNET CODE — do not use with real funds.
///
///      INVARIANT 3 is structural, not a check: guardians are given exactly two
///      capabilities here — `proposeRotation` and `approveRotation` — and neither
///      touches the asset. There is no guardian-callable path to a transfer
///      anywhere in this module, and rotation itself only rewrites the owner
///      address. A guardian majority that turns hostile still faces the 7-day
///      timelock and the old key's veto (PRD §6).
///
///      Approvals accrue against the proposal id and are counted at EXECUTE time,
///      not at propose time, so guardians can keep signing on during the delay —
///      which is the realistic flow when they are non-crypto humans being
///      contacted one at a time.
abstract contract RecoveryModule is ConfigGuard {
    bytes32 internal constant KIND_ROTATE = keccak256("ROTATE_OWNER");
    bytes32 internal constant KIND_GUARDIANS = keccak256("SET_GUARDIANS");

    address[] internal _guardians;
    mapping(address => bool) public isGuardian;

    /// @notice M in M-of-N.
    uint256 public guardianThreshold;

    /// @notice Approval tally per rotation proposal.
    mapping(uint256 => uint256) public rotationApprovals;
    mapping(uint256 => mapping(address => bool)) public hasApprovedRotation;

    modifier onlyGuardian() {
        if (!isGuardian[msg.sender]) revert T.NotGuardian();
        _;
    }

    /// @notice Rewrites the controller key. Implemented by the vault.
    function _setOwner(address newOwner) internal virtual;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function guardians() external view returns (address[] memory) {
        return _guardians;
    }

    function guardianCount() external view returns (uint256) {
        return _guardians.length;
    }

    // ---------------------------------------------------------------------
    // Guardian actions — the complete list. Note what is absent: anything
    // that moves value.
    // ---------------------------------------------------------------------

    /// @notice Queues a rotation to `newOwner` and counts the proposer as the
    ///         first approval.
    /// @dev Zero is rejected up front: rotating to the zero address would brick
    ///      the vault permanently, and on Arc a transfer there reverts anyway.
    function proposeRotation(address newOwner) external onlyGuardian returns (uint256 id) {
        if (newOwner == address(0)) revert T.ZeroAddress();

        id = _queue(KIND_ROTATE, abi.encode(newOwner), msg.sender);

        rotationApprovals[id] = 1;
        hasApprovedRotation[id][msg.sender] = true;
        emit T.RotationApproved(id, msg.sender, 1);
    }

    /// @notice Adds one guardian's approval to a pending rotation.
    function approveRotation(uint256 id) external onlyGuardian {
        T.Proposal storage p = _proposals[id];

        if (p.eta == 0 || p.kind != KIND_ROTATE) revert T.ProposalMissing(id);
        if (p.executed || p.vetoed) revert T.ProposalDead(id);
        if (hasApprovedRotation[id][msg.sender]) revert T.AlreadyApproved(msg.sender);

        hasApprovedRotation[id][msg.sender] = true;
        uint256 tally = ++rotationApprovals[id];
        emit T.RotationApproved(id, msg.sender, tally);
    }

    // ---------------------------------------------------------------------
    // Applied at execute time, past the timelock
    // ---------------------------------------------------------------------

    /// @dev The threshold is enforced HERE rather than at propose time, so that
    ///      a proposal which never gathers enough guardians simply cannot mature.
    function _applyRotation(uint256 id, bytes memory data) internal {
        uint256 tally = rotationApprovals[id];
        if (tally < guardianThreshold) revert T.NotEnoughApprovals(tally, guardianThreshold);

        address newOwner = abi.decode(data, (address));
        _setOwner(newOwner);
    }

    /// @notice Replaces the guardian set and threshold. Reachable only through
    ///         the config timelock, like every other mutation.
    function _setGuardians(address[] memory next, uint256 threshold) internal {
        _validateGuardians(next, threshold);

        // Clear the old set before writing the new one, or a removed guardian
        // would keep their privileges.
        uint256 oldLen = _guardians.length;
        for (uint256 i = 0; i < oldLen; i++) {
            isGuardian[_guardians[i]] = false;
        }
        delete _guardians;

        for (uint256 i = 0; i < next.length; i++) {
            isGuardian[next[i]] = true;
            _guardians.push(next[i]);
        }
        guardianThreshold = threshold;
    }

    /// @dev A threshold above the guardian count would make recovery impossible —
    ///      the exact stranding this product exists to prevent. Duplicates are
    ///      rejected because they would let one key satisfy an M-of-N vote alone.
    function _validateGuardians(address[] memory next, uint256 threshold) internal pure {
        if (threshold == 0 || threshold > next.length) {
            revert T.ThresholdUnreachable(threshold, next.length);
        }

        for (uint256 i = 0; i < next.length; i++) {
            if (next[i] == address(0)) revert T.ZeroAddress();
            for (uint256 j = i + 1; j < next.length; j++) {
                if (next[i] == next[j]) revert T.DuplicateGuardian(next[i]);
            }
        }
    }
}
