// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IUniversalRouter
/// @notice Minimal surface of Uniswap's Universal Router — an UNOWNED,
///         NON-UPGRADEABLE, already-deployed contract (Sepolia:
///         0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b). We use it to chain
///         swap → swap and route payouts ENTIRELY inside the router, so the whole
///         dynamic DeFi chain needs NO new contract of our own.
///
/// @dev Two router primitives make dynamic chaining possible in an otherwise
///      static, pre-signed Calibur (ERC-7821) batch:
///        - `CONTRACT_BALANCE` (0x8000…0000): an `amountIn` sentinel meaning
///          "use the router's entire current balance of the input token", so each
///          leg consumes exactly what the previous leg produced — no amount is
///          known at sign time.
///        - recipient sentinels `ADDRESS_THIS` (address(2)) / `MSG_SENDER`
///          (address(1)) let one command leave its output in the router for the
///          next command, or send it back to the caller (the Calibur executor).
///
///      Commands are one byte each (see Uniswap `Commands.sol`); `inputs[i]` is the
///      ABI-encoded argument tuple for `commands[i]`. Used here:
///        0x00 V3_SWAP_EXACT_IN (address recipient,uint256 amountIn,uint256 amountOutMin,bytes path,bool payerIsUser)
///        0x0c UNWRAP_WETH      (address recipient,uint256 amountMin)
///        0x0b WRAP_ETH         (address recipient,uint256 amount)
///        0x05 TRANSFER         (address token,address recipient,uint256 value)
///        0x04 SWEEP            (address token,address recipient,uint256 amountMin)
interface IUniversalRouter {
    /// @notice Execute an encoded sequence of router commands atomically.
    /// @param commands One byte per command.
    /// @param inputs   ABI-encoded arguments, one entry per command.
    /// @param deadline Unix timestamp after which the whole execution reverts.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
