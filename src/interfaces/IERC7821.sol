// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice A single call in an ERC-7821 batch.
struct Call {
    address to;
    uint256 value;
    bytes data;
}

/// @title IERC7821
/// @notice Minimal ERC-7821 "batch executor" surface implemented by Uniswap's
///         Calibur smart account. Used to submit this integration's batch.
/// @dev    The single-batch execution mode (no `opData`) is
///         `0x0100000000000000000000000000000000000000000000000000000000000000`
///         and `executionData = abi.encode(Call[] calls)`. When Calibur runs the
///         batch, each `call.to` is invoked with `msg.sender == <Calibur account>`.
///         This integration's batch is three calls: USDC.receiveWithAuthorization,
///         USDC.approve, then LayerswapDepository.depositERC20.
interface IERC7821 {
    /// @notice Execute a batch encoded in `executionData` under execution `mode`.
    function execute(bytes32 mode, bytes calldata executionData) external payable;

    /// @notice Whether `mode` is supported by this executor.
    function supportsExecutionMode(bytes32 mode) external view returns (bool result);
}
