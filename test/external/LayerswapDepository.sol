// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// Verbatim copy of the deployed Sepolia LayerswapDepository
// (0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4), vendored ONLY so local
// (non-fork) tests can deploy the genuine logic. Source:
// github.com/layerswap/layerswap-depository (evm/src/LayerswapDepository.sol).

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title LayerswapDepository
/// @notice Forwards native and ERC20 tokens to whitelisted Layerswap receiver addresses.
///         Only whitelisted addresses may receive funds. Owner manages the whitelist.
/// @custom:version 1.0.0
contract LayerswapDepository is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _whitelist;

    event AddressWhitelisted(address indexed addr);
    event AddressRemovedFromWhitelist(address indexed addr);
    event AddressUpdatedInWhitelist(address indexed oldAddr, address indexed newAddr);
    /// @dev token is address(0) for native deposits
    event Deposited(bytes32 indexed id, address indexed token, address indexed receiver, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NotWhitelisted();
    error AlreadyWhitelisted();
    error TransferFailed();
    error InvalidReceiver();
    error SameAddress();

    /// @param _owner Initial contract owner
    /// @param _initialAddresses Initial set of whitelisted receiver addresses
    constructor(address _owner, address[] memory _initialAddresses) Ownable(_owner) {
        uint256 len = _initialAddresses.length;
        for (uint256 i; i < len;) {
            _addToWhitelist(_initialAddresses[i]);
            unchecked {
                ++i;
            }
        }
    }

    function depositNative(bytes32 id, address receiver) external payable nonReentrant whenNotPaused {
        if (!_whitelist.contains(receiver)) revert NotWhitelisted();
        if (msg.value == 0) revert ZeroAmount();

        emit Deposited(id, address(0), receiver, msg.value);

        (bool success,) = receiver.call{value: msg.value}("");
        if (!success) revert TransferFailed();
    }

    function depositERC20(bytes32 id, address token, address receiver, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        if (token == address(0)) revert ZeroAddress();
        if (!_whitelist.contains(receiver)) revert NotWhitelisted();
        if (amount == 0) revert ZeroAmount();

        uint256 balBefore = IERC20(token).balanceOf(receiver);
        IERC20(token).safeTransferFrom(msg.sender, receiver, amount);
        uint256 received = IERC20(token).balanceOf(receiver) - balBefore;

        emit Deposited(id, token, receiver, received);
    }

    function addToWhitelist(address addr) external onlyOwner {
        _addToWhitelist(addr);
    }

    function removeFromWhitelist(address addr) external onlyOwner {
        if (!_whitelist.remove(addr)) revert NotWhitelisted();
        emit AddressRemovedFromWhitelist(addr);
    }

    function updateWhitelistedAddress(address oldAddr, address newAddr) external onlyOwner {
        if (oldAddr == newAddr) revert SameAddress();
        if (!_whitelist.remove(oldAddr)) revert NotWhitelisted();
        if (newAddr == address(0)) revert ZeroAddress();
        if (newAddr == address(this)) revert InvalidReceiver();
        if (!_whitelist.add(newAddr)) revert AlreadyWhitelisted();
        emit AddressUpdatedInWhitelist(oldAddr, newAddr);
    }

    function getWhitelistedAddresses() external view returns (address[] memory) {
        return _whitelist.values();
    }

    function isWhitelisted(address addr) external view returns (bool) {
        return _whitelist.contains(addr);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _addToWhitelist(address addr) internal {
        if (addr == address(0)) revert ZeroAddress();
        if (addr == address(this)) revert InvalidReceiver();
        if (!_whitelist.add(addr)) revert AlreadyWhitelisted();
        emit AddressWhitelisted(addr);
    }
}
