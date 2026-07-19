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
import {Treasury} from "../src/Treasury.sol";
import {FeeSplitter} from "../src/launch/FeeSplitter.sol";
import {RedemptionVault} from "../src/RedemptionVault.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockFeedV3} from "../src/mocks/MockFeedV3.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// NAV-FLOOR LAUNCH (from scratch, no launchpad): proven chassis (token → 4% v4 hook →
/// FeeSplitter 70/30 → vault/treasury; BuybackEngine buys the basket) with the NEW
/// RedemptionVault as the engine's sink. Basket accrues IN the vault; holders burn TTP
/// to redeem at NAV. TESTNET REHEARSAL SCRIPT — chain 46630 only. Mainnet remains a
/// separate, explicit GO-MAINNET step.
///   forge script script/DeployNavLaunch.s.sol --rpc-url $TESTNET_RPC_URL \
///     --private-key $DEV_WALLET_PRIVATE_KEY --broadcast -vv
contract DeployNavLaunch is Script {
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
    Treasury treasury;
    FeeSplitter splitter;
    RedemptionVault redemption;
    uint256 seedTtp;
    uint256 seedMock;

    // 4-name rehearsal basket (mainnet uses registry/ttp-ai-core.basket.json's 20)
    string[4] syms = ["NVDA", "MU", "CRWV", "TSLA"];
    int256[4] px = [int256(180e8), 120e8, 140e8, 428e8];
    uint16[4] wts = [uint16(4000), 3000, 2000, 1000];
    MockStockToken[4] toks;
    MockFeedV3[4] feeds;

    error WrongChain(uint256 got);

    function run() external {
        if (block.chainid != ROBINHOOD_TESTNET) revert WrongChain(block.chainid);
        pm = IPoolManager(vm.envAddress("TESTNET_POOL_MANAGER"));
        seedTtp = vm.envOr("SEED_TTP_ETH", uint256(0.0015 ether));
        seedMock = vm.envOr("SEED_MOCK_ETH", uint256(0.0004 ether));

        vm.startBroadcast();
        _core();
        _mocksAndVault();
        _pools();
        vm.stopBroadcast();
        _log();
    }

    function _core() internal {
        ttp = new TTPToken();
        vault = new FeeVault();
        treasury = new Treasury(address(vault), pm, address(0xdead)); // sleeve sink unused in rehearsal
        splitter = new FeeSplitter(address(vault), address(treasury), 7000);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY_ADDR, flags, type(TTPFeeHook).creationCode, abi.encode(pm, address(splitter), FEE_BPS)
        );
        hook = new TTPFeeHook{salt: salt}(pm, address(splitter), FEE_BPS);

        engine = new BuybackEngine(address(vault), pm);
        burnMode = new BurnMode(address(ttp));
        vault.setAuthorized(address(engine), true);
        vault.setAuthorized(address(treasury), true);
        lpRouter = new PoolModifyLiquidityTest(pm);
    }

    function _mocksAndVault() internal {
        RedemptionVault.Constituent[] memory cs = new RedemptionVault.Constituent[](4);
        for (uint256 i; i < 4; ++i) {
            toks[i] = new MockStockToken(string.concat("Mock ", syms[i]), syms[i]);
            feeds[i] = new MockFeedV3(px[i]);
            toks[i].mint(msg.sender, 1_000_000e18);
            toks[i].approve(address(lpRouter), type(uint256).max);
            cs[i] = RedemptionVault.Constituent(address(toks[i]), address(feeds[i]), wts[i], RedemptionVault.Status.Active);
        }
        redemption = new RedemptionVault(
            address(ttp), address(treasury), FORFEIT_CREATOR_WALLET,
            100, 9000, 5000, 30 days, 3600, cs
        );
        // engine: Distribute mode with the REDEMPTION VAULT as sink — stocks accrue there
        engine.setSinks(address(burnMode), address(redemption));
        engine.setMode(BuybackEngine.Mode.Distribute);
        BuybackEngine.BasketEntry[] memory entries = new BuybackEngine.BasketEntry[](4);
        for (uint256 i; i < 4; ++i) {
            entries[i] = BuybackEngine.BasketEntry({
                token: IStockToken(address(toks[i])),
                feed: IAggregatorV3(address(feeds[i])),
                weightBps: wts[i],
                poolKey: _key(address(toks[i]), IHooks(address(0)))
            });
        }
        engine.setBasket(entries);
    }

    function _pools() internal {
        // TTP/ETH pool with the 4% hook
        PoolKey memory tk = _key(address(ttp), IHooks(address(hook)));
        pm.initialize(tk, SQRT_PRICE_1_1);
        ttp.transfer(address(treasury), 10_000_000e18);
        (bool ok,) = address(treasury).call{value: seedTtp + seedTtp / 20}("");
        require(ok, "fund treasury");
        treasury.addLiquidity(tk, seedTtp);
        ttp.approve(address(lpRouter), type(uint256).max);
        engine.setTtpPoolKey(tk);
        // mock stock pools
        for (uint256 i; i < 4; ++i) {
            PoolKey memory k = _key(address(toks[i]), IHooks(address(0)));
            pm.initialize(k, SQRT_PRICE_1_1);
            lpRouter.modifyLiquidity{value: seedMock + seedMock / 50}(
                k,
                ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(60),
                    tickUpper: TickMath.maxUsableTick(60),
                    liquidityDelta: int256(seedMock),
                    salt: 0
                }),
                ""
            );
        }
    }

    function _key(address token, IHooks h) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: h
        });
    }

    function _log() internal view {
        console2.log("== TTP NAV-FLOOR LAUNCH (testnet rehearsal) ==");
        console2.log("TTPToken:       ", address(ttp));
        console2.log("FeeVault:       ", address(vault));
        console2.log("FeeSplitter:    ", address(splitter));
        console2.log("TTPFeeHook(4%): ", address(hook));
        console2.log("BuybackEngine:  ", address(engine));
        console2.log("RedemptionVault:", address(redemption));
        console2.log("Treasury:       ", address(treasury));
        console2.log("BurnMode:       ", address(burnMode));
        console2.log("LpRouter (dev): ", address(lpRouter));
        for (uint256 i; i < 4; ++i) console2.log(syms[i], address(toks[i]));
    }
}
