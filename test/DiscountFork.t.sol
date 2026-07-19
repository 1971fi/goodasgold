// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {DiscountSwapper} from "../src/DiscountSwapper.sol";
import {DiscountRouter} from "../src/DiscountRouter.sol";

interface IMockUSDG {
    function mint(address to, uint256 a) external;
    function approve(address s, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function owner() external view returns (address);
}
interface I1971 {
    function balanceOf(address a) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}
interface IVaultNav {
    function nav() external view returns (uint256);
    function navPerToken() external view returns (uint256);
}

/// FORK TEST for the discount buy-and-burn against the LIVE Robinhood Chain testnet pools.
/// This is the one thing DiscountRouter.t.sol (mocks) cannot prove: that the two-hop
/// USDG -> ETH -> 1971 swap actually SETTLES on v4 with the 4% fee hook on leg 2, and that a
/// real buy-burn raises navPerToken.
///
/// RUN (needs an RPC that can fork RH testnet 46630, in .env as RH_RPC):
///   forge test --match-contract DiscountFork --fork-url $env:RH_RPC -vv
/// If RH_RPC is unset the whole suite skips (so normal `forge test` stays green).
contract DiscountForkTest is Test {
    // current testnet deployment (website/src/addresses.json, rewire-synced)
    address constant PM = 0x552815eF68E6eb418A3d65D0AA1043d93204F612; // PoolManager (external)
    address constant USDG = 0x119E0A8c499dE27a2fC2a341aF229802D2548d19;
    address constant GAG = 0xD8eCaEe6dc47Ce14232F9Eb9468009495a3f0E32; // 1971
    address constant VAULT = 0xDb71F8831dAb638E05986D9C4F064546BF184462; // RedemptionVault
    address constant HOOK = 0xcf1bF1CEC0D7732ae1bD9BFF693C95CA16B000cc; // TTPFeeHook (4%)
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    DiscountSwapper swapper;
    DiscountRouter router;
    bool live;

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        live = true;

        PoolKey memory usdgEth = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: Currency.wrap(USDG),
            fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))
        });
        PoolKey memory gagEth = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: Currency.wrap(GAG),
            fee: 3000, tickSpacing: 60, hooks: IHooks(HOOK)
        });

        swapper = new DiscountSwapper(IPoolManager(PM), USDG, GAG);
        swapper.setKeys(usdgEth, gagEth);
        // discountBps 0 for the raw swapper test; router test tunes it after growing the reserve
        router = new DiscountRouter(USDG, GAG, VAULT, address(swapper), 0, 1_000_000e18, 0);
        vm.deal(address(swapper), 2 ether); // ETH buffer for the leg-2 hook fee
    }

    /// THE key proof: USDG -> 1971 settles end to end on the real pools (incl. the fee hook).
    function test_Swapper_UsdgToGag_SettlesOnRealPools() public {
        if (!live) return;
        vm.prank(IMockUSDG(USDG).owner());               // mock USDG mint is owner-gated on the live deploy
        IMockUSDG(USDG).mint(address(this), 100e18);
        IMockUSDG(USDG).approve(address(swapper), type(uint256).max);
        uint256 before = I1971(GAG).balanceOf(address(this));
        uint256 out = swapper.swapUsdgForToken(50e18, 0, address(this));
        assertGt(out, 0, "received 1971 from USDG");
        assertEq(I1971(GAG).balanceOf(address(this)) - before, out, "delivered exactly");
    }

    /// End to end via the router: grow the reserve so NAV clears the market price, then buy-burn
    /// and confirm navPerToken does not fall (accretive). Mint size may need tuning per pool state.
    function test_Router_BuyBurn_IsAccretive() public {
        if (!live) return;
        address usdgOwner = IMockUSDG(USDG).owner();
        vm.startPrank(usdgOwner);                          // owner-gated mints on the live deploy
        // CALIBRATION: testnet pools are ~0.0008 ETH deep and seeded 1:1 (market ~1 USDG per
        // 1971). First run proved the GUARD: 200e18 into that pool -> no discount -> correct
        // Slippage revert, buffer untouched. To demonstrate an actual discounted buy-burn we
        // (a) push navPerToken ABOVE the ~1.0 market price and (b) trade tiny vs pool depth.
        IMockUSDG(USDG).mint(VAULT, 2_000_000_000e18);     // NAV ~$2/token vs market ~$1 => deep discount
        IMockUSDG(USDG).mint(address(router), 1e18);       // router discount buffer
        vm.stopPrank();
        uint256 nptBefore = IVaultNav(VAULT).navPerToken();
        uint256 deadBefore = I1971(GAG).balanceOf(DEAD);
        router.setParams(300, 1_000_000e18, 0);           // 3% discount margin

        uint256 burned = router.discountBuyBurn(0.00005e18, 0); // tiny spend vs 0.0008-ETH pool
        assertGt(burned, 0, "bought and burned 1971");
        assertEq(I1971(GAG).balanceOf(DEAD) - deadBefore, burned, "burned to dead");
        assertGe(IVaultNav(VAULT).navPerToken(), nptBefore, "floor did not fall (accretive)");
    }
}
