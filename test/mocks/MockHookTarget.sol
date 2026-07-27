// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IPayoutSplitter, Leg} from "../../src/interfaces/IPayoutSplitter.sol";

/// @notice Records exactly what a PayoutSplitter hook leg calls it with, so tests
///         can assert byte-exact amount substitution, msg.value, and allowances.
contract MockHookTarget {
    bytes public lastCalldata;
    uint256 public lastValue;

    /// @dev ERC-20 hook target: pulls `amount` from the caller (the splitter must
    ///      have approved exactly this much). The `tag` arg mirrors a depositId-style
    ///      parameter, putting the amount word at offset 4 + 2*32 = 68.
    function pull(address token, bytes32, uint256 amount) external {
        lastCalldata = msg.data;
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "pull failed");
    }

    /// @dev ERC-20 hook target that IGNORES its allowance — used to prove the
    ///      splitter's terminal DustLeft check fires when a hook doesn't consume.
    function ignore(address, bytes32, uint256) external {
        lastCalldata = msg.data;
    }

    /// @dev Native hook target: requires msg.value == amount (proves substitution
    ///      and value agree). Amount word at offset 4 + 32 = 36.
    function sink(bytes32, uint256 amount) external payable {
        lastCalldata = msg.data;
        lastValue = msg.value;
        require(msg.value == amount, "value != amount");
    }
}

/// @notice Rejects everything — for native-transfer-failure and bubbling tests.
contract RevertingTarget {
    error Nope(uint256 code);

    receive() external payable {
        revert Nope(1);
    }

    function fail(uint256) external payable {
        revert Nope(2);
    }
}

/// @notice A hook target whose receive() re-enters split() to siphon the balance
///         mid-loop; the outer split must then revert with DustLeft.
contract ReentrantTarget {
    IPayoutSplitter internal immutable splitter;

    constructor(address _splitter) {
        splitter = IPayoutSplitter(_splitter);
    }

    receive() external payable {
        // Try to re-enter and route the splitter's REMAINING native balance to us.
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({target: address(this), shareBps: 10_000, amountOffset: type(uint256).max, data: ""});
        // Swallow failure: re-entering with zero remaining balance reverts, which
        // is fine — the attack only "succeeds" when balance remains.
        try splitter.split{value: 0}(address(0), legs) {} catch {}
    }
}
