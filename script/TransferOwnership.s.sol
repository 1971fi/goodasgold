// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {BuybackEngine} from "../src/BuybackEngine.sol";
import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {Treasury} from "../src/Treasury.sol";
import {TTPToken} from "../src/TTPToken.sol";

/// Ownership handover to the multisig (tokenomics knob #4).
/// Safe v1.3.0 factory is live on Robinhood Chain at the canonical address
/// 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67 — create the 2-of-3 Safe via the Safe
/// UI/SDK first, then run this with SAFE_ADDRESS set.
///
///   forge script script/TransferOwnership.s.sol --rpc-url $TESTNET_RPC_URL \
///     --private-key $DEV_WALLET_PRIVATE_KEY --broadcast -vv
///
/// TTPToken: this script does NOT renounce — renounce is a separate, deliberate,
/// post-launch-ops action (irreversible). Command printed at the end.
contract TransferOwnership is Script {
    uint256 constant ROBINHOOD_TESTNET = 46630;

    error WrongChain(uint256 got);
    error NotAContractSafe();

    function run() external {
        if (block.chainid != ROBINHOOD_TESTNET) revert WrongChain(block.chainid);

        address safe = vm.envAddress("SAFE_ADDRESS");
        // guard against handing everything to an EOA typo — a Safe is a contract
        if (safe.code.length == 0) revert NotAContractSafe();

        address vault = vm.envAddress("FEEVAULT_ADDRESS");
        address engine = vm.envAddress("ENGINE_ADDRESS");
        address distributor = vm.envAddress("DISTRIBUTOR_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        vm.startBroadcast();
        FeeVault(payable(vault)).transferOwnership(safe);
        BuybackEngine(payable(engine)).transferOwnership(safe);
        RewardsDistributor(distributor).transferOwnership(safe);
        Treasury(payable(treasury)).transferOwnership(safe);
        vm.stopBroadcast();

        console2.log("owners moved to Safe:", safe);
        console2.log("TTPToken renounce (run manually when launch ops are done):");
        console2.log("  cast send <TTP_ADDRESS> 'renounceOwnership()' --private-key ...");
    }
}
