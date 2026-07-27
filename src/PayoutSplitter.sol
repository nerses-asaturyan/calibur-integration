// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPayoutSplitter, Leg} from "./interfaces/IPayoutSplitter.sol";

/// @title PayoutSplitter
/// @notice Stateless, permissionless N-way percentage splitter with generic call
///         hooks. Splits the contract's OWN current balance of one token — ERC-20
///         or native ETH (`token == address(0)`) — across N legs by bps shares.
///
///         ZERO DUST BY CONSTRUCTION: the last leg receives
///         `total − (sum of the previous legs' floor-divided amounts)` rather than
///         its own bps computation, so rounding remainders cannot strand. A
///         terminal zero-balance check (`DustLeft`) additionally guarantees that
///         hook legs actually consumed their amounts.
///
///         GENERIC CALL HOOK: a leg with non-empty `data` calls `target` with that
///         calldata after writing the run-time amount into it at `amountOffset`
///         (the 0x/1inch amount-substitution pattern). This lets a split leg feed
///         contracts that take an exact-amount parameter — e.g. the original
///         LayerswapDepository's `depositERC20(id, token, receiver, AMOUNT)`
///         (amount word at offset 4 + 3*32 = 100) — with a fully dynamic amount.
///         Hooks that carry the amount only as `msg.value` (e.g. `depositNative`)
///         set `amountOffset = NO_SUBSTITUTION`.
///
/// @dev TRUST MODEL — identical to Uniswap's Universal Router:
///      * No owner, no pause, no storage. Anyone may call `split`.
///      * The contract must NEVER hold funds across transactions — anyone could
///        split them to arbitrary legs. Fund it and split within ONE atomic
///        transaction (e.g. an ERC-7821 batch); it enters and exits every tx empty.
///      * Legs are entirely caller-chosen: a malicious hook target can only
///        redirect the funds the caller itself routed into this transaction.
///        No ReentrancyGuard is needed: there is no state to corrupt, and a
///        re-entrant `split` that siphons balance makes the outer call revert
///        with `DustLeft`.
///      * Fee-on-transfer / rebasing tokens are OUT OF SCOPE: exact-amount legs
///        and the terminal zero-balance check assume clean transfer semantics
///        (USDC, WETH, UNI are clean).
contract PayoutSplitter is IPayoutSplitter {
    using SafeERC20 for IERC20;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant _NO_SUBSTITUTION = type(uint256).max;

    /// @inheritdoc IPayoutSplitter
    function NO_SUBSTITUTION() external pure returns (uint256) {
        return _NO_SUBSTITUTION;
    }

    /// @notice Accept native ETH (router SWEEP / UNWRAP_WETH pay via bare call).
    receive() external payable {}

    /// @inheritdoc IPayoutSplitter
    function split(address token, Leg[] calldata legs) external payable {
        uint256 n = legs.length;
        if (n == 0) revert NoLegs();

        // --- validate all legs up front (cheap, and no partial effects) ---
        uint256 sumBps;
        for (uint256 i; i < n; ++i) {
            Leg calldata leg = legs[i];
            if (leg.target == address(0)) revert ZeroTarget(i);
            sumBps += leg.shareBps;
            if (leg.data.length != 0 && leg.amountOffset != _NO_SUBSTITUTION) {
                // The amount word must lie fully inside `data`, past the selector.
                if (leg.amountOffset < 4 || leg.amountOffset + 32 > leg.data.length) {
                    revert InvalidAmountOffset(i);
                }
            }
        }
        if (sumBps != BPS_DENOMINATOR) revert SharesMustSumTo10000(sumBps);

        // --- total = our whole current balance (msg.value already included) ---
        uint256 total = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (total == 0) revert ZeroTotalBalance();

        // --- distribute; last leg takes the remainder (zero dust) ---
        uint256 distributed;
        for (uint256 i; i < n; ++i) {
            Leg calldata leg = legs[i];
            uint256 amount = (i == n - 1) ? total - distributed : (total * leg.shareBps) / BPS_DENOMINATOR;
            if (amount == 0) revert ZeroLegAmount(i);
            distributed += amount;

            bool isHook = leg.data.length != 0;
            if (isHook) {
                _callHook(token, leg, amount);
            } else if (token == address(0)) {
                (bool ok,) = leg.target.call{value: amount}("");
                if (!ok) revert NativeTransferFailed(i);
            } else {
                IERC20(token).safeTransfer(leg.target, amount);
            }
            emit LegPaid(i, leg.target, token, amount, isHook);
        }

        // --- terminal invariant: we exit the call empty ---
        uint256 remaining = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (remaining != 0) revert DustLeft(remaining);

        emit Split(token, msg.sender, total, n);
    }

    /// @dev Executes a hook leg: patches the run-time amount into the calldata
    ///      template (unless NO_SUBSTITUTION), grants an exact allowance for
    ///      ERC-20 legs (reset to zero afterwards), sends `amount` as msg.value
    ///      for native legs, and bubbles the target's revert reason verbatim.
    function _callHook(address token, Leg calldata leg, uint256 amount) internal {
        bytes memory payload = leg.data; // fresh memory copy of the template
        uint256 offset = leg.amountOffset;
        if (offset != _NO_SUBSTITUTION) {
            // Bounds pre-validated in split(): 4 <= offset && offset + 32 <= payload.length,
            // so the mstore lands entirely inside the freshly allocated array.
            assembly ("memory-safe") {
                mstore(add(add(payload, 0x20), offset), amount)
            }
        }

        bool ok;
        bytes memory ret;
        if (token == address(0)) {
            (ok, ret) = leg.target.call{value: amount}(payload);
        } else {
            IERC20(token).forceApprove(leg.target, amount);
            (ok, ret) = leg.target.call(payload);
            IERC20(token).forceApprove(leg.target, 0);
        }
        if (!ok) {
            // Bubble the original revert reason — never swallow it.
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
