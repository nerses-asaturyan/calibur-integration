// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Flow1Script} from "../script/Flow1.s.sol";
import {Flow2Script} from "../script/Flow2.s.sol";
import {Flow3Script} from "../script/Flow3.s.sol";
import {Flow4Script} from "../script/Flow4.s.sol";
import {BonusPermit2FlowScript} from "../script/BonusPermit2Flow.s.sol";

import {IERC20} from "../src/interfaces/IERC20.sol";
import {SplitForwarder} from "../src/SplitForwarder.sol";
import {NativeDepositDemoScript} from "../script/NativeDepositDemo.s.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {ILayerswapDepository} from "../src/interfaces/ILayerswapDepository.sol";
import {MockERC7821Executor} from "./mocks/MockERC7821Executor.sol";

/// @notice End-to-end Sepolia-fork tests that drive the ACTUAL flow scripts
///         (Flow1..Flow4 + BonusPermit2Flow) in every funding mode via
///         vm.setEnv, against the real USDC, WETH9, Universal Router, Permit2,
///         Multicall3, and our live depository.
///
/// Run:  forge test --fork-url $SEPOLIA_RPC_URL --match-contract FlowsSepoliaFork -vv
/// If SEPOLIA_RPC_URL is unset, every test is SKIPPED (not failed).
contract FlowsSepoliaForkTest is Test {
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    // EXPERIMENT: the ORIGINAL depository (no depositERC20All) + BalanceForwarder.
    address internal constant DEPOSITORY = 0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4;

    uint256 internal constant AMOUNT_IN = 10_000_000; // 10 USDC
    uint256 internal constant AMOUNT_ETH = 0.002 ether;
    uint256 internal constant FEE_BPS = 1234;

    address internal user;
    uint256 internal userPk;
    address internal relayer;
    uint256 internal relayerPk;
    address internal feeEoa;
    address internal receiver;
    MockERC7821Executor internal executor;
    SplitForwarder internal forwarder;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("SEPOLIA_RPC_URL not set -> flow fork tests skipped.");
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;

        (user, userPk) = makeAddrAndKey("flowUser");
        (relayer, relayerPk) = makeAddrAndKey("flowRelayer");
        feeEoa = makeAddr("flowFeeEoa");
        receiver = makeAddr("flowReceiver");
        executor = new MockERC7821Executor();
        forwarder = new SplitForwarder();

        // Whitelist our receiver on the live depository (we own it on the fork).
        vm.prank(ILayerswapDepository(DEPOSITORY).owner());
        ILayerswapDepository(DEPOSITORY).addToWhitelist(receiver);

        // Fund the actors.
        deal(USDC, user, 100_000_000); // 100 USDC
        vm.deal(user, 1 ether);
        vm.deal(relayer, 1 ether);

        // Env consumed by the scripts' _loadCfg (keys are throwaway test keys).
        vm.setEnv("USDC_SEPOLIA", vm.toString(USDC));
        vm.setEnv("LAYERSWAP_DEPOSITORY", vm.toString(DEPOSITORY));
        vm.setEnv("DEPOSIT_RECEIVER", vm.toString(receiver));
        vm.setEnv("FEE_RECIPIENT", vm.toString(feeEoa));
        vm.setEnv("CALIBUR_EXECUTOR", vm.toString(address(executor)));
        vm.setEnv("DEPOSIT_FORWARDER", vm.toString(address(forwarder)));
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(relayerPk)));
        vm.setEnv("USER_PRIVATE_KEY", vm.toString(bytes32(userPk)));
        vm.setEnv("AMOUNT_IN", vm.toString(AMOUNT_IN));
        vm.setEnv("AMOUNT_ETH", vm.toString(AMOUNT_ETH));
        vm.setEnv("FEE_BPS", vm.toString(FEE_BPS));
        vm.setEnv("SLIPPAGE_BPS", "100");
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // --------------------------------------------------------------------- //
    //                              Helpers                                   //
    // --------------------------------------------------------------------- //

    // NOTE: per-test funding mode is set on the script INSTANCE (setMode) —
    // vm.setEnv would race across parallel tests (env is process-global).

    function _approvePermit2() internal {
        vm.prank(user);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
    }

    /// @dev Zero-dust invariant: router, Multicall3 (delta), and executor all
    ///      empty in both tokens after the flow.
    function _assertNoDust() internal view {
        assertEq(IERC20(USDC).balanceOf(ROUTER), 0, "router USDC dust");
        assertEq(IERC20(WETH).balanceOf(ROUTER), 0, "router WETH dust");
        assertEq(ROUTER.balance, 0, "router ETH dust");
        assertEq(IERC20(USDC).balanceOf(address(executor)), 0, "executor USDC dust");
        assertEq(IERC20(WETH).balanceOf(address(executor)), 0, "executor WETH dust");
        assertEq(IERC20(USDC).balanceOf(address(forwarder)), 0, "forwarder USDC dust");
        assertEq(IERC20(WETH).balanceOf(address(forwarder)), 0, "forwarder WETH dust");
    }

    function _mc3UsdcBefore() internal view returns (uint256) {
        return IERC20(USDC).balanceOf(MULTICALL3);
    }

    // --------------------------------------------------------------------- //
    //                    Flow 1: all in -> swap -> depositAll                //
    // --------------------------------------------------------------------- //

    function testFork_Flow1_Gasless() public onlyFork {
        Flow1Script f = new Flow1Script();
        f.setMode("gasless");
        uint256 receiverBefore = IERC20(WETH).balanceOf(receiver);
        f.run();
        assertEq(IERC20(USDC).balanceOf(user), 90_000_000, "user paid exactly 10 USDC");
        assertGt(IERC20(WETH).balanceOf(receiver) - receiverBefore, 0, "receiver got the FULL WETH output");
        _assertNoDust();
    }

    function testFork_Flow1_UserErc20() public onlyFork {
        Flow1Script f = new Flow1Script();
        f.setMode("user-erc20");
        uint256 receiverBefore = IERC20(WETH).balanceOf(receiver);
        f.run();
        assertEq(IERC20(USDC).balanceOf(user), 90_000_000, "user paid exactly 10 USDC");
        assertGt(IERC20(WETH).balanceOf(receiver) - receiverBefore, 0, "receiver got WETH via 2612+MC3");
        // The forwarder (not Multicall3) collects the output now; strangers'
        // stranded MC3 tokens no longer ride into deposits.
        _assertNoDust();
    }

    function testFork_Flow1_UserEth() public onlyFork {
        Flow1Script f = new Flow1Script();
        f.setMode("user-eth");
        uint256 receiverBefore = IERC20(USDC).balanceOf(receiver);
        uint256 mc3Before = _mc3UsdcBefore();
        f.run();
        assertGt(IERC20(USDC).balanceOf(receiver) - receiverBefore, 0, "receiver got the FULL USDC output");
        assertEq(_mc3UsdcBefore(), mc3Before, "MC3 USDC delta zero");
        _assertNoDust();
    }

    // --------------------------------------------------------------------- //
    //            Flow 2: exact fee from input; rest swap -> user             //
    // --------------------------------------------------------------------- //

    function testFork_Flow2_Gasless() public onlyFork {
        Flow2Script f = new Flow2Script();
        f.setMode("gasless");
        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        f.run();
        assertEq(IERC20(USDC).balanceOf(feeEoa), AMOUNT_IN * FEE_BPS / 10_000, "exact fee");
        assertGt(IERC20(WETH).balanceOf(user) - wethBefore, 0, "user received swapped WETH");
        _assertNoDust();
    }

    function testFork_Flow2_UserErc20() public onlyFork {
        Flow2Script f = new Flow2Script();
        f.setMode("user-erc20");
        _approvePermit2();
        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        f.run();
        assertEq(IERC20(USDC).balanceOf(feeEoa), AMOUNT_IN * FEE_BPS / 10_000, "exact fee via PERMIT2_TRANSFER_FROM");
        assertGt(IERC20(WETH).balanceOf(user) - wethBefore, 0, "user received swapped WETH");
        _assertNoDust();
    }

    function testFork_Flow2_UserEth() public onlyFork {
        Flow2Script f = new Flow2Script();
        f.setMode("user-eth");
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        f.run();
        assertEq(feeEoa.balance, AMOUNT_ETH * FEE_BPS / 10_000, "exact native fee");
        assertGt(IERC20(USDC).balanceOf(user) - usdcBefore, 0, "user received swapped USDC");
        _assertNoDust();
    }

    // --------------------------------------------------------------------- //
    //        Flow 3: swap all -> live-exact split (user + fee EOA)           //
    // --------------------------------------------------------------------- //

    function testFork_Flow3_Gasless() public onlyFork {
        Flow3Script f = new Flow3Script();
        f.setMode("gasless");
        uint256 feeBefore = IERC20(WETH).balanceOf(feeEoa);
        uint256 userBefore = IERC20(WETH).balanceOf(user);
        f.run();
        uint256 fee = IERC20(WETH).balanceOf(feeEoa) - feeBefore;
        uint256 toUser = IERC20(WETH).balanceOf(user) - userBefore;
        assertGt(fee, 0, "fee EOA got its live-exact share");
        // PAY_PORTION is bips of the ACTUAL output: fee/(fee+toUser) == FEE_BPS/10000 (floor rounding).
        assertApproxEqAbs(fee * 10_000 / (fee + toUser), FEE_BPS, 1, "live-exact bips split");
        _assertNoDust();
    }

    function testFork_Flow3_UserErc20() public onlyFork {
        Flow3Script f = new Flow3Script();
        f.setMode("user-erc20");
        _approvePermit2();
        uint256 feeBefore = IERC20(WETH).balanceOf(feeEoa);
        uint256 userBefore = IERC20(WETH).balanceOf(user);
        f.run();
        uint256 fee = IERC20(WETH).balanceOf(feeEoa) - feeBefore;
        uint256 toUser = IERC20(WETH).balanceOf(user) - userBefore;
        assertApproxEqAbs(fee * 10_000 / (fee + toUser), FEE_BPS, 1, "live-exact bips split");
        _assertNoDust();
    }

    function testFork_Flow3_UserEth() public onlyFork {
        Flow3Script f = new Flow3Script();
        f.setMode("user-eth");
        uint256 feeBefore = IERC20(USDC).balanceOf(feeEoa);
        uint256 userBefore = IERC20(USDC).balanceOf(user);
        f.run();
        uint256 fee = IERC20(USDC).balanceOf(feeEoa) - feeBefore;
        uint256 toUser = IERC20(USDC).balanceOf(user) - userBefore;
        assertApproxEqAbs(fee * 10_000 / (fee + toUser), FEE_BPS, 1, "live-exact bips split");
        _assertNoDust();
    }

    // --------------------------------------------------------------------- //
    //     Flow 4: exact fee from input; rest swap -> depositAll (full)       //
    // --------------------------------------------------------------------- //

    function testFork_Flow4_Gasless() public onlyFork {
        Flow4Script f = new Flow4Script();
        f.setMode("gasless");
        uint256 receiverBefore = IERC20(WETH).balanceOf(receiver);
        f.run();
        assertEq(IERC20(USDC).balanceOf(feeEoa), AMOUNT_IN * FEE_BPS / 10_000, "exact fee");
        assertGt(IERC20(WETH).balanceOf(receiver) - receiverBefore, 0, "receiver got FULL WETH output");
        _assertNoDust();
    }

    function testFork_Flow4_UserErc20() public onlyFork {
        Flow4Script f = new Flow4Script();
        f.setMode("user-erc20");
        uint256 receiverBefore = IERC20(WETH).balanceOf(receiver);
        f.run();
        assertEq(IERC20(USDC).balanceOf(feeEoa), AMOUNT_IN * FEE_BPS / 10_000, "exact fee via 2612+MC3");
        assertGt(IERC20(WETH).balanceOf(receiver) - receiverBefore, 0, "receiver got FULL WETH output");
        _assertNoDust();
    }

    function testFork_Flow4_UserEth() public onlyFork {
        Flow4Script f = new Flow4Script();
        f.setMode("user-eth");
        uint256 receiverBefore = IERC20(USDC).balanceOf(receiver);
        f.run();
        assertEq(feeEoa.balance, AMOUNT_ETH * FEE_BPS / 10_000, "exact native fee");
        assertGt(IERC20(USDC).balanceOf(receiver) - receiverBefore, 0, "receiver got FULL USDC output");
        _assertNoDust();
    }

    // --------------------------------------------------------------------- //
    //          Bonus: plain token (WETH) gasless via Permit2                 //
    // --------------------------------------------------------------------- //

    function testFork_Bonus_Permit2PlainToken() public onlyFork {
        BonusPermit2FlowScript f = new BonusPermit2FlowScript();
        f.setMode("gasless");
        // One-time setup a real user would do once per plain token:
        vm.startPrank(user);
        IWETH9(WETH).deposit{value: 0.001 ether}();
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        vm.stopPrank();

        uint256 receiverBefore = IERC20(USDC).balanceOf(receiver);
        f.run();
        assertEq(IERC20(WETH).balanceOf(user), 0, "user's WETH pulled by signature");
        assertGt(IERC20(USDC).balanceOf(receiver) - receiverBefore, 0, "receiver got FULL USDC output");
        _assertNoDust();
    }

    // --------------------------------------------------------------------- //
    //     Native deposit demo: dynamic msg.value into depositNative          //
    // --------------------------------------------------------------------- //

    function testFork_NativeDepositDemo_DynamicMsgValue() public onlyFork {
        NativeDepositDemoScript f = new NativeDepositDemoScript();
        f.setMode("gasless");
        uint256 receiverBefore = receiver.balance;
        f.run();
        assertGt(receiver.balance - receiverBefore, 0, "receiver got NATIVE ETH via depositNative, dynamic amount");
        assertEq(address(forwarder).balance, 0, "forwarder native dust");
        _assertNoDust();
    }

    // --------------------------------------------------------------------- //
    //                    Atomicity: paused depository                        //
    // --------------------------------------------------------------------- //

    function testFork_Atomicity_PausedDepositoryRevertsWholeFlow() public onlyFork {
        vm.prank(ILayerswapDepository(DEPOSITORY).owner());
        (bool ok,) = DEPOSITORY.call(abi.encodeWithSignature("pause()"));
        require(ok, "could not pause");

        uint256 userBefore = IERC20(USDC).balanceOf(user);
        Flow1Script flow = new Flow1Script();
        flow.setMode("gasless");
        vm.expectRevert();
        flow.run();

        assertEq(IERC20(USDC).balanceOf(user), userBefore, "user USDC untouched: batch rolled back");
        _assertNoDust();
    }
}
