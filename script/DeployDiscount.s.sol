// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {DiscountSwapper} from "../src/DiscountSwapper.sol";
import {DiscountRouter} from "../src/DiscountRouter.sol";

interface IMockUSDGMint { function mint(address to, uint256 a) external; }

/// HARD FLOOR WIRE-UP: deploys DiscountSwapper + DiscountRouter onto the EXISTING live 1971
/// deployment (no core redeploy). After this, anyone can call discountBuyBurn when 1971 trades
/// below NAV: the buffer buys it off the market and burns it. Proven by DiscountFork 2/2.
///   forge script script/DeployDiscount.s.sol --rpc-url $env:RH_RPC \
///     --private-key $env:DEV_WALLET_PRIVATE_KEY --broadcast -vv
/// Reads the live addresses from env (set below to current deployment defaults).
contract DeployDiscount is Script {
    uint256 constant ROBINHOOD_TESTNET = 46630;
    address constant PM = 0x552815eF68E6eb418A3d65D0AA1043d93204F612;

    // current live deployment (rewire-synced); override via env if redeployed
    address usdg;
    address gag;
    address vault;
    address hook;

    error WrongChain(uint256 got);

    function run() external {
        if (block.chainid != ROBINHOOD_TESTNET) revert WrongChain(block.chainid);
        usdg = vm.envOr("USDG_ADDR", address(0x119E0A8c499dE27a2fC2a341aF229802D2548d19));
        gag = vm.envOr("GAG_ADDR", address(0xD8eCaEe6dc47Ce14232F9Eb9468009495a3f0E32));
        vault = vm.envOr("VAULT_ADDR", address(0xDb71F8831dAb638E05986D9C4F064546BF184462));
        hook = vm.envOr("HOOK_ADDR", address(0xcf1bF1CEC0D7732ae1bD9BFF693C95CA16B000cc));

        // params: 3% discount margin, 100 USDG max per call, 30 min cooldown (tune later)
        uint16 discountBps = uint16(vm.envOr("DISCOUNT_BPS", uint256(300)));
        uint256 maxSpend = vm.envOr("MAX_SPEND", uint256(100e18));
        uint256 cooldown = vm.envOr("COOLDOWN", uint256(30 minutes));
        uint256 seedBuffer = vm.envOr("SEED_BUFFER_USDG", uint256(50e18)); // testnet: mint mock USDG

        vm.startBroadcast();
        DiscountSwapper swapper = new DiscountSwapper(IPoolManager(PM), usdg, gag);
        swapper.setKeys(
            PoolKey({ currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: Currency.wrap(usdg), fee: 3000, tickSpacing: 60, hooks: IHooks(address(0)) }),
            PoolKey({ currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: Currency.wrap(gag), fee: 3000, tickSpacing: 60, hooks: IHooks(hook) })
        );
        DiscountRouter router = new DiscountRouter(usdg, gag, vault, address(swapper), discountBps, maxSpend, cooldown);

        // fund: dust ETH for the leg-2 hook fee, and a starter USDG buffer (mock mint, testnet only;
        // on mainnet the buffer is funded by routing a fee slice here instead)
        (bool ok,) = address(swapper).call{value: 0.0005 ether}("");
        require(ok, "fund swapper eth");
        IMockUSDGMint(usdg).mint(address(router), seedBuffer);
        vm.stopBroadcast();

        console2.log("== HARD FLOOR WIRED (testnet) ==");
        console2.log("DiscountSwapper:", address(swapper));
        console2.log("DiscountRouter: ", address(router));
        console2.log("params: discountBps", discountBps);
        console2.log("        maxSpend   ", maxSpend);
        console2.log("        cooldown   ", cooldown);
        console2.log("buffer USDG:", seedBuffer);
        console2.log("keeper call: cast send <router> \"discountBuyBurn(uint256,uint256)\" <usdgIn> 0 ...");
    }
}
