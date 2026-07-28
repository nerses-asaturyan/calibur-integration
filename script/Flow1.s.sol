// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {FlowBase, Call, IERC20, Leg, TokenSplit, console2} from "./FlowBase.s.sol";

/// @title Flow1 — user → swap venue → depository (full output; fee on
///        destination chain, so no on-chain fee leg)
///
/// VENUE-INDEPENDENT: the swap venue (Universal Router here; 0x Settler on
/// mainnet) only swaps and delivers the output to the SplitForwarder; the
/// deposit into the ORIGINAL depository is a 100% hook leg of SF.run.
///
///   FUNDING_MODE=gasless     relayer Calibur batch; user signs EIP-3009 only
///   FUNDING_MODE=user-erc20  ONE user tx: SF.runWithPermit (Permit2 witness
///                            binds the whole plan -> public-mempool-safe, no MEV assumption)
///   FUNDING_MODE=user-eth    ONE user tx, DIRECTLY to SplitForwarder.run{value}:
///                            a native router-hook leg swaps, then the USDC
///                            split deposits the full output.
contract Flow1Script is FlowBase {
    function run() external {
        (Cfg memory c, uint256 broadcasterPk, uint256 userPk) = _loadCfg();
        _logHeader(c, "Flow 1: all in -> swap -> deposit full output (fee on destination)");
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
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, c.amountIn));
        console2.log("  swap USDC -> WETH, exact-in:", c.amountIn, " minOut:", minOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _swapInput(c.forwarder, CONTRACT_BALANCE, minOut, _path(c, c.usdc, c.weth), false);

        Call[] memory calls = new Call[](4);
        calls[0] = _pull3009(c, userPk, c.amountIn);
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, c.amountIn))});
        calls[2] = Call({to: c.router, value: 0, data: _routerCall(abi.encodePacked(V3_SWAP_EXACT_IN), inputs)});
        calls[3] = _sfRunCall(c, _single(c.weth, _legs1(_depositLeg(c, c.weth, 10_000))));

        _submitCalibur(c, relayerPk, calls);
    }

    /// @dev ONE direct SF.runWithPermit tx (public-mempool-safe: the Permit2
    ///      witness signature commits to these exact splits). Split 1 funds the
    ///      router and invokes the swap (call-only leg); split 2 deposits the
    ///      full WETH output.
    function _userErc20(Cfg memory c, uint256 userPk) internal {
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, c.amountIn));
        console2.log("  swap USDC -> WETH, exact-in:", c.amountIn, " minOut:", minOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _swapInput(c.forwarder, CONTRACT_BALANCE, minOut, _path(c, c.usdc, c.weth), false);

        TokenSplit[] memory splits = new TokenSplit[](2);
        splits[0] = TokenSplit({
            token: c.usdc,
            legs: _legs2(
                _plainLeg(c.router, 10_000),
                _callOnlyLeg(c.router, _routerCall(abi.encodePacked(V3_SWAP_EXACT_IN), inputs))
            )
        });
        splits[1] = TokenSplit({token: c.weth, legs: _legs1(_depositLeg(c, c.weth, 10_000))});

        _submitUserErc20(c, userPk, c.amountIn, splits);
    }

    /// @dev ONE direct SF call: split 1 (native) = a 100% router hook that wraps
    ///      and swaps, paying USDC back to SF; split 2 (USDC) = 100% deposit hook.
    function _userEth(Cfg memory c, uint256 userPk) internal {
        uint256 minOut = _floor(c, _quote(c, c.weth, c.usdc, c.amountEth));
        console2.log("  wrap + swap WETH -> USDC, exact-in (wei):", c.amountEth, " minOut:", minOut);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE); // WRAP_ETH the hook's msg.value
        inputs[1] = _swapInput(c.forwarder, CONTRACT_BALANCE, minOut, _path(c, c.weth, c.usdc), false);

        TokenSplit[] memory splits = new TokenSplit[](2);
        splits[0] = TokenSplit({
            token: NATIVE,
            legs: _legs1(_routerHookLeg(c, 10_000, abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN), inputs))
        });
        splits[1] = TokenSplit({token: c.usdc, legs: _legs1(_depositLeg(c, c.usdc, 10_000))});

        _submitSfNative(c, userPk, splits, c.amountEth);
    }
}
