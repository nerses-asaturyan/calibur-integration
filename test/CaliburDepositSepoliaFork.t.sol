// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {console2} from "forge-std/console2.sol";
import {CaliburDepositTestBase} from "./CaliburDepositTestBase.sol";

import {CaliburDepositBatch} from "../src/CaliburDepositBatch.sol";
import {IERC3009USDC} from "../src/interfaces/IERC3009USDC.sol";
import {ILayerswapDepository} from "../src/interfaces/ILayerswapDepository.sol";
import {MockERC7821Executor} from "./mocks/MockERC7821Executor.sol";

/// @notice Integration tests against a live Ethereum Sepolia fork using the real
///         Circle USDC (EIP-3009) and the real LayerswapDepository. There is no
///         swap, so these tests do NOT depend on any DEX liquidity.
///
/// Run:  forge test --fork-url $SEPOLIA_RPC_URL --match-contract SepoliaFork -vvv
///
/// If SEPOLIA_RPC_URL is unset, every test is SKIPPED (not failed).
///
/// @dev A minimal ERC-7821 executor (MockERC7821Executor) is deployed on the fork
///      to stand in for the Calibur account: it runs the exact same `Call[]` batch
///      Calibur would, with `msg.sender == executor`. This lets us exercise the
///      real USDC + real depository without needing a deployed Calibur or its
///      signed-batch machinery. To target a real Calibur, set CALIBUR_EXECUTOR and
///      submit the same batch via Calibur's signed entrypoint.
contract CaliburDepositSepoliaForkTest is CaliburDepositTestBase {
    address internal constant DEFAULT_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant DEFAULT_DEPOSITORY = 0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4;

    bytes32 internal constant BATCH_MODE = 0x0100000000000000000000000000000000000000000000000000000000000000;

    IERC3009USDC internal usdc;
    ILayerswapDepository internal depository;
    MockERC7821Executor internal calibur;

    address internal user;
    uint256 internal userPk;
    address internal receiver = makeAddr("forkReceiver");
    address internal broadcaster = makeAddr("forkBroadcaster");

    uint256 internal constant USER_START = 1_000_000_000; // 1,000 USDC
    uint256 internal constant AMOUNT = 10_000_000; // 10 USDC
    bytes32 internal constant DEPOSIT_ID = bytes32(uint256(0xCAFE));

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("SEPOLIA_RPC_URL not set -> Sepolia fork tests skipped.");
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;

        usdc = IERC3009USDC(vm.envOr("USDC_SEPOLIA", DEFAULT_USDC));
        depository = ILayerswapDepository(vm.envOr("LAYERSWAP_DEPOSITORY", DEFAULT_DEPOSITORY));
        calibur = new MockERC7821Executor();

        (user, userPk) = makeAddrAndKey("forkUser");
        deal(address(usdc), user, USER_START);

        // Whitelist our receiver through the depository owner.
        address owner = depository.owner();
        vm.prank(owner);
        depository.addToWhitelist(receiver);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
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
        return keccak256(abi.encodePacked("forkNonce", i));
    }

    // --------------------------------------------------------------------- //
    //                                Tests                                  //
    // --------------------------------------------------------------------- //

    function testFork_HappyPath() public onlyFork {
        if (depository.paused()) {
            console2.log("Depository is paused on the fork -> happy path skipped.");
            vm.skip(true);
            return;
        }

        uint256 userBefore = usdc.balanceOf(user);
        uint256 receiverBefore = usdc.balanceOf(receiver);

        CaliburDepositBatch.FlowParams memory p = _flow(receiver, _nonce(1));
        _submit(p);

        assertEq(usdc.balanceOf(user), userBefore - AMOUNT, "user spent exactly amount");
        assertEq(usdc.balanceOf(receiver), receiverBefore + AMOUNT, "receiver got USDC");
        assertEq(usdc.balanceOf(address(calibur)), 0, "no USDC dust in calibur");
        assertEq(usdc.allowance(address(calibur), address(depository)), 0, "allowance fully consumed");
        assertTrue(usdc.authorizationState(user, _nonce(1)), "auth consumed");
        console2.log("Fork happy path OK. USDC deposited:", AMOUNT);
    }

    function testFork_Revert_InvalidSignature() public onlyFork {
        CaliburDepositBatch.FlowParams memory p = _flow(receiver, _nonce(2));
        p.s = bytes32(uint256(p.s) ^ 1);

        uint256 userBefore = usdc.balanceOf(user);
        vm.expectRevert();
        _submit(p);

        assertEq(usdc.balanceOf(user), userBefore, "USDC untouched on bad sig");
        assertFalse(usdc.authorizationState(user, _nonce(2)), "nonce unused");
    }

    function testFork_Revert_ExpiredAuthorization() public onlyFork {
        uint256 validBefore = block.timestamp + 100;
        bytes32 nonce = _nonce(3);
        (uint8 v, bytes32 r, bytes32 s) =
            _signAuth(userPk, usdc.DOMAIN_SEPARATOR(), user, address(calibur), AMOUNT, 0, validBefore, nonce);
        CaliburDepositBatch.FlowParams memory p = _flow(receiver, nonce);
        p.validBefore = validBefore;
        (p.v, p.r, p.s) = (v, r, s);

        vm.warp(validBefore + 1);

        uint256 userBefore = usdc.balanceOf(user);
        vm.expectRevert();
        _submit(p);
        assertEq(usdc.balanceOf(user), userBefore, "USDC untouched on expiry");
    }

    function testFork_Revert_DepositReceiverNotWhitelisted() public onlyFork {
        address bad = makeAddr("notWhitelistedFork");
        CaliburDepositBatch.FlowParams memory p = _flow(bad, _nonce(4));

        uint256 userBefore = usdc.balanceOf(user);
        vm.expectRevert(ILayerswapDepository.NotWhitelisted.selector);
        _submit(p);

        // Atomicity: failed deposit rolls back the USDC pull.
        assertEq(usdc.balanceOf(user), userBefore, "USDC untouched when deposit reverts");
        assertFalse(usdc.authorizationState(user, _nonce(4)), "auth NOT consumed");
        assertEq(usdc.balanceOf(address(calibur)), 0, "no USDC stuck");
    }

    function testFork_Atomicity_UserUsdcNotConsumedWhenPaused() public onlyFork {
        address owner = depository.owner();
        vm.prank(owner);
        (bool ok,) = address(depository).call(abi.encodeWithSignature("pause()"));
        if (!ok) {
            console2.log("Could not pause depository (owner mismatch?) -> skipping.");
            vm.skip(true);
            return;
        }

        uint256 userBefore = usdc.balanceOf(user);
        bytes32 nonce = _nonce(5);
        CaliburDepositBatch.FlowParams memory p = _flow(receiver, nonce);

        vm.expectRevert();
        _submit(p);

        assertEq(usdc.balanceOf(user), userBefore, "user USDC untouched");
        assertFalse(usdc.authorizationState(user, nonce), "auth NOT consumed");
    }
}
