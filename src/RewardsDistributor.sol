// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// RewardsDistributor — Merkle-claim distribution of Stock Tokens to TTP holders.
///
/// Design (deliberate divergence from INDEX's StockDistributorV2, see BUILD_LOG):
///   - PULL claims, not O(holders) push loops → no ~600-holder gas ceiling.
///   - No holder registry in the token, no min-balance floor baked into the protocol.
///   - Epoch snapshots computed offchain (balances at snapshot block), committed as a
///     Merkle root; leaf = keccak256(abi.encode(epoch, account, token, amount)).
/// Phase 0: claim verification is real; epoch funding/root pipeline lands in Phase 1.
/// Compliance: claims can be paused (geofence posture); BurnMode is the alternative sink.
contract RewardsDistributor {
    address public owner;

    struct Epoch {
        bytes32 merkleRoot;
        uint64 snapshotBlock;
        bool active;
    }

    uint256 public epochCount;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(bytes32 => bool)) public claimed; // epoch => leaf => done

    bool public paused;

    event EpochCommitted(uint256 indexed epoch, bytes32 root, uint64 snapshotBlock);
    event Claimed(uint256 indexed epoch, address indexed account, address indexed token, uint256 amount);
    event Paused(bool state);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error ZeroAddress();
    error EpochInactive();
    error AlreadyClaimed();
    error InvalidProof();
    error ClaimsPaused();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// Multisig handover (tokenomics knob #4).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setPaused(bool state) external onlyOwner {
        paused = state;
        emit Paused(state);
    }

    /// Commit an offchain-computed snapshot root. Tokens must already sit in this contract.
    function commitEpoch(bytes32 root, uint64 snapshotBlock) external onlyOwner returns (uint256 epoch) {
        epoch = ++epochCount;
        epochs[epoch] = Epoch({merkleRoot: root, snapshotBlock: snapshotBlock, active: true});
        emit EpochCommitted(epoch, root, snapshotBlock);
    }

    function claim(uint256 epoch, address account, address token, uint256 amount, bytes32[] calldata proof) external {
        if (paused) revert ClaimsPaused();
        Epoch storage e = epochs[epoch];
        if (!e.active) revert EpochInactive();

        bytes32 leaf = keccak256(abi.encode(epoch, account, token, amount));
        if (claimed[epoch][leaf]) revert AlreadyClaimed();
        if (!_verify(proof, e.merkleRoot, leaf)) revert InvalidProof();

        claimed[epoch][leaf] = true;
        if (!IERC20(token).transfer(account, amount)) revert TransferFailed();
        emit Claimed(epoch, account, token, amount);
    }

    /// Sorted-pair Merkle verification (OpenZeppelin MerkleProof-equivalent).
    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            h = h < p ? keccak256(abi.encode(h, p)) : keccak256(abi.encode(p, h));
        }
        return h == root;
    }
}
