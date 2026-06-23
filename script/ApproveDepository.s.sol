// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @title ApproveDepository
/// @notice One-time (optional) USDC approval from the executor account to the
///         LayerswapDepository. After this, `CaliburDeposit` automatically uses
///         the cheaper 2-call batch (receive → deposit), skipping the per-deposit
///         approve.
///
/// @dev SAFE because the executor custodies no idle USDC — funds only transit
///      through it during the atomic batch, and the depository only forwards to a
///      whitelisted receiver. A plain outbound `approve` from the executor EOA;
///      its EIP-7702 delegation does not affect outbound calls, so this works
///      whether or not delegation is currently enabled.
///
/// Run:
///   forge script script/ApproveDepository.s.sol:ApproveDepository \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
///
/// Revoke later (or after retiring the executor) with APPROVE_AMOUNT=0.
contract ApproveDepository is Script {
    function run() external {
        uint256 operatorPk = vm.envUint("OPERATOR_PRIVATE_KEY");
        address executor = vm.addr(operatorPk);
        address usdc = vm.envAddress("USDC_SEPOLIA");
        address depository = vm.envAddress("LAYERSWAP_DEPOSITORY");
        uint256 amount = vm.envOr("APPROVE_AMOUNT", type(uint256).max);

        console2.log("executor (approver):", executor);
        console2.log("USDC:", usdc);
        console2.log("depository (spender):", depository);
        console2.log("approval amount:", amount);

        vm.startBroadcast(operatorPk);
        IERC20(usdc).approve(depository, amount);
        vm.stopBroadcast();

        console2.log(amount == 0 ? "Allowance revoked." : "Approved. Deposits now use the 2-call batch.");
    }
}
