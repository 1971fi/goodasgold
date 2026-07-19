// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "./IERC20.sol";

/// Robinhood Stock Token = ERC-20 (18d) + ERC-8056 Scaled UI Amount extension.
/// uiMultiplier() encodes corporate actions (dividends/splits); raw balances never rebase.
/// NOTE: the Chainlink feed price ALREADY includes the multiplier — never apply it twice.
interface IStockToken is IERC20 {
    /// Current UI multiplier, 18 decimals fixed-point (1e18 = 1.0).
    function uiMultiplier() external view returns (uint256);

    /// Balance expressed in underlying shares (raw * uiMultiplier / 1e18).
    function balanceOfUI(address account) external view returns (uint256);

    /// UI-adjusted total supply.
    function totalSupplyUI() external view returns (uint256);

    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);
}
