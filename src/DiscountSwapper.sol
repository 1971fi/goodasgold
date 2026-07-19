// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title DiscountSwapper — concrete ISwapper for the DiscountRouter.
/// @notice Routes USDG -> ETH -> 1971 across the two native-ETH v4 pools and delivers 1971 to
///         `to`, reverting if the amount received is below `minOut`. ETH is purely an internal
///         hop: the credit from leg 1 is consumed by leg 2.
/// @dev    LEG 2 uses the 1971/ETH pool, which carries the 4% fee hook. That fee is charged to
///         us as the swapper. Economically it is NOT lost: it flows to the FeeVault and back
///         into the reserve. Mechanically it means leg 2 may owe slightly more ETH than the leg-1
///         credit, so we top up the difference from this contract's small ETH buffer (fund it via
///         plain ETH transfer). The router's minOut always guards the final 1971 received, so a
///         fee taken on the output side is handled too.
///
///         VERIFY ON A FORK before any live use: the exact fee accounting on the hooked pool is
///         the one thing that cannot be unit-tested off-chain. Test USDG->1971 end to end against
///         the real pools and confirm settlement closes and minOut holds. This is the #1 audit surface.
contract DiscountSwapper is IUnlockCallback {
    IPoolManager public immutable poolManager;
    IERC20 public immutable usdg;
    address public immutable token1971;
    PoolKey public usdgEthKey;   // currency0 = ETH (address 0), currency1 = USDG
    PoolKey public gagEthKey;    // currency0 = ETH (address 0), currency1 = 1971 (fee hook attached)
    address public admin;

    error NotPoolManager();
    error NotAdmin();
    error Slippage(uint256 out, uint256 minOut);

    modifier onlyAdmin() { if (msg.sender != admin) revert NotAdmin(); _; }

    constructor(IPoolManager _pm, address _usdg, address _token1971) {
        poolManager = _pm; usdg = IERC20(_usdg); token1971 = _token1971; admin = msg.sender;
    }

    receive() external payable {} // ETH buffer to cover the hook fee on leg 2

    function setKeys(PoolKey calldata _usdgEth, PoolKey calldata _gagEth) external onlyAdmin {
        usdgEthKey = _usdgEth; gagEthKey = _gagEth;
    }
    function transferAdmin(address to) external onlyAdmin { require(to != address(0), "zero"); admin = to; }
    function rescueEth(address to, uint256 amt) external onlyAdmin { (bool ok,) = to.call{value: amt}(""); require(ok, "eth"); }

    /// Pull USDG from caller (the DiscountRouter approves), swap to 1971, deliver to `to`.
    function swapUsdgForToken(uint256 usdgIn, uint256 minOut, address to) external returns (uint256 out) {
        require(usdg.transferFrom(msg.sender, address(this), usdgIn), "pull");
        bytes memory res = poolManager.unlock(abi.encode(usdgIn, minOut, to));
        out = abi.decode(res, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 usdgIn, uint256 minOut, address to) = abi.decode(data, (uint256, uint256, address));

        // LEG 1: USDG (currency1) -> ETH (currency0). exact-in USDG, zeroForOne = false.
        BalanceDelta d1 = poolManager.swap(
            usdgEthKey,
            SwapParams({ zeroForOne: false, amountSpecified: -int256(usdgIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 }),
            ""
        );
        // pay the USDG we owe (currency1 negative) via the v4 sync/transfer/settle pattern
        uint256 usdgOwed = uint256(uint128(-d1.amount1()));
        poolManager.sync(usdgEthKey.currency1);
        usdg.transfer(address(poolManager), usdgOwed);
        poolManager.settle();
        uint256 ethCredit = uint256(uint128(d1.amount0())); // ETH received, left as a credit

        // LEG 2: ETH (currency0) -> 1971 (currency1). exact-in the ETH credit, zeroForOne = true.
        BalanceDelta d2 = poolManager.swap(
            gagEthKey,
            SwapParams({ zeroForOne: true, amountSpecified: -int256(ethCredit), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            ""
        );
        // ETH owed by leg 2 (may exceed the credit if the hook charges the fee on the input side)
        uint256 ethOwed = uint256(uint128(-d2.amount0()));
        if (ethOwed > ethCredit) {
            poolManager.settle{value: ethOwed - ethCredit}(); // top up the fee from our ETH buffer
        }
        // deliver 1971
        uint256 out = uint256(uint128(d2.amount1()));
        if (out < minOut) revert Slippage(out, minOut);
        poolManager.take(gagEthKey.currency1, to, out);
        return abi.encode(out);
    }
}
