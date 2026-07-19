// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigGuard} from "./ConfigGuard.sol";
import {HeirloomTypes as T} from "./HeirloomTypes.sol";

/// @title ClaimsModule
/// @notice Cascading claims (PRD §4 MUST-3): an ordered beneficiary list, a claim
///         window per tier, automatic cascade when a window lapses, and a charity
///         terminal that never expires.
/// @dev UNAUDITED TESTNET CODE — do not use with real funds.
///
///      INVARIANT 6 — funds never dead-end — is enforced by construction, in two
///      places:
///        1. `_validateBeneficiaries` refuses any list without a real terminal
///           payee, so a vault can never be configured into a dead end.
///        2. `activeTierAt` returns the LAST tier for all sufficiently large
///           elapsed times. The terminal tier has no expiry, so at every instant
///           from `claimableAt` onward, exactly one tier is open and its payee
///           can extract the balance.
///
///      The cascade is a PURE function of elapsed time — it is derived on read,
///      never stored. Nothing has to "advance" it: no keeper, no cron, no
///      cooperating actor. An heir who never shows up cannot stall the tier
///      behind them, which is precisely how a stranded-funds bug would arise.
///
///      INVARIANT 4 — the claim path takes a tier INDEX and nothing else. There
///      is no destination parameter anywhere in this module, so a caller has no
///      way to name where money goes; it can only ever reach the address the
///      owner pre-registered.
abstract contract ClaimsModule is ConfigGuard {
    bytes32 internal constant KIND_BENEFICIARIES = keccak256("SET_BENEFICIARIES");

    T.Beneficiary[] internal _beneficiaries;

    /// @notice Absorbing: once the funds are distributed they cannot be recalled.
    bool public isClaimed;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function beneficiaries(uint256 index) external view returns (address payee, uint32 window) {
        T.Beneficiary storage b = _beneficiaries[index];
        return (b.payee, b.window);
    }

    function beneficiaryCount() external view returns (uint256) {
        return _beneficiaries.length;
    }

    /// @notice Which tier may claim at `nowTs`, given the vault became claimable
    ///         at `claimableAt`.
    /// @dev Windows are cumulative from `claimableAt`. Boundaries are handled so
    ///      that a tier owns `[start, start + window)` and the NEXT tier owns the
    ///      instant the window closes — no gap, no overlap, and no reliance on
    ///      strictly increasing timestamps (Arc).
    function activeTierAt(uint64 claimableAt, uint64 nowTs) public view returns (uint256) {
        uint256 n = _beneficiaries.length;
        if (n == 0) revert T.NoTerminalBeneficiary();
        if (nowTs <= claimableAt) return 0;

        uint256 elapsed = uint256(nowTs) - uint256(claimableAt);

        // Walk every non-terminal tier; the first whose cumulative window still
        // contains `elapsed` is open.
        uint256 cumulative;
        for (uint256 i = 0; i + 1 < n; i++) {
            cumulative += _beneficiaries[i].window;
            if (elapsed < cumulative) return i;
        }

        // Past every window: the terminal tier, open forever. This return is
        // what makes invariant 6 true — there is no time at which the loop
        // falls through to "nobody".
        return n - 1;
    }

    // ---------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------

    function _setBeneficiaries(T.Beneficiary[] memory next) internal {
        _validateBeneficiaries(next);

        delete _beneficiaries;
        for (uint256 i = 0; i < next.length; i++) {
            _beneficiaries.push(next[i]);
        }
    }

    /// @dev Validated at PROPOSE time as well as apply time, so a malformed list
    ///      is rejected immediately rather than sitting in the queue for a week
    ///      and then failing.
    ///
    ///      A zero payee anywhere is fatal, not just in the terminal slot: on Arc
    ///      a transfer to the zero address reverts, so a zero-payee tier would be
    ///      an unclaimable window that silently delays the cascade.
    function _validateBeneficiaries(T.Beneficiary[] memory next) internal pure {
        if (next.length == 0) revert T.NoTerminalBeneficiary();

        for (uint256 i = 0; i < next.length; i++) {
            if (next[i].payee == address(0)) revert T.ZeroAddress();
        }
    }
}
