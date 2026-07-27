// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {FlowBase, Call, IMulticall3, IERC20, Leg, TokenSplit, console2} from "./FlowBase.s.sol";

/// @title Flow2 — user → [fee → EOA + rest → swap venue → value to USER]
///        (split FIRST — done by the SplitForwarder on the KNOWN input, so the
///        fee is exact bips; the venue then swaps and delivers to the user)
///
/// VENUE-INDEPENDENT: the input split happens in SF.run; the venue's only jobs
/// are swap + deliver-to-address (0x-compatible).
///
///   FUNDING_MODE=gasless     relayer Calibur batch; user signs EIP-3009 only
///   FUNDING_MODE=user-erc20  ONE user tx: Multicall3 + in-batch EIP-2612 permit
///                            (mainnet: MEV-protected submission REQUIRED —
///                            note this replaced the router-only shape when the
///                            split moved out of the venue)
///   FUNDING_MODE=user-eth    ONE user tx, DIRECTLY to SplitForwarder.run{value}
contract Flow2Script is FlowBase {
    function run() external {
        (Cfg memory c, uint256 broadcasterPk, uint256 userPk) = _loadCfg();
        _logHeader(c, "Flow 2: SF splits input (exact fee -> EOA); venue swaps rest -> user");
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

    /// @dev The input split (SF): fee -> EOA, rest -> router (plain transfer);
    ///      then the router swaps its whole balance straight to the user.
    function _erc20Shape(Cfg memory c)
        internal
        returns (TokenSplit[] memory splits, bytes memory routerData)
    {
        uint256 fee = c.amountIn * c.feeBps / 10_000;
        uint256 rest = c.amountIn - fee;
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, rest));
        console2.log("  fee (exact):", fee, " swapped:", rest);
        console2.log("  minOut (WETH to user):", minOut);

        splits = _single(
            c.usdc, _legs2(_plainLeg(c.feeRecipient, uint96(c.feeBps)), _plainLeg(c.router, uint96(10_000 - c.feeBps)))
        );

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _swapInput(c.user, CONTRACT_BALANCE, minOut, _path(c, c.usdc, c.weth), false);
        routerData = _routerCall(abi.encodePacked(V3_SWAP_EXACT_IN), inputs);
    }

    function _gasless(Cfg memory c, uint256 relayerPk, uint256 userPk) internal {
        (TokenSplit[] memory splits, bytes memory routerData) = _erc20Shape(c);

        Call[] memory calls = new Call[](4);
        calls[0] = _pull3009(c, userPk, c.amountIn);
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.forwarder, c.amountIn))});
        calls[2] = _sfRunCall(c, splits);
        calls[3] = Call({to: c.router, value: 0, data: routerData});

        _submitCalibur(c, relayerPk, calls);
    }

    function _userErc20(Cfg memory c, uint256 userPk) internal {
        (TokenSplit[] memory splits, bytes memory routerData) = _erc20Shape(c);

        IMulticall3.Call3Value[] memory calls = new IMulticall3.Call3Value[](4);
        calls[0] = _permitLegMc3(c, userPk, c.amountIn);
        calls[1] = _transferFromLegMc3(c, c.forwarder, c.amountIn);
        calls[2] = _sfRunMc3(c, splits);
        calls[3] = IMulticall3.Call3Value({target: c.router, allowFailure: false, value: 0, callData: routerData});

        _submitMc3(c, userPk, calls, 0);
    }

    /// @dev ONE direct SF call: native split = [exact fee -> EOA plain, rest ->
    ///      router hook (value rides with execute: wrap + swap -> user)].
    function _userEth(Cfg memory c, uint256 userPk) internal {
        uint256 fee = c.amountEth * c.feeBps / 10_000;
        uint256 rest = c.amountEth - fee;
        uint256 minOut = _floor(c, _quote(c, c.weth, c.usdc, rest));
        console2.log("  fee (exact wei):", fee, " swapped (wei):", rest);
        console2.log("  minOut (USDC to user):", minOut);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE);
        inputs[1] = _swapInput(c.user, CONTRACT_BALANCE, minOut, _path(c, c.weth, c.usdc), false);

        TokenSplit[] memory splits = _single(
            NATIVE,
            _legs2(
                _plainLeg(c.feeRecipient, uint96(c.feeBps)),
                _routerHookLeg(c, uint96(10_000 - c.feeBps), abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN), inputs)
            )
        );

        _submitSfNative(c, userPk, splits, c.amountEth);
    }
}
