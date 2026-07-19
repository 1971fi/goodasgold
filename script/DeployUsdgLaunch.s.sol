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

import {TTPToken} from "../src/TTPToken.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {TTPFeeHook} from "../src/TTPFeeHook.sol";
import {BuybackEngine} from "../src/BuybackEngine.sol";
import {BurnMode} from "../src/modes/BurnMode.sol";
import {RedemptionVault} from "../src/RedemptionVault.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockFeedV3} from "../src/mocks/MockFeedV3.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// USDG-ONLY NAV-FLOOR LAUNCH (from scratch, no launchpad). Fees (ETH) → splitter → engine
/// swaps ETH→USDG into the RedemptionVault. Holders burn TTP to redeem USDG at NAV (pull).
/// Single reserve asset = simplest + lowest legal heat + truest dollar floor.
/// TESTNET REHEARSAL — chain 46630 only (mock USDG). Mainnet: set USDG = canonical Global
/// Dollar address from docs.robinhood.com/chain/contracts, and it is a separate GO-MAINNET step.
///   forge script script/DeployUsdgLaunch.s.sol --rpc-url $TESTNET_RPC_URL \
///     --private-key $DEV_WALLET_PRIVATE_KEY --broadcast -vv
contract DeployUsdgLaunch is Script {
    uint256 constant ROBINHOOD_TESTNET = 46630;
    uint256 constant FEE_BPS = 400;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address constant CREATE2_FACTORY_ADDR = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant FORFEIT_CREATOR_WALLET = 0x008baC045a4220Bf6755564C5eA2e1B271EB670F;

    IPoolManager pm;
    PoolModifyLiquidityTest lpRouter;
    TTPToken ttp;
    FeeVault vault;
    TTPFeeHook hook;
    BuybackEngine engine;
    BurnMode burnMode;
    RedemptionVault redemption;
    MockStockToken usdg;
    MockFeedV3 usdgFeed;
    uint256 seedTtp;
    uint256 seedUsdg;

    error WrongChain(uint256 got);

    function run() external {
        if (block.chainid != ROBINHOOD_TESTNET) revert WrongChain(block.chainid);
        pm = IPoolManager(vm.envAddress("TESTNET_POOL_MANAGER"));
        seedTtp = vm.envOr("SEED_TTP_ETH", uint256(0.0015 ether));
        seedUsdg = vm.envOr("SEED_USDG_ETH", uint256(0.0008 ether));

        vm.startBroadcast();
        _core();
        _vault();
        _pools();
        vm.stopBroadcast();
        _log();
    }

    function _core() internal {
        ttp = new TTPToken();
        vault = new FeeVault();
        // USDG-only v1: no splitter/treasury — 100% of fees back the floor. Hook pays FeeVault directly.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY_ADDR, flags, type(TTPFeeHook).creationCode, abi.encode(pm, address(vault), FEE_BPS)
        );
        hook = new TTPFeeHook{salt: salt}(pm, address(vault), FEE_BPS);
        engine = new BuybackEngine(address(vault), pm);
        burnMode = new BurnMode(address(ttp));
        vault.setAuthorized(address(engine), true);
        lpRouter = new PoolModifyLiquidityTest(pm);
    }

    function _vault() internal {
        usdg = new MockStockToken("Global Dollar", "USDG");
        usdgFeed = new MockFeedV3(1e8); // $1.00
        usdg.mint(msg.sender, 1_000_000e18);
        usdg.approve(address(lpRouter), type(uint256).max);

        RedemptionVault.Constituent[] memory cs = new RedemptionVault.Constituent[](1);
        cs[0] = RedemptionVault.Constituent(address(usdg), address(usdgFeed), 10000, RedemptionVault.Status.Active);
        redemption = new RedemptionVault(
            address(ttp), FORFEIT_CREATOR_WALLET, FORFEIT_CREATOR_WALLET,
            100, 9000, 5000, 30 days, 3600, cs
        );

        engine.setSinks(address(burnMode), address(redemption));
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
        PoolKey memory tk = _key(address(ttp), IHooks(address(hook)));
        pm.initialize(tk, SQRT_PRICE_1_1);
        ttp.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: seedTtp + seedTtp / 20}(
            tk,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(seedTtp), 0),
            ""
        );
        engine.setTtpPoolKey(tk);

        PoolKey memory uk = _key(address(usdg), IHooks(address(0)));
        pm.initialize(uk, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: seedUsdg + seedUsdg / 50}(
            uk,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(seedUsdg), 0),
            ""
        );
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
        console2.log("== TTP USDG NAV-FLOOR LAUNCH (testnet rehearsal) ==");
        console2.log("TTPToken:       ", address(ttp));
        console2.log("FeeVault:       ", address(vault));
        console2.log("TTPFeeHook(4%): ", address(hook));
        console2.log("BuybackEngine:  ", address(engine));
        console2.log("RedemptionVault:", address(redemption));
        console2.log("BurnMode:       ", address(burnMode));
        console2.log("USDG (mock):    ", address(usdg));
        console2.log("USDG feed:      ", address(usdgFeed));
        console2.log("LpRouter (dev): ", address(lpRouter));
    }
}
