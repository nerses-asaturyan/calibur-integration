// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LayerswapDepository} from "../src/LayerswapDepository.sol";

/// @title DeployDepositoryScript
/// @notice Deploys our own LayerswapDepository (with `depositERC20All`) to Sepolia.
///         Owner = the operator EOA (addr(PRIVATE_KEY)); initial whitelist =
///         [DEPOSIT_RECEIVER].
///
/// Usage:
///   forge script script/DeployDepository.s.sol:DeployDepositoryScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vv < /dev/null
contract DeployDepositoryScript is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address owner = vm.envOr("DEPOSITORY_OWNER", vm.addr(deployerPk));
        address receiver = vm.envAddress("DEPOSIT_RECEIVER");

        address[] memory initial = new address[](1);
        initial[0] = receiver;

        vm.startBroadcast(deployerPk);
        LayerswapDepository dep = new LayerswapDepository(owner, initial);
        vm.stopBroadcast();

        console2.log("LayerswapDepository deployed:", address(dep));
        console2.log("  owner:", owner);
        console2.log("  whitelisted receiver:", receiver);
        console2.log("  isWhitelisted:", dep.isWhitelisted(receiver));
        console2.log("Update LAYERSWAP_DEPOSITORY in .env to the address above.");
    }
}
