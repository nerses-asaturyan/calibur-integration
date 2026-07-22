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

/// @title CaliburRouterFlowScript
/// @notice End-to-end Sepolia demo of a GASLESS, post-deposit DeFi flow executed
///         as ONE atomic, relayer-sponsored Calibur (EIP-7702 / ERC-7821) batch,
///         with ZERO new contracts of our own.
///
/// FLOW (all in a single atomic batch; any failure reverts everything):
///   1. GASLESS INBOUND — USDC.receiveWithAuthorization(user -> executor): the
///      payer signs an EIP-3009 authorization off-chain; the relayer submits it.
///      (EIP-3009 requires msg.sender == `to`, and the executor IS the batch
///      caller, so `to` = executor.)
///   2. USDC.transfer(universalRouter, amountIn) — pre-fund the router so its
///      commands can operate on `CONTRACT_BALANCE` (payerIsUser = false).
///   3. UniversalRouter.execute(...) — the whole DYNAMIC chain lives here, using
///      Uniswap's UNOWNED router. Each leg consumes the previous leg's output via
///      the CONTRACT_BALANCE sentinel, so no intermediate amount is known at sign
///      time:
///        a. V3_SWAP_EXACT_IN  USDC -> WETH            (real Uniswap v3, feeIn pool)
///        b. UNWRAP_WETH + WRAP_ETH  WETH->ETH->WETH   (see AAVE SUBSTITUTE below)
///        c. V3_SWAP_EXACT_IN  WETH -> USDC            (see 0x SUBSTITUTE below)
///        d. TRANSFER  small fee (absolute) -> fee-recipient EOA
///        e. SWEEP     remainder -> executor           (min-out guarded)
///   4. USDC.approve(depository, floor)
///   5. LayerswapDepository.depositERC20(id, USDC, receiver, floor) — deposits the
///      slippage-computed FLOOR amount and emits Layerswap's `Deposited` event.
///
/// WHY A FLOOR ON STEP 5 (the one "partial" leg): an unowned router cannot call an
/// arbitrary function like `depositERC20`, and a static Calibur `Call` must name an
/// exact amount at sign time. So the router SWEEPs the (dynamic) remainder back to
/// the executor, and we deposit a conservative floor = minUsdcBack - feeAmount.
/// Any excess above the floor stays as dust in the executor. The SWAPS are fully
/// dynamic; only this final deposit amount is floored.
///
/// SUBSTITUTIONS (flagged per the task; Sepolia has no usable route for the
/// originals with real liquidity):
///   * 0x SWAP  -> a second real Uniswap v3 hop (feeOut pool). 0x's Swap API is
///     mainnet-only (no Sepolia deployment) and needs an off-chain HTTP call.
///   * AAVE supply/withdraw -> canonical WETH9 unwrap→rewrap round-trip, done
///     natively by the router. Aave v3 Sepolia's reserves are Aave's own faucet
///     test tokens (not Circle USDC / not canonical WETH9), which have no Uniswap
///     liquidity — so no atomic route feeds real swap liquidity into real Aave.
///     WETH9 is a real Sepolia contract; wrap/unwrap is the nearest "put an asset
///     in, take it back out" analog.
///
/// ROLES (same two-key model as the rest of the repo):
///   * PRIVATE_KEY / OPERATOR_PRIVATE_KEY — the relayer/sponsor EOA, delegated to
///     Calibur via EIP-7702. It broadcasts, pays ALL gas, and IS the executor and
///     the EIP-3009 `to`. (Run EnableDelegation.s.sol first.)
///   * USER_PRIVATE_KEY — the payer. Signs the EIP-3009 auth off-chain; pays no gas.
///
/// PREREQUISITES: executor delegated to Calibur (EnableDelegation.s.sol); payer
/// holds >= AMOUNT_IN Circle USDC; relayer holds Sepolia ETH for gas; a working
/// SEPOLIA_RPC_URL (the repo's Infura key currently 401s for Sepolia).
///
/// Usage:
///   forge script script/CaliburRouterFlow.s.sol:CaliburRouterFlowScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
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
    // "use the router's entire current balance of the input token"
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;
    // recipient == the router itself (leave output in-router for the next command)
    address internal constant ADDRESS_THIS = address(2);

    // Default Sepolia infra (all overridable via env; nothing user-specific hardcoded).
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant DEFAULT_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b; // Universal Router
    address internal constant DEFAULT_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3; // QuoterV2

    /// @dev All demo parameters, resolved from env, kept in one struct to keep the
    ///      command/batch builders below out of stack-too-deep territory.
    struct Cfg {
        address usdc; // Circle EIP-3009 USDC (the gaslessly-received token)
        address weth; // canonical WETH9
        address router; // Uniswap Universal Router
        address quoter; // Uniswap QuoterV2 (off-chain pricing only)
        address depository; // LayerswapDepository
        address receiver; // whitelisted Layerswap receiver (final destination)
        address feeRecipient; // fee EOA
        address executor; // Calibur account (delegated relayer EOA) == EIP-3009 `to`
        address user; // EIP-3009 payer
        uint24 feeIn; // Uniswap pool fee for USDC->WETH
        uint24 feeOut; // Uniswap pool fee for WETH->USDC
        uint256 amountIn; // USDC pulled in gaslessly
        uint256 feeAmount; // absolute USDC fee to the fee EOA
        uint256 slippageBps; // per-leg slippage tolerance (bps)
        bytes32 depositId; // Layerswap order correlation id
    }

    function run() external {
        uint256 broadcasterPk = vm.envUint("PRIVATE_KEY"); // relayer/sponsor (delegated)
        uint256 userPk = vm.envUint("USER_PRIVATE_KEY"); // payer (signs EIP-3009)

        Cfg memory c = _loadCfg(broadcasterPk, userPk);
        _validate(c);
        _preflight(c);

        // Split into two frames to stay clear of stack-too-deep without viaIR:
        //   1. price the legs + encode the router program (the dynamic chain);
        //   2. sign the EIP-3009 inbound + assemble the 5-call atomic batch.
        (bytes memory routerCall, uint256 floor) = _buildRouterCall(c);
        (Call[] memory calls, bytes32 authNonce) = _finalizeBatch(c, userPk, routerCall, floor);

        // --- Relayer submits and pays all gas ---
        vm.startBroadcast(broadcasterPk);
        IERC7821(c.executor).execute(ERC7821_BATCH_MODE, abi.encode(calls));
        vm.stopBroadcast();

        _logSummary(c, authNonce);
    }

    /// @dev Prices each swap leg off-chain (conservative: leg 2 is priced from
    ///      leg 1's *minimum* output so the floor is always achievable), then
    ///      encodes the Universal Router program that carries the dynamic chain.
    function _buildRouterCall(Cfg memory c) internal returns (bytes memory routerCall, uint256 floor) {
        uint256 minWeth = _applySlippage(_quote(c.quoter, c.usdc, c.weth, c.amountIn, c.feeIn), c.slippageBps);
        uint256 minUsdcBack = _applySlippage(_quote(c.quoter, c.weth, c.usdc, minWeth, c.feeOut), c.slippageBps);
        require(minUsdcBack > c.feeAmount, "FEE_AMOUNT >= guaranteed output; lower it");
        floor = minUsdcBack - c.feeAmount; // exact amount deposited to Layerswap

        _logPlan(c, minWeth, minUsdcBack, floor);

        (bytes memory commands, bytes[] memory inputs) = _buildRouterProgram(c, minWeth, minUsdcBack, floor);
        uint256 routerDeadline = block.timestamp + 30 minutes;
        routerCall = abi.encodeCall(IUniversalRouter.execute, (commands, inputs, routerDeadline));
    }

    /// @dev Signs the gasless EIP-3009 authorization (payer key) and assembles the
    ///      5-call batch. Not `view`: vm.randomUint() is state-mutating.
    function _finalizeBatch(Cfg memory c, uint256 userPk, bytes memory routerCall, uint256 floor)
        internal
        view
        returns (Call[] memory calls, bytes32 authNonce)
    {
        uint256 validBefore = block.timestamp + 10 minutes;
        authNonce = bytes32(vm.randomUint());
        (uint8 v, bytes32 r, bytes32 s) = _signAuth(userPk, c, validBefore, authNonce);
        calls = _buildBatch(c, routerCall, floor, validBefore, authNonce, v, r, s);
    }

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------

    function _loadCfg(uint256 broadcasterPk, uint256 userPk) internal view returns (Cfg memory c) {
        c.usdc = vm.envAddress("USDC_SEPOLIA");
        c.weth = vm.envOr("WETH_SEPOLIA", DEFAULT_WETH);
        c.router = vm.envOr("UNIVERSAL_ROUTER", DEFAULT_ROUTER);
        c.quoter = vm.envOr("UNISWAP_QUOTER", DEFAULT_QUOTER);
        c.depository = vm.envAddress("LAYERSWAP_DEPOSITORY");
        c.receiver = vm.envAddress("DEPOSIT_RECEIVER");
        c.feeRecipient = vm.envAddress("FEE_RECIPIENT");

        c.user = vm.addr(userPk);
        address userEnv = vm.envOr("USER_ADDRESS", address(0));
        require(userEnv == address(0) || userEnv == c.user, "USER_ADDRESS != addr(USER_PRIVATE_KEY)");
        // executor == EIP-3009 `to` == the delegated relayer account (NOT the impl).
        c.executor = vm.envOr("CALIBUR_EXECUTOR", vm.addr(broadcasterPk));

        c.feeIn = uint24(vm.envOr("POOL_FEE_IN", uint256(3000)));
        c.feeOut = uint24(vm.envOr("POOL_FEE_OUT", uint256(500)));
        c.amountIn = vm.envUint("AMOUNT_IN");
        c.feeAmount = vm.envUint("FEE_AMOUNT");
        c.slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100)); // default 1%
        c.depositId = vm.envOr("DEPOSIT_ID", bytes32(vm.randomUint()));
    }

    function _validate(Cfg memory c) internal pure {
        require(c.usdc != address(0), "USDC_SEPOLIA is zero");
        require(c.weth != address(0), "WETH is zero");
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
            console2.log("WARNING: DEPOSIT_RECEIVER is NOT whitelisted; depositERC20 reverts (NotWhitelisted).");
            console2.log("  receiver:", c.receiver);
        }
        if (c.executor.code.length == 0) {
            console2.log("WARNING: executor has NO code -> not delegated to Calibur. Run EnableDelegation.s.sol first.");
            console2.log("  executor:", c.executor);
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
    // Router program (the dynamic swap chain + payouts)
    // -------------------------------------------------------------------------

    function _buildRouterProgram(Cfg memory c, uint256 minWeth, uint256 minUsdcBack, uint256 floor)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        // Sequence: swap -> unwrap -> wrap -> swap -> fee transfer -> sweep remainder.
        commands = abi.encodePacked(V3_SWAP_EXACT_IN, UNWRAP_WETH, WRAP_ETH, V3_SWAP_EXACT_IN, TRANSFER, SWEEP);

        // v3 path = tokenIn | fee(uint24) | tokenOut (tightly packed).
        bytes memory pathIn = abi.encodePacked(c.usdc, c.feeIn, c.weth);
        bytes memory pathOut = abi.encodePacked(c.weth, c.feeOut, c.usdc);

        inputs = new bytes[](6);
        // a. swap the router's whole USDC balance -> WETH (payerIsUser = false: funds already in router)
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, minWeth, pathIn, false);
        // b. AAVE SUBSTITUTE: unwrap all WETH -> ETH, then rewrap all ETH -> WETH (net no-op on WETH)
        inputs[1] = abi.encode(ADDRESS_THIS, minWeth);
        inputs[2] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE);
        // c. 0x SUBSTITUTE: swap the router's whole WETH balance -> USDC (second Uniswap hop)
        inputs[3] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, minUsdcBack, pathOut, false);
        // d. pay the small absolute fee to the fee EOA
        inputs[4] = abi.encode(c.usdc, c.feeRecipient, c.feeAmount);
        // e. sweep the remaining USDC back to the executor (guarded by the floor)
        inputs[5] = abi.encode(c.usdc, c.executor, floor);
    }

    // -------------------------------------------------------------------------
    // Calibur batch
    // -------------------------------------------------------------------------

    function _buildBatch(
        Cfg memory c,
        bytes memory routerCall,
        uint256 floor,
        uint256 validBefore,
        bytes32 authNonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (Call[] memory calls) {
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
        // 2. move the inbound USDC into the router so its commands can use CONTRACT_BALANCE
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, c.amountIn))});
        // 3. the entire dynamic DeFi chain, inside the unowned Universal Router
        calls[2] = Call({to: c.router, value: 0, data: routerCall});
        // 4. approve exactly the floor for the depository pull
        calls[3] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.approve, (c.depository, floor))});
        // 5. Layerswap deposit (emits Deposited); receiver must be whitelisted
        calls[4] = Call({
            to: c.depository,
            value: 0,
            data: abi.encodeCall(ILayerswapDepository.depositERC20, (c.depositId, c.usdc, c.receiver, floor))
        });
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

    function _logPlan(Cfg memory c, uint256 minWeth, uint256 minUsdcBack, uint256 floor) internal pure {
        console2.log("==================================================");
        console2.log("Calibur router-native gasless DeFi flow (Sepolia)");
        console2.log("--------------------------------------------------");
        console2.log("STAGE 1  gasless inbound: USDC.receiveWithAuthorization(user -> executor)");
        console2.log("  amountIn (USDC, 6dp):", c.amountIn);
        console2.log("STAGE 2  USDC.transfer(universalRouter, amountIn)");
        console2.log("STAGE 3  UniversalRouter.execute():");
        console2.log("  a. swap USDC -> WETH (Uniswap v3, feeIn), minOut:", minWeth);
        console2.log("  b. AAVE SUBSTITUTE: WETH unwrap -> rewrap (WETH9)");
        console2.log("  c. 0x SUBSTITUTE: swap WETH -> USDC (Uniswap v3, feeOut), minOut:", minUsdcBack);
        console2.log("  d. TRANSFER fee -> feeRecipient:", c.feeAmount);
        console2.log("  e. SWEEP remainder -> executor (min:", floor);
        console2.log("STAGE 4  USDC.approve(depository, floor)");
        console2.log("STAGE 5  LayerswapDepository.depositERC20(floor):", floor);
        console2.log("  (dust above the floor stays in the executor)");
        console2.log("--------------------------------------------------");
    }

    function _logSummary(Cfg memory c, bytes32 authNonce) internal pure {
        console2.log("--------------------------------------------------");
        console2.log("Batch submitted by relayer (pays all gas).");
        console2.log("  user (EIP-3009 from):", c.user);
        console2.log("  executor (EIP-3009 to == relayer):", c.executor);
        console2.log("  USDC in:", c.usdc);
        console2.log("  universal router:", c.router);
        console2.log("  fee recipient EOA:", c.feeRecipient);
        console2.log("  layerswap depository:", c.depository);
        console2.log("  layerswap receiver:", c.receiver);
        console2.log("  auth nonce:");
        console2.logBytes32(authNonce);
        console2.log("  deposit id:");
        console2.logBytes32(c.depositId);
        console2.log("  (tx hash printed by forge below after broadcast)");
        console2.log("==================================================");
    }
}
