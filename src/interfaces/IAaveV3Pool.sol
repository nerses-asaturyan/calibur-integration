// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IAaveV3Pool
/// @notice Minimal surface of the Aave v3 Pool used by the flow scripts
///         (Sepolia: 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951).
/// @dev    `supply` pulls `amount` of `asset` from msg.sender (requires approval)
///         and mints aTokens to `onBehalfOf`. `withdraw` burns msg.sender's
///         aTokens and sends the underlying to `to`; `type(uint256).max`
///         withdraws the caller's entire aToken balance — the one dynamic-amount
///         primitive Aave gives us. Supplying and withdrawing within the same
///         transaction round-trips the exact amount (no time passes, so no
///         interest accrues).
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @return amountWithdrawn the underlying amount actually sent to `to`
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function getReservesList() external view returns (address[] memory);
}
