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
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";

/// @title CaliburMultiPairFlowScript (v2 — REAL Aave v3 + zero dust)
/// @notice The flagship variant: THREE distinct EOAs, SIX swaps across FIVE
///         different Uniswap v3 pools, a REAL Aave v3 supply+withdraw in the
///         middle, and a zero-dust finish via our depository's `depositERC20All`.
///         All dynamic chaining is delegated to Uniswap's unowned Universal
///         Router and Aave — no orchestration contract of our own.
///
/// THREE DISTINCT ROLES (all different addresses; enforced in _validate):
///   * payer (USER_PRIVATE_KEY)          — holds USDC, signs the EIP-3009 auth.
///   * relayer/executor (PRIVATE_KEY)    — delegated to Calibur (EIP-7702),
///       broadcasts, pays ALL gas, is the batch executor and EIP-3009 `to`.
///   * fee recipient (FEE_RECIPIENT)     — receives the fee; neither of the above.
///
/// HOW REAL AAVE BECOMES ATOMICALLY REACHABLE: Aave v3 Sepolia's reserves are
/// Aave's own faucet tokens, not the canonical assets — but a real Uniswap v3
/// pool (canonical WETH9 / aaveWETH, 0.30%) bridges them. We use the WETH
/// reserve because it has NO supply cap (the aaveUSDC/aaveDAI reserves sit above
/// their caps, so `supply` reverts SUPPLY_CAP_EXCEEDED there). And Aave's
/// `withdraw(asset, type(uint256).max, to)` is a DYNAMIC-amount primitive that
/// can pay straight to the Universal Router, so the chain re-enters the router
/// with no static-amount hop. Supplying and withdrawing in the SAME transaction
/// round-trips the exact amount (no time passes -> no interest accrues).
///
/// ONE atomic 10-call Calibur batch (any revert rolls back everything):
///   1. USDC.receiveWithAuthorization(user -> executor)      // gasless inbound
///   2. USDC.transfer(universalRouter, amountIn)             // pre-fund router
///   3. UniversalRouter.execute() — trip 1 (4 swaps):
///        USDC -> WETH      (pool 1: USDC/WETH     0.30%)
///        WETH -> UNI       (pool 2: WETH/UNI      0.30%)
///        UNI  -> WETH      (pool 3: UNI/WETH      0.05%)
///        WETH -> aaveWETH  (pool 4: bridge        0.30%), min = floorA
///        TRANSFER floorA aaveWETH -> executor
///        (the excess above floorA DELIBERATELY stays in the router — trip 2's
///         CONTRACT_BALANCE swap consumes it, so it is never dust)
///   4. aaveWETH.approve(aavePool, floorA)
///   5. AavePool.supply(aaveWETH, floorA, executor, 0)       // REAL Aave supply
///   6. AavePool.withdraw(aaveWETH, type(uint256).max, router) // REAL Aave
///        withdraw of the executor's WHOLE aToken balance, paid DIRECTLY to the
///        router (== exactly floorA: same-tx supply+withdraw accrues no interest)
///   7. UniversalRouter.execute() — trip 2 (2 swaps):
///        aaveWETH -> WETH (pool 4 again; consumes withdraw output + trip-1 excess)
///        WETH -> USDC     (pool 5: WETH/USDC 0.05%)
///        TRANSFER fee -> fee recipient EOA                  // payout 1
///        SWEEP ALL remaining USDC -> executor (min-out guarded)
///   8. USDC.approve(depository, type(uint256).max)
///   9. LayerswapDepository.depositERC20All(id, USDC, receiver) // payout 2:
///        deposits the executor's ENTIRE dynamic USDC balance — ZERO dust
///  10. USDC.approve(depository, 0)                          // hygiene
///
/// ZERO DUST, EVERY TOKEN: trip-1's aaveWETH excess is consumed by trip 2;
/// the executor's whole USDC balance is deposited by depositERC20All; all other
/// legs run on CONTRACT_BALANCE so nothing lingers anywhere.
///
/// PRICING NOTE: the bridge pool's REVERSE leg (aaveWETH -> WETH) cannot be
/// quoted at pre-trade state — the pool may hold ~no WETH-side liquidity until
/// OUR forward leg deposits it. A same-pool round trip in one tx always returns
/// >= input * (1-fee)^2, so that floor is computed analytically.
///
/// Usage:
///   forge script script/CaliburMultiPairFlow.s.sol:CaliburMultiPairFlowScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract CaliburMultiPairFlowScript is Script {
    bytes32 internal constant ERC7821_BATCH_MODE =
        0x0100000000000000000000000000000000000000000000000000000000000000;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    // Universal Router command bytes (Uniswap Commands.sol).
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant SWEEP = 0x04;
    bytes1 internal constant TRANSFER = 0x05;

    // Universal Router sentinels (Constants.sol).
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;
    address internal constant ADDRESS_THIS = address(2);

    // Sepolia infra / tokens (all overridable via env).
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant DEFAULT_UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant DEFAULT_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address internal constant DEFAULT_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
    // Aave v3 Sepolia (via PoolAddressesProvider 0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A).
    address internal constant DEFAULT_AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    // Aave v3 Sepolia's WETH reserve (Aave faucet token, NOT canonical WETH9).
    // Chosen because its supply cap is 0 == UNLIMITED (aaveUSDC/aaveDAI are over cap).
    address internal constant DEFAULT_AAVE_WETH = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;

    struct Cfg {
        address usdc;
        address weth;
        address uni;
        address aaveWeth;
        address aavePool;
        address router;
        address quoter;
        address depository;
        address receiver;
        address feeRecipient;
        address executor;
        address user;
        uint24 fee1; // USDC/WETH
        uint24 fee2; // WETH/UNI
        uint24 fee3; // UNI/WETH
        uint24 fee4; // WETH/USDC (trip 2 exit)
        uint24 feeAave; // WETH/aaveWETH bridge pool (both directions)
        uint256 amountIn;
        uint256 feeAmount;
        uint256 slippageBps;
        bytes32 depositId;
    }

    /// @dev Guaranteed per-hop minimums, each priced from the previous minimum.
    struct Mins {
        uint256 weth1; // hop 1: USDC -> WETH
        uint256 uni; // hop 2: WETH -> UNI
        uint256 weth2; // hop 3: UNI -> WETH
        uint256 floorA; // hop 4: WETH -> aaveWETH (the amount supplied to Aave)
        uint256 wethBack; // trip 2: aaveWETH -> WETH (analytic round-trip floor)
        uint256 usdcFinal; // trip 2: WETH -> USDC
        uint256 sweepFloor; // usdcFinal - feeAmount (SWEEP min-out only)
    }

    function run() external {
        uint256 broadcasterPk = vm.envUint("PRIVATE_KEY"); // relayer/sponsor (delegated)
        uint256 userPk = vm.envUint("USER_PRIVATE_KEY"); // payer (signs EIP-3009)

        Cfg memory c = _loadCfg(broadcasterPk, userPk);
        _validate(c);
        _preflight(c);

        (bytes memory trip1, bytes memory trip2, Mins memory m) = _buildRouterCalls(c);
        (Call[] memory calls, bytes32 authNonce) = _finalizeBatch(c, userPk, trip1, trip2, m.floorA);

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
        c.aaveWeth = vm.envOr("AAVE_WETH_SEPOLIA", DEFAULT_AAVE_WETH);
        c.aavePool = vm.envOr("AAVE_POOL_SEPOLIA", DEFAULT_AAVE_POOL);
        c.router = vm.envOr("UNIVERSAL_ROUTER", DEFAULT_ROUTER);
        c.quoter = vm.envOr("UNISWAP_QUOTER", DEFAULT_QUOTER);
        c.depository = vm.envAddress("LAYERSWAP_DEPOSITORY");
        c.receiver = vm.envAddress("DEPOSIT_RECEIVER");
        c.feeRecipient = vm.envAddress("FEE_RECIPIENT");

        c.user = vm.addr(userPk);
        address userEnv = vm.envOr("USER_ADDRESS", address(0));
        require(userEnv == address(0) || userEnv == c.user, "USER_ADDRESS != addr(USER_PRIVATE_KEY)");
        c.executor = vm.envOr("CALIBUR_EXECUTOR", vm.addr(broadcasterPk));

        c.fee1 = uint24(vm.envOr("POOL_FEE_1", uint256(3000))); // USDC/WETH
        c.fee2 = uint24(vm.envOr("POOL_FEE_2", uint256(3000))); // WETH/UNI
        c.fee3 = uint24(vm.envOr("POOL_FEE_3", uint256(500))); // UNI/WETH
        c.fee4 = uint24(vm.envOr("POOL_FEE_4", uint256(500))); // WETH/USDC
        c.feeAave = uint24(vm.envOr("POOL_FEE_AAVE", uint256(3000))); // WETH/aaveWETH

        c.amountIn = vm.envUint("AMOUNT_IN");
        c.feeAmount = vm.envUint("FEE_AMOUNT");
        c.slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100));
        c.depositId = vm.envOr("DEPOSIT_ID", bytes32(vm.randomUint()));
    }

    function _validate(Cfg memory c) internal pure {
        require(c.usdc != address(0), "USDC_SEPOLIA is zero");
        require(c.weth != address(0), "WETH is zero");
        require(c.uni != address(0), "UNI is zero");
        require(c.aaveWeth != address(0), "aaveWETH is zero");
        require(c.aavePool != address(0), "Aave pool is zero");
        require(c.router != address(0), "router is zero");
        require(c.quoter != address(0), "quoter is zero");
        require(c.depository != address(0), "LAYERSWAP_DEPOSITORY is zero");
        require(c.receiver != address(0), "DEPOSIT_RECEIVER is zero");
        require(c.feeRecipient != address(0), "FEE_RECIPIENT is zero");
        require(c.executor != address(0), "executor is zero");
        require(c.user != address(0), "user is zero");
        // THREE distinct EOAs.
        require(c.user != c.executor, "user must differ from relayer/executor");
        require(c.feeRecipient != c.user, "fee recipient must differ from user");
        require(c.feeRecipient != c.executor, "fee recipient must differ from relayer/executor");
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
        }
        if (c.executor.code.length == 0) {
            console2.log("WARNING: executor has NO code -> not delegated to Calibur. Run EnableDelegation.s.sol first.");
        }
        uint256 priorDust = IERC20(c.usdc).balanceOf(c.executor);
        if (priorDust > 0) {
            console2.log("NOTE: executor holds pre-existing USDC that depositERC20All will sweep into the deposit:", priorDust);
        }
    }

    // -------------------------------------------------------------------------
    // Router programs (trip 1: 4 swaps into Aave's token; trip 2: back + payouts)
    // -------------------------------------------------------------------------

    /// @dev Price every hop off-chain (each from the previous hop's minimum) and
    ///      encode both Universal Router programs.
    function _buildRouterCalls(Cfg memory c)
        internal
        returns (bytes memory trip1, bytes memory trip2, Mins memory m)
    {
        m.weth1 = _applySlippage(_quote(c.quoter, c.usdc, c.weth, c.amountIn, c.fee1), c.slippageBps);
        m.uni = _applySlippage(_quote(c.quoter, c.weth, c.uni, m.weth1, c.fee2), c.slippageBps);
        m.weth2 = _applySlippage(_quote(c.quoter, c.uni, c.weth, m.uni, c.fee3), c.slippageBps);
        m.floorA = _applySlippage(_quote(c.quoter, c.weth, c.aaveWeth, m.weth2, c.feeAave), c.slippageBps);
        // Reverse bridge leg (aaveWETH -> WETH) cannot be quoted at PRE-trade
        // state: the pool may hold ~no WETH-side liquidity until OUR forward leg
        // deposits it. A same-pool round trip in one tx always returns
        // >= input * (1-fee)^2, so this floor is computed analytically.
        m.wethBack =
            _applySlippage((m.weth2 * (1e6 - c.feeAave) / 1e6) * (1e6 - c.feeAave) / 1e6, c.slippageBps);
        m.usdcFinal = _applySlippage(_quote(c.quoter, c.weth, c.usdc, m.wethBack, c.fee4), c.slippageBps);
        require(m.usdcFinal > c.feeAmount, "FEE_AMOUNT >= guaranteed output; lower it");
        m.sweepFloor = m.usdcFinal - c.feeAmount;

        _logPlan(c, m);

        uint256 deadline = block.timestamp + 30 minutes;
        (bytes memory cmds1, bytes[] memory in1) = _trip1Program(c, m);
        (bytes memory cmds2, bytes[] memory in2) = _trip2Program(c, m);
        trip1 = abi.encodeCall(IUniversalRouter.execute, (cmds1, in1, deadline));
        trip2 = abi.encodeCall(IUniversalRouter.execute, (cmds2, in2, deadline));
    }

    function _trip1Program(Cfg memory c, Mins memory m)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        // 4 swaps across 4 different pools, then hand floorA of aaveWETH to the
        // executor for the Aave leg. NO sweep: the excess above floorA stays in
        // the router on purpose — trip 2's CONTRACT_BALANCE swap consumes it.
        commands =
            abi.encodePacked(V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, TRANSFER);

        inputs = new bytes[](5);
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.weth1, abi.encodePacked(c.usdc, c.fee1, c.weth), false);
        inputs[1] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.uni, abi.encodePacked(c.weth, c.fee2, c.uni), false);
        inputs[2] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.weth2, abi.encodePacked(c.uni, c.fee3, c.weth), false);
        inputs[3] = abi.encode(
            ADDRESS_THIS, CONTRACT_BALANCE, m.floorA, abi.encodePacked(c.weth, c.feeAave, c.aaveWeth), false
        );
        inputs[4] = abi.encode(c.aaveWeth, c.executor, m.floorA); // exactly floorA out for the Aave leg
    }

    function _trip2Program(Cfg memory c, Mins memory m)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        // Swap back everything the router now holds of aaveWETH (the Aave
        // withdraw paid here directly + trip-1's excess), exit to USDC, then the
        // two payouts.
        commands = abi.encodePacked(V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, TRANSFER, SWEEP);

        inputs = new bytes[](4);
        inputs[0] = abi.encode(
            ADDRESS_THIS, CONTRACT_BALANCE, m.wethBack, abi.encodePacked(c.aaveWeth, c.feeAave, c.weth), false
        );
        inputs[1] =
            abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, m.usdcFinal, abi.encodePacked(c.weth, c.fee4, c.usdc), false);
        inputs[2] = abi.encode(c.usdc, c.feeRecipient, c.feeAmount); // payout 1: fee
        inputs[3] = abi.encode(c.usdc, c.executor, m.sweepFloor); // sweep ALL USDC to executor
    }

    // -------------------------------------------------------------------------
    // Calibur batch
    // -------------------------------------------------------------------------

    function _finalizeBatch(Cfg memory c, uint256 userPk, bytes memory trip1, bytes memory trip2, uint256 floorA)
        internal
        view
        returns (Call[] memory calls, bytes32 authNonce)
    {
        uint256 validBefore = block.timestamp + 10 minutes;
        authNonce = bytes32(vm.randomUint());
        (uint8 v, bytes32 r, bytes32 s) = _signAuth(userPk, c, validBefore, authNonce);

        calls = new Call[](10);
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
        // 3. router trip 1: the 4-pool swap chain ending in aaveWETH
        calls[2] = Call({to: c.router, value: 0, data: trip1});
        // 4. allow Aave to pull exactly the supplied amount
        calls[3] = Call({to: c.aaveWeth, value: 0, data: abi.encodeCall(IERC20.approve, (c.aavePool, floorA))});
        // 5. REAL Aave v3 supply (aTokens minted to the executor)
        calls[4] = Call({
            to: c.aavePool,
            value: 0,
            data: abi.encodeCall(IAaveV3Pool.supply, (c.aaveWeth, floorA, c.executor, 0))
        });
        // 6. REAL Aave v3 withdraw of the WHOLE aToken balance, straight to the router
        calls[5] = Call({
            to: c.aavePool,
            value: 0,
            data: abi.encodeCall(IAaveV3Pool.withdraw, (c.aaveWeth, type(uint256).max, c.router))
        });
        // 7. router trip 2: swap back to USDC, pay the fee, sweep the rest
        calls[6] = Call({to: c.router, value: 0, data: trip2});
        // 8. approve max so depositERC20All can pull the dynamic balance
        calls[7] =
            Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.approve, (c.depository, type(uint256).max))});
        // 9. payout 2: deposit the executor's ENTIRE USDC balance — zero dust
        calls[8] = Call({
            to: c.depository,
            value: 0,
            data: abi.encodeCall(ILayerswapDepository.depositERC20All, (c.depositId, c.usdc, c.receiver))
        });
        // 10. hygiene: drop the standing allowance
        calls[9] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.approve, (c.depository, 0))});
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
        console2.log("Calibur multi-pair + REAL Aave v3 gasless flow (Sepolia, zero dust)");
        console2.log("--------------------------------------------------");
        console2.log("ROLES (three distinct EOAs):");
        console2.log("  payer (user):", c.user);
        console2.log("  relayer/executor:", c.executor);
        console2.log("  fee recipient:", c.feeRecipient);
        console2.log("--------------------------------------------------");
        console2.log("STAGE 1  gasless inbound (EIP-3009), amountIn:", c.amountIn);
        console2.log("STAGE 2  USDC.transfer(universalRouter, amountIn)");
        console2.log("STAGE 3  router trip 1 -- 4 swaps, 4 pools:");
        console2.log("  hop 1: USDC -> WETH      minOut:", m.weth1);
        console2.log("  hop 2: WETH -> UNI       minOut:", m.uni);
        console2.log("  hop 3: UNI  -> WETH      minOut:", m.weth2);
        console2.log("  hop 4: WETH -> aaveWETH  minOut:", m.floorA);
        console2.log("  TRANSFER floorA aaveWETH -> executor (excess stays in router for trip 2)");
        console2.log("STAGE 4  aaveWETH.approve(aavePool, floorA)");
        console2.log("STAGE 5  AavePool.supply(aaveWETH, floorA, executor)   << REAL AAVE");
        console2.log("STAGE 6  AavePool.withdraw(aaveWETH, MAX, router)      << REAL AAVE");
        console2.log("STAGE 7  router trip 2 -- 2 swaps + payouts:");
        console2.log("  aaveWETH -> WETH         minOut:", m.wethBack);
        console2.log("  WETH -> USDC             minOut:", m.usdcFinal);
        console2.log("  TRANSFER fee -> feeRecipient:", c.feeAmount);
        console2.log("  SWEEP ALL USDC -> executor, min:", m.sweepFloor);
        console2.log("STAGE 8  USDC.approve(depository, max)");
        console2.log("STAGE 9  depositERC20All -- executor's WHOLE balance (zero dust)");
        console2.log("STAGE 10 USDC.approve(depository, 0)");
        console2.log("--------------------------------------------------");
    }

    function _logSummary(Cfg memory c, Mins memory m, bytes32 authNonce) internal pure {
        console2.log("--------------------------------------------------");
        console2.log("Batch submitted by relayer (pays all gas).");
        console2.log("  token path: USDC -> WETH -> UNI -> WETH -> aaveWETH -> (Aave) -> aaveWETH -> WETH -> USDC");
        console2.log("  USDC (Circle):", c.usdc);
        console2.log("  aaveWETH (Aave faucet):", c.aaveWeth);
        console2.log("  Aave v3 pool:", c.aavePool);
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
