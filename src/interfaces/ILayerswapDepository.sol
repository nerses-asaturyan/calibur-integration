// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title ILayerswapDepository
/// @notice Surface of the deployed Sepolia LayerswapDepository
///         (0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4).
/// @dev    IMPORTANT: `depositERC20` reverts `NotWhitelisted()` unless the
///         `receiver` (not the caller) is whitelisted, and pulls tokens with
///         `safeTransferFrom(msg.sender, receiver, amount)`. So the caller (the
///         Calibur account) must hold `amount` and approve this contract first,
///         and the `receiver` must be on the owner-managed whitelist.
interface ILayerswapDepository {
    event Deposited(bytes32 indexed id, address indexed token, address indexed receiver, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NotWhitelisted();

    /// @notice Forward `amount` of `token` from the caller to a whitelisted `receiver`.
    function depositERC20(bytes32 id, address token, address receiver, uint256 amount) external;

    /// @notice Forward the caller's WHOLE `token` balance to a whitelisted `receiver`
    ///         (balance read at run time — the dynamic-amount, zero-dust variant).
    /// @dev    Only on our own deployment of the depository, not the original
    ///         0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4.
    function depositERC20All(bytes32 id, address token, address receiver) external;

    /// @notice Forward msg.value of native token to a whitelisted `receiver`.
    function depositNative(bytes32 id, address receiver) external payable;

    function isWhitelisted(address addr) external view returns (bool);
    function getWhitelistedAddresses() external view returns (address[] memory);
    function paused() external view returns (bool);
    function owner() external view returns (address);

    // Owner-only whitelist management (used by fork tests via prank).
    function addToWhitelist(address addr) external;
    function removeFromWhitelist(address addr) external;
}
