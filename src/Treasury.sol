// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {FeeVault} from "./FeeVault.sol";

/// Treasury — the volume-independent side of the payout flywheel:
///   1. PROTOCOL-OWNED LIQUIDITY: holds the TTP/ETH LP position itself (full-range),
///      earning the pool's LP-fee layer on top of the hook tax. Also fixes the
///      seed-liquidity custody hole (test routers let anyone withdraw their positions).
///   2. SGOV SLEEVE: holds a T-bill-ETF Stock Token whose yield accrues via ERC-8056
///      uiMultiplier. harvestSleeve() converts multiplier growth since the last
///      checkpoint into raw tokens pushed to the RewardsDistributor pot — payouts
///      keep dripping when trading volume weakens.
/// Funding: pulls ETH from FeeVault (must be authorized). All ops onlyOwner.
/// COMPLIANCE NOTE: sleeve yield feeding payouts strengthens the "expectation of
/// profits" character — on the counsel checklist (Open Decision #2 posture).
contract Treasury is IUnlockCallback {
    uint8 constant OP_LIQUIDITY = 0;
    uint8 constant OP_SWAP = 1;

    struct Op {
        uint8 kind;
        PoolKey key;
        int256 liquidityDelta; // OP_LIQUIDITY (0 = collect fees only)
        uint128 amountIn; // OP_SWAP
        uint128 minOut; // OP_SWAP
    }

    address public owner;
    address public feeVault;
    address public distributor;
    IPoolManager public immutable poolManager;

    IStockToken public sleeveToken;
    uint256 public sleeveMultCheckpoint; // uiMultiplier at last harvest

    event LiquidityChanged(int256 delta);
    event FeesCollected();
    event SleeveSet(address token, uint256 multCheckpoint);
    event SleeveHarvested(uint256 rawAmount, uint256 newMult);
    event PulledFromVault(uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPoolManager();
    error ZeroAddress();
    error NoSleeve();
    error SlippageExceeded(uint256 out, uint256 minOut);
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _feeVault, IPoolManager _poolManager, address _distributor) {
        if (_feeVault == address(0) || address(_poolManager) == address(0) || _distributor == address(0)) {
            revert ZeroAddress();
        }
        owner = msg.sender;
        feeVault = _feeVault;
        poolManager = _poolManager;
        distributor = _distributor;
    }

    receive() external payable {}

    /// Multisig handover (tokenomics knob #4).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---- funding ----

    /// Pull ETH from the FeeVault (treasury must be authorized there).
    function pullFromVault(uint256 amount) external onlyOwner {
        FeeVault(payable(feeVault)).releaseEth(amount);
        emit PulledFromVault(amount);
    }

    // ---- protocol-owned liquidity (full range) ----

    function addLiquidity(PoolKey calldata key, uint256 liquidity) external onlyOwner {
        _unlock(Op(OP_LIQUIDITY, key, int256(liquidity), 0, 0));
        emit LiquidityChanged(int256(liquidity));
    }

    function removeLiquidity(PoolKey calldata key, uint256 liquidity) external onlyOwner {
        _unlock(Op(OP_LIQUIDITY, key, -int256(liquidity), 0, 0));
        emit LiquidityChanged(-int256(liquidity));
    }

    /// modifyLiquidity with delta 0 realizes accrued LP fees to this contract.
    function collectFees(PoolKey calldata key) external onlyOwner {
        _unlock(Op(OP_LIQUIDITY, key, 0, 0, 0));
        emit FeesCollected();
    }

    // ---- sleeve ----

    /// Buy the sleeve asset (e.g. SGOV) with treasury ETH on its v4 pool.
    function buy(PoolKey calldata key, uint128 amountIn, uint128 minOut) external onlyOwner {
        _unlock(Op(OP_SWAP, key, 0, amountIn, minOut));
    }

    function setSleeve(IStockToken token) external onlyOwner {
        if (address(token) == address(0)) revert ZeroAddress();
        sleeveToken = token;
        sleeveMultCheckpoint = token.uiMultiplier();
        emit SleeveSet(address(token), sleeveMultCheckpoint);
    }

    /// Push multiplier growth since last checkpoint to the distributor pot:
    /// yieldRaw = raw * (m - checkpoint) / m  — the raw amount whose UI value equals
    /// the accrued yield. Permissionless poke (funds can only move to the distributor).
    function harvestSleeve() external returns (uint256 yieldRaw) {
        IStockToken t = sleeveToken;
        if (address(t) == address(0)) revert NoSleeve();
        uint256 m = t.uiMultiplier();
        uint256 cp = sleeveMultCheckpoint;
        if (m <= cp) return 0; // no growth (or corporate action down) — checkpoint unchanged
        uint256 raw = t.balanceOf(address(this));
        yieldRaw = (raw * (m - cp)) / m;
        sleeveMultCheckpoint = m;
        if (yieldRaw > 0 && !t.transfer(distributor, yieldRaw)) revert TransferFailed();
        emit SleeveHarvested(yieldRaw, m);
    }

    // ---- owner rescue (testnet ops) ----

    function sweepEth(address to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function sweepToken(address token, address to, uint256 amount) external onlyOwner {
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
    }

    // ---- v4 plumbing ----

    function _unlock(Op memory op) internal {
        poolManager.unlock(abi.encode(op));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Op memory op = abi.decode(data, (Op));

        if (op.kind == OP_LIQUIDITY) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                op.key,
                ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(op.key.tickSpacing),
                    tickUpper: TickMath.maxUsableTick(op.key.tickSpacing),
                    liquidityDelta: op.liquidityDelta,
                    salt: 0
                }),
                ""
            );
            _settleOrTake(op.key.currency0, delta.amount0());
            _settleOrTake(op.key.currency1, delta.amount1());
        } else {
            BalanceDelta delta = poolManager.swap(
                op.key,
                SwapParams({
                    zeroForOne: true, // ETH in
                    amountSpecified: -int256(uint256(op.amountIn)),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            int128 a1 = delta.amount1();
            uint256 out = a1 > 0 ? uint256(uint128(a1)) : 0;
            if (out < op.minOut) revert SlippageExceeded(out, op.minOut);
            _settleOrTake(op.key.currency0, delta.amount0());
            if (out > 0) poolManager.take(op.key.currency1, address(this), out);
        }
        return "";
    }

    function _settleOrTake(Currency c, int128 a) internal {
        if (a < 0) {
            uint256 amt = uint256(uint128(-a));
            if (c.isAddressZero()) {
                poolManager.settle{value: amt}();
            } else {
                poolManager.sync(c);
                if (!IERC20(Currency.unwrap(c)).transfer(address(poolManager), amt)) revert TransferFailed();
                poolManager.settle();
            }
        } else if (a > 0) {
            poolManager.take(c, address(this), uint256(uint128(a)));
        }
    }
}
