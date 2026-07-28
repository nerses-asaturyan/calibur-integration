// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {SplitForwarder, Leg, TokenSplit} from "../src/SplitForwarder.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Proves SplitForwarder drives a REAL 0x swap — real Settler /
///         AllowanceHolder, real Ethereum-mainnet liquidity, live Swap API
///         calldata — on a mainnet fork. NO mock.
///
/// The 0x swap is an SF hook leg: SF approves the AllowanceHolder and calls it
/// with the API's `exec` calldata; 0x pulls the sell token and delivers the buy
/// token to the taker (= SF); the next split distributes it. Zero dust holds.
///
/// Run (opt-in — needs a mainnet RPC, --ffi, and ZEROX_API_KEY in env):
///   set -a; source .env; set +a
///   export MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com
///   forge test --ffi --match-contract ZeroxMainnetFork -vv
/// Skipped automatically when MAINNET_RPC_URL is unset.
contract ZeroxMainnetForkTest is Test {
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
            console2.log("MAINNET_RPC_URL unset -> 0x mainnet-fork test skipped.");
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;
        sf = new SplitForwarder();
        deal(USDC, address(sf), SELL); // input pre-funded into SF (as an upstream leg would)
    }

    /// @dev Flow-3 shape via REAL 0x: swap USDC->WETH through the live Settler,
    ///      then split the ACTUAL WETH output 12.34% fee / remainder to user.
    function testFork_0x_RealSettler_SwapThenSplit() public {
        if (!forked) {
            vm.skip(true);
            return;
        }

        // Live 0x quote for taker = SF (so 0x delivers the WETH to SF).
        (address to, bytes memory data, uint256 minBuy) = _quote(address(sf));
        console2.log("0x AllowanceHolder:", to);
        console2.log("minBuyAmount (WETH):", minBuy);

        // split[0] USDC: 100% hook -> approve(AllowanceHolder) + call(exec data).
        Leg[] memory sell = new Leg[](1);
        sell[0] = Leg({target: to, shareBps: 10_000, amountOffset: NO_SUB, data: data});
        // split[1] WETH: the real output 0x delivered -> 12.34% fee, remainder user.
        Leg[] memory buy = new Leg[](2);
        buy[0] = Leg({target: feeEoa, shareBps: 1234, amountOffset: NO_SUB, data: ""});
        buy[1] = Leg({target: user, shareBps: 8766, amountOffset: NO_SUB, data: ""});

        // split[2] native: the real 0x Settler delivers a little ETH surplus
        // (positive slippage) to the taker — a genuine 0x behavior our terminal
        // native check (audit fix) catches. Sweep it to the user so nothing is
        // stranded. (Proof that a robust 0x flow must account for native surplus.)
        Leg[] memory nativeLegs = new Leg[](1);
        nativeLegs[0] = Leg({target: user, shareBps: 10_000, amountOffset: NO_SUB, data: ""});

        TokenSplit[] memory splits = new TokenSplit[](3);
        splits[0] = TokenSplit({token: USDC, legs: sell});
        splits[1] = TokenSplit({token: WETH, legs: buy});
        splits[2] = TokenSplit({token: address(0), legs: nativeLegs});

        uint256 userEthBefore = user.balance;
        sf.run(splits);

        uint256 out = IERC20(WETH).balanceOf(feeEoa) + IERC20(WETH).balanceOf(user);
        assertGe(out, minBuy, "real 0x delivered >= minBuyAmount");
        assertEq(IERC20(WETH).balanceOf(feeEoa), out * 1234 / 10_000, "fee = 12.34% of real output");
        assertEq(IERC20(USDC).balanceOf(address(sf)), 0, "no USDC dust");
        assertEq(IERC20(WETH).balanceOf(address(sf)), 0, "no WETH dust");
        assertEq(address(sf).balance, 0, "no native surplus dust");
        assertEq(IERC20(USDC).allowance(address(sf), to), 0, "allowance reset");
        console2.log("REAL 0x swap + split OK. WETH out:", out);
        console2.log("native surplus swept to user (wei):", user.balance - userEthBefore);
    }

    address internal constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    /// @dev MIXED venue in ONE run(): swap half the USDC via REAL 0x and half
    ///      via REAL Uniswap (SwapRouter02) — two hook legs, different targets,
    ///      same transaction. Proves the venues coexist with no conflict.
    function testFork_MixedVenue_0xAndUniswap_SameRun() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        deal(USDC, address(sf), SELL); // total 100 USDC; 50 to each venue
        uint256 half = SELL / 2;

        // 0x leg: live quote for 50 USDC, taker = SF.
        (address ah, bytes memory zeroxData,) = _quoteAmount(address(sf), half);

        // Uniswap leg: SwapRouter02.exactInputSingle(USDC->WETH 0.05%, recipient = SF, amountIn = 50 USDC).
        bytes memory uniData = abi.encodeWithSelector(
            bytes4(0x04e45aaf), // exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))
            USDC, WETH, uint24(500), address(sf), half, uint256(1), uint160(0)
        );

        // split[0] USDC: leg A (50%) -> 0x hook; leg B (remainder) -> Uniswap hook.
        Leg[] memory sell = new Leg[](2);
        sell[0] = Leg({target: ah, shareBps: 5000, amountOffset: NO_SUB, data: zeroxData});
        sell[1] = Leg({target: SWAP_ROUTER_02, shareBps: 5000, amountOffset: NO_SUB, data: uniData});
        // split[1] WETH: combined output of BOTH venues -> user.
        Leg[] memory buy = new Leg[](1);
        buy[0] = Leg({target: user, shareBps: 10_000, amountOffset: NO_SUB, data: ""});
        // split[2] native: 0x surplus sweep.
        Leg[] memory nat = new Leg[](1);
        nat[0] = Leg({target: user, shareBps: 10_000, amountOffset: NO_SUB, data: ""});

        TokenSplit[] memory splits = new TokenSplit[](3);
        splits[0] = TokenSplit({token: USDC, legs: sell});
        splits[1] = TokenSplit({token: WETH, legs: buy});
        splits[2] = TokenSplit({token: address(0), legs: nat});

        sf.run(splits);

        assertGt(IERC20(WETH).balanceOf(user), 0, "user got WETH from BOTH venues");
        assertEq(IERC20(USDC).balanceOf(address(sf)), 0, "no USDC dust (both legs pulled)");
        assertEq(IERC20(WETH).balanceOf(address(sf)), 0, "no WETH dust");
        assertEq(address(sf).balance, 0, "no native surplus dust");
        assertEq(IERC20(USDC).allowance(address(sf), ah), 0, "0x allowance reset");
        assertEq(IERC20(USDC).allowance(address(sf), SWAP_ROUTER_02), 0, "uniswap allowance reset");
        console2.log("MIXED 0x + Uniswap in one run OK. total WETH to user:", IERC20(WETH).balanceOf(user));
    }

    function _quote(address taker) internal returns (address to, bytes memory data, uint256 minBuy) {
        return _quoteAmount(taker, SELL);
    }

    function _quoteAmount(address taker, uint256 amount)
        internal
        returns (address to, bytes memory data, uint256 minBuy)
    {
        string[] memory cmd = new string[](7);
        cmd[0] = "bash";
        cmd[1] = "script/zerox_quote.sh";
        cmd[2] = "1";
        cmd[3] = vm.toString(USDC);
        cmd[4] = vm.toString(WETH);
        cmd[5] = vm.toString(amount);
        cmd[6] = vm.toString(taker);
        bytes memory out = vm.ffi(cmd);
        (to, data, minBuy) = abi.decode(out, (address, bytes, uint256));
    }
}
