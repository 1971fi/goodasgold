// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";

/// BurnMode — launch-default sink (Open Decision #2 resolved 2026-07-16).
/// The BuybackEngine market-buys TTP and takes the output here; burn() sweeps the
/// full balance to 0xdead. Value accrues via supply reduction — nothing is
/// distributed to anyone (non-distribution securities posture).
contract BurnMode {
    address public constant BURN_ADDRESS = address(0xdead);
    IERC20 public immutable ttp;

    uint256 public totalBurned;

    event Burned(uint256 amount, uint256 totalBurned);

    error ZeroAddress();
    error TransferFailed();

    constructor(address _ttp) {
        if (_ttp == address(0)) revert ZeroAddress();
        ttp = IERC20(_ttp);
    }

    receive() external payable {}

    /// Permissionless: sweeps the full TTP balance to 0xdead. Anyone may poke;
    /// tokens here can only ever move to the burn address.
    function burn() external returns (uint256 amount) {
        amount = ttp.balanceOf(address(this));
        if (amount == 0) return 0;
        totalBurned += amount;
        if (!ttp.transfer(BURN_ADDRESS, amount)) revert TransferFailed();
        emit Burned(amount, totalBurned);
    }
}
