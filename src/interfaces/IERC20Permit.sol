// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IERC20Permit
/// @notice EIP-2612 surface (Circle USDC implements this alongside EIP-3009).
///         `permit` is msg.sender-agnostic: anyone may submit a valid signature,
///         which is what lets `SplitForwarder.permitAndRun` set the user's
///         allowance and pull in a single self-submitted call.
interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
