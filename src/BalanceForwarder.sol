// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BalanceForwarder
/// @notice The minimal periphery that bridges "dynamic swap output" to
///         "exact-amount contract call" — so the ORIGINAL LayerswapDepository
///         (plain `depositERC20(id, token, receiver, amount)`, no whole-balance
///         variant) can receive a fully dynamic amount.
///
///         `executeWithBalance` reads THIS contract's live balance of `token`,
///         patches it into the caller-supplied calldata template at
///         `amountOffset` (the 0x/1inch amount-substitution pattern), grants
///         `target` an exact allowance, and makes the call. A terminal
///         zero-balance check guarantees the target consumed everything.
///
/// @dev TRUST MODEL — identical to the Universal Router / Multicall3:
///      * Stateless, no owner, permissionless. Anyone may call it with ANY
///        target and calldata — which is precisely why it must NEVER hold
///        funds across transactions: fund it and consume within ONE atomic tx
///        (an ERC-7821 batch or a Multicall3 aggregate). Anything parked here
///        between transactions is free for the taking.
///      * A malicious (token, target, data) triple can only redirect funds the
///        caller itself routed here in this same transaction.
///      * Fee-on-transfer / rebasing tokens are out of scope (the terminal
///        check assumes clean transfer semantics).
contract BalanceForwarder {
    using SafeERC20 for IERC20;

    error InvalidAmountOffset(); // offset < 4 or offset + 32 > data.length
    error NothingToForward();
    error BalanceNotConsumed(uint256 remaining);

    /// @notice Calls `target` with `data`, after writing this contract's whole
    ///         live `token` balance into `data` at byte `amountOffset` and
    ///         approving `target` for exactly that amount.
    /// @param token        the ERC-20 whose full balance is forwarded
    /// @param target       the contract to call (e.g. the original depository)
    /// @param amountOffset byte offset of the uint256 amount word inside `data`
    ///                     (e.g. depositERC20(bytes32,address,address,uint256)
    ///                     -> 4 + 3*32 = 100)
    /// @param data         calldata template; the word at `amountOffset` is a
    ///                     placeholder and will be overwritten
    function executeWithBalance(address token, address target, uint256 amountOffset, bytes calldata data) external {
        if (amountOffset < 4 || amountOffset + 32 > data.length) revert InvalidAmountOffset();

        uint256 amount = IERC20(token).balanceOf(address(this)); // run-time read
        if (amount == 0) revert NothingToForward();

        bytes memory payload = data; // fresh memory copy of the template
        assembly ("memory-safe") {
            // Bounds validated above: the mstore lands entirely inside payload.
            mstore(add(add(payload, 0x20), amountOffset), amount)
        }

        IERC20(token).forceApprove(target, amount);
        (bool ok, bytes memory ret) = target.call(payload);
        if (!ok) {
            // Bubble the target's revert reason verbatim.
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        IERC20(token).forceApprove(target, 0); // hygiene for targets that pull less than approved

        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (remaining != 0) revert BalanceNotConsumed(remaining); // zero-dust guarantee
    }
}
