// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Call, IERC7821} from "../src/interfaces/IERC7821.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IERC3009USDC} from "../src/interfaces/IERC3009USDC.sol";
import {ILayerswapDepository} from "../src/interfaces/ILayerswapDepository.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IQuoterV2} from "../src/interfaces/IQuoterV2.sol";
import {IPayoutSplitter, Leg} from "../src/interfaces/IPayoutSplitter.sol";

/// @title CaliburSplitFlowScript (TX 4)
/// @notice The generic-splitter demo: ONE atomic gasless transaction that proves
///         BOTH an ERC-20 split and a NATIVE-ETH split through the stateless
///         PayoutSplitter — with arbitrary (non-round) percentages and the
///         ORIGINAL, UNEXTENDED LayerswapDepository (no depositERC20All) fed via
///         the splitter's generic call hooks. Zero dust in every token.
///
/// ONE atomic 5-call Calibur batch:
///   1. USDC.receiveWithAuthorization(user -> executor)      // gasless inbound
///   2. USDC.transfer(universalRouter, amountIn)             // pre-fund router
///   3. UniversalRouter.execute():
///        V3_SWAP_EXACT_IN USDC -> WETH  (0.30%)             \
///        V3_SWAP_EXACT_IN WETH -> UNI   (0.30%)              } CONTRACT_BALANCE
///        V3_SWAP_EXACT_IN UNI  -> WETH  (0.05%)             /
///        PAY_PORTION  WETH portion (wethPortionBps) -> SPLITTER   // ERC-20 half
///        UNWRAP_WETH  the rest -> SPLITTER as NATIVE ETH          // native half
///        (ordering load-bearing: UNWRAP consumes the router's whole remaining
///         WETH balance, so PAY_PORTION must run first)
///   4. splitter.split(WETH,  [EOA-A 12.34%, EOA-B 37.66%,
///        hook: ORIGINAL depository depositERC20 (amount substituted at offset
///        100) 50% remainder])
///   5. splitter.split(ETH(0),[EOA-A 12.34%, EOA-B 37.66%,
///        hook: ORIGINAL depository depositNative (amount = msg.value,
///        NO_SUBSTITUTION) 50% remainder])
///
/// ZERO DUST: splitter legs are % of its live balance with the LAST leg taking
/// the arithmetic remainder; the splitter's terminal check reverts if anything
/// stays; the router is fully drained by PAY_PORTION + UNWRAP_WETH; the executor
/// never holds output at all.
///
/// Usage:
///   forge script script/CaliburSplitFlow.s.sol:CaliburSplitFlowScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract CaliburSplitFlowScript is Script {
    bytes32 internal constant ERC7821_BATCH_MODE =
        0x0100000000000000000000000000000000000000000000000000000000000000;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    // Universal Router command bytes (Uniswap Commands.sol).
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant PAY_PORTION = 0x06;
    bytes1 internal constant UNWRAP_WETH = 0x0c;

    // Universal Router sentinels (Constants.sol).
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;
    address internal constant ADDRESS_THIS = address(2);

    uint256 internal constant NO_SUB = type(uint256).max;
    // depositERC20(bytes32 id, address token, address receiver, uint256 amount): 4 + 3*32.
    uint256 internal constant DEPOSIT_ERC20_AMOUNT_OFFSET = 100;

    // Default Sepolia infra (all overridable via env).
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant DEFAULT_UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant DEFAULT_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address internal constant DEFAULT_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
    // The ORIGINAL Layerswap depository — deliberately the UNEXTENDED one.
    address internal constant DEFAULT_ORIGINAL_DEPOSITORY = 0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4;

    struct Cfg {
        address usdc;
        address weth;
        address uni;
        address router;
        address quoter;
        address splitter;
        address depository; // ORIGINAL depository (hook target)
        address receiver; // whitelisted Layerswap receiver
        address eoaA; // split leg 1
        address eoaB; // split leg 2
        address executor;
        address user;
        uint24 fee1; // USDC/WETH
        uint24 fee2; // WETH/UNI
        uint24 fee3; // UNI/WETH
        uint256 amountIn;
        uint256 bpsA; // leg 1 share
        uint256 bpsB; // leg 2 share (leg 3 = depository remainder, by sum)
        uint256 wethPortionBps; // share of the final WETH split as ERC-20 (rest = native)
        uint256 slippageBps;
        bytes32 depositIdErc20;
        bytes32 depositIdNative;
    }

    struct Mins {
        uint256 weth1; // hop 1: USDC -> WETH
        uint256 uni; // hop 2: WETH -> UNI
        uint256 weth2; // hop 3: UNI -> WETH (the total to be divided)
        uint256 ethFloor; // UNWRAP_WETH min-out (native portion)
    }

    function run() external {
        uint256 broadcasterPk = vm.envUint("PRIVATE_KEY"); // relayer/sponsor (delegated)
        uint256 userPk = vm.envUint("USER_PRIVATE_KEY"); // payer (signs EIP-3009)

        Cfg memory c = _loadCfg(broadcasterPk, userPk);
        _validate(c);
        _preflight(c);

        (bytes memory routerCall, Mins memory m) = _buildRouterCall(c);
        (Call[] memory calls, bytes32 authNonce) = _finalizeBatch(c, userPk, routerCall);

        vm.startBroadcast(broadcasterPk);
        IERC7821(c.executor).execute(ERC7821_BATCH_MODE, abi.encode(calls));
        vm.stopBroadcast();

        _logSummary(c, m, authNonce);
    }

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------

    function _loadCfg(uint256 broadcasterPk, uint256 userPk) internal view returns (Cfg memory c) {
        c.usdc = vm.envAddress("USDC_SEPOLIA");
        c.weth = vm.envOr("WETH_SEPOLIA", DEFAULT_WETH);
        c.uni = vm.envOr("UNI_SEPOLIA", DEFAULT_UNI);
        c.router = vm.envOr("UNIVERSAL_ROUTER", DEFAULT_ROUTER);
        c.quoter = vm.envOr("UNISWAP_QUOTER", DEFAULT_QUOTER);
        c.splitter = vm.envAddress("PAYOUT_SPLITTER");
        c.depository = vm.envOr("ORIGINAL_DEPOSITORY", DEFAULT_ORIGINAL_DEPOSITORY);
        c.receiver = vm.envAddress("DEPOSIT_RECEIVER");

        c.user = vm.addr(userPk);
        address userEnv = vm.envOr("USER_ADDRESS", address(0));
        require(userEnv == address(0) || userEnv == c.user, "USER_ADDRESS != addr(USER_PRIVATE_KEY)");
        c.executor = vm.envOr("CALIBUR_EXECUTOR", vm.addr(broadcasterPk));

        c.eoaA = vm.envOr("PAYOUT_EOA_1", vm.envAddress("FEE_RECIPIENT"));
        c.eoaB = vm.envOr("PAYOUT_EOA_2", c.user);

        c.fee1 = uint24(vm.envOr("POOL_FEE_1", uint256(3000))); // USDC/WETH
        c.fee2 = uint24(vm.envOr("POOL_FEE_2", uint256(3000))); // WETH/UNI
        c.fee3 = uint24(vm.envOr("POOL_FEE_3", uint256(500))); // UNI/WETH

        c.amountIn = vm.envUint("AMOUNT_IN");
        c.bpsA = vm.envOr("SPLIT_BPS_1", uint256(1234)); // 12.34%
        c.bpsB = vm.envOr("SPLIT_BPS_2", uint256(3766)); // 37.66% (depository gets 50.00%)
        c.wethPortionBps = vm.envOr("WETH_PORTION_BPS", uint256(5000));
        c.slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100));
        c.depositIdErc20 = bytes32(vm.randomUint());
        c.depositIdNative = bytes32(vm.randomUint());
    }

    function _validate(Cfg memory c) internal pure {
        require(c.usdc != address(0), "USDC_SEPOLIA is zero");
        require(c.weth != address(0), "WETH is zero");
        require(c.uni != address(0), "UNI is zero");
        require(c.router != address(0), "router is zero");
        require(c.quoter != address(0), "quoter is zero");
        require(c.splitter != address(0), "PAYOUT_SPLITTER is zero");
        require(c.depository != address(0), "ORIGINAL_DEPOSITORY is zero");
        require(c.receiver != address(0), "DEPOSIT_RECEIVER is zero");
        require(c.eoaA != address(0) && c.eoaB != address(0), "payout EOA is zero");
        require(c.eoaA != c.eoaB, "the two payout EOAs must differ");
        require(c.executor != address(0), "executor is zero");
        require(c.user != c.executor, "payer (user) must differ from executor");
        require(c.amountIn > 0, "AMOUNT_IN must be > 0");
        require(c.bpsA > 0 && c.bpsB > 0 && c.bpsA + c.bpsB < 10_000, "split bps must be >0 and sum < 10000");
        require(c.wethPortionBps > 0 && c.wethPortionBps < 10_000, "WETH_PORTION_BPS must be in (0,10000)");
        require(c.slippageBps < 10_000, "SLIPPAGE_BPS must be < 10000");
    }

    function _preflight(Cfg memory c) internal view {
        ILayerswapDepository dep = ILayerswapDepository(c.depository);
        if (dep.paused()) {
            console2.log("WARNING: ORIGINAL depository is paused; both hooks will revert (batch reverts atomically).");
        }
        if (!dep.isWhitelisted(c.receiver)) {
            console2.log("WARNING: DEPOSIT_RECEIVER is NOT whitelisted on the ORIGINAL depository.");
        }
        if (c.executor.code.length == 0) {
            console2.log("WARNING: executor has NO code -> not delegated to Calibur. Run EnableDelegation.s.sol first.");
        }
        if (c.splitter.code.length == 0) {
            console2.log("WARNING: PAYOUT_SPLITTER has no code on this chain.");
        }
    }

    // -------------------------------------------------------------------------
    // Router program: 3 swaps, then divide WETH between ERC-20 and native halves
    // -------------------------------------------------------------------------

    function _buildRouterCall(Cfg memory c) internal returns (bytes memory routerCall, Mins memory m) {
        m.weth1 = _applySlippage(_quote(c.quoter, c.usdc, c.weth, c.amountIn, c.fee1), c.slippageBps);
        m.uni = _applySlippage(_quote(c.quoter, c.weth, c.uni, m.weth1, c.fee2), c.slippageBps);
        m.weth2 = _applySlippage(_quote(c.quoter, c.uni, c.weth, m.uni, c.fee3), c.slippageBps);
        // Native portion floor: what UNWRAP_WETH must at least deliver after
        // PAY_PORTION took wethPortionBps of the (dynamic) WETH balance.
        m.ethFloor = m.weth2 * (10_000 - c.wethPortionBps) / 10_000;
        // Guard the smallest split leg against ZeroLegAmount (bpsA is the smallest).
        uint256 minSmallestLeg = (m.weth2 * c.wethPortionBps / 10_000) * _minBps(c) / 10_000;
        require(minSmallestLeg > 0, "AMOUNT_IN too small: a split leg would floor to zero");

        _logPlan(c, m);

        // swap x3 -> PAY_PORTION (WETH as ERC-20 -> splitter) -> UNWRAP_WETH (native -> splitter).
        bytes memory commands =
            abi.encodePacked(V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, PAY_PORTION, UNWRAP_WETH);

        bytes[] memory inputs = new bytes[](5);
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.weth1, abi.encodePacked(c.usdc, c.fee1, c.weth), false);
        inputs[1] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.uni, abi.encodePacked(c.weth, c.fee2, c.uni), false);
        inputs[2] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.weth2, abi.encodePacked(c.uni, c.fee3, c.weth), false);
        // ERC-20 half: wethPortionBps of the router's live WETH -> splitter (stays wrapped).
        inputs[3] = abi.encode(c.weth, c.splitter, c.wethPortionBps);
        // Native half: unwrap the router's WHOLE remaining WETH, pay ETH to splitter.
        inputs[4] = abi.encode(c.splitter, m.ethFloor);

        uint256 routerDeadline = block.timestamp + 30 minutes;
        routerCall = abi.encodeCall(IUniversalRouter.execute, (commands, inputs, routerDeadline));
    }

    function _minBps(Cfg memory c) internal pure returns (uint256) {
        uint256 rem = 10_000 - c.bpsA - c.bpsB;
        uint256 minv = c.bpsA < c.bpsB ? c.bpsA : c.bpsB;
        return minv < rem ? minv : rem;
    }

    // -------------------------------------------------------------------------
    // Split legs (the arbitrary-percentage payouts)
    // -------------------------------------------------------------------------

    function _erc20Legs(Cfg memory c) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](3);
        legs[0] = Leg({target: c.eoaA, shareBps: uint96(c.bpsA), amountOffset: NO_SUB, data: ""});
        legs[1] = Leg({target: c.eoaB, shareBps: uint96(c.bpsB), amountOffset: NO_SUB, data: ""});
        // Remainder leg: the ORIGINAL depository, amount substituted at run time.
        legs[2] = Leg({
            target: c.depository,
            shareBps: uint96(10_000 - c.bpsA - c.bpsB),
            amountOffset: DEPOSIT_ERC20_AMOUNT_OFFSET,
            data: abi.encodeCall(ILayerswapDepository.depositERC20, (c.depositIdErc20, c.weth, c.receiver, 0))
        });
    }

    function _nativeLegs(Cfg memory c) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](3);
        legs[0] = Leg({target: c.eoaA, shareBps: uint96(c.bpsA), amountOffset: NO_SUB, data: ""});
        legs[1] = Leg({target: c.eoaB, shareBps: uint96(c.bpsB), amountOffset: NO_SUB, data: ""});
        // Remainder leg: depositNative — the amount IS msg.value, nothing to patch.
        legs[2] = Leg({
            target: c.depository,
            shareBps: uint96(10_000 - c.bpsA - c.bpsB),
            amountOffset: NO_SUB,
            data: abi.encodeCall(ILayerswapDepository.depositNative, (c.depositIdNative, c.receiver))
        });
    }

    // -------------------------------------------------------------------------
    // Calibur batch — 5 calls
    // -------------------------------------------------------------------------

    function _finalizeBatch(Cfg memory c, uint256 userPk, bytes memory routerCall)
        internal
        view
        returns (Call[] memory calls, bytes32 authNonce)
    {
        uint256 validBefore = block.timestamp + 10 minutes;
        authNonce = bytes32(vm.randomUint());
        (uint8 v, bytes32 r, bytes32 s) = _signAuth(userPk, c, validBefore, authNonce);

        calls = new Call[](5);
        // 1. gasless inbound: user -> executor
        calls[0] = Call({
            to: c.usdc,
            value: 0,
            data: abi.encodeCall(
                IERC3009USDC.receiveWithAuthorization,
                (c.user, c.executor, c.amountIn, 0, validBefore, authNonce, v, r, s)
            )
        });
        // 2. pre-fund the router
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, c.amountIn))});
        // 3. swaps + hand the WETH/native halves to the splitter
        calls[2] = Call({to: c.router, value: 0, data: routerCall});
        // 4. ERC-20 split: WETH by 12.34/37.66/50.00 (last leg -> ORIGINAL depository hook)
        calls[3] = Call({
            to: c.splitter,
            value: 0,
            data: abi.encodeCall(IPayoutSplitter.split, (c.weth, _erc20Legs(c)))
        });
        // 5. native split: ETH by the same shares (last leg -> depositNative hook)
        calls[4] = Call({
            to: c.splitter,
            value: 0,
            data: abi.encodeCall(IPayoutSplitter.split, (address(0), _nativeLegs(c)))
        });
    }

    // -------------------------------------------------------------------------
    // Off-chain pricing
    // -------------------------------------------------------------------------

    function _quote(address quoter, address tokenIn, address tokenOut, uint256 amountIn, uint24 fee)
        internal
        returns (uint256 amountOut)
    {
        IQuoterV2.QuoteExactInputSingleParams memory p = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            fee: fee,
            sqrtPriceLimitX96: 0
        });
        (amountOut,,,) = IQuoterV2(quoter).quoteExactInputSingle(p);
    }

    function _applySlippage(uint256 amount, uint256 slippageBps) internal pure returns (uint256) {
        return (amount * (10_000 - slippageBps)) / 10_000;
    }

    // -------------------------------------------------------------------------
    // EIP-3009 signing (payer key)
    // -------------------------------------------------------------------------

    function _signAuth(uint256 userPk, Cfg memory c, uint256 validBefore, bytes32 authNonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 domainSeparator = IERC3009USDC(c.usdc).DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH, c.user, c.executor, c.amountIn, uint256(0), validBefore, authNonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
        (v, r, s) = vm.sign(userPk, digest);
    }

    // -------------------------------------------------------------------------
    // Logging
    // -------------------------------------------------------------------------

    function _logPlan(Cfg memory c, Mins memory m) internal pure {
        console2.log("==================================================");
        console2.log("Calibur generic-splitter flow (TX 4): ERC-20 + NATIVE splits, arbitrary %");
        console2.log("--------------------------------------------------");
        console2.log("ROLES: payer:", c.user);
        console2.log("  relayer/executor:", c.executor);
        console2.log("  split EOA A:", c.eoaA);
        console2.log("  split EOA B:", c.eoaB);
        console2.log("  ORIGINAL depository (hook target):", c.depository);
        console2.log("--------------------------------------------------");
        console2.log("STAGE 1  gasless inbound (EIP-3009), amountIn:", c.amountIn);
        console2.log("STAGE 2  USDC.transfer(universalRouter, amountIn)");
        console2.log("STAGE 3  router: USDC->WETH->UNI->WETH, then divide:");
        console2.log("  hop mins:", m.weth1, m.uni, m.weth2);
        console2.log("  PAY_PORTION WETH -> splitter (bps):", c.wethPortionBps);
        console2.log("  UNWRAP_WETH remainder -> splitter as ETH, min:", m.ethFloor);
        console2.log("STAGE 4  split(WETH):  bpsA/bpsB/remainder:", c.bpsA, c.bpsB);
        console2.log("  remainder -> depositERC20 hook (amount substituted at offset 100)");
        console2.log("STAGE 5  split(ETH):   same shares; remainder -> depositNative hook");
        console2.log("--------------------------------------------------");
    }

    function _logSummary(Cfg memory c, Mins memory m, bytes32 authNonce) internal pure {
        console2.log("--------------------------------------------------");
        console2.log("Batch submitted by relayer (pays all gas).");
        console2.log("  splitter:", c.splitter);
        console2.log("  ORIGINAL depository (no depositERC20All):", c.depository);
        console2.log("  layerswap receiver:", c.receiver);
        console2.log("  guaranteed minimum WETH divided (floor):", m.weth2);
        console2.log("  auth nonce:");
        console2.logBytes32(authNonce);
        console2.log("  deposit ids (erc20, native):");
        console2.logBytes32(c.depositIdErc20);
        console2.logBytes32(c.depositIdNative);
        console2.log("  (tx hash printed by forge below after broadcast)");
        console2.log("==================================================");
    }
}
