// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Call, IERC7821} from "../src/interfaces/IERC7821.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IERC3009USDC} from "../src/interfaces/IERC3009USDC.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IQuoterV2} from "../src/interfaces/IQuoterV2.sol";

/// @title CaliburNativeDualFlowScript
/// @notice Gasless USDC in -> multi-pool Uniswap chain -> NATIVE ETH out, split
///         between TWO different EOAs — entirely by the Universal Router. No
///         depository, no contract of ours at all, and the executor never holds
///         the output: the router pays both EOAs directly, in native ETH.
///
/// THE PRODUCT STORY: a user with USDC and ZERO ETH signs one EIP-3009
/// authorization off-chain. One relayer-sponsored atomic tx converts their USDC
/// through a real multi-pool swap chain and pays out native ETH to two EOAs —
/// by default a fee wallet (percentage cut) and THE USER THEMSELVES (gasless
/// "buy gas with USDC").
///
/// ONE atomic 3-call Calibur batch (any revert rolls back everything):
///   1. USDC.receiveWithAuthorization(user -> executor)      // gasless inbound
///   2. USDC.transfer(universalRouter, amountIn)             // pre-fund router
///   3. UniversalRouter.execute():
///        V3_SWAP_EXACT_IN USDC -> WETH  (pool 1: 0.30%)     \
///        V3_SWAP_EXACT_IN WETH -> UNI   (pool 2: 0.30%)      } CONTRACT_BALANCE
///        V3_SWAP_EXACT_IN UNI  -> WETH  (pool 3: 0.05%)     /
///        UNWRAP_WETH   -> the router now holds NATIVE ETH
///        PAY_PORTION   (ETH, payoutEoa1, splitBps)          // payout 1: % cut
///        SWEEP         (ETH, payoutEoa2, ethFloor)          // payout 2: ALL the rest
///
/// EVERY payout leg is dynamic — PAY_PORTION takes a percentage of the live
/// balance, SWEEP takes everything left — so ZERO dust by construction, in
/// tokens and in ETH. The off-chain quote only sets the SWEEP's min-out floor
/// (slippage guard): too much slippage -> whole tx reverts, signature unspent.
///
/// ROLES:
///   * PRIVATE_KEY  — relayer/executor (EIP-7702 Calibur account), pays all gas.
///   * USER_PRIVATE_KEY — payer; signs EIP-3009 off-chain, pays nothing.
///   * PAYOUT_EOA_1 (default FEE_RECIPIENT)     — receives splitBps of the ETH.
///   * PAYOUT_EOA_2 (default the payer itself)  — receives the remainder.
///
/// Usage:
///   forge script script/CaliburNativeDualFlow.s.sol:CaliburNativeDualFlowScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract CaliburNativeDualFlowScript is Script {
    bytes32 internal constant ERC7821_BATCH_MODE =
        0x0100000000000000000000000000000000000000000000000000000000000000;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    // Universal Router command bytes (Uniswap Commands.sol).
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant SWEEP = 0x04;
    bytes1 internal constant TRANSFER = 0x05;
    bytes1 internal constant PAY_PORTION = 0x06;
    bytes1 internal constant UNWRAP_WETH = 0x0c;

    // Universal Router sentinels (Constants.sol).
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;
    address internal constant ADDRESS_THIS = address(2);
    // Universal Router represents native ETH as address(0) in payment commands.
    address internal constant NATIVE_ETH = address(0);

    // Default Sepolia infra (all overridable via env).
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant DEFAULT_UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant DEFAULT_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address internal constant DEFAULT_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;

    struct Cfg {
        address usdc;
        address weth;
        address uni;
        address router;
        address quoter;
        address payoutEoa1; // percentage cut (splitBps)
        address payoutEoa2; // everything else, min-guarded
        address executor;
        address user;
        uint24 fee1; // USDC/WETH
        uint24 fee2; // WETH/UNI
        uint24 fee3; // UNI/WETH
        uint256 amountIn;
        uint256 splitBps; // payout 1's share of the final ETH, in bips
        uint256 slippageBps;
    }

    struct Mins {
        uint256 weth1; // hop 1: USDC -> WETH
        uint256 uni; // hop 2: WETH -> UNI
        uint256 weth2; // hop 3: UNI -> WETH (== ETH after unwrap)
        uint256 ethFloor; // SWEEP min-out for payout 2 (after payout 1's cut)
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

        c.user = vm.addr(userPk);
        address userEnv = vm.envOr("USER_ADDRESS", address(0));
        require(userEnv == address(0) || userEnv == c.user, "USER_ADDRESS != addr(USER_PRIVATE_KEY)");
        c.executor = vm.envOr("CALIBUR_EXECUTOR", vm.addr(broadcasterPk));

        // Payout 1 defaults to the fee wallet; payout 2 defaults to THE PAYER —
        // the "user converts USDC into native gas money, gaslessly" story.
        c.payoutEoa1 = vm.envOr("PAYOUT_EOA_1", vm.envAddress("FEE_RECIPIENT"));
        c.payoutEoa2 = vm.envOr("PAYOUT_EOA_2", c.user);

        c.fee1 = uint24(vm.envOr("POOL_FEE_1", uint256(3000))); // USDC/WETH
        c.fee2 = uint24(vm.envOr("POOL_FEE_2", uint256(3000))); // WETH/UNI
        c.fee3 = uint24(vm.envOr("POOL_FEE_3", uint256(500))); // UNI/WETH

        c.amountIn = vm.envUint("AMOUNT_IN");
        c.splitBps = vm.envOr("PAYOUT_SPLIT_BPS", uint256(1000)); // default 10% to payout 1
        c.slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100));
    }

    function _validate(Cfg memory c) internal pure {
        require(c.usdc != address(0), "USDC_SEPOLIA is zero");
        require(c.weth != address(0), "WETH is zero");
        require(c.uni != address(0), "UNI is zero");
        require(c.router != address(0), "router is zero");
        require(c.quoter != address(0), "quoter is zero");
        require(c.executor != address(0), "executor is zero");
        require(c.user != address(0), "user is zero");
        require(c.payoutEoa1 != address(0), "PAYOUT_EOA_1 is zero");
        require(c.payoutEoa2 != address(0), "PAYOUT_EOA_2 is zero");
        require(c.payoutEoa1 != c.payoutEoa2, "the two payout EOAs must differ");
        require(c.user != c.executor, "payer (user) must differ from executor");
        require(c.amountIn > 0, "AMOUNT_IN must be > 0");
        require(c.splitBps > 0 && c.splitBps < 10_000, "PAYOUT_SPLIT_BPS must be in (0,10000)");
        require(c.slippageBps < 10_000, "SLIPPAGE_BPS must be < 10000");
    }

    function _preflight(Cfg memory c) internal view {
        if (c.executor.code.length == 0) {
            console2.log("WARNING: executor has NO code -> not delegated to Calibur. Run EnableDelegation.s.sol first.");
        }
    }

    // -------------------------------------------------------------------------
    // Router program (swap chain -> unwrap -> native dual payout)
    // -------------------------------------------------------------------------

    function _buildRouterCall(Cfg memory c) internal returns (bytes memory routerCall, Mins memory m) {
        m.weth1 = _applySlippage(_quote(c.quoter, c.usdc, c.weth, c.amountIn, c.fee1), c.slippageBps);
        m.uni = _applySlippage(_quote(c.quoter, c.weth, c.uni, m.weth1, c.fee2), c.slippageBps);
        m.weth2 = _applySlippage(_quote(c.quoter, c.uni, c.weth, m.uni, c.fee3), c.slippageBps);
        // Guaranteed minimum for payout 2 = guaranteed ETH minus payout 1's cut.
        m.ethFloor = m.weth2 * (10_000 - c.splitBps) / 10_000;
        require(m.ethFloor > 0, "guaranteed payout-2 amount is zero; raise AMOUNT_IN");

        _logPlan(c, m);

        // swap x3 -> unwrap to native -> percentage payout -> sweep the rest.
        bytes memory commands =
            abi.encodePacked(V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, UNWRAP_WETH, PAY_PORTION, SWEEP);

        bytes[] memory inputs = new bytes[](6);
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.weth1, abi.encodePacked(c.usdc, c.fee1, c.weth), false);
        inputs[1] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.uni, abi.encodePacked(c.weth, c.fee2, c.uni), false);
        inputs[2] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.weth2, abi.encodePacked(c.uni, c.fee3, c.weth), false);
        // unwrap the router's WHOLE WETH balance into native ETH (kept in-router)
        inputs[3] = abi.encode(ADDRESS_THIS, m.weth2);
        // payout 1: splitBps of the router's live ETH balance -> EOA 1
        inputs[4] = abi.encode(NATIVE_ETH, c.payoutEoa1, c.splitBps);
        // payout 2: ALL remaining ETH -> EOA 2 (min-out = the slippage floor)
        inputs[5] = abi.encode(NATIVE_ETH, c.payoutEoa2, m.ethFloor);

        uint256 routerDeadline = block.timestamp + 30 minutes;
        routerCall = abi.encodeCall(IUniversalRouter.execute, (commands, inputs, routerDeadline));
    }

    // -------------------------------------------------------------------------
    // Calibur batch — just THREE calls
    // -------------------------------------------------------------------------

    function _finalizeBatch(Cfg memory c, uint256 userPk, bytes memory routerCall)
        internal
        view
        returns (Call[] memory calls, bytes32 authNonce)
    {
        uint256 validBefore = block.timestamp + 10 minutes;
        authNonce = bytes32(vm.randomUint());
        (uint8 v, bytes32 r, bytes32 s) = _signAuth(userPk, c, validBefore, authNonce);

        calls = new Call[](3);
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
        // 3. swaps + unwrap + BOTH payouts, all inside the unowned router
        calls[2] = Call({to: c.router, value: 0, data: routerCall});
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
        console2.log("Calibur NATIVE dual-EOA gasless flow (Sepolia, zero dust)");
        console2.log("--------------------------------------------------");
        console2.log("ROLES:");
        console2.log("  payer (user):", c.user);
        console2.log("  relayer/executor:", c.executor);
        console2.log("  payout EOA 1 (split", c.splitBps, "bps):", c.payoutEoa1);
        console2.log("  payout EOA 2 (remainder):", c.payoutEoa2);
        console2.log("--------------------------------------------------");
        console2.log("STAGE 1  gasless inbound (EIP-3009), amountIn:", c.amountIn);
        console2.log("STAGE 2  USDC.transfer(universalRouter, amountIn)");
        console2.log("STAGE 3  UniversalRouter.execute():");
        console2.log("  hop 1: USDC -> WETH  minOut:", m.weth1);
        console2.log("  hop 2: WETH -> UNI   minOut:", m.uni);
        console2.log("  hop 3: UNI  -> WETH  minOut:", m.weth2);
        console2.log("  UNWRAP_WETH -> native ETH (whole balance)");
        console2.log("  PAY_PORTION -> payout EOA 1 (bps):", c.splitBps);
        console2.log("  SWEEP ALL remaining ETH -> payout EOA 2, min:", m.ethFloor);
        console2.log("--------------------------------------------------");
    }

    function _logSummary(Cfg memory c, Mins memory m, bytes32 authNonce) internal pure {
        console2.log("--------------------------------------------------");
        console2.log("Batch submitted by relayer (pays all gas).");
        console2.log("  token path: USDC -> WETH -> UNI -> WETH -> native ETH");
        console2.log("  BOTH payouts in NATIVE ETH, straight from the router:");
        console2.log("    payout EOA 1:", c.payoutEoa1);
        console2.log("    payout EOA 2:", c.payoutEoa2);
        console2.log("  guaranteed minimum to payout 2 (wei):", m.ethFloor);
        console2.log("  executor / depository involvement in payouts: NONE");
        console2.log("  auth nonce:");
        console2.logBytes32(authNonce);
        console2.log("  (tx hash printed by forge below after broadcast)");
        console2.log("==================================================");
    }
}
