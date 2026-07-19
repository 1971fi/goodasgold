// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {GoodAsGold} from "../src/GoodAsGold.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {TTPFeeHook} from "../src/TTPFeeHook.sol";
import {BuybackEngine} from "../src/BuybackEngine.sol";
import {BurnMode} from "../src/modes/BurnMode.sol";
import {RedemptionVault} from "../src/RedemptionVault.sol";
import {GagDistributor} from "../src/GagDistributor.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockFeedV3} from "../src/mocks/MockFeedV3.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// GOOD AS GOLD (GAG) LAUNCH — from scratch, no launchpad. Full 3-leg product:
///   fees (ETH) → FeeVault → engine swaps ETH→USDG into GagDistributor →
///   distribute(): 60% → RedemptionVault (USDG reserve = FLOOR) + 40% → GAG dividend
///   accumulator (claimable YIELD). Holders: hold (claim USDG), redeem (burn GAG → USDG at
///   NAV), or sell (floor-backstopped). TESTNET REHEARSAL — chain 46630, mock USDG.
///   Mainnet: USDG = canonical Global Dollar; separate GO-MAINNET step.
///   forge script script/DeployGagLaunch.s.sol --rpc-url $TESTNET_RPC_URL \
///     --private-key $DEV_WALLET_PRIVATE_KEY --broadcast -vv
contract DeployGagLaunch is Script {
    uint256 constant ROBINHOOD_TESTNET = 46630;
    uint256 constant FEE_BPS = 400;
    uint16 constant RESERVE_BPS = 6000; // 60% floor / 40% yield — Josh's dial
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address constant CREATE2_FACTORY_ADDR = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CREATOR_WALLET = 0x008baC045a4220Bf6755564C5eA2e1B271EB670F;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager pm;
    PoolModifyLiquidityTest lpRouter;
    GoodAsGold gag;
    FeeVault feeVault;
    TTPFeeHook hook;
    BuybackEngine engine;
    BurnMode burnMode;
    RedemptionVault redemption;
    GagDistributor dist;
    MockStockToken usdg;
    MockFeedV3 usdgFeed;
    uint256 seedGag;
    uint256 seedUsdg;

    error WrongChain(uint256 got);

    function run() external {
        if (block.chainid != ROBINHOOD_TESTNET) revert WrongChain(block.chainid);
        pm = IPoolManager(vm.envAddress("TESTNET_POOL_MANAGER"));
        seedGag = vm.envOr("SEED_GAG_ETH", uint256(0.0015 ether));
        seedUsdg = vm.envOr("SEED_USDG_ETH", uint256(0.0008 ether));

        vm.startBroadcast();
        _core();
        _floorAndYield();
        _pools();
        _exclusions();
        vm.stopBroadcast();
        _log();
    }

    function _core() internal {
        usdg = new MockStockToken("Global Dollar", "USDG");
        usdgFeed = new MockFeedV3(1e8); // $1.00
        gag = new GoodAsGold(address(usdg), 1_000_000_000e18);
        feeVault = new FeeVault();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY_ADDR, flags, type(TTPFeeHook).creationCode, abi.encode(pm, address(feeVault), FEE_BPS)
        );
        hook = new TTPFeeHook{salt: salt}(pm, address(feeVault), FEE_BPS);
        engine = new BuybackEngine(address(feeVault), pm);
        burnMode = new BurnMode(address(gag));
        feeVault.setAuthorized(address(engine), true);
        lpRouter = new PoolModifyLiquidityTest(pm);
    }

    function _floorAndYield() internal {
        // FLOOR: redemption vault holds USDG, redeemable by burning GAG
        RedemptionVault.Constituent[] memory cs = new RedemptionVault.Constituent[](1);
        cs[0] = RedemptionVault.Constituent(address(usdg), address(usdgFeed), 10000, RedemptionVault.Status.Active);
        redemption = new RedemptionVault(
            address(gag), CREATOR_WALLET, CREATOR_WALLET, 100, 9000, 5000, 30 days, 3600, cs
        );
        // YIELD: distributor splits USDG 60% reserve / 40% GAG dividends
        dist = new GagDistributor(address(usdg), address(redemption), address(gag), RESERVE_BPS);
        gag.setDistributor(address(dist));

        // engine buys USDG into the distributor sink
        usdg.mint(msg.sender, 1_000_000e18);
        usdg.approve(address(lpRouter), type(uint256).max);
        engine.setSinks(address(burnMode), address(dist));
        engine.setMode(BuybackEngine.Mode.Distribute);
        BuybackEngine.BasketEntry[] memory entries = new BuybackEngine.BasketEntry[](1);
        entries[0] = BuybackEngine.BasketEntry({
            token: IStockToken(address(usdg)),
            feed: IAggregatorV3(address(usdgFeed)),
            weightBps: 10000,
            poolKey: _key(address(usdg), IHooks(address(0)))
        });
        engine.setBasket(entries);
    }

    function _pools() internal {
        PoolKey memory gk = _key(address(gag), IHooks(address(hook)));
        pm.initialize(gk, SQRT_PRICE_1_1);
        gag.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: seedGag + seedGag / 20}(
            gk,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(seedGag), 0),
            ""
        );
        engine.setTtpPoolKey(gk);

        PoolKey memory uk = _key(address(usdg), IHooks(address(0)));
        pm.initialize(uk, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: seedUsdg + seedUsdg / 50}(
            uk,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(seedUsdg), 0),
            ""
        );
    }

    /// Keep pooled/reserve/burned GAG out of the dividend book so no USDG is stranded.
    function _exclusions() internal {
        gag.excludeFromDividends(address(pm));          // v4 PoolManager holds pooled GAG
        gag.excludeFromDividends(address(redemption));  // reserve vault (transient GAG on redeem)
        gag.excludeFromDividends(address(dist));        // distributor
        gag.excludeFromDividends(DEAD);                 // burned GAG
        gag.excludeFromDividends(address(feeVault));
    }

    function _key(address token, IHooks h) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: h
        });
    }

    function _log() internal view {
        console2.log("== GOOD AS GOLD (GAG) LAUNCH - testnet rehearsal ==");
        console2.log("GoodAsGold (GAG):", address(gag));
        console2.log("FeeVault:        ", address(feeVault));
        console2.log("TTPFeeHook(4%):  ", address(hook));
        console2.log("BuybackEngine:   ", address(engine));
        console2.log("GagDistributor:  ", address(dist), "(60/40)");
        console2.log("RedemptionVault: ", address(redemption));
        console2.log("BurnMode:        ", address(burnMode));
        console2.log("USDG (mock):     ", address(usdg));
        console2.log("USDG feed:       ", address(usdgFeed));
        console2.log("LpRouter (dev):  ", address(lpRouter));
    }
}
