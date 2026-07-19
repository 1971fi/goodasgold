// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RedemptionVault} from "../src/RedemptionVault.sol";
import {TTPToken} from "../src/TTPToken.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockFeedV3} from "../src/mocks/MockFeedV3.sol";

/// From-scratch NAV-floor vault — the invariant suite, ported from the (retired) Flap
/// variant where it passed 26/26. Uses circulating supply (total - 0xdead).
contract RedemptionVaultTest is Test {
    RedemptionVault vault;
    TTPToken ttp;
    MockStockToken a;
    MockStockToken b;
    MockFeedV3 fa;
    MockFeedV3 fb;
    address treasury = address(0x7EA5);
    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);

    function setUp() public {
        ttp = new TTPToken();
        a = new MockStockToken("Mock NVDA", "NVDA");
        b = new MockStockToken("Mock MU", "MU");
        fa = new MockFeedV3(100e8);
        fb = new MockFeedV3(100e8);

        RedemptionVault.Constituent[] memory cs = new RedemptionVault.Constituent[](2);
        cs[0] = RedemptionVault.Constituent(address(a), address(fa), 5000, RedemptionVault.Status.Active);
        cs[1] = RedemptionVault.Constituent(address(b), address(fb), 5000, RedemptionVault.Status.Active);

        vault = new RedemptionVault(
            address(ttp), treasury, creator,
            100,    // 1% redemption fee
            9000,   // floor
            5000,   // 50% of haircut -> creator
            30 days,
            3600,
            cs
        );

        // vault holds 1000 of each stock; alice holds 10% of supply
        a.mint(address(vault), 1000e18);
        b.mint(address(vault), 1000e18);
        ttp.transfer(alice, 100_000_000e18); // 10% of 1B
    }

    function test_NavAndCirculating() public view {
        assertEq(vault.nav(), 200_000e18, "nav $200k");
        // circulating = 1B (nothing burned)
        assertEq(vault.circulatingSupply(), 1_000_000_000e18, "circ");
        assertEq(vault.navPerToken(), 200_000e18 * 1e18 / 1_000_000_000e18, "npt");
    }

    function test_ConstructorRejectsBadWeights() public {
        RedemptionVault.Constituent[] memory cs = new RedemptionVault.Constituent[](1);
        cs[0] = RedemptionVault.Constituent(address(a), address(new MockFeedV3(1e8)), 9999, RedemptionVault.Status.Active);
        vm.expectRevert();
        new RedemptionVault(address(ttp), treasury, creator, 100, 9000, 5000, 30 days, 3600, cs);
    }

    function test_RedeemFullMaturity_NeutralOrBetter() public {
        uint256 nptBefore = vault.navPerToken();
        vm.startPrank(alice);
        vault.startMaturity();
        vm.warp(block.timestamp + 31 days);
        fa.set(100e8); fb.set(100e8); // refresh feed updatedAt after warp (real feeds update continuously)
        ttp.approve(address(vault), type(uint256).max);
        vault.redeem(100_000_000e18); // alice's full 10%
        vm.stopPrank();
        // 10% of each pot = 100; fee 1% = 1 -> alice 99, treasury 1, creator 0
        assertEq(a.balanceOf(alice), 99e18, "alice");
        assertEq(a.balanceOf(treasury), 1e18, "fee");
        assertEq(a.balanceOf(creator), 0, "no forfeit at maturity");
        // burn went to dead -> circulating shrank
        assertEq(vault.circulatingSupply(), 900_000_000e18, "circ shrank");
        // fee retention makes full-maturity redemption weakly accretive; never below
        assertGe(vault.navPerToken(), nptBefore, "npt never decreases");
    }

    function test_RedeemEarly_ForfeitureSplit_AndInvariant() public {
        uint256 nptBefore = vault.navPerToken();
        vm.startPrank(alice);
        vault.startMaturity(); // weight = floor 9000 at t0
        ttp.approve(address(vault), type(uint256).max);
        vault.redeem(100_000_000e18);
        vm.stopPrank();
        // proRata 100: holder 90 -> fee 0.9 -> net 89.1; haircut 10 -> creator 5, vault keeps 5
        assertEq(a.balanceOf(alice), 89.1e18, "alice net");
        assertEq(a.balanceOf(treasury), 0.9e18, "fee");
        assertEq(a.balanceOf(creator), 5e18, "creator forfeiture");
        assertEq(a.balanceOf(address(vault)), 905e18, "vault retains 5");
        // THE INVARIANT: NAV per circulating token strictly increased
        assertGt(vault.navPerToken(), nptBefore, "floor ratchets up");
    }

    function test_MaturityRamp() public {
        vm.prank(alice);
        vault.startMaturity();
        assertEq(vault.timeWeightBps(alice), 9000, "floor at t0");
        vm.warp(block.timestamp + 15 days);
        assertApproxEqAbs(vault.timeWeightBps(alice), 9500, 5, "midpoint");
        vm.warp(block.timestamp + 30 days);
        assertEq(vault.timeWeightBps(alice), 10000, "matured");
    }

    function test_NoOptIn_GetsFloor() public {
        // redeem without startMaturity -> floor weight (the lazy path never over-pays)
        assertEq(vault.timeWeightBps(alice), 9000, "no opt-in = floor");
    }

    function test_DividendAccrual_UiMultiplierDrift() public {
        // dividends: feed price drifts up with uiMultiplier; vault NAV rises with NO trades.
        uint256 before = vault.nav();
        // simulate reinvested dividend: multiplier 1.02 => feed prints 102 (fa is constituent-0's feed)
        fa.set(102e8);
        assertGt(vault.nav(), before, "dividends accrue to the vault");
    }

    function test_AdminGating() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(RedemptionVault.NotAdmin.selector);
        vault.setConstituentStatus(0, RedemptionVault.Status.Halted);
        vault.setConstituentStatus(0, RedemptionVault.Status.Halted); // deployer=admin ok
    }

    function test_UsdgOnly_SingleConstituent_RedeemsCash() public {
        // v1 shape: one reserve asset = USDG, feed pinned ~$1. Reuses the SAME vault contract.
        MockStockToken usdg = new MockStockToken("Global Dollar", "USDG");
        MockFeedV3 uf = new MockFeedV3(1e8); // $1.00
        RedemptionVault.Constituent[] memory cs = new RedemptionVault.Constituent[](1);
        cs[0] = RedemptionVault.Constituent(address(usdg), address(uf), 10000, RedemptionVault.Status.Active);
        RedemptionVault v = new RedemptionVault(
            address(ttp), treasury, creator, 100, 9000, 5000, 30 days, 3600, cs
        );
        usdg.mint(address(v), 200_000e18);      // 200k USDG reserve (alice keeps her setUp TTP)
        // NAV = 200k USDG * $1 = $200k; supply 1B -> floor $0.0002/TTP
        assertEq(v.nav(), 200_000e18, "usdg nav");
        vm.startPrank(alice);
        v.startMaturity();
        vm.warp(block.timestamp + 31 days);
        uf.set(1e8); // refresh after warp
        ttp.approve(address(v), type(uint256).max);
        uint256 before = usdg.balanceOf(alice);
        v.redeem(50_000_000e18); // redeem some TTP
        vm.stopPrank();
        assertGt(usdg.balanceOf(alice) - before, 0, "alice received USDG, not stocks");
        assertEq(usdg.balanceOf(creator), 0, "no forfeiture at full maturity");
    }

    function test_AddReservedConstituent() public {
        MockStockToken tsm = new MockStockToken("Mock TSM", "TSM");
        vault.addConstituent(address(tsm), address(new MockFeedV3(440e8)), 0);
        assertEq(vault.basketComposition().length, 3, "TSM added");
        address dupFeed = address(new MockFeedV3(1e8)); // precompute — `new` in the arg eats expectRevert
        vm.expectRevert();
        vault.addConstituent(address(tsm), dupFeed, 0); // dup token -> revert
    }
}
