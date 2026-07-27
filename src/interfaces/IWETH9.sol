// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IWETH9
/// @notice Canonical WETH9 (Sepolia: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14).
///         Deliberately has NO permit function — which makes it the repo's
///         demo "plain ERC-20" for the Permit2 inbound path.
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address guy, uint256 wad) external returns (bool);
    function transfer(address dst, uint256 wad) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}
