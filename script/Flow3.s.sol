// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {FlowBase, Call, IERC20, IPermit2, console2} from "./FlowBase.s.sol";

/// @title Flow3 — user → uniswap → [value to USER + fee → EOA]
///        (swap FIRST: the fee is a LIVE-EXACT bips share of the ACTUAL output
///        via PAY_PORTION; SWEEP sends every remaining wei to the user)
///
///   FUNDING_MODE=gasless     relayer Calibur batch; user signs EIP-3009 only
///   FUNDING_MODE=user-erc20  ONE user tx, ROUTER-ONLY (PERMIT2_PERMIT) —
///                            public-mempool-safe
///   FUNDING_MODE=user-eth    ONE user tx, ROUTER-ONLY
///
/// No depository leg -> no Multicall3 anywhere in this flow.
///
/// Usage:
///   FUNDING_MODE=user-eth forge script script/Flow3.s.sol:Flow3Script \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract Flow3Script is FlowBase {
    function run() external {
        (Cfg memory c, uint256 broadcasterPk, uint256 userPk) = _loadCfg();
        _logHeader(c, "Flow 3: swap all -> live-exact split: user + fee EOA");
        _preflight(c, false);

        if (_is(c.mode, MODE_GASLESS)) {
            _gasless(c, broadcasterPk, userPk);
        } else if (_is(c.mode, MODE_USER_ERC20)) {
            _userErc20(c, userPk);
        } else {
            _userEth(c, userPk);
        }
        _logDone(c);
    }

    /// @dev PAY_PORTION takes feeBps of the router's LIVE output balance (exact
    ///      2-way split of the actual amount); SWEEP pays the user everything
    ///      left, min-guarded by the quoted floor net of the fee share.
    function _tailInputs(Cfg memory c, address out, address userRecipient, uint256 minOut)
        internal
        pure
        returns (bytes memory feeInput, bytes memory sweepInput)
    {
        feeInput = abi.encode(out, c.feeRecipient, c.feeBps);
        sweepInput = abi.encode(out, userRecipient, minOut * (10_000 - c.feeBps) / 10_000);
    }

    function _gasless(Cfg memory c, uint256 relayerPk, uint256 userPk) internal {
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, c.amountIn));
        console2.log("  swap exact-in:", c.amountIn, " minOut:", minOut);

        bytes memory commands = abi.encodePacked(V3_SWAP_EXACT_IN, PAY_PORTION, SWEEP);
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = _swapInput(ADDRESS_THIS, CONTRACT_BALANCE, minOut, _path(c, c.usdc, c.weth), false);
        (inputs[1], inputs[2]) = _tailInputs(c, c.weth, c.user, minOut);

        Call[] memory calls = new Call[](3);
        calls[0] = _pull3009(c, userPk, c.amountIn);
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, c.amountIn))});
        calls[2] = Call({to: c.router, value: 0, data: _routerCall(commands, inputs)});

        _submitCalibur(c, relayerPk, calls);
    }

    function _userErc20(Cfg memory c, uint256 userPk) internal {
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, c.amountIn));
        (IPermit2.PermitSingle memory single, bytes memory sig) =
            _signPermit2Single(c, userPk, c.usdc, uint160(c.amountIn), block.timestamp + 10 minutes);
        console2.log("  swap exact-in:", c.amountIn, " minOut:", minOut);

        bytes memory commands = abi.encodePacked(PERMIT2_PERMIT, V3_SWAP_EXACT_IN, PAY_PORTION, SWEEP);
        bytes[] memory inputs = new bytes[](4);
        inputs[0] = _permit2PermitInput(single, sig);
        inputs[1] = _swapInput(ADDRESS_THIS, c.amountIn, minOut, _path(c, c.usdc, c.weth), true); // pull from user
        (inputs[2], inputs[3]) = _tailInputs(c, c.weth, MSG_SENDER, minOut);

        _submitRouter(c, userPk, commands, inputs, 0);
    }

    function _userEth(Cfg memory c, uint256 userPk) internal {
        uint256 minOut = _floor(c, _quote(c, c.weth, c.usdc, c.amountEth));
        console2.log("  wrap + swap exact-in (wei):", c.amountEth, " minOut:", minOut);

        bytes memory commands = abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN, PAY_PORTION, SWEEP);
        bytes[] memory inputs = new bytes[](4);
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE);
        inputs[1] = _swapInput(ADDRESS_THIS, CONTRACT_BALANCE, minOut, _path(c, c.weth, c.usdc), false);
        (inputs[2], inputs[3]) = _tailInputs(c, c.usdc, MSG_SENDER, minOut);

        _submitRouter(c, userPk, commands, inputs, c.amountEth);
    }
}
