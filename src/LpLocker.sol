// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title LpLocker — owner-gated v4 liquidity holder for the 1971/ETH pool.
/// @notice The v4 test router (PoolModifyLiquidityTest) credits WHOEVER CALLS IT on withdrawal,
///         so any liquidity seeded through it is permissionlessly stealable. This contract owns
///         its positions and only the owner can add/remove. Fund it (ETH via the payable call,
///         1971 via plain transfer) before calling modify(); credits on removal go to the owner.
contract LpLocker is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public owner;

    error NotPoolManager();
    error NotOwner();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(IPoolManager _pm) { poolManager = _pm; owner = msg.sender; }

    receive() external payable {}

    function transferOwner(address to) external onlyOwner { require(to != address(0), "zero"); owner = to; }
    function rescueEth(address to, uint256 amt) external onlyOwner { (bool ok,) = to.call{value: amt}(""); require(ok, "eth"); }
    function rescueToken(address token, address to, uint256 amt) external onlyOwner { require(IERC20(token).transfer(to, amt), "tok"); }

    /// Add (positive delta) or remove (negative delta) liquidity. Pays from this contract's
    /// balances; removal credits are taken straight to the owner.
    function modify(PoolKey calldata key, ModifyLiquidityParams calldata p) external payable onlyOwner {
        poolManager.unlock(abi.encode(key, p));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, ModifyLiquidityParams memory p) = abi.decode(data, (PoolKey, ModifyLiquidityParams));
        (BalanceDelta d,) = poolManager.modifyLiquidity(key, p, "");

        int128 a0 = d.amount0(); // native ETH
        if (a0 < 0) poolManager.settle{value: uint256(uint128(-a0))}();
        else if (a0 > 0) poolManager.take(key.currency0, owner, uint256(uint128(a0)));

        int128 a1 = d.amount1(); // ERC20 (1971)
        if (a1 < 0) {
            poolManager.sync(key.currency1);
            require(IERC20(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint256(uint128(-a1))), "pay1");
            poolManager.settle();
        } else if (a1 > 0) {
            poolManager.take(key.currency1, owner, uint256(uint128(a1)));
        }
        return "";
    }
}
