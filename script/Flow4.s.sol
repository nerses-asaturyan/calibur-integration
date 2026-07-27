// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {FlowBase, Call, IMulticall3, IERC20, console2} from "./FlowBase.s.sol";

/// @title Flow4 — user → [fee → EOA + rest → uniswap → depository (full output)]
///        (split FIRST: fee = exact bips of the KNOWN input; the ENTIRE dynamic
///        swap output is deposited via depositERC20All — full amount, event,
///        zero dust)
///
///   FUNDING_MODE=gasless     relayer Calibur batch; user signs EIP-3009 only
///   FUNDING_MODE=user-erc20  ONE user tx: Multicall3 + in-batch EIP-2612 permit
///                            (mainnet: MEV-protected submission REQUIRED)
///   FUNDING_MODE=user-eth    ONE user tx: Multicall3 value-legs
///
/// Usage:
///   FUNDING_MODE=user-eth forge script script/Flow4.s.sol:Flow4Script \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract Flow4Script is FlowBase {
    function run() external {
        (Cfg memory c, uint256 broadcasterPk, uint256 userPk) = _loadCfg();
        _logHeader(c, "Flow 4: fee (exact bips of input) -> EOA; rest -> swap -> depositERC20All");
        _preflight(c, true);

        if (_is(c.mode, MODE_GASLESS)) {
            _gasless(c, broadcasterPk, userPk);
        } else if (_is(c.mode, MODE_USER_ERC20)) {
            _userErc20(c, userPk);
        } else {
            _userEth(c, userPk);
        }
        _logDone(c);
    }

    function _gasless(Cfg memory c, uint256 relayerPk, uint256 userPk) internal {
        uint256 fee = c.amountIn * c.feeBps / 10_000;
        uint256 rest = c.amountIn - fee;
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, rest));
        console2.log("  fee (exact):", fee, " swapped:", rest);
        console2.log("  minOut (WETH -> depository):", minOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _swapInput(c.executor, CONTRACT_BALANCE, minOut, _path(c, c.usdc, c.weth), false);

        Call[] memory tail = _depositAllTailCalls(c, c.weth);
        Call[] memory calls = new Call[](7);
        calls[0] = _pull3009(c, userPk, c.amountIn);
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.feeRecipient, fee))});
        calls[2] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, rest))});
        calls[3] = Call({to: c.router, value: 0, data: _routerCall(abi.encodePacked(V3_SWAP_EXACT_IN), inputs)});
        (calls[4], calls[5], calls[6]) = (tail[0], tail[1], tail[2]);

        _submitCalibur(c, relayerPk, calls);
    }

    /// @dev ONE user tx: Multicall3 [2612 permit (allowFailure=true) -> exact fee
    ///      transferFrom(user->feeEOA) -> transferFrom(user->router) -> swap
    ///      (paid to Multicall3) -> depositERC20All tail].
    ///      Mainnet: private submission required.
    function _userErc20(Cfg memory c, uint256 userPk) internal {
        uint256 fee = c.amountIn * c.feeBps / 10_000;
        uint256 rest = c.amountIn - fee;
        console2.log("  fee (exact):", fee, " swapped:", rest);

        IMulticall3.Call3Value[] memory tail = _depositAllTailMc3(c, c.weth);
        IMulticall3.Call3Value[] memory calls = new IMulticall3.Call3Value[](7);
        calls[0] = _permitLegMc3(c, userPk, c.amountIn);
        calls[1] = _transferFromLegMc3(c, c.feeRecipient, fee);
        calls[2] = _transferFromLegMc3(c, c.router, rest);
        calls[3] = _swapToMc3LegErc20(c, rest);
        (calls[4], calls[5], calls[6]) = (tail[0], tail[1], tail[2]);

        _submitMc3(c, userPk, calls, 0);
    }

    /// @dev ONE user tx: Multicall3 [exact native fee value-leg -> router value-leg
    ///      (wrap + swap, paid to Multicall3) -> depositERC20All tail].
    function _userEth(Cfg memory c, uint256 userPk) internal {
        uint256 fee = c.amountEth * c.feeBps / 10_000;
        uint256 rest = c.amountEth - fee;
        console2.log("  fee (exact wei):", fee, " swapped (wei):", rest);

        IMulticall3.Call3Value[] memory tail = _depositAllTailMc3(c, c.usdc);
        IMulticall3.Call3Value[] memory calls = new IMulticall3.Call3Value[](5);
        calls[0] = IMulticall3.Call3Value({target: c.feeRecipient, allowFailure: false, value: fee, callData: ""});
        calls[1] = _wrapSwapToMc3Leg(c, rest);
        (calls[2], calls[3], calls[4]) = (tail[0], tail[1], tail[2]);

        _submitMc3(c, userPk, calls, c.amountEth);
    }
}
