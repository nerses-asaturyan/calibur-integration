// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {SplitForwarder} from "../src/SplitForwarder.sol";

/// @title DeploySplitForwarderScript
/// @notice Deploys the stateless SplitForwarder (no constructor args, no owner).
///
/// Usage:
///   forge script script/DeploySplitForwarder.s.sol:DeploySplitForwarderScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vv < /dev/null
contract DeploySplitForwarderScript is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        SplitForwarder sf = new SplitForwarder();
        vm.stopBroadcast();

        console2.log("SplitForwarder deployed:", address(sf));
        console2.log("Set DEPOSIT_FORWARDER in .env to the address above.");
    }
}
