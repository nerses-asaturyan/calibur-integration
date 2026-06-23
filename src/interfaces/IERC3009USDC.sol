// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IERC3009USDC
/// @notice EIP-3009 ("transfer with authorization") surface as implemented by
///         Circle's USDC (FiatTokenV2_2) on Ethereum Sepolia
///         (0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238), plus the ERC20 methods
///         the batch needs.
/// @dev    Use `receiveWithAuthorization` (NOT `transferWithAuthorization`) when
///         pulling from a contract: it requires `msg.sender == to`, which both
///         binds the funds to the Calibur account and prevents front-running of
///         the user's signed authorization.
interface IERC3009USDC {
    /// @notice Execute a transfer where the recipient (`to`) submits the tx.
    /// @dev Reverts unless `msg.sender == to`. `nonce` is an arbitrary unique
    ///      bytes32 (random), not a sequential counter.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Cancel an as-yet-unused authorization.
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external;

    /// @notice Returns true once `nonce` has been used or cancelled for `authorizer`.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);

    /// @notice EIP-712 domain separator used for building the authorization digest.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice EIP-712 typehash for `ReceiveWithAuthorization`.
    function RECEIVE_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);

    // --- ERC20 subset used by the batch ---
    function approve(address spender, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}
