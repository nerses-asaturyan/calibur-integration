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
import {SplitForwarder, Leg, TokenSplit} from "../src/SplitForwarder.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";
import {IERC20Permit} from "../src/interfaces/IERC20Permit.sol";
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
        _snapDust();
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

    /// @dev Zero-dust invariant. The router carries pre-existing balances on the
    ///      live fork (strangers' funds), so router checks are DELTA-based
    ///      against a snapshot; the SplitForwarder and executor are fresh
    ///      contracts and must be absolutely empty.
    uint256 internal snapRouterUsdc;
    uint256 internal snapRouterWeth;
    uint256 internal snapRouterEth;

    function _snapDust() internal {
        // Model the router's real mainnet state: it custodies NOTHING between
        // transactions (anyone can sweep it, so it is always drained). On the
        // Sepolia fork it happens to hold stranger funds, which WRAP_ETH/
        // CONTRACT_BALANCE legs would otherwise absorb — so zero it first.
        vm.deal(ROUTER, 0);
        deal(WETH, ROUTER, 0);
        deal(USDC, ROUTER, 0);
        snapRouterUsdc = 0;
        snapRouterWeth = 0;
        snapRouterEth = 0;
    }

    function _assertNoDust() internal view {
        assertEq(IERC20(USDC).balanceOf(ROUTER), snapRouterUsdc, "router USDC delta");
        assertEq(IERC20(WETH).balanceOf(ROUTER), snapRouterWeth, "router WETH delta");
        assertEq(ROUTER.balance, snapRouterEth, "router ETH delta");
        assertEq(IERC20(USDC).balanceOf(address(executor)), 0, "executor USDC dust");
        assertEq(IERC20(WETH).balanceOf(address(executor)), 0, "executor WETH dust");
        assertEq(IERC20(USDC).balanceOf(address(forwarder)), 0, "forwarder USDC dust");
        assertEq(IERC20(WETH).balanceOf(address(forwarder)), 0, "forwarder WETH dust");
        assertEq(address(forwarder).balance, 0, "forwarder ETH dust");
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
        _approvePermit2();
        uint256 receiverBefore = IERC20(WETH).balanceOf(receiver);
        f.run();
        assertEq(IERC20(USDC).balanceOf(user), 90_000_000, "user paid exactly 10 USDC");
        assertGt(IERC20(WETH).balanceOf(receiver) - receiverBefore, 0, "receiver got the FULL WETH output");
        // Intent-bound: one direct runWithPermit tx, public-mempool-safe.
        _assertNoDust();
    }

    function testFork_Flow1_UserEth() public onlyFork {
        Flow1Script f = new Flow1Script();
        f.setMode("user-eth");
        uint256 receiverBefore = IERC20(USDC).balanceOf(receiver);
        f.run();
        assertGt(IERC20(USDC).balanceOf(receiver) - receiverBefore, 0, "receiver got the FULL USDC output");
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
        _approvePermit2();
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
    //   EIP-2612 user-sent (permitAndRun): NO Permit2, NO approve            //
    // --------------------------------------------------------------------- //

    /// @dev Flow 1 & 4 driven with ERC20_AUTH=2612 — the user never approves
    ///      Permit2; USDC's native permit is consumed inside SF.permitAndRun.
    function testFork_Flow1_UserErc20_2612() public onlyFork {
        Flow1Script f = new Flow1Script();
        f.setMode("user-erc20");
        f.setErc20Auth("2612");
        // NOTE: deliberately NO _approvePermit2() — proving the path needs none.
        uint256 receiverBefore = IERC20(WETH).balanceOf(receiver);
        f.run();
        assertEq(IERC20(USDC).balanceOf(user), 90_000_000, "user paid exactly 10 USDC");
        assertGt(IERC20(WETH).balanceOf(receiver) - receiverBefore, 0, "receiver got FULL WETH output (2612 path)");
        assertEq(IERC20(USDC).allowance(user, PERMIT2), 0, "Permit2 never approved");
        _assertNoDust();
    }

    function testFork_Flow4_UserErc20_2612() public onlyFork {
        Flow4Script f = new Flow4Script();
        f.setMode("user-erc20");
        f.setErc20Auth("2612");
        uint256 receiverBefore = IERC20(WETH).balanceOf(receiver);
        f.run();
        assertEq(IERC20(USDC).balanceOf(feeEoa), AMOUNT_IN * FEE_BPS / 10_000, "exact fee (2612 path)");
        assertGt(IERC20(WETH).balanceOf(receiver) - receiverBefore, 0, "receiver got FULL WETH output");
        _assertNoDust();
    }

    /// @dev permitAndRun binds by owner = msg.sender: an attacker who lifts the
    ///      user's 2612 signature from the mempool cannot pull the USER's funds.
    ///      Calling with the user's (v,r,s): the permit recovers to the user
    ///      (≠ attacker) — caught — then transferFrom pulls from the ATTACKER,
    ///      who has nothing/hasn't approved → revert. User untouched.
    function testFork_Permit2612_ReplayCannotDrainUser() public onlyFork {
        address attacker = makeAddr("attacker2612");
        uint256 deadline = block.timestamp + 1 hours;

        // User signs permit(user, SF, value) — the exact sig a mempool bot sees.
        (uint8 v, bytes32 r, bytes32 s) =
            _sign2612ForSF(userPk, user, address(forwarder), AMOUNT_IN, deadline);

        // Minimal honest splits (100% USDC -> feeEoa) just to have a valid array.
        TokenSplit[] memory splits = new TokenSplit[](1);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({target: feeEoa, shareBps: 10_000, amountOffset: type(uint256).max, data: ""});
        splits[0] = TokenSplit({token: USDC, legs: legs});

        vm.prank(attacker);
        vm.expectRevert(); // transferFrom(attacker,...) has no balance/allowance
        forwarder.permitAndRun(USDC, AMOUNT_IN, deadline, v, r, s, splits);

        assertEq(IERC20(USDC).balanceOf(user), 100_000_000, "user funds untouched by replay");
    }

    function _sign2612ForSF(uint256 pk, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        uint256 nonce = IERC20Permit(USDC).nonces(owner);
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", IERC20Permit(USDC).DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
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
    //   Intent-binding: a replayer with ALTERED splits cannot steal          //
    // --------------------------------------------------------------------- //

    /// @dev Terminal-invariant fix: native ETH is ALWAYS checked, so a caller
    ///      who sends msg.value with a plan that names no native split can no
    ///      longer strand that ETH (it would previously sit and be sweepable).
    function testFork_Terminal_NativeLeftoverReverts() public onlyFork {
        deal(USDC, address(forwarder), 1_000_000); // fund a USDC-only plan
        TokenSplit[] memory splits = new TokenSplit[](1);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({target: feeEoa, shareBps: 10_000, amountOffset: type(uint256).max, data: ""});
        splits[0] = TokenSplit({token: USDC, legs: legs});

        vm.deal(address(this), 1 ether);
        // USDC distributes fine, but the 0.1 ETH sent as value is unaccounted →
        // terminal native check reverts the whole call.
        vm.expectRevert(abi.encodeWithSelector(SplitForwarder.BalanceNotConsumed.selector, address(0), 0.1 ether));
        forwarder.run{value: 0.1 ether}(splits);
    }

    /// @dev The core security property of runWithPermit: the user's Permit2
    ///      witness commits to keccak256(abi.encode(splits)). An attacker who
    ///      lifts the pending signature and swaps in their OWN splits (e.g.
    ///      "100% to the attacker") produces a different witness → Permit2
    ///      rejects the signature → nothing moves. Public-mempool-safe with no
    ///      submission assumptions.
    function testFork_Intent_AlteredSplitsReplayReverts() public onlyFork {
        _approvePermit2();
        address attacker = makeAddr("attacker");

        // The user signs a witness over the HONEST split (100% → depository).
        TokenSplit[] memory honest = new TokenSplit[](1);
        Leg[] memory hl = new Leg[](1);
        hl[0] = Leg({
            target: DEPOSITORY,
            shareBps: 10_000,
            amountOffset: 100,
            data: abi.encodeCall(ILayerswapDepository.depositERC20, (bytes32(uint256(1)), USDC, receiver, 0))
        });
        honest[0] = TokenSplit({token: USDC, legs: hl});

        uint256 nonce = 424242;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signWitness(userPk, USDC, 10_000_000, nonce, deadline, keccak256(abi.encode(honest)));

        // The attacker replays that signature but substitutes a MALICIOUS split
        // (100% plain transfer → attacker). Different splits ⇒ different witness.
        TokenSplit[] memory evil = new TokenSplit[](1);
        Leg[] memory el = new Leg[](1);
        el[0] = Leg({target: attacker, shareBps: 10_000, amountOffset: type(uint256).max, data: ""});
        evil[0] = TokenSplit({token: USDC, legs: el});

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: USDC, amount: 10_000_000}),
            nonce: nonce,
            deadline: deadline
        });

        vm.prank(attacker);
        vm.expectRevert(); // Permit2 InvalidSigner: the witness no longer matches
        forwarder.runWithPermit(permit, user, evil, sig);

        assertEq(IERC20(USDC).balanceOf(user), 100_000_000, "user funds untouched by the replay attempt");
        assertEq(IERC20(USDC).balanceOf(attacker), 0, "attacker got nothing");
    }

    /// @dev Sign a Permit2 permitWitnessTransferFrom digest (spender = forwarder).
    function _signWitness(uint256 pk, address token, uint256 amount, uint256 nonce, uint256 deadline, bytes32 witness)
        internal
        view
        returns (bytes memory)
    {
        bytes32 tokenPerms = keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount));
        bytes32 witnessTypehash = keccak256(
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,bytes32 witness)TokenPermissions(address token,uint256 amount)"
        );
        bytes32 structHash =
            keccak256(abi.encode(witnessTypehash, tokenPerms, address(forwarder), nonce, deadline, witness));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", IPermit2(PERMIT2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
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
