// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// FeeSplitter — automates the 70/30 vault split (tokenomics knob #2).
/// Set as the TTPFeeHook's `treasury` target at (re)deploy: hook fees land here,
/// permissionless flush() forwards vaultBps → FeeVault and the rest → Treasury.
/// Accumulate-then-flush (rather than splitting in receive) keeps the hook's
/// take() cheap and gas-predictable.
contract FeeSplitter {
    uint256 public constant BPS = 10_000;

    address public owner;
    address public immutable vault;
    address public immutable treasury;
    uint256 public vaultBps; // e.g. 7000 = 70% to vault (buybacks)

    uint256 public totalToVault;
    uint256 public totalToTreasury;

    event Flushed(uint256 toVault, uint256 toTreasury);
    event VaultBpsSet(uint256 bps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error ZeroAddress();
    error BadBps();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _vault, address _treasury, uint256 _vaultBps) {
        if (_vault == address(0) || _treasury == address(0)) revert ZeroAddress();
        if (_vaultBps > BPS) revert BadBps();
        owner = msg.sender;
        vault = _vault;
        treasury = _treasury;
        vaultBps = _vaultBps;
    }

    receive() external payable {}

    /// Anyone may flush; funds can only ever move to the two fixed targets.
    function flush() external returns (uint256 toVault, uint256 toTreasury) {
        uint256 bal = address(this).balance;
        if (bal == 0) return (0, 0);
        toVault = (bal * vaultBps) / BPS;
        toTreasury = bal - toVault;
        totalToVault += toVault;
        totalToTreasury += toTreasury;
        if (toVault > 0) {
            (bool ok1,) = vault.call{value: toVault}("");
            if (!ok1) revert TransferFailed();
        }
        if (toTreasury > 0) {
            (bool ok2,) = treasury.call{value: toTreasury}("");
            if (!ok2) revert TransferFailed();
        }
        emit Flushed(toVault, toTreasury);
    }

    function setVaultBps(uint256 bps) external onlyOwner {
        if (bps > BPS) revert BadBps();
        vaultBps = bps;
        emit VaultBpsSet(bps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
