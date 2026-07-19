// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stand-in for Arc USDC. The detail that matters for the vault is the
///         ERC-20 decimals surface: SIX, not eighteen. Every amount in the vault
///         and in these tests is 6dp, so `1e6 == $1.00`.
/// @dev Also mirrors Arc's behaviour of reverting on transfers to the zero
///      address, so tests exercise the same failure the real chain would produce.
/// @dev UNAUDITED TESTNET CODE.
contract MockUSDC is ERC20 {
    error TransferToZeroAddress();

    constructor() ERC20("USD Coin", "USDC") {}

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Arc rejects zero-address transfers; OZ v5 already reverts on this
    ///      path, but the explicit check pins the behaviour our vault relies on.
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(0)) revert TransferToZeroAddress();
        super._update(from, to, value);
    }
}
