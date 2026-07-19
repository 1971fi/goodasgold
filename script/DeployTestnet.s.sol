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

/// ONE-SHOT testnet deploy: core + hooked TTP/ETH pool + 8-name mock basket + wiring.
/// Defaults sized for a faucet-poor wallet (~0.0065 ETH of seeds + gas).
///   forge script script/DeployTestnet.s.sol --rpc-url $TESTNET_RPC_URL \
///     --private-key $DEV_WALLET_PRIVATE_KEY --broadcast -vv
/// HARD GATE: chain 46630 only. Mainnet requires explicit GO MAINNET + separate script.
contract DeployTestnet is Script {
    uint256 constant ROBINHOOD_TESTNET = 46630;
    uint256 constant FEE_BPS = 400; // 4% each way — optimized for fees+payouts
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2**96
    address constant CREATE2_FACTORY_ADDR = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // state vars instead of run() locals — avoids stack-too-deep
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
    MockStockToken sgov;
    uint256 seedTtp;
    uint256 seedMock;

    error WrongChain(uint256 got);

    function run() external {
        if (block.chainid != ROBINHOOD_TESTNET) revert WrongChain(block.chainid);
        pm = IPoolManager(vm.envAddress("TESTNET_POOL_MANAGER"));
        seedTtp = vm.envOr("SEED_TTP_ETH", uint256(0.002 ether));
        seedMock = vm.envOr("SEED_MOCK_ETH", uint256(0.0005 ether));

        vm.startBroadcast();
        _deployCore();
        _setupTtpPool();
        _setupBasket();
        _setupSleeve();
        vm.stopBroadcast();

        _log();
    }

    function _deployCore() internal {
        ttp = new TTPToken();
        vault = new FeeVault();
        distributor = new RewardsDistributor();
        treasury = new Treasury(address(vault), pm, address(distributor));
        // knob #2 automation: hook fees land in the splitter, flush() sends 70/30
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
        // LAUNCH MODE = DISTRIBUTE (Josh, 2026-07-16 — supersedes burn default;
        // attestation gate is the compliance boundary, see docs/ATTESTATION.md)
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
        // PROTOCOL-OWNED LIQUIDITY: the treasury holds the seed LP position itself
        // (fixes the test-router custody hole and earns the LP fee layer)
        ttp.transfer(address(treasury), 10_000_000e18);
        (bool ok,) = address(treasury).call{value: seedTtp + seedTtp / 20}("");
        require(ok, "fund treasury");
        treasury.addLiquidity(key, seedTtp);
        ttp.approve(address(lpRouter), type(uint256).max); // mock pools still use lpRouter
        engine.setTtpPoolKey(key);
    }

    function _setupBasket() internal {
        string[8] memory syms = ["NVDA", "AMD", "INTC", "MU", "SNDK", "BE", "CRWV", "ORCL"];
        int256[8] memory px = [int256(180e8), 210e8, 35e8, 180e8, 60e8, 28e8, 140e8, 250e8];

        BuybackEngine.BasketEntry[] memory entries = new BuybackEngine.BasketEntry[](8);
        for (uint256 i; i < 8; ++i) {
            entries[i] = _deployMockPool(syms[i], px[i]);
        }
        engine.setBasket(entries);
    }

    function _deployMockPool(string memory sym, int256 price)
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
        _seed(key, seedMock);

        console2.log(string.concat("mock ", sym), address(tok), "feed:", address(feed));
        entry = BuybackEngine.BasketEntry({
            token: IStockToken(address(tok)),
            feed: IAggregatorV3(address(feed)),
            weightBps: 1250,
            poolKey: key
        });
    }

    function _setupSleeve() internal {
        // SGOV sleeve: T-bill ETF mock whose uiMultiplier growth = volume-independent yield
        sgov = new MockStockToken("Mock SGOV", "SGOV");
        sgov.mint(msg.sender, 1_000_000e18);
        sgov.approve(address(lpRouter), type(uint256).max);
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(sgov)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pm.initialize(key, SQRT_PRICE_1_1);
        _seed(key, seedMock);
        // fund + buy the sleeve with treasury ETH
        (bool ok,) = address(treasury).call{value: seedMock / 2 + seedMock / 50}("");
        require(ok, "fund sleeve buy");
        treasury.buy(key, uint128(seedMock / 2), 1);
        treasury.setSleeve(IStockToken(address(sgov)));
    }

    function _seed(PoolKey memory key, uint256 liquidity) internal {
        lpRouter.modifyLiquidity{value: liquidity + liquidity / 50}( // +2% margin
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ""
        );
    }

    function _log() internal view {
        console2.log("== TTP TESTNET DEPLOYMENT ==");
        console2.log("TTPToken:          ", address(ttp));
        console2.log("FeeVault:          ", address(vault));
        console2.log("TTPFeeHook:        ", address(hook));
        console2.log("BuybackEngine:     ", address(engine));
        console2.log("RewardsDistributor:", address(distributor));
        console2.log("BurnMode:          ", address(burnMode));
        console2.log("Treasury:          ", address(treasury));
        console2.log("FeeSplitter:       ", address(splitter));
        console2.log("SGOV (sleeve):     ", address(sgov));
        console2.log("LpRouter (dev):    ", address(lpRouter));
        console2.log("PoolManager (ext): ", address(pm));
    }
}
