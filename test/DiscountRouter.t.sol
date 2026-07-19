// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DiscountRouter} from "../src/DiscountRouter.sol";

address constant DEAD = 0x000000000000000000000000000000000000dEaD;

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

contract Mock1971 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { totalSupply += a; balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
}

// navPerToken = navUsd / circulating, where circulating = totalSupply - burned(dead).
// So burning tokens raises navPerToken -> lets us prove accretion for real.
contract MockNav {
    Mock1971 public token; uint256 public navUsd;
    constructor(Mock1971 t, uint256 n) { token = t; navUsd = n; }
    function navPerToken() external view returns (uint256) {
        uint256 circ = token.totalSupply() - token.balanceOf(DEAD);
        return circ == 0 ? 0 : (navUsd * 1e18) / circ;
    }
}

// gives `out = usdgIn / price` tokens, enforcing minOut like a real DEX router
contract MockSwapper {
    MockUSDG public usdg; Mock1971 public token; uint256 public price; // WAD, USD per token
    constructor(MockUSDG u, Mock1971 t, uint256 p) { usdg = u; token = t; price = p; }
    function setPrice(uint256 p) external { price = p; }
    function swapUsdgForToken(uint256 usdgIn, uint256 minOut, address to) external returns (uint256 out) {
        usdg.transferFrom(msg.sender, address(this), usdgIn);
        out = (usdgIn * 1e18) / price;
        require(out >= minOut, "INSUFFICIENT_OUTPUT");
        token.transfer(to, out);
    }
}

contract DiscountRouterTest is Test {
    MockUSDG usdg; Mock1971 token; MockNav nav; MockSwapper swap; DiscountRouter router;

    function setUp() public {
        usdg = new MockUSDG();
        token = new Mock1971();
        token.mint(address(this), 1_000_000e18);           // holder supply
        swap = new MockSwapper(usdg, token, 0.90e18);      // market at $0.90 (10% discount)
        token.mint(address(swap), 1000e18);                // swapper inventory (part of supply, like a pool)
        nav = new MockNav(token, token.totalSupply());     // navUsd = total -> navPerToken = $1.00
        router = new DiscountRouter(address(usdg), address(token), address(nav), address(swap), 300, 1000e18, 1 hours);
        usdg.mint(address(router), 500e18);                // the discount buffer
    }

    function test_BuyBurnAtDiscount_IsAccretive() public {
        assertEq(nav.navPerToken(), 1e18, "start $1.00");
        uint256 before = nav.navPerToken();
        uint256 burned = router.discountBuyBurn(100e18, 0);
        // at $0.90, 100 USDG buys ~111.11 tokens; all burned to dead
        assertApproxEqAbs(burned, 111.11e18, 0.02e18, "bought ~111");
        assertEq(token.balanceOf(DEAD), burned, "burned to dead");
        assertEq(usdg.balanceOf(address(router)), 400e18, "buffer spent 100");
        assertGt(nav.navPerToken(), before, "floor ratcheted UP");
    }

    function test_RevertsWhenNotDiscounted() public {
        swap.setPrice(1.00e18);                            // no discount -> cannot meet the NAV-derived minOut
        vm.expectRevert();
        router.discountBuyBurn(100e18, 0);
        // buffer untouched, nothing burned
        assertEq(usdg.balanceOf(address(router)), 500e18, "no spend");
        assertEq(token.balanceOf(DEAD), 0, "no burn");
    }

    function test_Cooldown() public {
        router.discountBuyBurn(50e18, 0);
        vm.expectRevert(DiscountRouter.Cooldown.selector);
        router.discountBuyBurn(50e18, 0);
        vm.warp(block.timestamp + 1 hours + 1);
        router.discountBuyBurn(50e18, 0);                  // ok after cooldown
    }

    function test_CapAndBuffer() public {
        vm.expectRevert(DiscountRouter.OverCap.selector);
        router.discountBuyBurn(2000e18, 0);                // over maxSpendPerCall
        vm.expectRevert(DiscountRouter.NoBuffer.selector);
        router.discountBuyBurn(600e18, 0);                 // exceeds the 500 buffer (under cap)
    }
}
