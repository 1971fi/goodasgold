// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Testnet stand-in for a Robinhood Stock Token: ERC-20 (18d) + ERC-8056 uiMultiplier.
/// Needed because NO canonical Stock Tokens exist on Robinhood Chain testnet
/// (see state/BUILD_LOG.md 2026-07-16). TESTNET/TEST USE ONLY.
contract MockStockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    address public owner;
    uint256 public totalSupply;
    uint256 public uiMultiplier = 1e18; // 1.0 at "listing", per ERC-8056

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);

    error NotOwner();
    error Insufficient();

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// Simulate a corporate action (dividend reinvestment / split).
    function setUiMultiplier(uint256 m) external {
        if (msg.sender != owner) revert NotOwner();
        emit UIMultiplierUpdated(uiMultiplier, m, block.timestamp);
        uiMultiplier = m;
    }

    function balanceOfUI(address account) external view returns (uint256) {
        return (balanceOf[account] * uiMultiplier) / 1e18;
    }

    function totalSupplyUI() external view returns (uint256) {
        return (totalSupply * uiMultiplier) / 1e18;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert Insufficient();
            allowance[from][msg.sender] = allowed - value;
        }
        return _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        if (balanceOf[from] < value) revert Insufficient();
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}
