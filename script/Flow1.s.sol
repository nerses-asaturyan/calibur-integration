// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {FlowBase, Call, IMulticall3, IERC20, console2} from "./FlowBase.s.sol";

/// @title Flow1 — user → uniswap → depository (full output; fee charged on
///        destination chain, so no on-chain fee leg)
///
/// The ENTIRE input is swapped (exact-in) and the ENTIRE dynamic output is
/// deposited via depositERC20All — full amount, `Deposited` event, zero dust.
///
///   FUNDING_MODE=gasless     relayer Calibur batch; user signs EIP-3009 only
///   FUNDING_MODE=user-erc20  ONE user tx: Multicall3 + in-batch EIP-2612 permit
///                            (mainnet: MEV-protected submission REQUIRED)
///   FUNDING_MODE=user-eth    ONE user tx: Multicall3 value-leg into the router
///
/// Usage:
///   FUNDING_MODE=gasless forge script script/Flow1.s.sol:Flow1Script \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract Flow1Script is FlowBase {
    function run() external {
        (Cfg memory c, uint256 broadcasterPk, uint256 userPk) = _loadCfg();
        _logHeader(c, "Flow 1: all in -> swap -> depositERC20All (fee on destination)");
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

    /// @dev Calibur batch: pull X -> fund router -> swap all (paid straight to the
    ///      FORWARDER) -> forwarder.executeWithBalance -> original depositERC20.
    function _gasless(Cfg memory c, uint256 relayerPk, uint256 userPk) internal {
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, c.amountIn));
        console2.log("  swap USDC -> WETH, exact-in:", c.amountIn, " minOut:", minOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _swapInput(c.forwarder, CONTRACT_BALANCE, minOut, _path(c, c.usdc, c.weth), false);

        Call[] memory calls = new Call[](4);
        calls[0] = _pull3009(c, userPk, c.amountIn);
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, c.amountIn))});
        calls[2] = Call({to: c.router, value: 0, data: _routerCall(abi.encodePacked(V3_SWAP_EXACT_IN), inputs)});
        calls[3] = _forwardDepositCall(c, c.weth);

        _submitCalibur(c, relayerPk, calls);
    }

    /// @dev ONE user tx: Multicall3 [2612 permit (allowFailure=true; nonce-grief
    ///      tolerance) -> transferFrom(user->router) -> swap (paid to Multicall3)
    ///      -> depositERC20All tail]. Mainnet: private submission required.
    function _userErc20(Cfg memory c, uint256 userPk) internal {
        console2.log("  swap USDC -> WETH, exact-in:", c.amountIn);
        IMulticall3.Call3Value[] memory calls = new IMulticall3.Call3Value[](4);
        calls[0] = _permitLegMc3(c, userPk, c.amountIn);
        calls[1] = _transferFromLegMc3(c, c.router, c.amountIn);
        calls[2] = _swapToMc3LegErc20(c, c.amountIn);
        calls[3] = _forwardDepositMc3(c, c.weth);

        _submitMc3(c, userPk, calls, 0);
    }

    /// @dev ONE user tx: Multicall3 [router{value}: wrap all -> swap (paid to
    ///      Multicall3) -> depositERC20All tail].
    function _userEth(Cfg memory c, uint256 userPk) internal {
        console2.log("  wrap + swap WETH -> USDC, exact-in (wei):", c.amountEth);
        IMulticall3.Call3Value[] memory calls = new IMulticall3.Call3Value[](2);
        calls[0] = _wrapSwapToMc3Leg(c, c.amountEth);
        calls[1] = _forwardDepositMc3(c, c.usdc);

        _submitMc3(c, userPk, calls, c.amountEth);
    }
}
