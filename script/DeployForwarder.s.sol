// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {BalanceForwarder} from "../src/BalanceForwarder.sol";

/// @title DeployForwarderScript
/// @notice Deploys the stateless BalanceForwarder (no constructor args, no owner).
///
/// Usage:
///   forge script script/DeployForwarder.s.sol:DeployForwarderScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vv < /dev/null
contract DeployForwarderScript is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        BalanceForwarder fwd = new BalanceForwarder();
        vm.stopBroadcast();

        console2.log("BalanceForwarder deployed:", address(fwd));
        console2.log("Set DEPOSIT_FORWARDER in .env to the address above.");
    }
}
