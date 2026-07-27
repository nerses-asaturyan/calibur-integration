// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {CaliburDepositTestBase} from "./CaliburDepositTestBase.sol";

import {PayoutSplitter} from "../src/PayoutSplitter.sol";
import {IPayoutSplitter, Leg} from "../src/interfaces/IPayoutSplitter.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Call} from "../src/interfaces/IERC7821.sol";
import {IERC3009USDC} from "../src/interfaces/IERC3009USDC.sol";

import {MockERC3009USDC} from "./mocks/MockERC3009USDC.sol";
import {MockERC7821Executor} from "./mocks/MockERC7821Executor.sol";
import {MockHookTarget, RevertingTarget, ReentrantTarget} from "./mocks/MockHookTarget.sol";
import {LayerswapDepository} from "./external/LayerswapDepository.sol";

/// @notice Unit tests for PayoutSplitter: bps math + last-leg remainder (zero
///         dust), generic call hooks with amount substitution, native ETH,
///         validation reverts, atomicity inside an ERC-7821 batch, reentrancy.
contract PayoutSplitterTest is CaliburDepositTestBase {
    bytes32 internal constant BATCH_MODE = 0x0100000000000000000000000000000000000000000000000000000000000000;
    uint256 internal constant NO_SUB = type(uint256).max;

    PayoutSplitter internal splitter;
    MockERC3009USDC internal usdc;
    MockHookTarget internal hookTarget;
    LayerswapDepository internal depository;

    address internal eoaA = makeAddr("eoaA");
    address internal eoaB = makeAddr("eoaB");
    address internal receiver = makeAddr("lsReceiver");
    address internal depositoryOwner = makeAddr("depositoryOwner");

    function setUp() public {
        splitter = new PayoutSplitter();
        usdc = new MockERC3009USDC();
        hookTarget = new MockHookTarget();

        address[] memory initial = new address[](1);
        initial[0] = receiver;
        depository = new LayerswapDepository(depositoryOwner, initial);
    }

    // --------------------------------------------------------------------- //
    //                              Helpers                                   //
    // --------------------------------------------------------------------- //

    function _plain(address target, uint96 bps) internal pure returns (Leg memory) {
        return Leg({target: target, shareBps: bps, amountOffset: NO_SUB, data: ""});
    }

    function _legs2(Leg memory a, Leg memory b) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        (legs[0], legs[1]) = (a, b);
    }

    function _legs3(Leg memory a, Leg memory b, Leg memory c) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](3);
        (legs[0], legs[1], legs[2]) = (a, b, c);
    }

    /// @dev depositERC20(bytes32 id, address token, address receiver, uint256 amount):
    ///      amount word at byte offset 4 + 3*32 = 100.
    function _depositErc20Hook(bytes32 id, uint96 bps) internal view returns (Leg memory) {
        return Leg({
            target: address(depository),
            shareBps: bps,
            amountOffset: 100,
            data: abi.encodeCall(depository.depositERC20, (id, address(usdc), receiver, 0))
        });
    }

    // --------------------------------------------------------------------- //
    //                        ERC-20: plain splits                            //
    // --------------------------------------------------------------------- //

    function test_Erc20_TwoPlainLegs_ExactAmounts() public {
        usdc.mint(address(splitter), 1_000_000);
        splitter.split(address(usdc), _legs2(_plain(eoaA, 1234), _plain(eoaB, 8766)));

        assertEq(usdc.balanceOf(eoaA), 123_400, "eoaA got exactly 12.34%");
        assertEq(usdc.balanceOf(eoaB), 876_600, "eoaB got the remainder (87.66%)");
        assertEq(usdc.balanceOf(address(splitter)), 0, "splitter empty");
    }

    function test_Erc20_LastLegRemainder_ZeroDust() public {
        // 10_001 * 3333 / 10000 = 3333 (floor) twice; last leg gets 10_001 - 6_666 = 3_335.
        usdc.mint(address(splitter), 10_001);
        splitter.split(address(usdc), _legs3(_plain(eoaA, 3333), _plain(eoaB, 3333), _plain(receiver, 3334)));

        assertEq(usdc.balanceOf(eoaA), 3333);
        assertEq(usdc.balanceOf(eoaB), 3333);
        assertEq(usdc.balanceOf(receiver), 3335, "last leg absorbed the rounding remainder");
        assertEq(usdc.balanceOf(address(splitter)), 0, "zero dust");
    }

    function testFuzz_ZeroDust(uint96 bpsA, uint96 bpsB, uint96 total) public {
        bpsA = uint96(bound(bpsA, 1, 9998));
        bpsB = uint96(bound(bpsB, 1, 9999 - bpsA));
        uint96 bpsC = 10_000 - bpsA - bpsB;
        // Large enough that no leg floors to zero.
        total = uint96(bound(total, 100_000, type(uint96).max));

        usdc.mint(address(splitter), total);
        splitter.split(address(usdc), _legs3(_plain(eoaA, bpsA), _plain(eoaB, bpsB), _plain(receiver, bpsC)));

        assertEq(
            usdc.balanceOf(eoaA) + usdc.balanceOf(eoaB) + usdc.balanceOf(receiver), total, "payouts sum to total"
        );
        assertEq(usdc.balanceOf(address(splitter)), 0, "zero dust always");
    }

    // --------------------------------------------------------------------- //
    //                        ERC-20: call hooks                              //
    // --------------------------------------------------------------------- //

    function test_Erc20_Hook_AmountSubstitutedAtOffset() public {
        usdc.mint(address(splitter), 1_000_000);
        // pull(address token, bytes32 tag, uint256 amount): amount at 4 + 2*32 = 68.
        Leg memory hook = Leg({
            target: address(hookTarget),
            shareBps: 5000,
            amountOffset: 68,
            data: abi.encodeCall(hookTarget.pull, (address(usdc), bytes32(uint256(0xBEEF)), 0))
        });
        splitter.split(address(usdc), _legs2(_plain(eoaA, 5000), hook));

        bytes memory got = hookTarget.lastCalldata();
        assertEq(bytes4(got), MockHookTarget.pull.selector, "selector intact");
        // Word at offset 68 must equal the computed amount (the remainder = 500_000).
        uint256 word;
        assembly {
            word := mload(add(add(got, 0x20), 68))
        }
        assertEq(word, 500_000, "amount substituted byte-exactly");
        assertEq(usdc.balanceOf(address(hookTarget)), 500_000, "hook pulled its amount");
        assertEq(usdc.allowance(address(splitter), address(hookTarget)), 0, "no residual allowance");
        assertEq(usdc.balanceOf(address(splitter)), 0, "zero dust");
    }

    function test_Erc20_Hook_OriginalDepository_DepositERC20() public {
        usdc.mint(address(splitter), 1_000_000);
        bytes32 id = bytes32(uint256(0xD1D1));

        // Legs: 12.34% -> eoaA, 37.66% -> eoaB, 50% remainder -> depositERC20 hook.
        vm.expectEmit(true, true, true, true, address(depository));
        emit LayerswapDepository.Deposited(id, address(usdc), receiver, 500_000);
        splitter.split(address(usdc), _legs3(_plain(eoaA, 1234), _plain(eoaB, 3766), _depositErc20Hook(id, 5000)));

        assertEq(usdc.balanceOf(eoaA), 123_400);
        assertEq(usdc.balanceOf(eoaB), 376_600);
        assertEq(usdc.balanceOf(receiver), 500_000, "depository forwarded the remainder to the receiver");
        assertEq(usdc.balanceOf(address(splitter)), 0, "zero dust");
        assertEq(usdc.allowance(address(splitter), address(depository)), 0, "no residual allowance");
    }

    // --------------------------------------------------------------------- //
    //                              Native ETH                                //
    // --------------------------------------------------------------------- //

    function test_Native_PlainLegs() public {
        vm.deal(address(splitter), 1 ether);
        splitter.split(address(0), _legs2(_plain(eoaA, 1234), _plain(eoaB, 8766)));

        assertEq(eoaA.balance, 0.1234 ether);
        assertEq(eoaB.balance, 0.8766 ether);
        assertEq(address(splitter).balance, 0, "zero dust");
    }

    function test_Native_Hook_DepositNative_NoSubstitution() public {
        vm.deal(address(splitter), 1 ether);
        bytes32 id = bytes32(uint256(0xE7E7));
        Leg memory hook = Leg({
            target: address(depository),
            shareBps: 5000,
            amountOffset: NO_SUB,
            data: abi.encodeCall(depository.depositNative, (id, receiver))
        });

        vm.expectEmit(true, true, true, true, address(depository));
        emit LayerswapDepository.Deposited(id, address(0), receiver, 0.5 ether);
        splitter.split(address(0), _legs2(_plain(eoaA, 5000), hook));

        assertEq(eoaA.balance, 0.5 ether);
        assertEq(receiver.balance, 0.5 ether, "depositNative forwarded msg.value to receiver");
        assertEq(address(splitter).balance, 0, "zero dust");
    }

    function test_Native_PayableSplitWithValue() public {
        // Fund partially beforehand and send the rest as msg.value in split().
        vm.deal(address(splitter), 0.25 ether);
        vm.deal(address(this), 0.75 ether);
        splitter.split{value: 0.75 ether}(address(0), _legs2(_plain(eoaA, 5000), _plain(eoaB, 5000)));

        assertEq(eoaA.balance, 0.5 ether, "total included msg.value");
        assertEq(eoaB.balance, 0.5 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_Native_Hook_Sink_SubstitutionMatchesValue() public {
        vm.deal(address(splitter), 2 ether);
        // sink(bytes32 tag, uint256 amount): amount at 4 + 32 = 36; requires value == amount.
        Leg memory hook = Leg({
            target: address(hookTarget),
            shareBps: 7500,
            amountOffset: 36,
            data: abi.encodeCall(hookTarget.sink, (bytes32(uint256(1)), 0))
        });
        splitter.split(address(0), _legs2(_plain(eoaA, 2500), hook));

        assertEq(hookTarget.lastValue(), 1.5 ether, "hook value == substituted amount");
        assertEq(address(splitter).balance, 0);
    }

    // --------------------------------------------------------------------- //
    //                                Reverts                                 //
    // --------------------------------------------------------------------- //

    function test_Revert_EmptyLegs() public {
        usdc.mint(address(splitter), 1);
        vm.expectRevert(IPayoutSplitter.NoLegs.selector);
        splitter.split(address(usdc), new Leg[](0));
    }

    function test_Revert_SharesSumWrong() public {
        usdc.mint(address(splitter), 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(IPayoutSplitter.SharesMustSumTo10000.selector, 9_999));
        splitter.split(address(usdc), _legs2(_plain(eoaA, 1234), _plain(eoaB, 8765)));

        vm.expectRevert(abi.encodeWithSelector(IPayoutSplitter.SharesMustSumTo10000.selector, 10_001));
        splitter.split(address(usdc), _legs2(_plain(eoaA, 1234), _plain(eoaB, 8767)));
    }

    function test_Revert_ZeroTotalBalance() public {
        vm.expectRevert(IPayoutSplitter.ZeroTotalBalance.selector);
        splitter.split(address(usdc), _legs2(_plain(eoaA, 5000), _plain(eoaB, 5000)));
    }

    function test_Revert_ZeroLegAmount() public {
        usdc.mint(address(splitter), 5); // 5 * 1 bps / 10000 == 0
        vm.expectRevert(abi.encodeWithSelector(IPayoutSplitter.ZeroLegAmount.selector, 0));
        splitter.split(address(usdc), _legs2(_plain(eoaA, 1), _plain(eoaB, 9999)));
    }

    function test_Revert_OffsetTooSmall() public {
        usdc.mint(address(splitter), 1_000_000);
        Leg memory hook = Leg({target: address(hookTarget), shareBps: 10_000, amountOffset: 3, data: hex"11223344"});
        Leg[] memory legs = new Leg[](1);
        legs[0] = hook;
        vm.expectRevert(abi.encodeWithSelector(IPayoutSplitter.InvalidAmountOffset.selector, 0));
        splitter.split(address(usdc), legs);
    }

    function test_Revert_OffsetPastEnd() public {
        usdc.mint(address(splitter), 1_000_000);
        bytes memory data = abi.encodeCall(hookTarget.sink, (bytes32(0), 0)); // 4 + 64 = 68 bytes
        Leg memory hook = Leg({target: address(hookTarget), shareBps: 10_000, amountOffset: 37, data: data});
        Leg[] memory legs = new Leg[](1);
        legs[0] = hook;
        vm.expectRevert(abi.encodeWithSelector(IPayoutSplitter.InvalidAmountOffset.selector, 0));
        splitter.split(address(usdc), legs);
    }

    function test_Revert_ZeroTarget() public {
        usdc.mint(address(splitter), 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(IPayoutSplitter.ZeroTarget.selector, 1));
        splitter.split(address(usdc), _legs2(_plain(eoaA, 5000), _plain(address(0), 5000)));
    }

    function test_Revert_NativeRecipientRejects() public {
        RevertingTarget bad = new RevertingTarget();
        vm.deal(address(splitter), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IPayoutSplitter.NativeTransferFailed.selector, 1));
        splitter.split(address(0), _legs2(_plain(eoaA, 5000), _plain(address(bad), 5000)));
    }

    function test_Revert_HookRevertBubblesReason() public {
        RevertingTarget bad = new RevertingTarget();
        usdc.mint(address(splitter), 1_000_000);
        Leg memory hook = Leg({
            target: address(bad),
            shareBps: 10_000,
            amountOffset: 4,
            data: abi.encodeCall(bad.fail, (0))
        });
        Leg[] memory legs = new Leg[](1);
        legs[0] = hook;
        vm.expectRevert(abi.encodeWithSelector(RevertingTarget.Nope.selector, 2));
        splitter.split(address(usdc), legs);
    }

    function test_Revert_DustLeft_WhenHookDoesNotPull() public {
        usdc.mint(address(splitter), 1_000_000);
        Leg memory hook = Leg({
            target: address(hookTarget),
            shareBps: 5000,
            amountOffset: 68,
            data: abi.encodeCall(hookTarget.ignore, (address(usdc), bytes32(0), 0))
        });
        vm.expectRevert(abi.encodeWithSelector(IPayoutSplitter.DustLeft.selector, 500_000));
        splitter.split(address(usdc), _legs2(_plain(eoaA, 5000), hook));
    }

    // --------------------------------------------------------------------- //
    //                     Atomicity in an ERC-7821 batch                     //
    // --------------------------------------------------------------------- //

    /// @dev Full batch: EIP-3009 receive -> transfer to splitter -> split with a
    ///      depository hook while the depository is PAUSED. The hook reverts, so
    ///      the entire batch (including the gasless receive) must roll back.
    function test_Atomicity_HookRevertRollsBackWholeBatch() public {
        MockERC7821Executor calibur = new MockERC7821Executor();
        (address user, uint256 userPk) = makeAddrAndKey("payer");
        usdc.mint(user, 1_000_000);

        vm.prank(depositoryOwner);
        depository.pause();

        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(0xA70));
        (uint8 v, bytes32 r, bytes32 s) =
            _signAuth(userPk, usdc.DOMAIN_SEPARATOR(), user, address(calibur), 1_000_000, 0, validBefore, nonce);

        Leg[] memory legs =
            _legs3(_plain(eoaA, 1234), _plain(eoaB, 3766), _depositErc20Hook(bytes32(uint256(0xFA11)), 5000));

        Call[] memory calls = new Call[](3);
        calls[0] = Call({
            to: address(usdc),
            value: 0,
            data: abi.encodeCall(
                IERC3009USDC.receiveWithAuthorization,
                (user, address(calibur), 1_000_000, 0, validBefore, nonce, v, r, s)
            )
        });
        calls[1] = Call({to: address(usdc), value: 0, data: abi.encodeCall(IERC20.transfer, (address(splitter), 1_000_000))});
        calls[2] =
            Call({to: address(splitter), value: 0, data: abi.encodeCall(IPayoutSplitter.split, (address(usdc), legs))});

        vm.expectRevert();
        calibur.execute(BATCH_MODE, abi.encode(calls));

        assertEq(usdc.balanceOf(user), 1_000_000, "user USDC untouched");
        assertFalse(usdc.authorizationState(user, nonce), "auth nonce NOT consumed");
        assertEq(usdc.balanceOf(address(splitter)), 0, "splitter empty");
        assertEq(usdc.balanceOf(eoaA), 0, "no partial payout");
    }

    /// @dev Happy-path batch: same shape, depository live -> everything lands.
    function test_Batch_HappyPath_SplitWithDepositoryHook() public {
        MockERC7821Executor calibur = new MockERC7821Executor();
        (address user, uint256 userPk) = makeAddrAndKey("payer2");
        usdc.mint(user, 1_000_000);

        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(0xA71));
        (uint8 v, bytes32 r, bytes32 s) =
            _signAuth(userPk, usdc.DOMAIN_SEPARATOR(), user, address(calibur), 1_000_000, 0, validBefore, nonce);

        Leg[] memory legs =
            _legs3(_plain(eoaA, 1234), _plain(eoaB, 3766), _depositErc20Hook(bytes32(uint256(0x600D)), 5000));

        Call[] memory calls = new Call[](3);
        calls[0] = Call({
            to: address(usdc),
            value: 0,
            data: abi.encodeCall(
                IERC3009USDC.receiveWithAuthorization,
                (user, address(calibur), 1_000_000, 0, validBefore, nonce, v, r, s)
            )
        });
        calls[1] = Call({to: address(usdc), value: 0, data: abi.encodeCall(IERC20.transfer, (address(splitter), 1_000_000))});
        calls[2] =
            Call({to: address(splitter), value: 0, data: abi.encodeCall(IPayoutSplitter.split, (address(usdc), legs))});

        calibur.execute(BATCH_MODE, abi.encode(calls));

        assertEq(usdc.balanceOf(user), 0, "user paid");
        assertEq(usdc.balanceOf(eoaA), 123_400);
        assertEq(usdc.balanceOf(eoaB), 376_600);
        assertEq(usdc.balanceOf(receiver), 500_000, "depository leg landed");
        assertEq(usdc.balanceOf(address(splitter)), 0, "zero dust");
        assertEq(usdc.balanceOf(address(calibur)), 0, "executor empty");
    }

    // --------------------------------------------------------------------- //
    //                              Reentrancy                                //
    // --------------------------------------------------------------------- //

    /// @dev A malicious plain-leg recipient re-enters split() mid-loop and siphons
    ///      the remaining balance. The outer split must then fail (its later legs
    ///      can't be paid / terminal check fires) -> whole tx reverts, no theft.
    function test_Reentrancy_MaliciousLegCannotProfit_OuterReverts() public {
        ReentrantTarget attacker = new ReentrantTarget(address(splitter));
        vm.deal(address(splitter), 1 ether);
        // Delta-based assertions: on a Sepolia fork these deterministic test
        // addresses can carry pre-existing live-network balances.
        uint256 attackerBefore = address(attacker).balance;
        uint256 eoaABefore = eoaA.balance;

        // attacker is FIRST leg: its receive() re-enters and drains the remaining
        // 0.75 ether to itself; the second leg then cannot be paid.
        vm.expectRevert();
        splitter.split(address(0), _legs2(_plain(address(attacker), 2500), _plain(eoaA, 7500)));

        // Atomicity: the revert undid everything, including the attacker's gains.
        assertEq(address(attacker).balance, attackerBefore, "attacker kept nothing");
        assertEq(eoaA.balance, eoaABefore, "second leg unpaid");
        assertEq(address(splitter).balance, 1 ether, "splitter balance restored by revert");
    }
}
