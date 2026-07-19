// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Treasury} from "../src/Treasury.sol";
import {TTPToken} from "../src/TTPToken.sol";

/// LP tranching (tokenomics knob #1): the 60% LP bucket enters the pool in TRANCHES,
/// not at once — each run adds one tranche of treasury-owned full-range liquidity.
/// Suggested mainnet schedule (document each run in BUILD_LOG):
///   T0 launch: 10% of LP bucket · then 15% weekly x6 as volume/price discovery allows.
///
///   TRANCHE_LIQUIDITY=<liquidity units> forge script script/TrancheLiquidity.s.sol \
///     --rpc-url $TESTNET_RPC_URL --private-key $DEV_WALLET_PRIVATE_KEY --broadcast -vv
///
/// Requires: treasury already funded with TTP + ETH for the tranche, caller = treasury owner.
contract TrancheLiquidity is Script {
    uint256 constant ROBINHOOD_TESTNET = 46630;

    error WrongChain(uint256 got);

    function run() external {
        if (block.chainid != ROBINHOOD_TESTNET) revert WrongChain(block.chainid);

        Treasury treasury = Treasury(payable(vm.envAddress("TREASURY_ADDRESS")));
        address ttp = vm.envAddress("TTP_ADDRESS");
        address hook = vm.envAddress("HOOK_ADDRESS");
        uint256 liquidity = vm.envUint("TRANCHE_LIQUIDITY");

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(ttp),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        vm.startBroadcast();
        treasury.addLiquidity(key, liquidity);
        vm.stopBroadcast();

        console2.log("tranche added:", liquidity);
        console2.log("treasury ETH remaining:", address(treasury).balance);
    }
}
