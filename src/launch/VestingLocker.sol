// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";

/// VestingLocker — linear vesting with cliff, immutable terms, no owner.
/// Used at mainnet launch for the treasury reserve (300M) and team (100M) buckets
/// (tokenomics knob #1). Fund it by transferring TTP in after deployment; anyone
/// can poke release() — tokens only ever go to the beneficiary.
contract VestingLocker {
    IERC20 public immutable token;
    address public immutable beneficiary;
    uint64 public immutable start;
    uint64 public immutable cliff; // absolute timestamp
    uint64 public immutable end;

    uint256 public released;

    event Released(uint256 amount, uint256 totalReleased);

    error ZeroAddress();
    error BadSchedule();
    error TransferFailed();

    constructor(IERC20 _token, address _beneficiary, uint64 _start, uint64 _cliffDuration, uint64 _duration) {
        if (address(_token) == address(0) || _beneficiary == address(0)) revert ZeroAddress();
        if (_duration == 0 || _cliffDuration > _duration) revert BadSchedule();
        token = _token;
        beneficiary = _beneficiary;
        start = _start;
        cliff = _start + _cliffDuration;
        end = _start + _duration;
    }

    /// Total vested at `ts` (0 before cliff, linear to end, then everything held+released).
    function vestedAmount(uint64 ts) public view returns (uint256) {
        uint256 total = token.balanceOf(address(this)) + released;
        if (ts < cliff) return 0;
        if (ts >= end) return total;
        return (total * (ts - start)) / (end - start);
    }

    function releasable() public view returns (uint256) {
        return vestedAmount(uint64(block.timestamp)) - released;
    }

    function release() external returns (uint256 amount) {
        amount = releasable();
        if (amount == 0) return 0;
        released += amount;
        if (!token.transfer(beneficiary, amount)) revert TransferFailed();
        emit Released(amount, released);
    }
}
