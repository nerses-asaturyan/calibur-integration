// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {CaliburDepositTestBase} from "./CaliburDepositTestBase.sol";

import {CaliburDepositBatch} from "../src/CaliburDepositBatch.sol";
import {Call} from "../src/interfaces/IERC7821.sol";

import {MockERC3009USDC} from "./mocks/MockERC3009USDC.sol";
import {MockERC7821Executor} from "./mocks/MockERC7821Executor.sol";
import {LayerswapDepository} from "./external/LayerswapDepository.sol";

/// @notice Deterministic, network-free coverage of the atomic Calibur batch
///         (EIP-3009 receive → Layerswap deposit, no swap) using mock USDC + a
///         minimal ERC-7821 executor standing in for Calibur + the genuine
///         LayerswapDepository logic. The deposited token IS USDC.
contract CaliburDepositLocalTest is CaliburDepositTestBase {
    bytes32 internal constant BATCH_MODE = 0x0100000000000000000000000000000000000000000000000000000000000000;

    MockERC3009USDC internal usdc;
    MockERC7821Executor internal calibur; // stands in for the Calibur account
    LayerswapDepository internal depository;

    address internal user;
    uint256 internal userPk;
    address internal receiver = makeAddr("receiver");
    address internal depOwner = makeAddr("depOwner");
    address internal broadcaster = makeAddr("broadcaster");

    uint256 internal constant USER_START = 1_000_000_000; // 1,000 USDC
    uint256 internal constant AMOUNT = 10_000_000; // 10 USDC
    bytes32 internal constant DEPOSIT_ID = bytes32(uint256(0xABCDEF));

    function setUp() public {
        (user, userPk) = makeAddrAndKey("user");

        usdc = new MockERC3009USDC();
        calibur = new MockERC7821Executor();

        address[] memory initial = new address[](1);
        initial[0] = receiver;
        depository = new LayerswapDepository(depOwner, initial);

        usdc.mint(user, USER_START);
    }

    // --------------------------------------------------------------------- //
    //                              Helpers                                  //
    // --------------------------------------------------------------------- //

    function _flow(address recv, bytes32 nonce) internal view returns (CaliburDepositBatch.FlowParams memory p) {
        uint256 validBefore = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signAuth(userPk, usdc.DOMAIN_SEPARATOR(), user, address(calibur), AMOUNT, 0, validBefore, nonce);
        p = CaliburDepositBatch.FlowParams({
            usdc: address(usdc),
            depository: address(depository),
            executor: address(calibur),
            user: user,
            amount: AMOUNT,
            validAfter: 0,
            validBefore: validBefore,
            nonce: nonce,
            v: v,
            r: r,
            s: s,
            receiver: recv,
            depositId: DEPOSIT_ID
        });
    }

    function _submit(CaliburDepositBatch.FlowParams memory p) internal {
        vm.prank(broadcaster);
        calibur.execute(BATCH_MODE, CaliburDepositBatch.encode(p));
    }

    function _nonce(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("nonce", i));
    }

    function _assertUntouched(bytes32 nonce) internal view {
        assertEq(usdc.balanceOf(user), USER_START, "user USDC unchanged");
        assertFalse(usdc.authorizationState(user, nonce), "auth not consumed");
        assertEq(usdc.balanceOf(receiver), 0, "receiver unchanged");
        assertEq(usdc.balanceOf(address(calibur)), 0, "no USDC stuck in calibur");
        assertEq(usdc.allowance(address(calibur), address(depository)), 0, "no residual allowance");
    }

    // --------------------------------------------------------------------- //
    //                            Happy path                                 //
    // --------------------------------------------------------------------- //

    function test_HappyPath_ViaCaliburBatch() public {
        CaliburDepositBatch.FlowParams memory p = _flow(receiver, _nonce(1));

        vm.expectEmit(true, true, true, true, address(depository));
        emit LayerswapDepository.Deposited(DEPOSIT_ID, address(usdc), receiver, AMOUNT);

        _submit(p);

        assertEq(usdc.balanceOf(user), USER_START - AMOUNT, "user spent amount");
        assertEq(usdc.balanceOf(receiver), AMOUNT, "receiver got USDC");
        assertEq(usdc.balanceOf(address(calibur)), 0, "no USDC dust in calibur");
        assertEq(usdc.allowance(address(calibur), address(depository)), 0, "allowance fully consumed");
        assertTrue(usdc.authorizationState(user, _nonce(1)), "nonce used");
    }

    /// @dev The batch must go through the Calibur account: USDC's receive variant
    ///      requires msg.sender == to. A foreign caller of receiveWithAuthorization
    ///      (to = calibur) is rejected.
    function test_ReceiveAuth_RejectsNonPayeeCaller() public {
        CaliburDepositBatch.FlowParams memory p = _flow(receiver, _nonce(2));
        Call[] memory calls = CaliburDepositBatch.build(p);

        // Broadcaster tries to run the receive call directly (msg.sender != calibur).
        vm.prank(broadcaster);
        vm.expectRevert(MockERC3009USDC.CallerMustBePayee.selector);
        (bool ok,) = calls[0].to.call(calls[0].data);
        ok; // silence unused
    }

    // --------------------------------------------------------------------- //
    //                          Revert / safety                              //
    // --------------------------------------------------------------------- //

    function test_Revert_InvalidSignature() public {
        CaliburDepositBatch.FlowParams memory p = _flow(receiver, _nonce(3));
        p.s = bytes32(uint256(p.s) ^ 1);

        vm.expectRevert(); // MockERC3009USDC.InvalidSignature
        _submit(p);

        _assertUntouched(_nonce(3));
    }

    function test_Revert_ExpiredAuthorization() public {
        bytes32 nonce = _nonce(4);
        uint256 validBefore = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) =
            _signAuth(userPk, usdc.DOMAIN_SEPARATOR(), user, address(calibur), AMOUNT, 0, validBefore, nonce);
        CaliburDepositBatch.FlowParams memory p = _flow(receiver, nonce);
        p.validBefore = validBefore;
        (p.v, p.r, p.s) = (v, r, s);

        vm.warp(validBefore + 1);

        vm.expectRevert(MockERC3009USDC.AuthExpired.selector);
        _submit(p);

        _assertUntouched(nonce);
    }

    function test_Revert_DepositReceiverNotWhitelisted() public {
        CaliburDepositBatch.FlowParams memory p = _flow(makeAddr("notWhitelisted"), _nonce(5));

        vm.expectRevert(LayerswapDepository.NotWhitelisted.selector);
        _submit(p);

        _assertUntouched(_nonce(5));
    }

    function test_Revert_DepositPaused() public {
        vm.prank(depOwner);
        depository.pause();

        CaliburDepositBatch.FlowParams memory p = _flow(receiver, _nonce(6));

        vm.expectRevert(); // Pausable.EnforcedPause
        _submit(p);

        _assertUntouched(_nonce(6));
    }

    /// @notice Core atomicity property: when the deposit (final call) reverts, the
    ///         EIP-3009 receive is rolled back — user's USDC is NOT consumed and
    ///         the authorization nonce stays unused.
    function test_Atomicity_UserUsdcNotConsumedWhenDepositFails() public {
        vm.prank(depOwner);
        depository.pause();

        uint256 before = usdc.balanceOf(user);
        bytes32 nonce = _nonce(7);
        CaliburDepositBatch.FlowParams memory p = _flow(receiver, nonce);

        vm.expectRevert();
        _submit(p);

        assertEq(usdc.balanceOf(user), before, "user USDC untouched");
        assertFalse(usdc.authorizationState(user, nonce), "authorization NOT consumed");
        assertEq(usdc.balanceOf(receiver), 0, "receiver got nothing");
    }

    function test_Revert_ReusedNonce() public {
        // First flow succeeds and consumes the nonce.
        CaliburDepositBatch.FlowParams memory p = _flow(receiver, _nonce(8));
        _submit(p);
        assertTrue(usdc.authorizationState(user, _nonce(8)), "nonce consumed");

        // Replaying the exact same authorization must fail.
        vm.expectRevert(MockERC3009USDC.AuthUsed.selector);
        _submit(p);
    }
}
