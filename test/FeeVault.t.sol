// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeVault} from "../src/FeeVault.sol";
import {TTPToken} from "../src/TTPToken.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes4) external;
    function deal(address, uint256) external;
}

contract FeeVaultTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    FeeVault v;
    TTPToken token;
    address engine = address(0xE461);
    address treasury = address(0x7EA5);

    function setUp() public {
        v = new FeeVault();
        token = new TTPToken();
        v.setAuthorized(engine, true);
        v.setAuthorized(treasury, true);
    }

    function testEthAccrual() public {
        vm.deal(address(this), 5 ether);
        (bool ok,) = address(v).call{value: 2 ether}("");
        require(ok, "send");
        require(v.totalEthReceived() == 2 ether, "accrued");
        require(address(v).balance == 2 ether, "held");
    }

    function testTokenDeposit() public {
        token.approve(address(v), 100e18);
        v.depositToken(address(token), 100e18);
        require(v.totalTokenReceived(address(token)) == 100e18, "accrued");
        require(token.balanceOf(address(v)) == 100e18, "held");
    }

    function testOnlyAuthorizedCanRelease() public {
        token.approve(address(v), 100e18);
        v.depositToken(address(token), 100e18);
        vm.expectRevert(FeeVault.NotAuthorized.selector);
        v.releaseToken(address(token), 100e18);

        vm.prank(engine);
        v.releaseToken(address(token), 40e18);
        require(token.balanceOf(engine) == 40e18, "engine funds itself");

        vm.prank(treasury);
        v.releaseToken(address(token), 10e18);
        require(token.balanceOf(treasury) == 10e18, "treasury funds itself");
    }

    function testReleaseGoesToCallerOnly() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(v).call{value: 1 ether}("");
        require(ok, "send");
        vm.prank(engine);
        v.releaseEth(0.5 ether);
        require(engine.balance == 0.5 ether, "to caller");
    }

    function testOnlyOwnerAuthorizes() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(FeeVault.NotOwner.selector);
        v.setAuthorized(address(0xBAD), true);
    }

    function testDeauthorize() public {
        v.setAuthorized(engine, false);
        vm.prank(engine);
        vm.expectRevert(FeeVault.NotAuthorized.selector);
        v.releaseEth(1);
    }
}
