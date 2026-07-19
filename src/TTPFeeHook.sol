// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// TTPFeeHook — the protocol's primary fee source (Open Decision #1: maximize capture).
/// Uniswap v4 hook on the TTP/ETH pool charging `feeBps` in NATIVE ETH on both buys and
/// sells, sent straight to the FeeVault. Pattern proven by INDEX's IndexFeeHook
/// (0x2cD9...c0cC, torn down in state/BUILD_LOG.md):
///   - ETH is the SPECIFIED amount (exact-in buy, exact-out sell) → charged in beforeSwap.
///   - ETH is the UNSPECIFIED amount (exact-in sell, exact-out buy) → charged in afterSwap.
/// Pools without native ETH as currency0 pass through untaxed (guard, not a feature —
/// known INDEX leak; mitigated by us seeding/owning the canonical pool).
contract TTPFeeHook is BaseHook {
    using SafeCast for uint256;

    uint256 public constant MAX_FEE_BPS = 500; // hard cap 5%
    uint256 internal constant BPS = 10_000;

    uint256 public immutable feeBps;
    address public immutable treasury; // FeeVault

    error FeeTooHigh();
    error ZeroAddress();

    constructor(IPoolManager pm, address treasury_, uint256 feeBps_) BaseHook(pm) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        treasury = treasury_;
        feeBps = feeBps_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// ETH is specified iff exactIn == zeroForOne (input is c0=ETH on exact-in buys;
    /// output is c0=ETH on exact-out sells).
    function _ethSpecified(SwapParams calldata p) internal pure returns (bool) {
        return (p.amountSpecified < 0) == p.zeroForOne;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.currency0.isAddressZero() || !_ethSpecified(params)) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amt =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = (amt * feeBps) / BPS;
        if (fee == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // take now (hook goes -fee), returned delta credits the hook +fee: nets zero,
        // the swapper pays. Canonical fee-taking-hook pattern.
        poolManager.take(key.currency0, treasury, fee);
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (!key.currency0.isAddressZero() || _ethSpecified(params)) {
            return (this.afterSwap.selector, 0); // fee already handled in beforeSwap (or non-ETH pool)
        }
        int128 a0 = delta.amount0();
        uint256 amt = a0 < 0 ? uint256(uint128(-a0)) : uint256(uint128(a0));
        uint256 fee = (amt * feeBps) / BPS;
        if (fee == 0) return (this.afterSwap.selector, 0);

        poolManager.take(key.currency0, treasury, fee);
        return (this.afterSwap.selector, fee.toInt128());
    }
}
