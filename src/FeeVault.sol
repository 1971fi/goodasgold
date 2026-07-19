// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// FeeVault v2 — collects protocol fees (ETH primary, per Open Decision #3) and
/// releases them to AUTHORIZED pullers only: the BuybackEngine (buybacks) and the
/// Treasury (POL + sleeve funding). Funds always move to msg.sender, so a puller
/// can only ever fund itself.
contract FeeVault {
    address public owner;
    mapping(address => bool) public authorized;

    /// Lifetime accounting for the dashboard's Fee Flow view.
    uint256 public totalEthReceived;
    mapping(address => uint256) public totalTokenReceived; // token => lifetime amount

    event EthReceived(address indexed from, uint256 amount);
    event TokenReceived(address indexed token, address indexed from, uint256 amount);
    event ReleasedEth(address indexed to, uint256 amount);
    event ReleasedToken(address indexed token, address indexed to, uint256 amount);
    event AuthorizedSet(address indexed puller, bool allowed);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotAuthorized();
    error ZeroAddress();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAuthorized() {
        if (!authorized[msg.sender]) revert NotAuthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {
        totalEthReceived += msg.value;
        emit EthReceived(msg.sender, msg.value);
    }

    /// Pull-style ERC-20 fee deposit (caller must approve first).
    function depositToken(address token, uint256 amount) external {
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalTokenReceived[token] += amount;
        emit TokenReceived(token, msg.sender, amount);
    }

    /// Multisig handover (tokenomics knob #4).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setAuthorized(address puller, bool allowed) external onlyOwner {
        if (puller == address(0)) revert ZeroAddress();
        authorized[puller] = allowed;
        emit AuthorizedSet(puller, allowed);
    }

    /// Authorized puller funds itself with ETH.
    function releaseEth(uint256 amount) external onlyAuthorized {
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ReleasedEth(msg.sender, amount);
    }

    /// Authorized puller funds itself with an ERC-20 (e.g. USDG if that lane opens).
    function releaseToken(address token, uint256 amount) external onlyAuthorized {
        if (!IERC20(token).transfer(msg.sender, amount)) revert TransferFailed();
        emit ReleasedToken(token, msg.sender, amount);
    }
}
