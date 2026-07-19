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
import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {BurnMode} from "../src/modes/BurnMode.sol";
import {Treasury} from "../src/Treasury.sol";
import {FeeSplitter} from "../src/launch/FeeSplitter.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockFeedV3} from "../src/mocks/MockFeedV3.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// LEAN dress-rehearsal deploy — Distribute mode + FeeSplitter, but only a 2-name basket
/// and no sleeve, sized to run on a nearly-empty dev wallet (~0.0015 ETH incl. gas).
/// Proves the new v3 machinery (70/30 splitter, distribute-default) without the faucet.
///   forge script script/DeployLean.s.sol --rpc-url $TESTNET_RPC_URL \
///     --private-key $DEV_WALLET_PRIVATE_KEY --broadcast -vv
/// HARD GATE: chain 46630 only.
contract DeployLean is Script {
    uint256 constant ROBINHOOD_TESTNET = 46630;
    uint256 constant FEE_BPS = 400; // 4% each way — optimized for fees+payouts (Laffer peak, headroom under 5% cap)
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address constant CREATE2_FACTORY_ADDR = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    IPoolManager pm;
    PoolModifyLiquidityTest lpRouter;
    TTPToken ttp;
    FeeVault vault;
    TTPFeeHook hook;
    BuybackEngine engine;
    RewardsDistributor distributor;
    BurnMode burnMode;
    Treasury treasury;
    FeeSplitter splitter;
    uint256 seedTtp;
    uint256 seedMock;

    error WrongChain(uint256 got);

    function run() external {
        if (block.chainid != ROBINHOOD_TESTNET) revert WrongChain(block.chainid);
        pm = IPoolManager(vm.envAddress("TESTNET_POOL_MANAGER"));
        seedTtp = vm.envOr("SEED_TTP_ETH", uint256(0.00015 ether));
        seedMock = vm.envOr("SEED_MOCK_ETH", uint256(0.00008 ether));

        vm.startBroadcast();
        _deployCore();
        _setupTtpPool();
        _setupBasket();
        vm.stopBroadcast();

        _log();
    }

    function _deployCore() internal {
        ttp = new TTPToken();
        vault = new FeeVault();
        distributor = new RewardsDistributor();
        treasury = new Treasury(address(vault), pm, address(distributor));
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
        engine.setSinks(address(burnMode), address(distributor));
        engine.setMode(BuybackEngine.Mode.Distribute);
        lpRouter = new PoolModifyLiquidityTest(pm);
    }

    function _setupTtpPool() internal {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(ttp)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pm.initialize(key, SQRT_PRICE_1_1);
        ttp.transfer(address(treasury), 10_000_000e18);
        (bool ok,) = address(treasury).call{value: seedTtp + seedTtp / 20}("");
        require(ok, "fund treasury");
        treasury.addLiquidity(key, seedTtp);
        ttp.approve(address(lpRouter), type(uint256).max);
        engine.setTtpPoolKey(key);
    }

    function _setupBasket() internal {
        // 2 names, 50/50 — enough to prove Distribute + Merkle claim
        BuybackEngine.BasketEntry[] memory entries = new BuybackEngine.BasketEntry[](2);
        entries[0] = _mockPool("NVDA", 180e8, 5000);
        entries[1] = _mockPool("MU", 120e8, 5000);
        engine.setBasket(entries);
    }

    function _mockPool(string memory sym, int256 price, uint16 weightBps)
        internal
        returns (BuybackEngine.BasketEntry memory entry)
    {
        MockStockToken tok = new MockStockToken(string.concat("Mock ", sym), sym);
        MockFeedV3 feed = new MockFeedV3(price);
        tok.mint(msg.sender, 1_000_000e18);
        tok.approve(address(lpRouter), type(uint256).max);

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(tok)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pm.initialize(key, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: seedMock + seedMock / 50}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: int256(seedMock),
                salt: 0
            }),
            ""
        );
        console2.log(string.concat("mock ", sym), address(tok), "feed:", address(feed));
        entry = BuybackEngine.BasketEntry({
            token: IStockToken(address(tok)),
            feed: IAggregatorV3(address(feed)),
            weightBps: weightBps,
            poolKey: key
        });
    }

    function _log() internal view {
        console2.log("== TTP TESTNET DEPLOYMENT v3-lean (Distribute) ==");
        console2.log("TTPToken:          ", address(ttp));
        console2.log("FeeVault:          ", address(vault));
        console2.log("FeeSplitter:       ", address(splitter));
        console2.log("TTPFeeHook:        ", address(hook));
        console2.log("BuybackEngine:     ", address(engine));
        console2.log("RewardsDistributor:", address(distributor));
        console2.log("BurnMode:          ", address(burnMode));
        console2.log("Treasury:          ", address(treasury));
        console2.log("LpRouter (dev):    ", address(lpRouter));
        console2.log("PoolManager (ext): ", address(pm));
    }
}
