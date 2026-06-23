// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC3009USDC} from "../src/interfaces/IERC3009USDC.sol";

/// @title SignReceiveAuthorization
/// @notice OPTIONAL off-chain helper that produces a valid EIP-3009
///         `ReceiveWithAuthorization` signature. The main `CaliburDeposit` script
///         now signs at runtime, so this is only needed when the payer signs
///         out-of-band (e.g. in a real wallet) instead of via USER_PRIVATE_KEY.
///         It reads the live USDC `DOMAIN_SEPARATOR()` so you never have to guess
///         the EIP-712 domain, and prints AUTH_V/R/S/NONCE/VALID_BEFORE. It does
///         NOT broadcast anything.
///
/// Run (note: no --broadcast):
///   USER_PRIVATE_KEY=0x... \
///   forge script script/SignReceiveAuthorization.s.sol:SignReceiveAuthorization \
///     --rpc-url $SEPOLIA_RPC_URL -vvv
///
/// Required env: USER_PRIVATE_KEY, USDC_SEPOLIA, AMOUNT_IN, and the executor —
///               either CALIBUR_EXECUTOR, or OPERATOR_PRIVATE_KEY to derive it.
/// Optional env: VALID_AFTER (default 0), VALID_BEFORE (default now+10m),
///               AUTH_NONCE (default derived & printed).
contract SignReceiveAuthorization is Script {
    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    function run() external view {
        uint256 userPk = vm.envUint("USER_PRIVATE_KEY");
        address from = vm.addr(userPk);
        address usdc = vm.envAddress("USDC_SEPOLIA");
        // EIP-3009 `to` == the Calibur executor (the OPERATOR account, not the
        // payer). If CALIBUR_EXECUTOR is unset/empty, derive it from the operator
        // key you already provide. (It must differ from the payer, so it cannot
        // be derived from USER_PRIVATE_KEY.)
        address to = vm.envOr("CALIBUR_EXECUTOR", address(0));
        if (to == address(0)) {
            to = vm.addr(vm.envUint("OPERATOR_PRIVATE_KEY"));
        }
        require(to != from, "executor (to) must differ from payer (from)");
        uint256 value = vm.envUint("AMOUNT_IN");
        uint256 validAfter = vm.envOr("VALID_AFTER", uint256(0));
        uint256 validBefore = vm.envOr("VALID_BEFORE", block.timestamp + 10 minutes);
        bytes32 nonce = vm.envOr("AUTH_NONCE", keccak256(abi.encode(from, to, value, validBefore, block.timestamp)));

        bytes32 domainSeparator = IERC3009USDC(usdc).DOMAIN_SEPARATOR();
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        console2.log("== EIP-3009 ReceiveWithAuthorization signed ==");
        console2.log("USER_ADDRESS  (from):", from);
        console2.log("CALIBUR_EXECUTOR (to):", to);
        console2.log("USDC:", usdc);
        console2.log("AMOUNT_IN:", value);
        console2.log("VALID_AFTER:", validAfter);
        console2.log("VALID_BEFORE:", validBefore);
        console2.log("AUTH_NONCE:");
        console2.logBytes32(nonce);
        console2.log("AUTH_V:", uint256(v));
        console2.log("AUTH_R:");
        console2.logBytes32(r);
        console2.log("AUTH_S:");
        console2.logBytes32(s);
        console2.log("(paste AUTH_V/AUTH_R/AUTH_S/AUTH_NONCE/VALID_BEFORE into .env)");
    }
}
