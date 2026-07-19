// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {TTPToken} from "../src/TTPToken.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";

contract TreasuryTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    TTPToken ttp;
    FeeVault vault;
    Treasury treasury;
    MockStockToken sgov;
    address distributor = address(0xD157);

    PoolKey ttpKey; // hookless — POL mechanics don't need the fee hook
    PoolKey sgovKey;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 100_000 ether);
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        ttp = new TTPToken();
        vault = new FeeVault();
        treasury = new Treasury(address(vault), IPoolManager(address(manager)), distributor);
        vault.setAuthorized(address(treasury), true);

        ttpKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(ttp)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(ttpKey, SQRT_PRICE_1_1);

        // fund treasury with both sides for POL
        ttp.transfer(address(treasury), 100_000e18);
        (bool ok,) = address(treasury).call{value: 5_000 ether}("");
        require(ok);

        // SGOV pool (seeded externally so treasury can buy)
        sgov = new MockStockToken("Mock SGOV", "SGOV");
        sgov.mint(address(this), 1_000_000e18);
        sgov.approve(address(lpRouter), type(uint256).max);
        sgovKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(sgov)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(sgovKey, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: 1_010 ether}(
            sgovKey,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1_000e18, 0),
            ""
        );
    }

    function test_AddCollectRemoveLiquidity() public {
        uint256 ethBefore = address(treasury).balance;
        uint256 ttpBefore = ttp.balanceOf(address(treasury));
        treasury.addLiquidity(ttpKey, 1_000e18);
        assertLt(address(treasury).balance, ethBefore, "eth in");
        assertLt(ttp.balanceOf(address(treasury)), ttpBefore, "ttp in");

        // trade through the pool to accrue LP fees
        for (uint256 i; i < 3; ++i) {
            swapRouter.swap{value: 10 ether}(
                ttpKey,
                SwapParams(true, -int256(10 ether), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
        }
        uint256 ethMid = address(treasury).balance;
        treasury.collectFees(ttpKey);
        assertGt(address(treasury).balance, ethMid, "LP fees collected in ETH");

        // full exit returns principal
        uint256 ethBeforeExit = address(treasury).balance;
        treasury.removeLiquidity(ttpKey, 1_000e18);
        assertGt(address(treasury).balance, ethBeforeExit, "principal back");
    }

    function test_BuySleeveAndHarvest() public {
        treasury.buy(sgovKey, 10 ether, 1);
        uint256 raw = sgov.balanceOf(address(treasury));
        assertGt(raw, 0, "sleeve bought");

        treasury.setSleeve(IStockToken(address(sgov)));
        assertEq(treasury.harvestSleeve(), 0, "no growth yet");

        // simulate T-bill yield: +2% via uiMultiplier
        sgov.setUiMultiplier(1.02e18);
        uint256 y = treasury.harvestSleeve();
        // yieldRaw = raw * (1.02-1.00)/1.02 ≈ 1.9608% of raw
        assertApproxEqRel(y, (raw * 2) / 102, 0.001e18, "yield share");
        assertEq(sgov.balanceOf(distributor), y, "distributor got yield");

        // idempotent until next growth
        assertEq(treasury.harvestSleeve(), 0, "checkpoint advanced");
        sgov.setUiMultiplier(1.03e18);
        assertGt(treasury.harvestSleeve(), 0, "next growth harvests");
    }

    function test_PullFromVault() public {
        (bool ok,) = address(vault).call{value: 3 ether}("");
        require(ok);
        uint256 before = address(treasury).balance;
        treasury.pullFromVault(1 ether);
        assertEq(address(treasury).balance, before + 1 ether, "funded");
    }

    function test_OnlyOwnerOps() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert(Treasury.NotOwner.selector);
        treasury.addLiquidity(ttpKey, 1);
        vm.expectRevert(Treasury.NotOwner.selector);
        treasury.buy(sgovKey, 1, 0);
        vm.expectRevert(Treasury.NotOwner.selector);
        treasury.pullFromVault(1);
        vm.stopPrank();
    }

    function test_HarvestWithoutSleeveReverts() public {
        vm.expectRevert(Treasury.NoSleeve.selector);
        treasury.harvestSleeve();
    }
}
