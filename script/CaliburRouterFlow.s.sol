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

/// @title CaliburRouterFlowScript (v2 — zero dust)
/// @notice End-to-end Sepolia demo of a GASLESS, post-deposit DeFi flow executed
///         as ONE atomic, relayer-sponsored Calibur (EIP-7702 / ERC-7821) batch.
///         v2 targets OUR OWN LayerswapDepository deployment, whose
///         `depositERC20All` forwards the caller's WHOLE balance — so the final
///         deposit amount is fully dynamic and NOTHING is left behind (zero dust).
///
/// FLOW (all in a single atomic batch; any failure reverts everything):
///   1. GASLESS INBOUND — USDC.receiveWithAuthorization(user -> executor): the
///      payer signs an EIP-3009 authorization off-chain; the relayer submits it.
///   2. USDC.transfer(universalRouter, amountIn) — pre-fund the router so its
///      commands operate on CONTRACT_BALANCE (payerIsUser = false).
///   3. UniversalRouter.execute(...) — the DYNAMIC chain, in Uniswap's UNOWNED
///      router; each leg consumes the previous leg's output via CONTRACT_BALANCE:
///        a. V3_SWAP_EXACT_IN  USDC -> WETH   (pool 1: USDC/WETH feeA)
///        b. UNWRAP_WETH + WRAP_ETH            (native ETH round-trip on WETH9)
///        c. V3_SWAP_EXACT_IN  WETH -> UNI    (pool 2: WETH/UNI  feeB)
///        d. V3_SWAP_EXACT_IN  UNI  -> WETH   (pool 3: UNI/WETH  feeC)
///        e. V3_SWAP_EXACT_IN  WETH -> USDC   (pool 4: WETH/USDC feeD)
///        f. TRANSFER  small fee (absolute) -> fee-recipient EOA
///        g. SWEEP     ALL remaining USDC -> executor (min-out guarded by floor)
///   4. USDC.approve(depository, type(uint256).max)
///   5. LayerswapDepository.depositERC20All(id, USDC, receiver) — forwards the
///      executor's ENTIRE USDC balance (the dynamic sweep + any historical dust)
///      and emits `Deposited` with the true amount. ZERO dust remains.
///   6. USDC.approve(depository, 0) — hygiene: drop the standing allowance.
///
/// WHY THIS IS NOW ZERO-DUST: v1 had to deposit a slippage-computed FLOOR
/// (a static `Call` must name an exact amount), leaving the excess as dust in the
/// executor. `depositERC20All` reads the executor's balance AT RUN TIME, so the
/// exact dynamic amount — whatever the swaps actually produced — is deposited.
/// The floor now only guards the SWEEP's min-out (slippage protection), it no
/// longer caps the deposit.
///
/// FOUR REAL UNISWAP V3 POOLS + a native WETH9 unwrap/rewrap in one batch:
///   USDC/WETH 0.30%  ->  (ETH round-trip)  ->  WETH/UNI 0.30%  ->
///   UNI/WETH 0.05%   ->  WETH/USDC 0.05%
///
/// ROLES (same two-key model as the rest of the repo):
///   * PRIVATE_KEY — the relayer/sponsor EOA, delegated to Calibur via EIP-7702.
///     It broadcasts, pays ALL gas, and IS the executor and the EIP-3009 `to`.
///   * USER_PRIVATE_KEY — the payer. Signs the EIP-3009 auth off-chain; no gas.
///
/// Usage:
///   forge script script/CaliburRouterFlow.s.sol:CaliburRouterFlowScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract CaliburRouterFlowScript is Script {
    // ERC-7821 single-batch execution mode (no opData).
    bytes32 internal constant ERC7821_BATCH_MODE =
        0x0100000000000000000000000000000000000000000000000000000000000000;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    // --- Universal Router command bytes (Uniswap Commands.sol) ---
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant SWEEP = 0x04;
    bytes1 internal constant TRANSFER = 0x05;
    bytes1 internal constant WRAP_ETH = 0x0b;
    bytes1 internal constant UNWRAP_WETH = 0x0c;

    // --- Universal Router sentinels (Constants.sol) ---
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;
    address internal constant ADDRESS_THIS = address(2);

    // Default Sepolia infra (all overridable via env).
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant DEFAULT_UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant DEFAULT_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b; // Universal Router
    address internal constant DEFAULT_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3; // QuoterV2

    struct Cfg {
        address usdc; // Circle EIP-3009 USDC
        address weth; // canonical WETH9
        address uni; // Sepolia UNI
        address router; // Uniswap Universal Router
        address quoter; // Uniswap QuoterV2 (off-chain pricing only)
        address depository; // OUR LayerswapDepository (has depositERC20All)
        address receiver; // whitelisted Layerswap receiver
        address feeRecipient; // fee EOA
        address executor; // Calibur account (delegated relayer EOA) == EIP-3009 `to`
        address user; // EIP-3009 payer
        uint24 feeA; // pool 1: USDC/WETH
        uint24 feeB; // pool 2: WETH/UNI
        uint24 feeC; // pool 3: UNI/WETH
        uint24 feeD; // pool 4: WETH/USDC
        uint256 amountIn; // USDC pulled in gaslessly
        uint256 feeAmount; // absolute USDC fee to the fee EOA
        uint256 slippageBps; // per-leg slippage tolerance (bps)
        bytes32 depositId; // Layerswap order correlation id
    }

    /// @dev Per-hop guaranteed minimum outputs (each priced from the previous
    ///      hop's minimum, so every min is genuinely achievable on-chain).
    struct Mins {
        uint256 weth1; // after hop a (USDC -> WETH)
        uint256 uni; // after hop c (WETH -> UNI)
        uint256 weth2; // after hop d (UNI -> WETH)
        uint256 usdcBack; // after hop e (WETH -> USDC)
        uint256 sweepFloor; // usdcBack - feeAmount (SWEEP min-out only, NOT the deposit amount)
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
        c.depository = vm.envAddress("LAYERSWAP_DEPOSITORY");
        c.receiver = vm.envAddress("DEPOSIT_RECEIVER");
        c.feeRecipient = vm.envAddress("FEE_RECIPIENT");

        c.user = vm.addr(userPk);
        address userEnv = vm.envOr("USER_ADDRESS", address(0));
        require(userEnv == address(0) || userEnv == c.user, "USER_ADDRESS != addr(USER_PRIVATE_KEY)");
        c.executor = vm.envOr("CALIBUR_EXECUTOR", vm.addr(broadcasterPk));

        // Fee tiers of the four pools (defaults = the liquid Sepolia pools).
        c.feeA = uint24(vm.envOr("POOL_FEE_A", uint256(3000))); // USDC/WETH
        c.feeB = uint24(vm.envOr("POOL_FEE_B", uint256(3000))); // WETH/UNI
        c.feeC = uint24(vm.envOr("POOL_FEE_C", uint256(500))); // UNI/WETH
        c.feeD = uint24(vm.envOr("POOL_FEE_D", uint256(500))); // WETH/USDC

        c.amountIn = vm.envUint("AMOUNT_IN");
        c.feeAmount = vm.envUint("FEE_AMOUNT");
        c.slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100)); // default 1% per leg
        c.depositId = vm.envOr("DEPOSIT_ID", bytes32(vm.randomUint()));
    }

    function _validate(Cfg memory c) internal pure {
        require(c.usdc != address(0), "USDC_SEPOLIA is zero");
        require(c.weth != address(0), "WETH is zero");
        require(c.uni != address(0), "UNI is zero");
        require(c.router != address(0), "router is zero");
        require(c.quoter != address(0), "quoter is zero");
        require(c.depository != address(0), "LAYERSWAP_DEPOSITORY is zero");
        require(c.receiver != address(0), "DEPOSIT_RECEIVER is zero");
        require(c.feeRecipient != address(0), "FEE_RECIPIENT is zero");
        require(c.executor != address(0), "executor is zero");
        require(c.user != address(0), "user is zero");
        require(c.user != c.executor, "payer (user) must differ from executor");
        require(c.amountIn > 0, "AMOUNT_IN must be > 0");
        require(c.slippageBps < 10_000, "SLIPPAGE_BPS must be < 10000");
    }

    function _preflight(Cfg memory c) internal view {
        ILayerswapDepository dep = ILayerswapDepository(c.depository);
        if (dep.paused()) {
            console2.log("WARNING: LayerswapDepository is paused; deposit will revert (batch reverts atomically).");
        }
        if (!dep.isWhitelisted(c.receiver)) {
            console2.log("WARNING: DEPOSIT_RECEIVER is NOT whitelisted; depositERC20All reverts (NotWhitelisted).");
            console2.log("  receiver:", c.receiver);
        }
        if (c.executor.code.length == 0) {
            console2.log("WARNING: executor has NO code -> not delegated to Calibur. Run EnableDelegation.s.sol first.");
            console2.log("  executor:", c.executor);
        }
        uint256 priorDust = IERC20(c.usdc).balanceOf(c.executor);
        if (priorDust > 0) {
            console2.log("NOTE: executor holds pre-existing USDC that depositERC20All will sweep into the deposit:", priorDust);
        }
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
    // Router program (the dynamic 4-pool chain + payouts)
    // -------------------------------------------------------------------------

    /// @dev Price the four hops (each from the previous hop's minimum), then
    ///      encode the Universal Router program carrying the dynamic chain.
    function _buildRouterCall(Cfg memory c) internal returns (bytes memory routerCall, Mins memory m) {
        m.weth1 = _applySlippage(_quote(c.quoter, c.usdc, c.weth, c.amountIn, c.feeA), c.slippageBps);
        m.uni = _applySlippage(_quote(c.quoter, c.weth, c.uni, m.weth1, c.feeB), c.slippageBps);
        m.weth2 = _applySlippage(_quote(c.quoter, c.uni, c.weth, m.uni, c.feeC), c.slippageBps);
        m.usdcBack = _applySlippage(_quote(c.quoter, c.weth, c.usdc, m.weth2, c.feeD), c.slippageBps);
        require(m.usdcBack > c.feeAmount, "FEE_AMOUNT >= guaranteed output; lower it");
        m.sweepFloor = m.usdcBack - c.feeAmount;

        _logPlan(c, m);

        (bytes memory commands, bytes[] memory inputs) = _buildRouterProgram(c, m);
        uint256 routerDeadline = block.timestamp + 30 minutes;
        routerCall = abi.encodeCall(IUniversalRouter.execute, (commands, inputs, routerDeadline));
    }

    function _buildRouterProgram(Cfg memory c, Mins memory m)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        // swap -> unwrap -> rewrap -> swap -> swap -> swap -> fee transfer -> sweep.
        commands = abi.encodePacked(
            V3_SWAP_EXACT_IN, UNWRAP_WETH, WRAP_ETH, V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, TRANSFER, SWEEP
        );

        inputs = new bytes[](8);
        // a. pool 1: swap the router's whole USDC balance -> WETH
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.weth1, abi.encodePacked(c.usdc, c.feeA, c.weth), false);
        // b. native ETH round-trip: unwrap all WETH -> ETH, rewrap all ETH -> WETH (WETH9)
        inputs[1] = abi.encode(ADDRESS_THIS, m.weth1);
        inputs[2] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE);
        // c. pool 2: WETH -> UNI
        inputs[3] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.uni, abi.encodePacked(c.weth, c.feeB, c.uni), false);
        // d. pool 3: UNI -> WETH
        inputs[4] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.weth2, abi.encodePacked(c.uni, c.feeC, c.weth), false);
        // e. pool 4: WETH -> USDC
        inputs[5] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.usdcBack, abi.encodePacked(c.weth, c.feeD, c.usdc), false);
        // f. pay the small absolute fee to the fee EOA
        inputs[6] = abi.encode(c.usdc, c.feeRecipient, c.feeAmount);
        // g. sweep ALL remaining USDC to the executor (min-out = sweepFloor)
        inputs[7] = abi.encode(c.usdc, c.executor, m.sweepFloor);
    }

    // -------------------------------------------------------------------------
    // Calibur batch
    // -------------------------------------------------------------------------

    function _finalizeBatch(Cfg memory c, uint256 userPk, bytes memory routerCall)
        internal
        view
        returns (Call[] memory calls, bytes32 authNonce)
    {
        uint256 validBefore = block.timestamp + 10 minutes;
        authNonce = bytes32(vm.randomUint());
        (uint8 v, bytes32 r, bytes32 s) = _signAuth(userPk, c, validBefore, authNonce);
        calls = _buildBatch(c, routerCall, validBefore, authNonce, v, r, s);
    }

    function _buildBatch(
        Cfg memory c,
        bytes memory routerCall,
        uint256 validBefore,
        bytes32 authNonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (Call[] memory calls) {
        calls = new Call[](6);
        // 1. gasless inbound: user -> executor
        calls[0] = Call({
            to: c.usdc,
            value: 0,
            data: abi.encodeCall(
                IERC3009USDC.receiveWithAuthorization,
                (c.user, c.executor, c.amountIn, 0, validBefore, authNonce, v, r, s)
            )
        });
        // 2. move the inbound USDC into the router so its commands can use CONTRACT_BALANCE
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, c.amountIn))});
        // 3. the entire dynamic DeFi chain, inside the unowned Universal Router
        calls[2] = Call({to: c.router, value: 0, data: routerCall});
        // 4. approve max so depositERC20All can pull whatever the dynamic balance is
        calls[3] =
            Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.approve, (c.depository, type(uint256).max))});
        // 5. deposit the executor's ENTIRE USDC balance — the zero-dust deposit
        calls[4] = Call({
            to: c.depository,
            value: 0,
            data: abi.encodeCall(ILayerswapDepository.depositERC20All, (c.depositId, c.usdc, c.receiver))
        });
        // 6. hygiene: drop the standing allowance again
        calls[5] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.approve, (c.depository, 0))});
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
        console2.log("Calibur router-native gasless DeFi flow v2 (zero dust)");
        console2.log("--------------------------------------------------");
        console2.log("STAGE 1  gasless inbound: USDC.receiveWithAuthorization, amountIn:", c.amountIn);
        console2.log("STAGE 2  USDC.transfer(universalRouter, amountIn)");
        console2.log("STAGE 3  UniversalRouter.execute() -- 4 pools + native ETH round-trip:");
        console2.log("  a. USDC -> WETH (pool 1), minOut:", m.weth1);
        console2.log("  b. WETH unwrap -> rewrap (WETH9 native round-trip)");
        console2.log("  c. WETH -> UNI  (pool 2), minOut:", m.uni);
        console2.log("  d. UNI  -> WETH (pool 3), minOut:", m.weth2);
        console2.log("  e. WETH -> USDC (pool 4), minOut:", m.usdcBack);
        console2.log("  f. TRANSFER fee -> feeRecipient:", c.feeAmount);
        console2.log("  g. SWEEP ALL remaining USDC -> executor, min:", m.sweepFloor);
        console2.log("STAGE 4  USDC.approve(depository, max)");
        console2.log("STAGE 5  depositERC20All -- deposits the executor's WHOLE balance (zero dust)");
        console2.log("STAGE 6  USDC.approve(depository, 0)");
        console2.log("--------------------------------------------------");
    }

    function _logSummary(Cfg memory c, Mins memory m, bytes32 authNonce) internal pure {
        console2.log("--------------------------------------------------");
        console2.log("Batch submitted by relayer (pays all gas).");
        console2.log("  token path: USDC -> WETH -> (ETH) -> WETH -> UNI -> WETH -> USDC");
        console2.log("  user (EIP-3009 from):", c.user);
        console2.log("  executor (EIP-3009 to == relayer):", c.executor);
        console2.log("  fee recipient EOA:", c.feeRecipient);
        console2.log("  layerswap depository (ours, depositERC20All):", c.depository);
        console2.log("  layerswap receiver:", c.receiver);
        console2.log("  guaranteed minimum deposited (floor):", m.sweepFloor);
        console2.log("  auth nonce:");
        console2.logBytes32(authNonce);
        console2.log("  deposit id:");
        console2.logBytes32(c.depositId);
        console2.log("  (tx hash printed by forge below after broadcast)");
        console2.log("==================================================");
    }
}
