// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

interface IGag {
    function distributeDividends(uint256 amount) external;
    function totalShares() external view returns (uint256);
}

/// @title GagDistributor — the disclosed fee split: USDG → reserve (floor) + holder yield.
/// @notice Fees arrive here as USDG (engine swaps ETH→USDG into this contract). `distribute()`
///         routes `reserveBps` to the RedemptionVault (grows the redemption floor) and the rest
///         into GAG's claimable dividend accumulator (holder yield). Permissionless keeper call;
///         split ratio is IMMUTABLE and disclosed. If there are no eligible holders yet, 100%
///         routes to the floor so the call never reverts on an empty book.
contract GagDistributor {
    uint256 internal constant BPS = 10_000;
    IERC20 public immutable usdg;
    address public immutable reserve;    // RedemptionVault — its USDG balance IS the floor
    IGag public immutable gag;
    uint16 public immutable reserveBps;  // 6000 = 60% floor / 40% yield (Josh's dial)

    event Distributed(uint256 toReserve, uint256 toYield);

    constructor(address _usdg, address _reserve, address _gag, uint16 _reserveBps) {
        require(_usdg != address(0) && _reserve != address(0) && _gag != address(0), "zero");
        require(_reserveBps <= BPS, "bps");
        usdg = IERC20(_usdg);
        reserve = _reserve;
        gag = IGag(_gag);
        reserveBps = _reserveBps;
    }

    function distribute() external returns (uint256 toReserve, uint256 toYield) {
        uint256 bal = usdg.balanceOf(address(this));
        if (bal == 0) return (0, 0);
        toReserve = (bal * reserveBps) / BPS;
        toYield = bal - toReserve;
        if (gag.totalShares() == 0) { toReserve = bal; toYield = 0; } // empty book → all to floor
        if (toReserve > 0) require(usdg.transfer(reserve, toReserve), "x reserve");
        if (toYield > 0) {
            require(usdg.approve(address(gag), toYield), "approve");
            gag.distributeDividends(toYield); // pulls via transferFrom
        }
        emit Distributed(toReserve, toYield);
    }
}
