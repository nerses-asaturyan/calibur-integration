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

/// @title CaliburMultiPairFlowScript
/// @notice Variant of CaliburRouterFlow that (a) uses THREE distinct EOAs and
///         (b) routes through THREE DIFFERENT token pairs, so the swap chain is
///         visually obvious on a block explorer. Still ZERO new contracts: the
///         dynamic multi-hop chaining runs inside Uniswap's unowned Universal
///         Router via the CONTRACT_BALANCE sentinel.
///
/// THREE DISTINCT ROLES (all different addresses; enforced in _validate):
///   * payer (USER_PRIVATE_KEY)          — holds USDC, signs the EIP-3009 auth.
///   * relayer/executor (PRIVATE_KEY)    — delegated to Calibur (EIP-7702),
///       broadcasts, pays ALL gas, is the batch executor and EIP-3009 `to`.
///   * fee recipient (FEE_RECIPIENT)     — receives the fee; neither of the above.
///
/// SWAP CHAIN (three different Uniswap v3 pairs, all real Sepolia liquidity):
///   USDC --(pair 1: USDC/WETH)--> WETH --(pair 2: WETH/UNI)--> UNI
///        --(pair 3: UNI/USDC)--> USDC
/// Each leg feeds the next via CONTRACT_BALANCE, so no intermediate amount is
/// known at sign time. We end back in USDC purely so the deposit amount is easy
/// to read against the input; Layerswap is token-agnostic, so any final token
/// would work.
///
/// ONE atomic 5-call Calibur batch (any revert rolls back everything, incl. the
/// EIP-3009 receive):
///   1. USDC.receiveWithAuthorization(user -> executor)       // gasless inbound
///   2. USDC.transfer(universalRouter, amountIn)              // pre-fund router
///   3. UniversalRouter.execute():
///        V3_SWAP_EXACT_IN USDC->WETH, WETH->UNI, UNI->USDC   // the 3-pair chain
///        TRANSFER small fee -> fee recipient EOA             // payout 1
///        SWEEP  remainder    -> executor                     // (guarded by floor)
///   4. USDC.approve(depository, floor)
///   5. LayerswapDepository.depositERC20(id, USDC, receiver, floor)  // payout 2
///
/// The Layerswap amount is a slippage-computed FLOOR (minUsdcBack - feeAmount)
/// because an unowned router cannot call depositERC20 and a static Calibur Call
/// must name an exact amount; excess over the floor stays as dust in the executor.
/// (This variant drops the WETH wrap/unwrap "Aave substitute" from CaliburRouterFlow
/// to keep the multi-pair swap path the visual focus.)
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
    address internal constant DEFAULT_UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // Sepolia UNI (liquid vs WETH & USDC)
    address internal constant DEFAULT_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address internal constant DEFAULT_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;

    struct Cfg {
        address usdc;
        address weth;
        address uni;
        address router;
        address quoter;
        address depository;
        address receiver;
        address feeRecipient;
        address executor;
        address user;
        uint24 fee1; // USDC/WETH
        uint24 fee2; // WETH/UNI
        uint24 fee3; // UNI/USDC
        uint256 amountIn;
        uint256 feeAmount;
        uint256 slippageBps;
        bytes32 depositId;
    }

    function run() external {
        uint256 broadcasterPk = vm.envUint("PRIVATE_KEY"); // relayer/sponsor (delegated)
        uint256 userPk = vm.envUint("USER_PRIVATE_KEY"); // payer (signs EIP-3009)

        Cfg memory c = _loadCfg(broadcasterPk, userPk);
        _validate(c);
        _preflight(c);

        (bytes memory routerCall, uint256 floor) = _buildRouterCall(c);
        (Call[] memory calls, bytes32 authNonce) = _finalizeBatch(c, userPk, routerCall, floor);

        vm.startBroadcast(broadcasterPk);
        IERC7821(c.executor).execute(ERC7821_BATCH_MODE, abi.encode(calls));
        vm.stopBroadcast();

        _logSummary(c, authNonce);
    }

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

        // Pair fee tiers (defaults are the liquid Sepolia pools).
        c.fee1 = uint24(vm.envOr("POOL_FEE_1", uint256(3000))); // USDC/WETH
        c.fee2 = uint24(vm.envOr("POOL_FEE_2", uint256(3000))); // WETH/UNI
        c.fee3 = uint24(vm.envOr("POOL_FEE_3", uint256(500))); // UNI/USDC

        c.amountIn = vm.envUint("AMOUNT_IN");
        c.feeAmount = vm.envUint("FEE_AMOUNT");
        c.slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100));
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
            console2.log("WARNING: DEPOSIT_RECEIVER is NOT whitelisted; depositERC20 reverts (NotWhitelisted).");
        }
        if (c.executor.code.length == 0) {
            console2.log("WARNING: executor has NO code -> not delegated to Calibur. Run EnableDelegation.s.sol first.");
        }
    }

    /// @dev Price the three hops off-chain (each priced from the previous hop's
    ///      minimum output, so the floor is always achievable), then encode the
    ///      Universal Router program that carries the dynamic 3-pair chain.
    function _buildRouterCall(Cfg memory c) internal returns (bytes memory routerCall, uint256 floor) {
        uint256 minWeth = _applySlippage(_quote(c.quoter, c.usdc, c.weth, c.amountIn, c.fee1), c.slippageBps);
        uint256 minUni = _applySlippage(_quote(c.quoter, c.weth, c.uni, minWeth, c.fee2), c.slippageBps);
        uint256 minUsdcBack = _applySlippage(_quote(c.quoter, c.uni, c.usdc, minUni, c.fee3), c.slippageBps);
        require(minUsdcBack > c.feeAmount, "FEE_AMOUNT >= guaranteed output; lower it");
        floor = minUsdcBack - c.feeAmount;

        _logPlan(c, minWeth, minUni, minUsdcBack, floor);

        (bytes memory commands, bytes[] memory inputs) = _buildRouterProgram(c, minWeth, minUni, minUsdcBack, floor);
        uint256 routerDeadline = block.timestamp + 30 minutes;
        routerCall = abi.encodeCall(IUniversalRouter.execute, (commands, inputs, routerDeadline));
    }

    function _buildRouterProgram(Cfg memory c, uint256 minWeth, uint256 minUni, uint256 minUsdcBack, uint256 floor)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        // 3 swaps (different pairs) -> fee transfer -> sweep remainder.
        commands = abi.encodePacked(V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, TRANSFER, SWEEP);

        bytes memory path1 = abi.encodePacked(c.usdc, c.fee1, c.weth); // pair 1: USDC/WETH
        bytes memory path2 = abi.encodePacked(c.weth, c.fee2, c.uni); // pair 2: WETH/UNI
        bytes memory path3 = abi.encodePacked(c.uni, c.fee3, c.usdc); // pair 3: UNI/USDC

        inputs = new bytes[](5);
        // payerIsUser = false: funds are already in the router (pre-funded in call 2);
        // amountIn = CONTRACT_BALANCE: consume the full output of the previous hop.
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, minWeth, path1, false);
        inputs[1] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, minUni, path2, false);
        inputs[2] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, minUsdcBack, path3, false);
        inputs[3] = abi.encode(c.usdc, c.feeRecipient, c.feeAmount); // TRANSFER fee
        inputs[4] = abi.encode(c.usdc, c.executor, floor); // SWEEP remainder to executor (min = floor)
    }

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
        calls[0] = Call({
            to: c.usdc,
            value: 0,
            data: abi.encodeCall(
                IERC3009USDC.receiveWithAuthorization,
                (c.user, c.executor, c.amountIn, 0, validBefore, authNonce, v, r, s)
            )
        });
        calls[1] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.transfer, (c.router, c.amountIn))});
        calls[2] = Call({to: c.router, value: 0, data: routerCall});
        calls[3] = Call({to: c.usdc, value: 0, data: abi.encodeCall(IERC20.approve, (c.depository, floor))});
        calls[4] = Call({
            to: c.depository,
            value: 0,
            data: abi.encodeCall(ILayerswapDepository.depositERC20, (c.depositId, c.usdc, c.receiver, floor))
        });
    }

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

    function _logPlan(Cfg memory c, uint256 minWeth, uint256 minUni, uint256 minUsdcBack, uint256 floor)
        internal
        pure
    {
        console2.log("==================================================");
        console2.log("Calibur multi-pair gasless DeFi flow (Sepolia)");
        console2.log("--------------------------------------------------");
        console2.log("ROLES (three distinct EOAs):");
        console2.log("  payer (user):", c.user);
        console2.log("  relayer/executor:", c.executor);
        console2.log("  fee recipient:", c.feeRecipient);
        console2.log("--------------------------------------------------");
        console2.log("STAGE 1  gasless inbound: receiveWithAuthorization(user -> executor), amountIn:", c.amountIn);
        console2.log("STAGE 2  USDC.transfer(universalRouter, amountIn)");
        console2.log("STAGE 3  UniversalRouter.execute() -- 3 different pairs:");
        console2.log("  hop 1: USDC -> WETH  minOut:", minWeth);
        console2.log("  hop 2: WETH -> UNI   minOut:", minUni);
        console2.log("  hop 3: UNI  -> USDC  minOut:", minUsdcBack);
        console2.log("  fee   -> feeRecipient:", c.feeAmount);
        console2.log("  sweep -> executor (min):", floor);
        console2.log("STAGE 4  USDC.approve(depository, floor)");
        console2.log("STAGE 5  LayerswapDepository.depositERC20(floor):", floor);
        console2.log("--------------------------------------------------");
    }

    function _logSummary(Cfg memory c, bytes32 authNonce) internal pure {
        console2.log("--------------------------------------------------");
        console2.log("Batch submitted by relayer (pays all gas).");
        console2.log("  token path: USDC -> WETH -> UNI -> USDC");
        console2.log("  USDC:", c.usdc);
        console2.log("  WETH:", c.weth);
        console2.log("  UNI :", c.uni);
        console2.log("  layerswap receiver:", c.receiver);
        console2.log("  auth nonce:");
        console2.logBytes32(authNonce);
        console2.log("  deposit id:");
        console2.logBytes32(c.depositId);
        console2.log("  (tx hash printed by forge below after broadcast)");
        console2.log("==================================================");
    }
}
