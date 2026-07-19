// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Chainlink AggregatorV3 mock (8 decimals, like the real Stock Token feeds).
/// Per docs, the real feeds' price ALREADY includes the corporate-action multiplier.
/// TESTNET/TEST USE ONLY.
contract MockFeedV3 {
    uint8 public constant decimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(int256 _answer) {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    function set(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId += 1;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
