// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {console2} from "forge-std/console2.sol";
import {CaliburDepositTestBase} from "./CaliburDepositTestBase.sol";

import {PayoutSplitter} from "../src/PayoutSplitter.sol";
import {IPayoutSplitter, Leg} from "../src/interfaces/IPayoutSplitter.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Call} from "../src/interfaces/IERC7821.sol";
import {IERC3009USDC} from "../src/interfaces/IERC3009USDC.sol";
import {ILayerswapDepository} from "../src/interfaces/ILayerswapDepository.sol";
import {MockERC7821Executor} from "./mocks/MockERC7821Executor.sol";

/// @notice Sepolia-fork tests wiring PayoutSplitter to the REAL Circle USDC and
///         the REAL ORIGINAL LayerswapDepository (the unextended one, no
///         depositERC20All) — proving the call-hook makes dynamic-amount deposits
///         possible against it.
///
/// Run:  forge test --fork-url $SEPOLIA_RPC_URL --match-contract PayoutSplitterSepoliaFork -vvv
/// If SEPOLIA_RPC_URL is unset, every test is SKIPPED (not failed).
contract PayoutSplitterSepoliaForkTest is CaliburDepositTestBase {
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant ORIGINAL_DEPOSITORY = 0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4;
    bytes32 internal constant BATCH_MODE = 0x0100000000000000000000000000000000000000000000000000000000000000;
    uint256 internal constant NO_SUB = type(uint256).max;

    PayoutSplitter internal splitter;
    ILayerswapDepository internal depository;
    IERC3009USDC internal usdc;

    address internal eoaA = makeAddr("splitEoaA");
    address internal eoaB = makeAddr("splitEoaB");
    address internal receiver = makeAddr("splitReceiver");

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("SEPOLIA_RPC_URL not set -> Sepolia fork tests skipped.");
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;

        splitter = new PayoutSplitter();
        usdc = IERC3009USDC(USDC);
        depository = ILayerswapDepository(ORIGINAL_DEPOSITORY);

        vm.prank(depository.owner());
        depository.addToWhitelist(receiver);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _legs3(Leg memory a, Leg memory b, Leg memory c) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](3);
        (legs[0], legs[1], legs[2]) = (a, b, c);
    }

    function _plain(address target, uint96 bps) internal pure returns (Leg memory) {
        return Leg({target: target, shareBps: bps, amountOffset: NO_SUB, data: ""});
    }

    function testFork_UsdcSplit_OriginalDepositoryHook() public onlyFork {
        if (depository.paused()) {
            vm.skip(true);
            return;
        }
        // The live receiver used by the flows must already be whitelisted.
        assertTrue(
            depository.isWhitelisted(0x7f8bad12Da9a9382C9AD82cA732578755F739E83), "live DEPOSIT_RECEIVER whitelisted"
        );

        deal(USDC, address(splitter), 10_000_000); // 10 USDC
        bytes32 id = bytes32(uint256(0xF0F0));
        uint256 receiverBefore = IERC20(USDC).balanceOf(receiver);

        Leg memory hook = Leg({
            target: ORIGINAL_DEPOSITORY,
            shareBps: 5000,
            amountOffset: 100, // depositERC20(bytes32,address,address,uint256): 4 + 3*32
            data: abi.encodeCall(ILayerswapDepository.depositERC20, (id, USDC, receiver, 0))
        });

        splitter.split(USDC, _legs3(_plain(eoaA, 1234), _plain(eoaB, 3766), hook));

        assertEq(IERC20(USDC).balanceOf(eoaA), 1_234_000, "12.34%");
        assertEq(IERC20(USDC).balanceOf(eoaB), 3_766_000, "37.66%");
        assertEq(
            IERC20(USDC).balanceOf(receiver) - receiverBefore, 5_000_000, "original depository forwarded the remainder"
        );
        assertEq(IERC20(USDC).balanceOf(address(splitter)), 0, "zero dust");
        assertEq(IERC20(USDC).allowance(address(splitter), ORIGINAL_DEPOSITORY), 0, "zero residual allowance");
    }

    function testFork_NativeSplit_DepositNativeHook() public onlyFork {
        if (depository.paused()) {
            vm.skip(true);
            return;
        }
        vm.deal(address(splitter), 1 ether);
        bytes32 id = bytes32(uint256(0xF1F1));
        uint256 receiverBefore = receiver.balance;

        Leg memory hook = Leg({
            target: ORIGINAL_DEPOSITORY,
            shareBps: 5000,
            amountOffset: NO_SUB, // amount travels as msg.value only
            data: abi.encodeCall(ILayerswapDepository.depositNative, (id, receiver))
        });

        splitter.split(address(0), _legs3(_plain(eoaA, 1234), _plain(eoaB, 3766), hook));

        assertEq(eoaA.balance, 0.1234 ether);
        assertEq(eoaB.balance, 0.3766 ether);
        assertEq(receiver.balance - receiverBefore, 0.5 ether, "depositNative forwarded the remainder");
        assertEq(address(splitter).balance, 0, "zero dust");
    }

    /// @dev The demo batch shape minus the router (no DEX dependency): real USDC
    ///      EIP-3009 gasless inbound -> transfer to splitter -> 3-way split with
    ///      the ORIGINAL depository hook.
    function testFork_FullBatch_ReceiveAuth_Transfer_Split() public onlyFork {
        if (depository.paused()) {
            vm.skip(true);
            return;
        }
        MockERC7821Executor calibur = new MockERC7821Executor();
        (address user, uint256 userPk) = makeAddrAndKey("splitPayer");
        deal(USDC, user, 10_000_000);

        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("splitFlowNonce");
        (uint8 v, bytes32 r, bytes32 s) =
            _signAuth(userPk, usdc.DOMAIN_SEPARATOR(), user, address(calibur), 10_000_000, 0, validBefore, nonce);

        Leg memory hook = Leg({
            target: ORIGINAL_DEPOSITORY,
            shareBps: 5000,
            amountOffset: 100,
            data: abi.encodeCall(ILayerswapDepository.depositERC20, (bytes32(uint256(0xF2F2)), USDC, receiver, 0))
        });
        Leg[] memory legs = _legs3(_plain(eoaA, 1234), _plain(eoaB, 3766), hook);

        Call[] memory calls = new Call[](3);
        calls[0] = Call({
            to: USDC,
            value: 0,
            data: abi.encodeCall(
                IERC3009USDC.receiveWithAuthorization, (user, address(calibur), 10_000_000, 0, validBefore, nonce, v, r, s)
            )
        });
        calls[1] = Call({to: USDC, value: 0, data: abi.encodeCall(IERC20.transfer, (address(splitter), 10_000_000))});
        calls[2] = Call({to: address(splitter), value: 0, data: abi.encodeCall(IPayoutSplitter.split, (USDC, legs))});

        uint256 receiverBefore = IERC20(USDC).balanceOf(receiver);
        calibur.execute(BATCH_MODE, abi.encode(calls));

        assertEq(IERC20(USDC).balanceOf(user), 0, "user paid gaslessly");
        assertEq(IERC20(USDC).balanceOf(eoaA), 1_234_000);
        assertEq(IERC20(USDC).balanceOf(eoaB), 3_766_000);
        assertEq(IERC20(USDC).balanceOf(receiver) - receiverBefore, 5_000_000);
        assertEq(IERC20(USDC).balanceOf(address(splitter)), 0, "zero dust in splitter");
        assertEq(IERC20(USDC).balanceOf(address(calibur)), 0, "zero dust in executor");
        console2.log("Fork full-batch split OK: 12.34% / 37.66% / 50% -> original depository");
    }
}
