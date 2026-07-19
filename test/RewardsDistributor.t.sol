// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {TTPToken} from "../src/TTPToken.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes4) external;
}

/// Merkle-claim round trip with a two-leaf tree built in-test.
/// (Uses TTPToken as the reward token stand-in; Phase 1 adds a MockStockToken
/// with uiMultiplier() and full epoch-funding tests.)
contract RewardsDistributorTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    RewardsDistributor d;
    TTPToken token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    bytes32 leafA;
    bytes32 leafB;
    bytes32 root;

    function setUp() public {
        d = new RewardsDistributor();
        token = new TTPToken();
        token.transfer(address(d), 300e18);

        // epoch 1: alice → 100, bob → 200
        leafA = keccak256(abi.encode(uint256(1), alice, address(token), uint256(100e18)));
        leafB = keccak256(abi.encode(uint256(1), bob, address(token), uint256(200e18)));
        root = leafA < leafB ? keccak256(abi.encode(leafA, leafB)) : keccak256(abi.encode(leafB, leafA));
        d.commitEpoch(root, uint64(block.number));
    }

    function _proofFor(bool forAlice) internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = forAlice ? leafB : leafA;
    }

    function testClaimHappyPath() public {
        d.claim(1, alice, address(token), 100e18, _proofFor(true));
        require(token.balanceOf(alice) == 100e18, "alice paid");
        d.claim(1, bob, address(token), 200e18, _proofFor(false));
        require(token.balanceOf(bob) == 200e18, "bob paid");
    }

    function testDoubleClaimReverts() public {
        d.claim(1, alice, address(token), 100e18, _proofFor(true));
        vm.expectRevert(RewardsDistributor.AlreadyClaimed.selector);
        d.claim(1, alice, address(token), 100e18, _proofFor(true));
    }

    function testWrongAmountReverts() public {
        vm.expectRevert(RewardsDistributor.InvalidProof.selector);
        d.claim(1, alice, address(token), 999e18, _proofFor(true));
    }

    function testPausedBlocksClaims() public {
        d.setPaused(true);
        vm.expectRevert(RewardsDistributor.ClaimsPaused.selector);
        d.claim(1, alice, address(token), 100e18, _proofFor(true));
    }

    function testUnknownEpochReverts() public {
        vm.expectRevert(RewardsDistributor.EpochInactive.selector);
        d.claim(2, alice, address(token), 100e18, _proofFor(true));
    }
}
