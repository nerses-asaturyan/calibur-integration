// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {FlowBase, Call, IERC20, TokenSplit, console2} from "./FlowBase.s.sol";

/// @title NativeDepositDemo — dynamic-amount NATIVE deposit into the ORIGINAL
///        depository: the capability `depositERC20All` fundamentally cannot
///        offer (native amounts must ride as msg.value, and no contract can
///        pull ETH from its caller — the fix has to live on the caller side,
///        which is exactly what the SplitForwarder is).
///
/// Gasless Calibur batch (user signs EIP-3009 only):
///   1. USDC.receiveWithAuthorization(user -> executor)
///   2. USDC.transfer(router, X)
///   3. router: swap USDC -> WETH, then UNWRAP_WETH paying NATIVE ETH -> SF
///   4. SF.run([{native: [100% hook depositNative(id, receiver)]}])
///        -> the dynamic amount travels as msg.value
///        -> Deposited(id, address(0), receiver, amount)
///
/// Usage:
///   forge script script/NativeDepositDemo.s.sol:NativeDepositDemoScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract NativeDepositDemoScript is FlowBase {
    function run() external {
        (Cfg memory c,, uint256 userPk) = _loadCfg();
        uint256 relayerPk = vm.envUint("PRIVATE_KEY");
        _logHeader(c, "Native deposit demo: swap -> unwrap -> depositNative with DYNAMIC msg.value");
        _preflight(c, true);

        uint256 minOut = _floor(c, _quote(c, c.usdc, c.weth, c.amountIn));
        console2.log("  swap USDC -> WETH exact-in:", c.amountIn, " unwrap minOut (wei):", minOut);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = _swapInput(ADDRESS_THIS, CONTRACT_BALANCE, minOut, _path(c, c.usdc, c.weth), false);
        inputs[1] = abi.encode(c.forwarder, minOut); // UNWRAP_WETH: whole WETH balance -> native ETH -> SF

        TokenSplit[] memory splits = _single(NATIVE, _legs1(_depositNativeLeg(c, 10_000)));

        Call[] memory calls = new Call[](4);
        calls[0] = _pull3009(c, userPk, c.amountIn);
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, c.amountIn))});
        calls[2] =
            Call({to: c.router, value: 0, data: _routerCall(abi.encodePacked(V3_SWAP_EXACT_IN, UNWRAP_WETH), inputs)});
        calls[3] = _sfRunCall(c, splits);

        _submitCalibur(c, relayerPk, calls);
        _logDone(c);
    }
}
