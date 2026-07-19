// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {TTPToken} from "../src/TTPToken.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {TTPFeeHook} from "../src/TTPFeeHook.sol";
import {BuybackEngine} from "../src/BuybackEngine.sol";
import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {BurnMode} from "../src/modes/BurnMode.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockFeedV3} from "../src/mocks/MockFeedV3.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// Pool-level integration: TTPFeeHook fee capture, burn-mode and distribute-mode
/// buybacks against a real v4 PoolManager, and the Merkle claim e2e.
contract IntegrationTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2**96
    uint256 constant FEE_BPS = 300; // 3%

    PoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    TTPToken ttp;
    FeeVault vault;
    TTPFeeHook hook;
    BuybackEngine engine;
    RewardsDistributor dist;
    BurnMode burnMode;

    MockStockToken tokA;
    MockStockToken tokB;
    MockFeedV3 feedA;
    MockFeedV3 feedB;

    PoolKey ttpKey;
    PoolKey keyA;
    PoolKey keyB;

    address alice = address(0xA11CE);

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 100_000 ether);

        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        ttp = new TTPToken();
        vault = new FeeVault();

        // mine a hook address with the right permission bits, deploy via CREATE2
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs = abi.encode(IPoolManager(address(manager)), address(vault), FEE_BPS);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TTPFeeHook).creationCode, ctorArgs);
        hook = new TTPFeeHook{salt: salt}(IPoolManager(address(manager)), address(vault), FEE_BPS);
        require(address(hook) == hookAddr, "hook addr mismatch");

        // TTP/ETH pool with the fee hook, 1:1, full-range liquidity
        ttpKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(ttp)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(ttpKey, SQRT_PRICE_1_1);
        ttp.approve(address(lpRouter), type(uint256).max);
        _seed(ttpKey, 5_000e18);

        // protocol wiring
        engine = new BuybackEngine(address(vault), IPoolManager(address(manager)));
        vault.setAuthorized(address(engine), true);
        burnMode = new BurnMode(address(ttp));
        dist = new RewardsDistributor();
        engine.setSinks(address(burnMode), address(dist));
        engine.setTtpPoolKey(ttpKey);

        // AI-bottleneck mock basket: two names, 50/50, hookless ETH pools
        tokA = new MockStockToken("Mock NVDA", "NVDA");
        tokB = new MockStockToken("Mock MU", "MU");
        feedA = new MockFeedV3(180e8);
        feedB = new MockFeedV3(120e8);
        tokA.mint(address(this), 1_000_000e18);
        tokB.mint(address(this), 1_000_000e18);
        tokA.approve(address(lpRouter), type(uint256).max);
        tokB.approve(address(lpRouter), type(uint256).max);

        keyA = _hooklessKey(address(tokA));
        keyB = _hooklessKey(address(tokB));
        manager.initialize(keyA, SQRT_PRICE_1_1);
        manager.initialize(keyB, SQRT_PRICE_1_1);
        _seed(keyA, 5_000e18);
        _seed(keyB, 5_000e18);

        BuybackEngine.BasketEntry[] memory entries = new BuybackEngine.BasketEntry[](2);
        entries[0] = BuybackEngine.BasketEntry({
            token: IStockToken(address(tokA)),
            feed: IAggregatorV3(address(feedA)),
            weightBps: 5000,
            poolKey: keyA
        });
        entries[1] = BuybackEngine.BasketEntry({
            token: IStockToken(address(tokB)),
            feed: IAggregatorV3(address(feedB)),
            weightBps: 5000,
            poolKey: keyB
        });
        engine.setBasket(entries);
    }

    function _hooklessKey(address token) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _seed(PoolKey memory key, uint256 liquidity) internal {
        lpRouter.modifyLiquidity{value: liquidity + 10 ether}(
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

    function _buy(PoolKey memory key, uint256 ethIn) internal {
        swapRouter.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ---- TTPFeeHook ----

    function test_HookTakesFeeOnBuy() public {
        _buy(ttpKey, 1 ether);
        // beforeSwap path: 3% of the specified ETH input goes to the vault
        assertEq(address(vault).balance, 0.03 ether, "vault fee");
        assertEq(vault.totalEthReceived(), 0.03 ether, "vault accounting");
    }

    function test_HookTakesFeeOnSell() public {
        _buy(ttpKey, 1 ether); // acquire some TTP first
        uint256 vaultBefore = address(vault).balance;
        uint256 ttpBal = ttp.balanceOf(address(this));
        ttp.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            ttpKey,
            SwapParams({
                zeroForOne: false, // TTP in, ETH out — afterSwap path (ETH unspecified)
                amountSpecified: -int256(ttpBal / 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(address(vault).balance, vaultBefore, "sell fee accrued");
    }

    function test_UntaxedPoolPassesThrough() public {
        _buy(keyA, 1 ether); // hookless pool — no fee
        assertEq(address(vault).balance, 0, "no fee on hookless pool");
    }

    // ---- Burn mode (launch default) ----

    function test_BurnModeBuyback() public {
        (bool ok,) = address(vault).call{value: 10 ether}("");
        require(ok);
        assertEq(uint256(engine.mode()), uint256(BuybackEngine.Mode.Burn), "burn is default");

        uint256[] memory minOuts = new uint256[](1);
        minOuts[0] = 1;
        engine.executeBuyback(5 ether, minOuts);

        uint256 burned = ttp.balanceOf(address(0xdead));
        assertGt(burned, 0, "TTP burned");
        assertEq(burnMode.totalBurned(), burned, "accounting");
        // our own hook taxes the buyback swap → 3% of 5 ETH lands back in the vault
        assertEq(address(vault).balance, 5 ether + 0.15 ether, "vault: 10 - 5 spent + 0.15 fee");
    }

    // ---- Distribute mode (counsel-gated) ----

    function test_DistributeModeBuyback_AndClaim() public {
        engine.setMode(BuybackEngine.Mode.Distribute);
        (bool ok,) = address(vault).call{value: 10 ether}("");
        require(ok);

        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 1;
        minOuts[1] = 1;
        engine.executeBuyback(4 ether, minOuts);

        uint256 balA = tokA.balanceOf(address(dist));
        uint256 balB = tokB.balanceOf(address(dist));
        assertGt(balA, 0, "distributor holds A");
        assertGt(balB, 0, "distributor holds B");
        // 50/50 split on identical pools → near-equal outputs
        assertApproxEqRel(balA, balB, 0.01e18, "weights respected");

        // Merkle e2e: single-leaf epoch → alice claims the full A pot
        bytes32 leaf = keccak256(abi.encode(uint256(1), alice, address(tokA), balA));
        dist.commitEpoch(leaf, uint64(block.number));
        dist.claim(1, alice, address(tokA), balA, new bytes32[](0));
        assertEq(tokA.balanceOf(alice), balA, "alice claimed");
    }

    function test_SlippageReverts() public {
        (bool ok,) = address(vault).call{value: 10 ether}("");
        require(ok);
        uint256[] memory minOuts = new uint256[](1);
        minOuts[0] = type(uint128).max;
        vm.expectRevert();
        engine.executeBuyback(1 ether, minOuts);
    }

    function test_OnlyOwnerExecutes() public {
        uint256[] memory minOuts = new uint256[](1);
        vm.prank(alice);
        vm.expectRevert(BuybackEngine.NotOwner.selector);
        engine.executeBuyback(1 ether, minOuts);
    }

    // ---- valuation ----

    function test_HoldingValueUsesFeedDirectly() public {
        tokA.mint(address(dist), 10e18);
        // 10 tokens * $180 (8dp feed) — Chainlink price already includes uiMultiplier
        assertEq(engine.holdingValue(0, address(dist)), 1800e8, "usd value");
        // corporate action changes uiMultiplier but NOT the raw-balance valuation path
        tokA.setUiMultiplier(2e18);
        assertEq(engine.holdingValue(0, address(dist)), 1800e8, "no double-count");
        assertEq(tokA.balanceOfUI(address(dist)), 20e18, "UI balance doubled");
    }
}
