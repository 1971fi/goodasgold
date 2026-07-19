// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GoodAsGold} from "../src/GoodAsGold.sol";

contract MockUSDG {
    string public symbol = "USDG";
    uint8 public decimals = 18;
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

contract GoodAsGoldTest is Test {
    GoodAsGold gag;
    MockUSDG usdg;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address pool = address(0x9001);       // excluded (DEX/vault stand-in)
    address vault = address(0x7A17);      // redemption vault (burns GAG)

    function setUp() public {
        usdg = new MockUSDG();
        gag = new GoodAsGold(address(usdg), 1000e18);   // small supply for clean math
        gag.excludeFromDividends(pool);
        gag.transfer(alice, 100e18);
        gag.transfer(bob, 300e18);
        gag.transfer(pool, 600e18);                     // excluded -> not eligible
        // fund + approve for distribution (test acts as distributor/admin)
        usdg.mint(address(this), 1_000_000e18);
        usdg.approve(address(gag), type(uint256).max);
    }

    function _sumOutstanding() internal view returns (uint256) {
        return gag.withdrawableDividendOf(alice) + gag.withdrawableDividendOf(bob) + gag.withdrawableDividendOf(pool)
            + gag.withdrawnDividends(alice) + gag.withdrawnDividends(bob) + gag.withdrawnDividends(pool);
    }

    function test_ExcludedSupplyAndShares() public view {
        assertEq(gag.totalShares(), 400e18, "only alice+bob eligible");
        assertEq(gag.shares(pool), 0, "pool excluded");
    }

    // per-share truncation leaves at most a few wei of dust IN the contract (safe direction —
    // never over-pays). Assert shares ~pro-rata; assert preservation EXACTLY (capture+compare).
    uint256 constant DUST = 1e6; // 1e-12 USDG tolerance

    function test_DistributeProRata_ExcludesPool() public {
        gag.distributeDividends(40e18); // alice 25%, bob 75%, pool 0
        assertApproxEqAbs(gag.withdrawableDividendOf(alice), 10e18, DUST, "alice ~25%");
        assertApproxEqAbs(gag.withdrawableDividendOf(bob), 30e18, DUST, "bob ~75%");
        assertEq(gag.withdrawableDividendOf(pool), 0, "pool none (exact)");
    }

    function test_ClaimPaysExactly_AndInvariant() public {
        gag.distributeDividends(40e18);
        uint256 accrued = gag.withdrawableDividendOf(alice);
        vm.prank(alice);
        gag.claim();
        assertEq(usdg.balanceOf(alice), accrued, "claim pays EXACTLY accrued");
        assertEq(gag.withdrawableDividendOf(alice), 0, "nothing left");
        // INVARIANT: outstanding + withdrawn never exceeds distributed (dust stays in contract)
        assertLe(_sumOutstanding(), gag.totalDividendsDistributed(), "never over-pays");
        assertApproxEqAbs(_sumOutstanding(), gag.totalDividendsDistributed(), DUST, "conservation");
    }

    function test_TransferPreservesAccrued() public {
        gag.distributeDividends(40e18);       // alice ~10, bob ~30
        uint256 aliceBefore = gag.withdrawableDividendOf(alice);
        uint256 bobBefore = gag.withdrawableDividendOf(bob);
        vm.prank(bob);
        gag.transfer(alice, 100e18);          // bob->alice AFTER distribution
        // transfer must NOT change past accrual at all (exact)
        assertEq(gag.withdrawableDividendOf(alice), aliceBefore, "alice past unchanged");
        assertEq(gag.withdrawableDividendOf(bob), bobBefore, "bob past unchanged");
        // next distribution splits by NEW shares: alice 200, bob 200 -> 50/50
        gag.distributeDividends(40e18);
        assertApproxEqAbs(gag.withdrawableDividendOf(alice), aliceBefore + 20e18, DUST, "+20");
        assertApproxEqAbs(gag.withdrawableDividendOf(bob), bobBefore + 20e18, DUST, "+20");
        assertLe(_sumOutstanding(), gag.totalDividendsDistributed(), "conservation");
    }

    function test_BurnRemovesShares_KeepsAccrued() public {
        gag.distributeDividends(40e18);       // alice ~10
        uint256 aliceAccrued = gag.withdrawableDividendOf(alice);
        vm.prank(alice);
        gag.approve(vault, type(uint256).max);
        vm.prank(vault);
        gag.burnFrom(alice, 100e18);          // redemption burns alice's whole balance
        assertEq(gag.shares(alice), 0, "alice shares gone");
        assertEq(gag.totalShares(), 300e18, "only bob eligible now");
        assertEq(gag.withdrawableDividendOf(alice), aliceAccrued, "already-accrued preserved (exact)");
        assertEq(gag.totalSupply(), 900e18, "supply shrank");
    }

    function test_DistributeRevertsWithNoShares() public {
        GoodAsGold g2 = new GoodAsGold(address(usdg), 1000e18);
        g2.excludeFromDividends(address(this)); // exclude the only holder -> 0 eligible
        usdg.approve(address(g2), type(uint256).max);
        vm.expectRevert(GoodAsGold.NoShares.selector);
        g2.distributeDividends(1e18);
    }

    function test_OnlyDistributorCanDistribute() public {
        gag.setDistributor(address(0xDEAD));
        vm.prank(address(0xBAD));
        vm.expectRevert(GoodAsGold.NotDistributor.selector);
        gag.distributeDividends(1e18);
    }
}
