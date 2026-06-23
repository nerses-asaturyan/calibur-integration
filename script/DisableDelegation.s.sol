// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DisableDelegation
/// @notice EIP-7702: clears the OPERATOR account's delegation by re-delegating to
///         the zero address. After this runs, the operator's code is empty again
///         and it is a plain EOA.
///
/// Run (broadcasts a type-4 / SetCode transaction to Sepolia):
///   OPERATOR_PRIVATE_KEY=0x... \
///   forge script script/DisableDelegation.s.sol:DisableDelegation \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
///
/// Verify: `cast code <operator> --rpc-url $SEPOLIA_RPC_URL` → `0x` (empty).
contract DisableDelegation is Script {
    /// @dev See EnableDelegation: a 0-wei no-op carrier so the EIP-7702
    ///      authorization (operator -> address(0)) is included in a transaction.
    address internal constant CARRIER = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY");
        address operator = vm.addr(operatorPk);

        console2.log("== EIP-7702 DISABLE delegation ==");
        console2.log("operator (delegation will be cleared):", operator);

        vm.startBroadcast(operatorPk);
        vm.signAndAttachDelegation(address(0), operatorPk); // address(0) clears the delegation
        (bool ok,) = CARRIER.call{value: 0}("");
        require(ok, "carrier tx failed");
        vm.stopBroadcast();

        console2.log("Submitted. After mining, the operator's code should be empty (0x).");
        console2.log("Verify: cast code", operator);
    }
}
