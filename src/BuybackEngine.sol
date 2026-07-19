// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {FeeVault} from "./FeeVault.sol";
import {BurnMode} from "./modes/BurnMode.sol";

/// BuybackEngine — converts FeeVault ETH into either:
///   BURN mode (launch default, Open Decision #2): TTP bought on our v4 pool → BurnMode → 0xdead.
///   DISTRIBUTE mode (counsel-gated): the AI Bottleneck basket (Open Decision #4) bought
///   across per-name ETH pools → RewardsDistributor for Merkle epochs.
/// Fee unit is native ETH throughout (Open Decision #3).
/// All swaps are exact-in, native ETH as currency0 (guaranteed: native addr(0) sorts first).
contract BuybackEngine is IUnlockCallback {
    enum Mode {
        Burn,
        Distribute
    }

    struct BasketEntry {
        IStockToken token;
        IAggregatorV3 feed; // Chainlink; price ALREADY includes uiMultiplier
        uint16 weightBps; // target weight, sum = 10_000
        PoolKey poolKey; // ETH/token v4 pool used for buybacks
    }

    struct SwapPlan {
        PoolKey key;
        uint128 amountIn;
        uint128 minOut;
        address recipient;
    }

    address public owner;
    address public feeVault;
    IPoolManager public immutable poolManager;

    Mode public mode = Mode.Burn; // launch posture: burn (Open Decision #2)
    PoolKey public ttpPoolKey; // ETH/TTP pool (with TTPFeeHook attached)
    address public burnMode;
    address public distributor;
    BasketEntry[] public basket;

    event ModeSet(Mode mode);
    event SinksSet(address burnMode, address distributor);
    event TtpPoolKeySet();
    event BasketSet(uint256 entries);
    event BuybackExecuted(Mode mode, uint256 ethSpent, uint256 swaps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPoolManager();
    error ZeroAddress();
    error BadWeights();
    error BadParams();
    error SlippageExceeded(uint256 i, uint256 out, uint256 minOut);
    error SinkUnset();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _feeVault, IPoolManager _poolManager) {
        if (_feeVault == address(0) || address(_poolManager) == address(0)) revert ZeroAddress();
        owner = msg.sender;
        feeVault = _feeVault;
        poolManager = _poolManager;
    }

    receive() external payable {} // funded by FeeVault.releaseEth

    // ---- owner config ----

    /// Multisig handover (tokenomics knob #4).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// Compliance switch (Open Decision #2). Distribute requires counsel sign-off +
    /// attestation-gated epochs — flag any change of default in BUILD_LOG.
    function setMode(Mode m) external onlyOwner {
        mode = m;
        emit ModeSet(m);
    }

    function setSinks(address _burnMode, address _distributor) external onlyOwner {
        if (_burnMode == address(0) || _distributor == address(0)) revert ZeroAddress();
        burnMode = _burnMode;
        distributor = _distributor;
        emit SinksSet(_burnMode, _distributor);
    }

    function setTtpPoolKey(PoolKey calldata key) external onlyOwner {
        ttpPoolKey = key;
        emit TtpPoolKeySet();
    }

    function setBasket(BasketEntry[] calldata entries) external onlyOwner {
        delete basket;
        uint256 total;
        for (uint256 i; i < entries.length; ++i) {
            total += entries[i].weightBps;
            basket.push(entries[i]);
        }
        if (total != 10_000) revert BadWeights();
        emit BasketSet(entries.length);
    }

    function basketLength() external view returns (uint256) {
        return basket.length;
    }

    /// USD value (feed decimals) of a basket holding sitting at `holder`.
    /// Chainlink price already includes the corporate-action multiplier — do NOT
    /// apply uiMultiplier() again.
    function holdingValue(uint256 i, address holder) external view returns (uint256) {
        BasketEntry storage e = basket[i];
        (, int256 price,, uint256 updatedAt,) = e.feed.latestRoundData();
        if (price <= 0 || updatedAt == 0) return 0;
        return (e.token.balanceOf(holder) * uint256(price)) / 1e18;
    }

    // ---- buyback execution ----

    /// Pull `amountIn` ETH from the vault and swap per current mode.
    /// minOuts: Burn mode → [minTtpOut]; Distribute mode → one per basket entry.
    function executeBuyback(uint256 amountIn, uint256[] calldata minOuts) external onlyOwner {
        FeeVault(payable(feeVault)).releaseEth(amountIn);

        SwapPlan[] memory plans;
        if (mode == Mode.Burn) {
            if (burnMode == address(0)) revert SinkUnset();
            if (minOuts.length != 1) revert BadParams();
            plans = new SwapPlan[](1);
            plans[0] = SwapPlan({
                key: ttpPoolKey,
                amountIn: uint128(amountIn),
                minOut: uint128(minOuts[0]),
                recipient: burnMode
            });
        } else {
            if (distributor == address(0)) revert SinkUnset();
            uint256 n = basket.length;
            if (n == 0 || minOuts.length != n) revert BadParams();
            plans = new SwapPlan[](n);
            uint256 assigned;
            for (uint256 i; i < n; ++i) {
                uint256 share = i == n - 1 ? amountIn - assigned : (amountIn * basket[i].weightBps) / 10_000;
                assigned += share;
                plans[i] = SwapPlan({
                    key: basket[i].poolKey,
                    amountIn: uint128(share),
                    minOut: uint128(minOuts[i]),
                    recipient: distributor
                });
            }
        }

        poolManager.unlock(abi.encode(plans));

        if (mode == Mode.Burn) BurnMode(payable(burnMode)).burn();
        emit BuybackExecuted(mode, amountIn, plans.length);
    }

    /// v4 unlock callback: executes each planned exact-in ETH→token swap, settles the
    /// ETH owed from this contract's balance, and takes output straight to the sink.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SwapPlan[] memory plans = abi.decode(data, (SwapPlan[]));

        for (uint256 i; i < plans.length; ++i) {
            SwapPlan memory p = plans[i];
            BalanceDelta delta = poolManager.swap(
                p.key,
                SwapParams({
                    zeroForOne: true, // native ETH (currency0) in → token (currency1) out
                    amountSpecified: -int256(uint256(p.amountIn)), // exact input
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );

            // settle ETH owed (includes any hook fee charged to us as swapper)
            int128 a0 = delta.amount0();
            if (a0 < 0) {
                poolManager.settle{value: uint256(uint128(-a0))}();
            }

            // take output to the sink
            int128 a1 = delta.amount1();
            uint256 out = a1 > 0 ? uint256(uint128(a1)) : 0;
            if (out < p.minOut) revert SlippageExceeded(i, out, p.minOut);
            if (out > 0) poolManager.take(p.key.currency1, p.recipient, out);
        }
        return "";
    }
}
