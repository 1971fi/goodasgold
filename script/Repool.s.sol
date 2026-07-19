// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {GoodAsGold} from "../src/GoodAsGold.sol";
import {BuybackEngine} from "../src/BuybackEngine.sol";
import {DiscountSwapper} from "../src/DiscountSwapper.sol";
import {LpLocker} from "../src/LpLocker.sol";

/// ============================ 1971 REPOOL (mainnet fix) =============================
/// The launch pool was initialized 1:1 (1 GAG = 1 ETH, absurd) with dust liquidity, and
/// the test lpRouter lets ANYONE withdraw positions. This script:
///   1. reclaims the old dust position (~0.02 ETH back to deployer)
///   2. deploys LpLocker (owner-gated LP holder; positions not stealable)
///   3. creates a NEW 1971/ETH pool (fee 10000 / spacing 200, same 4% hook) at a sane
///      price: PRICE_GAG_PER_ETH tokens per 1 ETH (default 100,000,000 -> ~$35k FDV)
///   4. seeds it two-sided with SEED_ETH + matching GAG via the locker
///   5. places a one-sided GAG "ask wall" (GAG_WALL, default 500M) just below the current
///      tick down to min tick: a bonding curve that sells GAG into buys, zero extra ETH
///   6. repoints BuybackEngine.setTtpPoolKey + DiscountSwapper.setKeys at the new pool
///   7. excludes the locker from dividends
/// The old dust pool is left empty and abandoned.
///
///   $env:SEED_ETH="30000000000000000"              # 0.03 ETH (required decision)
///   $env:GAG_WALL="500000000000000000000000000"    # optional, default 500M GAG
///   $env:PRICE_GAG_PER_ETH="100000000"             # optional, default 1e8 GAG/ETH
///   forge script script/Repool.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com `
///     --private-key $env:DEV_WALLET_PRIVATE_KEY --broadcast -vv
contract Repool is Script {
    uint256 constant ROBINHOOD_MAINNET = 4663;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    // deployed 2026-07-18 (broadcast/DeployMainnet.s.sol/4663/run-latest.json)
    address constant GAG = 0x18fA6c4f8000bA5910B132825aB4De4819209F1c;
    address constant HOOK = 0xF5AeEd6f2be9BF5C36Ef53d3e2a81e92468f40CC;
    address constant ENGINE = 0x91eF9b09fa009D422B1D51f6a7A463B439Ade8ce;
    address constant SWAPPER = 0x779ae42E06c73174983362d62aae191d52Ae08B2;
    address constant LP_ROUTER = 0xCb7B5a59e49aacE208846cf8873E2013C8bED8B0;
    uint256 constant OLD_LIQ = 0.02e18; // liquidityDelta used by DeployMainnet._pools

    error WrongChain(uint256 got);
    error PriceTooLow();

    function run() external {
        if (block.chainid != ROBINHOOD_MAINNET) revert WrongChain(block.chainid);
        uint256 seedEth = vm.envUint("SEED_ETH");
        uint256 gagWall = vm.envOr("GAG_WALL", uint256(500_000_000e18));
        uint256 price = vm.envOr("PRICE_GAG_PER_ETH", uint256(100_000_000)); // GAG per ETH

        IPoolManager pm = IPoolManager(PM);
        PoolKey memory oldKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(GAG), 3000, 60, IHooks(HOOK));
        PoolKey memory newKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(GAG), 10000, 200, IHooks(HOOK));

        // price (GAG per ETH, both 18dp) -> sqrtPriceX96 = sqrt(price) << 96
        uint160 sqrtP = uint160(_sqrt(price << 96) << 48); // sqrt(p*2^96)*2^48 == sqrt(p)*2^96
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 wallUpper = (tick / 200) * 200 - 200; // one spacing below current, aligned
        if (wallUpper <= TickMath.minUsableTick(200) + 400) revert PriceTooLow();
        uint160 sqrtMin = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(200));
        uint160 sqrtMax = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(200));

        vm.startBroadcast();

        // 1. reclaim the dust position (old pool left empty, harmless)
        PoolModifyLiquidityTest(payable(LP_ROUTER)).modifyLiquidity(
            oldKey,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), -int256(OLD_LIQ), 0),
            ""
        );

        // 2. owner-gated locker; exclude from dividends BEFORE funding it with the GAG
        //    the two positions need (+margin)
        LpLocker locker = new LpLocker(pm);
        GoodAsGold(GAG).excludeFromDividends(address(locker));
        GoodAsGold(GAG).transfer(address(locker), seedEth * price + gagWall + 1e18);

        // 3. new pool at the real launch price
        pm.initialize(newKey, sqrtP);

        // 4. two-sided full-range seed around current price
        uint128 seedLiq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtMin, sqrtMax, seedEth, seedEth * price);
        locker.modify{value: seedEth + seedEth / 20}(
            newKey,
            ModifyLiquidityParams(TickMath.minUsableTick(200), TickMath.maxUsableTick(200), int256(uint256(seedLiq)), 0)
        );

        // 5. one-sided GAG ask wall below current tick (sells GAG as price appreciates)
        uint128 wallLiq = LiquidityAmounts.getLiquidityForAmount1(sqrtMin, TickMath.getSqrtPriceAtTick(wallUpper), gagWall);
        locker.modify(newKey, ModifyLiquidityParams(TickMath.minUsableTick(200), wallUpper, int256(uint256(wallLiq)), 0));

        // 6. repoint engine + swapper at the new pool
        BuybackEngine(payable(ENGINE)).setTtpPoolKey(newKey);
        DiscountSwapper(payable(SWAPPER)).setKeys(
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDG), 500, 10, IHooks(address(0))), newKey
        );

        vm.stopBroadcast();

        console2.log("========== REPOOL DONE ==========");
        console2.log("LpLocker:", address(locker));
        console2.log("new pool: fee 10000 / spacing 200 / hook", HOOK);
        console2.log("init tick:", tick);
        console2.log("GAG per ETH:", price);
        console2.log("seed ETH (wei):", seedEth);
        console2.log("GAG wall (wei):", gagWall);
        console2.log("engine + swapper repointed; old dust pool emptied; locker excluded.");
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
