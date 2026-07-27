// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {FlowBase, Call, IERC20, IPermit2, console2} from "./FlowBase.s.sol";

/// @title Flow2 — user → [fee → EOA + rest → uniswap → value to USER]
///        (split FIRST: fee = exact bips of the KNOWN input; swap output goes
///        back to the user, dynamic is fine — the user is an EOA)
///
///   FUNDING_MODE=gasless     relayer Calibur batch; user signs EIP-3009 only
///   FUNDING_MODE=user-erc20  ONE user tx, ROUTER-ONLY (PERMIT2_PERMIT):
///                            public-mempool-SAFE — the permit is bound to the
///                            router's msg.sender. Needs the one-time
///                            USDC.approve(Permit2) setup tx.
///   FUNDING_MODE=user-eth    ONE user tx, ROUTER-ONLY (fee paid from msg.value)
///
/// No depository leg -> no Multicall3 anywhere in this flow.
///
/// Usage:
///   FUNDING_MODE=user-erc20 forge script script/Flow2.s.sol:Flow2Script \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract Flow2Script is FlowBase {
    function run() external {
        (Cfg memory c, uint256 broadcasterPk, uint256 userPk) = _loadCfg();
        _logHeader(c, "Flow 2: fee (exact bips of input) -> EOA; rest -> swap -> user");
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

    /// @dev Calibur batch: pull X -> exact fee to EOA -> rest to router -> swap
    ///      paid straight to the user.
    function _gasless(Cfg memory c, uint256 relayerPk, uint256 userPk) internal {
        uint256 fee = c.amountIn * c.feeBps / 10_000;
        uint256 rest = c.amountIn - fee;
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, rest));
        console2.log("  fee (exact):", fee, " swapped:", rest);
        console2.log("  minOut (WETH to user):", minOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _swapInput(c.user, CONTRACT_BALANCE, minOut, _path(c, c.usdc, c.weth), false);

        Call[] memory calls = new Call[](4);
        calls[0] = _pull3009(c, userPk, c.amountIn);
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.feeRecipient, fee))});
        calls[2] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, rest))});
        calls[3] = Call({to: c.router, value: 0, data: _routerCall(abi.encodePacked(V3_SWAP_EXACT_IN), inputs)});

        _submitCalibur(c, relayerPk, calls);
    }

    /// @dev ONE user tx, router only: PERMIT2_PERMIT (in-router signature) ->
    ///      PERMIT2_TRANSFER_FROM exact fee -> exact-in swap of the rest, paid
    ///      straight to msg.sender (the user). Mempool-safe.
    function _userErc20(Cfg memory c, uint256 userPk) internal {
        uint256 fee = c.amountIn * c.feeBps / 10_000;
        uint256 rest = c.amountIn - fee;
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, rest));
        (IPermit2.PermitSingle memory single, bytes memory sig) =
            _signPermit2Single(c, userPk, c.usdc, uint160(c.amountIn), block.timestamp + 10 minutes);
        console2.log("  fee (exact):", fee, " swapped:", rest);
        console2.log("  minOut (WETH to user):", minOut);

        bytes memory commands = abi.encodePacked(PERMIT2_PERMIT, PERMIT2_TRANSFER_FROM, V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = _permit2PermitInput(single, sig);
        inputs[1] = abi.encode(c.usdc, c.feeRecipient, uint160(fee)); // pull fee user -> fee EOA
        inputs[2] = _swapInput(MSG_SENDER, rest, minOut, _path(c, c.usdc, c.weth), true); // pull rest from user, output to user

        _submitRouter(c, userPk, commands, inputs, 0);
    }

    /// @dev ONE user tx, router only: exact ETH fee from msg.value -> wrap the
    ///      rest -> swap paid straight to msg.sender.
    function _userEth(Cfg memory c, uint256 userPk) internal {
        uint256 fee = c.amountEth * c.feeBps / 10_000;
        uint256 rest = c.amountEth - fee;
        uint256 minOut = _floor(c, _quote(c, c.weth, c.usdc, rest));
        console2.log("  fee (exact wei):", fee, " swapped (wei):", rest);
        console2.log("  minOut (USDC to user):", minOut);

        bytes memory commands = abi.encodePacked(TRANSFER, WRAP_ETH, V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(NATIVE, c.feeRecipient, fee); // exact native fee from the router's msg.value
        inputs[1] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE); // wrap everything left
        inputs[2] = _swapInput(MSG_SENDER, CONTRACT_BALANCE, minOut, _path(c, c.weth, c.usdc), false);

        _submitRouter(c, userPk, commands, inputs, c.amountEth);
    }
}
