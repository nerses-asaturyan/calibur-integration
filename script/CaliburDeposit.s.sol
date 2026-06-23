// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC7821} from "../src/interfaces/IERC7821.sol";
import {IERC3009USDC} from "../src/interfaces/IERC3009USDC.sol";
import {ILayerswapDepository} from "../src/interfaces/ILayerswapDepository.sol";
import {CaliburDepositBatch} from "../src/CaliburDepositBatch.sol";

/// @title CaliburDepositScript
/// @notice Signs the EIP-3009 authorization at runtime and submits the atomic
///         "receive → (approve) → deposit" batch through the Calibur executor
///         (your broadcaster EOA delegated to Calibur via EIP-7702). No new
///         contract is deployed.
///
/// @dev `executor` (the EIP-3009 `to`) defaults to the broadcaster's own address
///      (addr(PRIVATE_KEY)) — NOT the Calibur implementation. Dynamic per run:
///      validBefore = now + 10m, validAfter = 0, random nonce, random depositId
///      (override with env DEPOSIT_ID), and v/r/s signed here from USER_PRIVATE_KEY.
///
/// @dev If the executor already has a standing allowance to the depository, the
///      approve call is skipped (2-call batch). Grant it once with
///      `ApproveDepository.s.sol`; it is safe because the executor holds no idle
///      USDC (funds only transit during the atomic batch).
///
/// Usage:
///   forge script script/CaliburDeposit.s.sol:CaliburDepositScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
contract CaliburDepositScript is Script {
    bytes32 internal constant ERC7821_BATCH_MODE =
        0x0100000000000000000000000000000000000000000000000000000000000000;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    function run() external {
        uint256 broadcasterPk = vm.envUint("PRIVATE_KEY"); // operator (delegated) key
        uint256 userPk = vm.envUint("USER_PRIVATE_KEY"); // payer key (signs the EIP-3009 auth)

        address user = vm.addr(userPk);
        address userEnv = vm.envOr("USER_ADDRESS", address(0));
        require(userEnv == address(0) || userEnv == user, "USER_ADDRESS != addr(USER_PRIVATE_KEY)");

        // executor == the EIP-3009 `to` == the delegated broadcaster account.
        // Defaults to the broadcaster's own address (NOT the Calibur implementation).
        address executor = vm.envOr("CALIBUR_EXECUTOR", vm.addr(broadcasterPk));

        CaliburDepositBatch.FlowParams memory p;
        p.usdc = vm.envAddress("USDC_SEPOLIA");
        p.depository = vm.envAddress("LAYERSWAP_DEPOSITORY");
        p.executor = executor;
        p.user = user;
        p.amount = vm.envUint("AMOUNT_IN");
        p.receiver = vm.envAddress("DEPOSIT_RECEIVER");

        // --- dynamic values ---
        p.validAfter = 0;
        p.validBefore = block.timestamp + 10 minutes;
        p.nonce = bytes32(vm.randomUint());
        p.depositId = vm.envOr("DEPOSIT_ID", bytes32(vm.randomUint()));

        // --- sign EIP-3009 ReceiveWithAuthorization (to = executor) at runtime ---
        (p.v, p.r, p.s) = _sign(userPk, p);

        _validate(p);
        _preflight(p);

        // Skip the approve call if the executor already has enough standing allowance.
        uint256 standing = IERC3009USDC(p.usdc).allowance(p.executor, p.depository);
        bytes memory executionData;
        if (standing >= p.amount) {
            executionData = CaliburDepositBatch.encodePreApproved(p);
            console2.log("standing allowance present -> 2-call batch (approve skipped)");
        } else {
            executionData = CaliburDepositBatch.encode(p);
            console2.log("no standing allowance -> 3-call batch (includes approve)");
        }

        vm.startBroadcast(broadcasterPk);
        IERC7821(p.executor).execute(ERC7821_BATCH_MODE, executionData);
        vm.stopBroadcast();

        _logSummary(p);
    }

    function _sign(uint256 userPk, CaliburDepositBatch.FlowParams memory p)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 domainSeparator = IERC3009USDC(p.usdc).DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                p.user,
                p.executor,
                p.amount,
                p.validAfter,
                p.validBefore,
                p.nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
        (v, r, s) = vm.sign(userPk, digest);
    }

    function _validate(CaliburDepositBatch.FlowParams memory p) internal pure {
        require(p.usdc != address(0), "USDC_SEPOLIA is zero");
        require(p.depository != address(0), "LAYERSWAP_DEPOSITORY is zero");
        require(p.executor != address(0), "executor is zero");
        require(p.user != address(0), "USER is zero");
        require(p.receiver != address(0), "DEPOSIT_RECEIVER is zero");
        require(p.user != p.executor, "payer (user) must differ from executor");
        require(p.amount > 0, "AMOUNT_IN must be > 0");
    }

    function _preflight(CaliburDepositBatch.FlowParams memory p) internal view {
        ILayerswapDepository dep = ILayerswapDepository(p.depository);
        if (dep.paused()) {
            console2.log("WARNING: LayerswapDepository is paused; deposit will revert.");
        }
        if (!dep.isWhitelisted(p.receiver)) {
            console2.log("WARNING: DEPOSIT_RECEIVER is NOT whitelisted; deposit reverts (NotWhitelisted).");
            console2.log("Receiver:", p.receiver);
        }
    }

    function _logSummary(CaliburDepositBatch.FlowParams memory p) internal view {
        console2.log("--------------------------------------------------");
        console2.log("Calibur batch submitted");
        console2.log("user (EIP-3009 from):", p.user);
        console2.log("executor (EIP-3009 to == broadcaster):", p.executor);
        console2.log("USDC:", p.usdc);
        console2.log("amount (deposited token == USDC):", p.amount);
        console2.log("depository:", p.depository);
        console2.log("deposit receiver:", p.receiver);
        console2.log("validBefore (now + 10m):", p.validBefore);
        console2.log("nonce (random):");
        console2.logBytes32(p.nonce);
        console2.log("deposit id (random):");
        console2.logBytes32(p.depositId);
        console2.log("(tx hash is printed by forge below after broadcast)");
        console2.log("--------------------------------------------------");
    }
}
