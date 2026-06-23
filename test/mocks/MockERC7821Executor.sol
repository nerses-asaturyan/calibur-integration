// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC7821, Call} from "../../src/interfaces/IERC7821.sol";

/// @notice Minimal ERC-7821 batch executor that stands in for the Calibur
///         account in tests: it runs the deposit batch so each inner call
///         executes with `msg.sender == address(this)` (the "Calibur account").
contract MockERC7821Executor is IERC7821 {
    bytes32 internal constant BATCH_MODE = 0x0100000000000000000000000000000000000000000000000000000000000000;

    error UnsupportedMode();

    function supportsExecutionMode(bytes32 mode) external pure returns (bool) {
        return mode == BATCH_MODE;
    }

    function execute(bytes32 mode, bytes calldata executionData) external payable {
        if (mode != BATCH_MODE) revert UnsupportedMode();
        Call[] memory calls = abi.decode(executionData, (Call[]));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) {
                // Bubble the original revert reason — never swallow it.
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}
