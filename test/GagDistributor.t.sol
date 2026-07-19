// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GoodAsGold} from "../src/GoodAsGold.sol";
import {GagDistributor} from "../src/GagDistributor.sol";

contract MockUSDG {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

contract GagDistributorTest is Test {
    GoodAsGold gag;
    MockUSDG usdg;
    GagDistributor dist;
    address reserve = address(0x7EA5);
    address alice = address(0xA11CE);

    function setUp() public {
        usdg = new MockUSDG();
        gag = new GoodAsGold(address(usdg), 1000e18);
        dist = new GagDistributor(address(usdg), reserve, address(gag), 6000); // 60/40
        gag.setDistributor(address(dist));
        gag.excludeFromDividends(address(this)); // deployer holds the rest — exclude so alice is the sole eligible holder
        gag.transfer(alice, 100e18); // the one eligible holder
    }

    function test_SplitsSixtyForty() public {
        usdg.mint(address(dist), 100e18);
        (uint256 r, uint256 y) = dist.distribute();
        assertEq(r, 60e18, "60% to reserve");
        assertEq(y, 40e18, "40% to yield");
        assertEq(usdg.balanceOf(reserve), 60e18, "reserve funded");
        assertEq(gag.totalDividendsDistributed(), 40e18, "yield distributed");
        assertApproxEqAbs(gag.withdrawableDividendOf(alice), 40e18, 1e6, "alice (only holder) gets ~all yield");
    }

    function test_EmptyBook_AllToFloor() public {
        // exclude the only holder -> totalShares 0 -> 100% to reserve, no revert
        gag.excludeFromDividends(alice);
        usdg.mint(address(dist), 100e18);
        (uint256 r, uint256 y) = dist.distribute();
        assertEq(r, 100e18, "all to floor when no holders");
        assertEq(y, 0, "no yield leg");
        assertEq(usdg.balanceOf(reserve), 100e18, "reserve got everything");
    }

    function test_ZeroBalanceNoop() public {
        (uint256 r, uint256 y) = dist.distribute();
        assertEq(r, 0); assertEq(y, 0);
    }
}
