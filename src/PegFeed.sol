// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PegFeed — AggregatorV3-shaped fixed $1.00 feed for USDG on RH mainnet.
/// @notice No Chainlink USDG/USD feed exists on Robinhood Chain. USDG is a regulated,
///         fully-reserved dollar stablecoin, so the vault prices it at exactly $1.00.
///         DISCLOSED tradeoff: a USDG depeg would not be reflected in NAV. If Chainlink
///         ships a USDG feed, redeploy the vault pointing at it.
contract PegFeed {
    int256 public constant PRICE = 1e8; // $1.00, 8 decimals (Chainlink convention)

    function decimals() external pure returns (uint8) { return 8; }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, PRICE, block.timestamp, block.timestamp, 1);
    }
}
