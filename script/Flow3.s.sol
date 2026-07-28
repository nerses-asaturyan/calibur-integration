// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {FlowBase, Call, IERC20, Leg, TokenSplit, console2} from "./FlowBase.s.sol";

/// @title Flow3 — user → swap venue → SplitForwarder splits the OUTPUT:
///        [value to USER + fee → EOA]
///
/// VENUE-INDEPENDENT: this is the flow that previously depended on the
/// Universal Router's own PAY_PORTION/SWEEP payment commands. The split now
/// happens in SF.run on the ACTUAL output balance — live-exact bips, remainder
/// to the user — so any venue that can deliver output to an address (0x
/// Settler included) plugs in unchanged.
///
///   FUNDING_MODE=gasless     relayer Calibur batch; user signs EIP-3009 only
///   FUNDING_MODE=user-erc20  ONE user tx: SF.runWithPermit (Permit2 witness
///                            binds the whole plan -> public-mempool-safe, no MEV assumption)
///                            (mainnet: MEV-protected submission REQUIRED —
///                            note this replaced the router-only shape when the
///                            split moved out of the venue)
///   FUNDING_MODE=user-eth    ONE user tx, DIRECTLY to SplitForwarder.run{value}
contract Flow3Script is FlowBase {
    function run() external {
        (Cfg memory c, uint256 broadcasterPk, uint256 userPk) = _loadCfg();
        _logHeader(c, "Flow 3: swap all -> SF splits ACTUAL output: user + fee EOA");
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

    /// @dev Output split: fee bips -> EOA, remainder -> user. Computed on SF's
    ///      LIVE balance of the output token — live-exact, any venue.
    function _outSplit(Cfg memory c, address outToken) internal view returns (TokenSplit[] memory) {
        return _single(
            outToken,
            _legs2(_plainLeg(c.feeRecipient, uint96(c.feeBps)), _plainLeg(c.user, uint96(10_000 - c.feeBps)))
        );
    }

    function _gasless(Cfg memory c, uint256 relayerPk, uint256 userPk) internal {
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, c.amountIn));
        console2.log("  swap exact-in:", c.amountIn, " minOut:", minOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _swapInput(c.forwarder, CONTRACT_BALANCE, minOut, _path(c, c.usdc, c.weth), false);

        Call[] memory calls = new Call[](4);
        calls[0] = _pull3009(c, userPk, c.amountIn);
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, c.amountIn))});
        calls[2] = Call({to: c.router, value: 0, data: _routerCall(abi.encodePacked(V3_SWAP_EXACT_IN), inputs)});
        calls[3] = _sfRunCall(c, _outSplit(c, c.weth));

        _submitCalibur(c, relayerPk, calls);
    }

    /// @dev ONE direct SF.runWithPermit tx (public-mempool-safe). Split 1 funds
    ///      the router + runs the swap (output back to SF); split 2 is the
    ///      live-exact output split.
    function _userErc20(Cfg memory c, uint256 userPk) internal {
        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, c.amountIn));
        console2.log("  swap exact-in:", c.amountIn, " minOut:", minOut);

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
        splits[1] = _outSplit(c, c.weth)[0];

        _submitSfRunWithPermit(c, userPk, c.amountIn, splits);
    }

    /// @dev ONE direct SF call: split 1 (native) = 100% router hook (wrap + swap
    ///      -> SF); split 2 (USDC) = the live-exact output split.
    function _userEth(Cfg memory c, uint256 userPk) internal {
        uint256 minOut = _floor(c, _quote(c, c.weth, c.usdc, c.amountEth));
        console2.log("  wrap + swap exact-in (wei):", c.amountEth, " minOut:", minOut);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE);
        inputs[1] = _swapInput(c.forwarder, CONTRACT_BALANCE, minOut, _path(c, c.weth, c.usdc), false);

        TokenSplit[] memory splits = new TokenSplit[](2);
        splits[0] = TokenSplit({
            token: NATIVE,
            legs: _legs1(_routerHookLeg(c, 10_000, abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN), inputs))
        });
        splits[1] = _outSplit(c, c.usdc)[0];

        _submitSfNative(c, userPk, splits, c.amountEth);
    }
}
