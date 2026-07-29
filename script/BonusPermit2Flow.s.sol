// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {FlowBase, Call, IPermit2, console2} from "./FlowBase.s.sol";

/// @title BonusPermit2Flow — Flow 1 shape with a PLAIN ERC-20 (WETH) inbound
///        via Permit2 SignatureTransfer.
///
/// Proves the "any ERC-20 gasless" claim for tokens WITHOUT permit functions:
/// WETH9 has no EIP-2612 and no EIP-3009. After a ONE-TIME setup
/// (`WETH.approve(Permit2, max)` — one user tx per token, ever), every flow is
/// signature-only: the user signs a Permit2 `PermitTransferFrom` with
/// spender = OUR EXECUTOR, so only the executor can consume it (same safety
/// property as EIP-3009's msg.sender == to).
///
/// Atomic Calibur batch (relayer pays):
///   1. permit2.permitTransferFrom(user -> router, X WETH)   // gasless inbound
///   2. router: swap WETH -> USDC (exact-in), paid to the SplitForwarder
///   3. SF.run([{USDC: 100% hook -> depositERC20(id, USDC, receiver, ▸amount◂)}])
///        // full dynamic output deposited into the ORIGINAL depository
///
/// Usage (after one-time WETH.approve(Permit2)):
///   forge script script/BonusPermit2Flow.s.sol:BonusPermit2FlowScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract BonusPermit2FlowScript is FlowBase {
    function run() external {
        (Cfg memory c,, uint256 userPk) = _loadCfg();
        uint256 relayerPk = vm.envUint("PRIVATE_KEY");
        uint256 amount = vm.envOr("AMOUNT_WETH", uint256(0.001 ether));
        _logHeader(c, "Bonus: PLAIN token (WETH) gasless via Permit2 -> swap -> SF deposit");
        _preflight(c, true);

        uint256 minOut = _floor(c, _quote(c, c.weth, c.usdc, amount));
        console2.log("  WETH in (exact):", amount, " minOut (USDC -> depository):", minOut);

        uint256 deadline = block.timestamp + 10 minutes;
        uint256 nonce = vm.randomUint(); // Permit2 SignatureTransfer nonces are unordered
        bytes memory sig = _signPermit2Transfer(c, userPk, c.weth, amount, nonce, deadline);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _swapInput(c.forwarder, CONTRACT_BALANCE, minOut, _path(c, c.weth, c.usdc), false);

        Call[] memory calls = new Call[](3);
        calls[0] = Call({to: c.permit2, value: 0, data: _permit2PullData(c, amount, nonce, deadline, sig)});
        calls[1] = Call({to: c.router, value: 0, data: _routerCall(abi.encodePacked(V3_SWAP_EXACT_IN), inputs)});
        calls[2] = _depositTailCall(c);

        _submitCalibur(c, relayerPk, calls);
        _logDone(c);
    }

    /// @dev Separate frame to keep run() clear of stack-too-deep.
    function _depositTailCall(Cfg memory c) internal view returns (Call memory) {
        return _sfRunCall(c, _single(c.usdc, _legs1(_depositLeg(c, c.usdc, 10_000))));
    }

    /// @dev Separate frame to keep run() clear of stack-too-deep.
    function _permit2PullData(Cfg memory c, uint256 amount, uint256 nonce, uint256 deadline, bytes memory sig)
        internal
        pure
        returns (bytes memory)
    {
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: c.weth, amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
        IPermit2.SignatureTransferDetails memory details =
            IPermit2.SignatureTransferDetails({to: c.router, requestedAmount: amount});
        return abi.encodeCall(IPermit2.permitTransferFrom, (permit, details, c.user, sig));
    }
}
