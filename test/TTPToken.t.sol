// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TTPToken} from "../src/TTPToken.sol";

/// Self-contained forge tests (no forge-std yet — sandbox couldn't vendor it; Phase 1
/// swaps to forge-std Test). Failures signal by revert, which forge test reports.
interface Vm {
    function prank(address) external;
    function expectRevert(bytes4) external;
}

contract TTPTokenTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    TTPToken t;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        t = new TTPToken();
    }

    function testSupplyMintedToDeployer() public view {
        require(t.totalSupply() == 1_000_000_000e18, "supply");
        require(t.balanceOf(address(this)) == 1_000_000_000e18, "deployer bal");
    }

    function testTransfer() public {
        t.transfer(alice, 100e18);
        require(t.balanceOf(alice) == 100e18, "alice bal");
        require(t.balanceOf(address(this)) == 1_000_000_000e18 - 100e18, "sender bal");
    }

    function testTransferInsufficientReverts() public {
        vm.prank(alice);
        vm.expectRevert(TTPToken.InsufficientBalance.selector);
        t.transfer(bob, 1);
    }

    function testApproveTransferFrom() public {
        t.approve(alice, 50e18);
        vm.prank(alice);
        t.transferFrom(address(this), bob, 50e18);
        require(t.balanceOf(bob) == 50e18, "bob bal");
        require(t.allowance(address(this), alice) == 0, "allowance spent");
    }

    function testInfiniteAllowanceNotDecremented() public {
        t.approve(alice, type(uint256).max);
        vm.prank(alice);
        t.transferFrom(address(this), bob, 1e18);
        require(t.allowance(address(this), alice) == type(uint256).max, "still max");
    }

    function testRenounce() public {
        t.renounceOwnership();
        require(t.owner() == address(0), "renounced");
    }

    function testNonOwnerCannotRenounce() public {
        vm.prank(alice);
        vm.expectRevert(TTPToken.NotOwner.selector);
        t.renounceOwnership();
    }
}
