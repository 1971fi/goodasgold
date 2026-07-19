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
import {DiscountSwapper} from "../src/DiscountSwapper.sol";
import {DiscountRouter} from "../src/DiscountRouter.sol";
import {PegFeed} from "../src/PegFeed.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// ============================ 1971 MAINNET LAUNCH ============================
/// GO MAINNET. Real ETH, real USDG, Robinhood Chain 4663. Runs the exact stack proven on
/// testnet (26 unit + 2 fork tests green, floor ratchet observed live), with:
///   - canonical Global Dollar USDG (0x5fc5...d168, $3.2B, admin-verified)
///   - the live v4 PoolManager (0x8366...0951, 1k+ txs)
///   - PegFeed ($1.00 fixed; no Chainlink USDG feed exists on RH -> disclosed)
/// Deploys token+vault+hook+engine+split+discount stack, initializes/seeds the 1971/ETH pool
/// (with the 4% hook) and an ETH/USDG POL position, wires exclusions, prints everything.
///
///   $env:SEED_GAG_ETH="<ETH into the 1971/ETH pool>"      # main liquidity, your call
///   $env:SEED_USDG_ETH="<ETH into the ETH/USDG POL>"      # small; engine's swap route
///   forge script script/DeployMainnet.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
///     --private-key $env:DEV_WALLET_PRIVATE_KEY --broadcast -vv
contract DeployMainnet is Script {
    uint256 constant ROBINHOOD_MAINNET = 4663;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;   // live v4 PoolManager
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // canonical Global Dollar
    address constant CREATE2_FACTORY_ADDR = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CREATOR_WALLET = 0x008baC045a4220Bf6755564C5eA2e1B271EB670F;
    uint256 constant FEE_BPS = 400;       // 4% each way
    uint16 constant RESERVE_BPS = 6000;   // 60 floor / 40 yield
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager pm = IPoolManager(PM);
    PoolModifyLiquidityTest lpRouter;
    GoodAsGold gag;
    FeeVault feeVault;
    TTPFeeHook hook;
    BuybackEngine engine;
    BurnMode burnMode;
    RedemptionVault redemption;
    GagDistributor dist;
    DiscountSwapper swapper;
    DiscountRouter discount;
    PegFeed feed;

    error WrongChain(uint256 got);

    function run() external {
        if (block.chainid != ROBINHOOD_MAINNET) revert WrongChain(block.chainid);
        uint256 seedGag = vm.envUint("SEED_GAG_ETH");   // required: forces an explicit size decision

        vm.startBroadcast();
        _core();
        _vaultAndSplit();
        _discountStack();
        _pools(seedGag);
        _exclusions();
        vm.stopBroadcast();
        _log();
    }

    function _core() internal {
        gag = new GoodAsGold(USDG, 1_000_000_000e18);
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
        feed = new PegFeed();
    }

    function _vaultAndSplit() internal {
        RedemptionVault.Constituent[] memory cs = new RedemptionVault.Constituent[](1);
        cs[0] = RedemptionVault.Constituent(USDG, address(feed), 10000, RedemptionVault.Status.Active);
        redemption = new RedemptionVault(
            address(gag), CREATOR_WALLET, CREATOR_WALLET, 100, 9000, 5000, 30 days, 7 days, cs
        );
        dist = new GagDistributor(USDG, address(redemption), address(gag), RESERVE_BPS);
        gag.setDistributor(address(dist));

        engine.setSinks(address(burnMode), address(dist));
        engine.setMode(BuybackEngine.Mode.Distribute);
        BuybackEngine.BasketEntry[] memory entries = new BuybackEngine.BasketEntry[](1);
        entries[0] = BuybackEngine.BasketEntry({
            token: IStockToken(USDG),
            feed: IAggregatorV3(address(feed)),
            weightBps: 10000,
            poolKey: _usdgKey()   // the CANONICAL v4 ETH/USDG pool ($600k liq, $6.8M/day). setBasket is owner-mutable if the tier needs a change.
        });
        engine.setBasket(entries);
    }

    function _discountStack() internal {
        swapper = new DiscountSwapper(pm, USDG, address(gag));
        swapper.setKeys(_usdgKey(), _key(address(gag), IHooks(address(hook))));
        // 3% margin, 500 USDG/call cap, 1h cooldown. Buffer fills from future fee routing.
        discount = new DiscountRouter(USDG, address(gag), address(redemption), address(swapper), 300, 500e18, 1 hours);
        (bool ok,) = address(swapper).call{value: 0.002 ether}(""); // leg-2 hook-fee buffer
        require(ok, "fund swapper");
    }

    function _pools(uint256 seedGag) internal {
        // 1971/ETH pool with the 4% hook: THE market. Fresh pool; we set the price and seed it.
        PoolKey memory gk = _key(address(gag), IHooks(address(hook)));
        pm.initialize(gk, SQRT_PRICE_1_1);
        gag.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: seedGag + seedGag / 20}(
            gk, ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(seedGag), 0), ""
        );
        engine.setTtpPoolKey(gk);
        // NO USDG pool work: the canonical v4 ETH/USDG pool already exists with real liquidity
        // ($600k depth, $6.8M daily volume). Engine and swapper route through it via _usdgKey().
    }

    function _exclusions() internal {
        gag.excludeFromDividends(address(pm));
        gag.excludeFromDividends(address(redemption));
        gag.excludeFromDividends(address(dist));
        gag.excludeFromDividends(0x000000000000000000000000000000000000dEaD);
        gag.excludeFromDividends(address(feeVault));
    }

    function _key(address token, IHooks h) internal pure returns (PoolKey memory) {
        return PoolKey({ currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: Currency.wrap(token), fee: 3000, tickSpacing: 60, hooks: h });
    }

    /// canonical ETH/USDG v4 pool (0.05% tier, genesis-era, live volume)
    function _usdgKey() internal pure returns (PoolKey memory) {
        return PoolKey({ currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: Currency.wrap(USDG), fee: 500, tickSpacing: 10, hooks: IHooks(address(0)) });
    }

    function _log() internal view {
        console2.log("========== 1971 IS LIVE ON ROBINHOOD CHAIN MAINNET ==========");
        console2.log("GoodAsGold (1971):", address(gag));
        console2.log("FeeVault:         ", address(feeVault));
        console2.log("TTPFeeHook (4%):  ", address(hook));
        console2.log("BuybackEngine:    ", address(engine));
        console2.log("GagDistributor:   ", address(dist));
        console2.log("RedemptionVault:  ", address(redemption));
        console2.log("DiscountSwapper:  ", address(swapper));
        console2.log("DiscountRouter:   ", address(discount));
        console2.log("PegFeed ($1):     ", address(feed));
        console2.log("BurnMode:         ", address(burnMode));
        console2.log("USDG (canonical): ", USDG);
        console2.log("next: CHAIN=4663 node rewire.mjs DeployMainnet, rebuild site, post the thread.");
    }
}
