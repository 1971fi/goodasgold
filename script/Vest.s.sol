// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {GoodAsGold} from "../src/GoodAsGold.sol";
import {VestingLocker} from "../src/launch/VestingLocker.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// ====================== 1971 SUPPLY LOCKUP + BURN (mainnet) ======================
/// Turns the deployer's remaining balance into the disclosed structure:
///   - VEST_AMOUNT -> immutable VestingLocker (beneficiary = creator wallet,
///     3-month cliff, 12-month linear, no owner, terms unchangeable)
///   - everything else the deployer holds -> TRUE BURN (totalSupply shrinks,
///     floor per token ratchets up for all holders)
/// Deployer liquid balance after this: 0.
///
///   $env:VEST_AMOUNT="350000000000000000000000000"   # 350M (35%), explicit decision
///   forge script script/Vest.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com `
///     --private-key $env:DEV_WALLET_PRIVATE_KEY --broadcast -vv
contract Vest is Script {
    uint256 constant ROBINHOOD_MAINNET = 4663;
    address constant GAG = 0x18fA6c4f8000bA5910B132825aB4De4819209F1c;
    address constant CREATOR_WALLET = 0x008baC045a4220Bf6755564C5eA2e1B271EB670F;

    error WrongChain(uint256 got);
    error NothingToBurn();

    function run() external {
        if (block.chainid != ROBINHOOD_MAINNET) revert WrongChain(block.chainid);
        uint256 vestAmount = vm.envUint("VEST_AMOUNT");
        GoodAsGold gag = GoodAsGold(GAG);

        vm.startBroadcast();

        // 1. immutable vesting: 3-month cliff, 12-month linear, creator wallet beneficiary
        VestingLocker locker =
            new VestingLocker(IERC20(GAG), CREATOR_WALLET, uint64(block.timestamp), 90 days, 365 days);
        gag.excludeFromDividends(address(locker)); // unvested tokens earn no yield
        gag.transfer(address(locker), vestAmount);

        // 2. true burn of everything left in the deployer wallet
        uint256 rest = gag.balanceOf(msg.sender);
        if (rest == 0) revert NothingToBurn();
        gag.approve(msg.sender, rest);
        gag.burnFrom(msg.sender, rest);

        vm.stopBroadcast();

        console2.log("========== LOCKUP + BURN DONE ==========");
        console2.log("VestingLocker:", address(locker));
        console2.log("vested (wei):", vestAmount);
        console2.log("burned (wei):", rest);
        console2.log("new totalSupply:", gag.totalSupply());
        console2.log("deployer balance:", gag.balanceOf(msg.sender));
    }
}
