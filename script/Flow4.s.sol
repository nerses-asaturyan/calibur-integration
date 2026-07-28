// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {FlowBase, Call, IERC20, Leg, TokenSplit, console2} from "./FlowBase.s.sol";

/// @title Flow4 — user → [fee → EOA + rest → swap venue → depository (full output)]
///        (input split AND deposit both via the SplitForwarder; the venue only
///        swaps and delivers to SF — 0x-compatible)
///
///   FUNDING_MODE=gasless     relayer Calibur batch; user signs EIP-3009 only
///   FUNDING_MODE=user-erc20  ONE user tx: SF.runWithPermit (Permit2 witness
///                            binds the whole plan -> public-mempool-safe, no MEV assumption)
///   FUNDING_MODE=user-eth    ONE user tx, DIRECTLY to SplitForwarder.run{value}
contract Flow4Script is FlowBase {
    function run() external {
        (Cfg memory c, uint256 broadcasterPk, uint256 userPk) = _loadCfg();
        _logHeader(c, "Flow 4: SF splits input (fee -> EOA); venue swaps rest -> SF deposits full output");
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

    /// @dev Input split: exact fee -> EOA, rest -> router; then a swap paid to
    ///      SF; then the 100% deposit hook on the swap output.
    function _erc20Pieces(Cfg memory c)
        internal
        returns (TokenSplit[] memory inSplit, bytes memory routerData, TokenSplit[] memory depositSplit)
    {
        uint256 fee = c.amountIn * c.feeBps / 10_000;
        uint256 rest = c.amountIn - fee;
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, rest));
        console2.log("  fee (exact):", fee, " swapped:", rest);
        console2.log("  minOut (WETH -> depository):", minOut);

        inSplit = _single(
            c.usdc, _legs2(_plainLeg(c.feeRecipient, uint96(c.feeBps)), _plainLeg(c.router, uint96(10_000 - c.feeBps)))
        );

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _swapInput(c.forwarder, CONTRACT_BALANCE, minOut, _path(c, c.usdc, c.weth), false);
        routerData = _routerCall(abi.encodePacked(V3_SWAP_EXACT_IN), inputs);

        depositSplit = _single(c.weth, _legs1(_depositLeg(c, c.weth, 10_000)));
    }

    function _gasless(Cfg memory c, uint256 relayerPk, uint256 userPk) internal {
        (TokenSplit[] memory inSplit, bytes memory routerData, TokenSplit[] memory depositSplit) = _erc20Pieces(c);

        Call[] memory calls = new Call[](5);
        calls[0] = _pull3009(c, userPk, c.amountIn);
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.forwarder, c.amountIn))});
        calls[2] = _sfRunCall(c, inSplit);
        calls[3] = Call({to: c.router, value: 0, data: routerData});
        calls[4] = _sfRunCall(c, depositSplit);

        _submitCalibur(c, relayerPk, calls);
    }

    /// @dev ONE direct SF.runWithPermit tx (public-mempool-safe). Split 1:
    ///      exact fee -> EOA, rest -> router, call-only leg runs the swap
    ///      (output back to SF); split 2 deposits the full output.
    function _userErc20(Cfg memory c, uint256 userPk) internal {
        (TokenSplit[] memory inSplit, bytes memory routerData, TokenSplit[] memory depositSplit) = _erc20Pieces(c);

        TokenSplit[] memory splits = new TokenSplit[](2);
        splits[0] = TokenSplit({
            token: c.usdc,
            legs: _legs3(inSplit[0].legs[0], inSplit[0].legs[1], _callOnlyLeg(c.router, routerData))
        });
        splits[1] = depositSplit[0];

        _submitSfRunWithPermit(c, userPk, c.amountIn, splits);
    }

    /// @dev ONE direct SF call: native split = [exact fee -> EOA, rest -> router
    ///      hook (wrap + swap -> SF)]; USDC split = 100% deposit hook.
    function _userEth(Cfg memory c, uint256 userPk) internal {
        uint256 fee = c.amountEth * c.feeBps / 10_000;
        uint256 rest = c.amountEth - fee;
        uint256 minOut = _floor(c, _quote(c, c.weth, c.usdc, rest));
        console2.log("  fee (exact wei):", fee, " swapped (wei):", rest);
        console2.log("  minOut (USDC -> depository):", minOut);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE);
        inputs[1] = _swapInput(c.forwarder, CONTRACT_BALANCE, minOut, _path(c, c.weth, c.usdc), false);

        TokenSplit[] memory splits = new TokenSplit[](2);
        splits[0] = TokenSplit({
            token: NATIVE,
            legs: _legs2(
                _plainLeg(c.feeRecipient, uint96(c.feeBps)),
                _routerHookLeg(c, uint96(10_000 - c.feeBps), abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN), inputs)
            )
        });
        splits[1] = TokenSplit({token: c.usdc, legs: _legs1(_depositLeg(c, c.usdc, 10_000))});

        _submitSfNative(c, userPk, splits, c.amountEth);
    }
}
