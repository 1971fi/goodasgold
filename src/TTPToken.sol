// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// TTP — Tax The Poor. Deliberately vanilla fixed-supply ERC-20.
/// Lesson from the INDEX teardown: keep ALL mechanics (fees, registries, distribution)
/// out of the token. No fee-on-transfer, no holder registry, no rebasing.
/// 1B supply minted to deployer; owner exists only for launch ops, then renounce.
/// Phase 1: swap this hand-rolled ERC-20 for OpenZeppelin ERC20 + Ownable imports
/// (kept dependency-free in Phase 0 so the scaffold compiles standalone).
contract TTPToken is IERC20 {
    string public constant name = "Tax The Poor";
    string public constant symbol = "TTP";
    uint8 public constant decimals = 18;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    uint256 public immutable totalSupply = TOTAL_SUPPLY;
    address public owner;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address holder, address spender) external view returns (uint256) {
        return _allowances[holder][spender];
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            unchecked {
                _allowances[from][msg.sender] = allowed - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = _balances[from];
        if (bal < value) revert InsufficientBalance();
        unchecked {
            _balances[from] = bal - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    /// Launch plan: renounce once pools are seeded and distributor is live.
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
