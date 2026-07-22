// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IQuoterV2
/// @notice Minimal surface of Uniswap's QuoterV2 (Sepolia:
///         0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3). Used OFF-CHAIN (in the
///         script, before broadcast) to price each swap leg so we can derive
///         `amountOutMinimum` slippage floors. Not called on-chain in the batch.
/// @dev `quoteExactInputSingle` is state-mutating in signature (it simulates the
///      swap and reverts internally to measure it), but it is invoked as a plain
///      `eth_call` from the script, so it just returns the quote.
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}
