// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VestingLocker} from "../src/launch/VestingLocker.sol";
import {FeeSplitter} from "../src/launch/FeeSplitter.sol";
import {TTPToken} from "../src/TTPToken.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract LaunchTest is Test {
    TTPToken ttp;
    address team = address(0x7EA0);

    function setUp() public {
        ttp = new TTPToken();
        vm.deal(address(this), 100 ether);
    }

    // ---- VestingLocker ----

    function _locker(uint64 cliffD, uint64 durD) internal returns (VestingLocker v) {
        v = new VestingLocker(IERC20(address(ttp)), team, uint64(block.timestamp), cliffD, durD);
        ttp.transfer(address(v), 100_000_000e18);
    }

    function test_NothingBeforeCliff() public {
        VestingLocker v = _locker(90 days, 365 days);
        vm.warp(block.timestamp + 89 days);
        assertEq(v.releasable(), 0, "pre-cliff");
        assertEq(v.release(), 0, "release no-op");
    }

    function test_LinearAfterCliff() public {
        VestingLocker v = _locker(90 days, 365 days);
        vm.warp(block.timestamp + 182 days + 12 hours); // ~half duration
        uint256 r = v.release();
        assertApproxEqRel(r, 50_000_000e18, 0.01e18, "~half vested");
        assertEq(ttp.balanceOf(team), r, "paid to beneficiary");
        // immediate second release: nothing new
        assertEq(v.release(), 0, "no double release");
    }

    function test_FullAtEnd() public {
        VestingLocker v = _locker(90 days, 365 days);
        vm.warp(block.timestamp + 366 days);
        v.release();
        assertEq(ttp.balanceOf(team), 100_000_000e18, "fully vested");
        assertEq(ttp.balanceOf(address(v)), 0, "locker empty");
    }

    function testFuzz_VestingMonotonic(uint64 t1, uint64 t2) public {
        VestingLocker v = _locker(90 days, 365 days);
        t1 = uint64(bound(t1, block.timestamp, block.timestamp + 400 days));
        t2 = uint64(bound(t2, t1, block.timestamp + 400 days));
        assertLe(v.vestedAmount(t1), v.vestedAmount(t2), "vesting must be monotonic");
    }

    function test_BadScheduleReverts() public {
        vm.expectRevert(VestingLocker.BadSchedule.selector);
        new VestingLocker(IERC20(address(ttp)), team, uint64(block.timestamp), 10 days, 5 days);
    }

    // ---- FeeSplitter ----

    function test_Flush7030() public {
        FeeVault vault = new FeeVault();
        address treasury = address(0x7777);
        FeeSplitter s = new FeeSplitter(address(vault), treasury, 7000);

        (bool ok,) = address(s).call{value: 1 ether}("");
        require(ok);
        (uint256 toVault, uint256 toTreasury) = s.flush();
        assertEq(toVault, 0.7 ether, "70 vault");
        assertEq(toTreasury, 0.3 ether, "30 treasury");
        assertEq(address(vault).balance, 0.7 ether, "vault got it");
        assertEq(treasury.balance, 0.3 ether, "treasury got it");
        assertEq(vault.totalEthReceived(), 0.7 ether, "vault accounting fired");

        // empty flush is a no-op
        (uint256 a, uint256 b) = s.flush();
        assertEq(a + b, 0, "empty flush");
    }

    function test_SplitterOwnerOps() public {
        FeeSplitter s = new FeeSplitter(address(0x1), address(0x2), 7000);
        vm.prank(address(0xBAD));
        vm.expectRevert(FeeSplitter.NotOwner.selector);
        s.setVaultBps(5000);

        s.setVaultBps(5000);
        assertEq(s.vaultBps(), 5000);

        s.transferOwnership(address(0x1234));
        vm.expectRevert(FeeSplitter.NotOwner.selector);
        s.setVaultBps(6000); // old owner locked out
    }

    // ---- ownership handover across core contracts ----

    function test_TransferOwnershipEverywhere() public {
        FeeVault vault = new FeeVault();
        address safe = address(0x5AFE);

        vault.transferOwnership(safe);
        assertEq(vault.owner(), safe, "vault owner moved");

        vm.expectRevert(FeeVault.NotOwner.selector);
        vault.setAuthorized(address(this), true); // old owner locked out

        vm.prank(safe);
        vault.setAuthorized(address(this), true); // new owner works
        assertTrue(vault.authorized(address(this)), "safe controls vault");
    }
}
