// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Call} from "./interfaces/IERC7821.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC3009USDC} from "./interfaces/IERC3009USDC.sol";
import {ILayerswapDepository} from "./interfaces/ILayerswapDepository.sol";

/// @title CaliburDepositBatch
/// @notice Pure helper that builds the ERC-7821 `Call[]` batch for the atomic
///         "EIP-3009 receive → Layerswap deposit" flow, executed by Calibur.
///
/// @dev Library of `internal` functions only — inlined into callers, NOT a
///      deployed contract, so the integration adds no new on-chain contract.
///
/// TERMINOLOGY: `executor` is the account that runs the batch — your
/// broadcaster/operator EOA that you delegated to the Calibur *implementation*
/// via EIP-7702. After delegation it runs Calibur code at its own address, so it
/// is BOTH the batch executor AND the EIP-3009 `to`. It is NOT the Calibur
/// implementation address (`0x0000…8f00`); that is only the delegation target.
///
/// Every call runs with `msg.sender == executor`:
///   1. USDC.receiveWithAuthorization(user, executor, amount, ...)  // user -> executor
///   2. USDC.approve(depository, amount)                            // executor allows depository
///   3. depository.depositERC20(id, USDC, receiver, amount)         // executor -> receiver
///
/// Step 2 exists because `depositERC20` pulls via `transferFrom(executor, ...)`.
/// If the executor has already granted the depository a standing allowance (it
/// custodies no idle USDC, so a one-time max approval is safe), use the 2-call
/// `buildPreApproved` variant and skip step 2 — see CaliburDeposit.s.sol, which
/// picks automatically based on the live allowance.
///
/// Atomicity: Calibur runs the calls in one transaction. If the deposit reverts,
/// the receive is rolled back — the user's USDC is NOT moved and the EIP-3009
/// nonce is NOT consumed.
library CaliburDepositBatch {
    /// @param usdc        EIP-3009 USDC token.
    /// @param depository  LayerswapDepository.
    /// @param executor    Account that executes the batch; also the EIP-3009 `to`
    ///                     (your broadcaster EOA delegated to Calibur). USDC's
    ///                     `receiveWithAuthorization` requires `msg.sender == to`.
    /// @param user        EIP-3009 `from` (the payer who signed the authorization).
    /// @param amount      USDC amount pulled and deposited (token's smallest unit).
    /// @param validAfter  EIP-3009 not-valid-before timestamp.
    /// @param validBefore EIP-3009 expiry timestamp (acts as the flow deadline).
    /// @param nonce       Random unique EIP-3009 nonce.
    /// @param v,r,s       EIP-3009 signature by `user`.
    /// @param receiver    Whitelisted Layerswap receiver (final destination).
    /// @param depositId   Off-chain order correlation id.
    struct FlowParams {
        address usdc;
        address depository;
        address executor;
        address user;
        uint256 amount;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
        address receiver;
        bytes32 depositId;
    }

    /// @notice Build the 3-call batch (self-contained: receive → approve → deposit).
    function build(FlowParams memory p) internal pure returns (Call[] memory calls) {
        calls = new Call[](3);
        calls[0] = _receiveCall(p);
        calls[1] = Call({to: p.usdc, value: 0, data: abi.encodeCall(IERC20.approve, (p.depository, p.amount))});
        calls[2] = _depositCall(p);
    }

    /// @notice Build the 2-call batch (receive → deposit), skipping the approve.
    ///         Requires the executor to already hold a standing allowance to the
    ///         depository (e.g. a one-time max approval). Cheaper per deposit.
    function buildPreApproved(FlowParams memory p) internal pure returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = _receiveCall(p);
        calls[1] = _depositCall(p);
    }

    /// @notice ABI-encode the 3-call batch into Calibur's `execute` executionData.
    function encode(FlowParams memory p) internal pure returns (bytes memory) {
        return abi.encode(build(p));
    }

    /// @notice ABI-encode the 2-call (pre-approved) batch.
    function encodePreApproved(FlowParams memory p) internal pure returns (bytes memory) {
        return abi.encode(buildPreApproved(p));
    }

    function _receiveCall(FlowParams memory p) private pure returns (Call memory) {
        return Call({
            to: p.usdc,
            value: 0,
            data: abi.encodeCall(
                IERC3009USDC.receiveWithAuthorization,
                (p.user, p.executor, p.amount, p.validAfter, p.validBefore, p.nonce, p.v, p.r, p.s)
            )
        });
    }

    function _depositCall(FlowParams memory p) private pure returns (Call memory) {
        return Call({
            to: p.depository,
            value: 0,
            data: abi.encodeCall(ILayerswapDepository.depositERC20, (p.depositId, p.usdc, p.receiver, p.amount))
        });
    }
}
