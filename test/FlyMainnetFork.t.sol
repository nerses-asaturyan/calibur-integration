// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {SplitForwarder, Leg, TokenSplit} from "../src/SplitForwarder.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Proves SplitForwarder drives a REAL Fly (Magpie) same-chain swap —
///         real MagpieRouterV3, real Ethereum-mainnet liquidity, live Fly API
///         calldata — on a mainnet fork. NO mock. Same approach as the 0x test.
///
/// The Fly swap is an SF hook leg: SF approves MagpieRouterV3 and calls it with
/// the API's swapWithMagpieSignature calldata; the router pulls the sell token
/// from SF and delivers the buy token to the recipient (= SF, bound in the
/// quote's toAddress); the next split distributes it. Zero dust holds.
///
/// Run (opt-in — needs a mainnet RPC + --ffi; Fly quote is keyless):
///   export MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com
///   forge test --ffi --match-contract FlyMainnetFork -vv
/// Skipped automatically when MAINNET_RPC_URL is unset.
contract FlyMainnetForkTest is Test {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal constant NO_SUB = type(uint256).max;
    uint256 internal constant SELL = 100_000_000; // 100 USDC

    SplitForwarder internal sf;
    address internal feeEoa = makeAddr("feeEoa");
    address internal user = makeAddr("user");
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("MAINNET_RPC_URL unset -> Fly mainnet-fork test skipped.");
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;
        sf = new SplitForwarder();
        vm.deal(address(sf), 0); // the fresh SF address may collide with a funded
            // address on the fork; zero it so the run starts from a truly empty forwarder
        deal(USDC, address(sf), SELL);
    }

    /// @dev Flow-3 shape via REAL Fly: swap USDC->WETH through MagpieRouterV3,
    ///      then split the ACTUAL WETH output 12.34% fee / remainder to user.
    function testFork_Fly_RealRouter_SwapThenSplit() public {
        if (!forked) {
            vm.skip(true);
            return;
        }

        (address to, bytes memory data, uint256 minOut) = _quote(address(sf));
        console2.log("MagpieRouterV3:", to);
        console2.log("amountOutMin (WETH):", minOut);

        // split[0] USDC: 100% hook -> approve(router) + call(swapWithMagpieSignature).
        Leg[] memory sell = new Leg[](1);
        sell[0] = Leg({target: to, shareBps: 10_000, amountOffset: NO_SUB, data: data});
        // split[1] WETH: the real output -> 12.34% fee, remainder user.
        Leg[] memory buy = new Leg[](2);
        buy[0] = Leg({target: feeEoa, shareBps: 1234, amountOffset: NO_SUB, data: ""});
        buy[1] = Leg({target: user, shareBps: 8766, amountOffset: NO_SUB, data: ""});

        TokenSplit[] memory splits = new TokenSplit[](2);
        splits[0] = TokenSplit({token: USDC, legs: sell});
        splits[1] = TokenSplit({token: WETH, legs: buy});

        sf.run(splits);

        uint256 out = IERC20(WETH).balanceOf(feeEoa) + IERC20(WETH).balanceOf(user);
        assertGe(out, minOut, "real Fly delivered >= amountOutMin");
        assertEq(IERC20(WETH).balanceOf(feeEoa), out * 1234 / 10_000, "fee = 12.34% of real output");
        assertEq(IERC20(USDC).balanceOf(address(sf)), 0, "no USDC dust");
        assertEq(IERC20(WETH).balanceOf(address(sf)), 0, "no WETH dust");
        assertEq(IERC20(USDC).allowance(address(sf), to), 0, "allowance reset");
        console2.log("REAL Fly swap + split OK. WETH out:", out);
    }

    function _quote(address taker) internal returns (address to, bytes memory data, uint256 minOut) {
        string[] memory cmd = new string[](7);
        cmd[0] = "bash";
        cmd[1] = "script/fly_quote.sh";
        cmd[2] = "ethereum";
        cmd[3] = vm.toString(USDC);
        cmd[4] = vm.toString(WETH);
        cmd[5] = vm.toString(SELL);
        cmd[6] = vm.toString(taker);
        (to, data, minOut) = abi.decode(vm.ffi(cmd), (address, bytes, uint256));
    }
}
