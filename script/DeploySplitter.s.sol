// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PayoutSplitter} from "../src/PayoutSplitter.sol";

/// @title DeploySplitterScript
/// @notice Deploys the stateless, permissionless PayoutSplitter (no constructor
///         args, no owner). Anyone can use it; it must never hold funds across
///         transactions.
///
/// Usage:
///   forge script script/DeploySplitter.s.sol:DeploySplitterScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vv < /dev/null
contract DeploySplitterScript is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        PayoutSplitter splitter = new PayoutSplitter();
        vm.stopBroadcast();

        console2.log("PayoutSplitter deployed:", address(splitter));
        console2.log("Set PAYOUT_SPLITTER in .env to the address above.");
    }
}
