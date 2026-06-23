// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title EnableDelegation
/// @notice EIP-7702: delegates the OPERATOR account's code to the Calibur
///         implementation. After this runs, the operator EOA *is* the Calibur
///         smart account — its code becomes `0xef0100 || CALIBUR_IMPLEMENTATION`,
///         so it can run `execute(mode, executionData)` (self-call) and act as the
///         `CALIBUR_EXECUTOR` for the deposit flow.
///
/// Run (broadcasts a type-4 / SetCode transaction to Sepolia):
///   OPERATOR_PRIVATE_KEY=0x... CALIBUR_IMPLEMENTATION=0x... \
///   forge script script/EnableDelegation.s.sol:EnableDelegation \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
///
/// Verify: `cast code <operator> --rpc-url $SEPOLIA_RPC_URL` → `0xef0100<impl>`.
///
/// @dev The operator (the delegated account) is the EIP-3009 `to`. It MUST be a
///      different account from the payer who signs the authorization, otherwise
///      the receive is a no-op self-transfer. See the README "roles" section.
contract EnableDelegation is Script {
    /// @dev 0-wei no-op carrier recipient (an address with no code). EIP-7702
    ///      authorizations ride on a transaction; this recipient and the 0 amount
    ///      are irrelevant to the delegation itself — the authorization list is
    ///      what sets the code. A no-code recipient guarantees the carrier
    ///      succeeds regardless of the Calibur ABI.
    address internal constant CARRIER = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY");
        address operator = vm.addr(operatorPk);
        address caliburImpl = vm.envAddress("CALIBUR_IMPLEMENTATION");
        require(caliburImpl != address(0), "CALIBUR_IMPLEMENTATION is zero");
        require(caliburImpl.code.length > 0, "CALIBUR_IMPLEMENTATION has no code on this chain");

        console2.log("== EIP-7702 ENABLE delegation ==");
        console2.log("operator (becomes the Calibur account / CALIBUR_EXECUTOR):", operator);
        console2.log("delegating to Calibur implementation:", caliburImpl);

        vm.startBroadcast(operatorPk);
        vm.signAndAttachDelegation(caliburImpl, operatorPk);
        (bool ok,) = CARRIER.call{value: 0}("");
        require(ok, "carrier tx failed");
        vm.stopBroadcast();

        console2.log("Submitted. After mining, the operator's code should be 0xef0100 + the implementation.");
        console2.log("Verify: cast code", operator);
        console2.log("Set CALIBUR_EXECUTOR to the operator address above for the deposit script.");
    }
}
