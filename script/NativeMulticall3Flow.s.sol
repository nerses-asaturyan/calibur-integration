// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";

import {ILayerswapDepository} from "../src/interfaces/ILayerswapDepository.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IQuoterV2} from "../src/interfaces/IQuoterV2.sol";

/// @title NativeMulticall3FlowScript (TX 5)
/// @notice USER-INVOKED native-ETH deposit flow using ONLY well-known, already
///         deployed contracts — no custom contract anywhere (not even our
///         PayoutSplitter). The USER sends one transaction (and therefore pays
///         its gas — inherent to native inbound: nothing can pull ETH from a
///         plain EOA by signature).
///
/// WHY THIS NEEDS NO SPLITTER: the user chooses the ETH amount, so per-leg
/// values are computable UPFRONT — Multicall3's value-bearing `Call3Value[]`
/// IS the splitter for the inbound. Dynamic amounts only exist AFTER a swap,
/// and there the Universal Router's own PAY_PORTION/SWEEP split dynamically.
///
/// ONE atomic Multicall3.aggregate3Value{value: AMOUNT_ETH} from the payer:
///   1. {fee EOA,             value: 12.34%, data: ""}          plain ETH send
///   2. {ORIGINAL depository, value: 37.66%, depositNative(id, receiver)}
///        -> emits Deposited(id, address(0), receiver, 37.66%)
///   3. {Universal Router,    value: 50.00%, execute():
///        WRAP_ETH(whole balance) -> V3_SWAP WETH -> USDC (0.05% pool)
///        PAY_PORTION 25% of the USDC -> fee EOA               (dynamic split)
///        SWEEP remaining USDC        -> the payer              (dynamic split)}
///
/// ZERO DUST: leg values sum to msg.value exactly (last leg = remainder);
/// the router is fully drained by PAY_PORTION + SWEEP; Multicall3 holds nothing
/// across the call. Any leg reverting reverts the whole tx (allowFailure=false).
///
/// KNOWN CONTRACTS ONLY: Multicall3 0xcA11…CA11, WETH9, Uniswap V3 pool,
/// Universal Router, and the ORIGINAL LayerswapDepository.
///
/// Usage:
///   forge script script/NativeMulticall3Flow.s.sol:NativeMulticall3FlowScript \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
contract NativeMulticall3FlowScript is Script {
    // --- Universal Router command bytes (Uniswap Commands.sol) ---
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant SWEEP = 0x04;
    bytes1 internal constant PAY_PORTION = 0x06;
    bytes1 internal constant WRAP_ETH = 0x0b;

    // --- Universal Router sentinels (Constants.sol) ---
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;
    address internal constant ADDRESS_THIS = address(2);

    // Known Sepolia deployments (all overridable via env).
    address internal constant DEFAULT_MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant DEFAULT_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address internal constant DEFAULT_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
    address internal constant DEFAULT_ORIGINAL_DEPOSITORY = 0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4;

    struct Cfg {
        address multicall3;
        address weth;
        address usdc;
        address router;
        address quoter;
        address depository; // ORIGINAL depository
        address receiver; // whitelisted Layerswap receiver
        address feeEoa; // payout EOA (gets the exact-% ETH leg + the dynamic USDC portion)
        address user; // the payer — SENDS this tx itself
        uint24 poolFee; // WETH/USDC pool for the swap leg
        uint256 amountEth; // total native input
        uint256 bpsFee; // leg 1: exact-% ETH to fee EOA
        uint256 bpsDeposit; // leg 2: exact-% ETH to depositNative (leg 3 = remainder)
        uint256 usdcPortionBps; // dynamic split inside the router leg
        uint256 slippageBps;
        bytes32 depositId;
    }

    function run() external {
        uint256 userPk = vm.envUint("USER_PRIVATE_KEY"); // the USER sends this tx

        Cfg memory c = _loadCfg(userPk);
        _validate(c);
        _preflight(c);

        (IMulticall3.Call3Value[] memory calls, uint256 minUsdcOut) = _buildCalls(c);
        _logPlan(c, minUsdcOut);

        vm.startBroadcast(userPk);
        IMulticall3(c.multicall3).aggregate3Value{value: c.amountEth}(calls);
        vm.stopBroadcast();

        _logSummary(c);
    }

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------

    function _loadCfg(uint256 userPk) internal view returns (Cfg memory c) {
        c.multicall3 = vm.envOr("MULTICALL3", DEFAULT_MULTICALL3);
        c.weth = vm.envOr("WETH_SEPOLIA", DEFAULT_WETH);
        c.usdc = vm.envAddress("USDC_SEPOLIA");
        c.router = vm.envOr("UNIVERSAL_ROUTER", DEFAULT_ROUTER);
        c.quoter = vm.envOr("UNISWAP_QUOTER", DEFAULT_QUOTER);
        c.depository = vm.envOr("ORIGINAL_DEPOSITORY", DEFAULT_ORIGINAL_DEPOSITORY);
        c.receiver = vm.envAddress("DEPOSIT_RECEIVER");
        c.feeEoa = vm.envAddress("FEE_RECIPIENT");
        c.user = vm.addr(userPk);

        c.poolFee = uint24(vm.envOr("POOL_FEE_WETH_USDC", uint256(500)));
        c.amountEth = vm.envOr("AMOUNT_ETH", uint256(0.002 ether));
        c.bpsFee = vm.envOr("NATIVE_BPS_FEE", uint256(1234)); // 12.34%
        c.bpsDeposit = vm.envOr("NATIVE_BPS_DEPOSIT", uint256(3766)); // 37.66% (router leg = 50.00%)
        c.usdcPortionBps = vm.envOr("USDC_PORTION_BPS", uint256(2500)); // 25% of the swapped USDC
        c.slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100));
        c.depositId = bytes32(vm.randomUint());
    }

    function _validate(Cfg memory c) internal pure {
        require(c.usdc != address(0), "USDC_SEPOLIA is zero");
        require(c.receiver != address(0), "DEPOSIT_RECEIVER is zero");
        require(c.feeEoa != address(0), "FEE_RECIPIENT is zero");
        require(c.feeEoa != c.user, "fee EOA must differ from the user");
        require(c.amountEth > 0, "AMOUNT_ETH must be > 0");
        require(c.bpsFee > 0 && c.bpsDeposit > 0 && c.bpsFee + c.bpsDeposit < 10_000, "bad bps");
        require(c.usdcPortionBps > 0 && c.usdcPortionBps < 10_000, "USDC_PORTION_BPS must be in (0,10000)");
        require(c.slippageBps < 10_000, "SLIPPAGE_BPS must be < 10000");
    }

    function _preflight(Cfg memory c) internal view {
        ILayerswapDepository dep = ILayerswapDepository(c.depository);
        if (dep.paused()) {
            console2.log("WARNING: depository is paused; depositNative leg will revert (whole tx reverts).");
        }
        if (!dep.isWhitelisted(c.receiver)) {
            console2.log("WARNING: DEPOSIT_RECEIVER is NOT whitelisted on the ORIGINAL depository.");
        }
        if (c.multicall3.code.length == 0) {
            console2.log("WARNING: Multicall3 has no code on this chain.");
        }
        if (c.user.balance < c.amountEth) {
            console2.log("WARNING: user's ETH balance is below AMOUNT_ETH (plus gas).");
        }
    }

    // -------------------------------------------------------------------------
    // The three value-bearing calls (exact-% inbound; dynamic split post-swap)
    // -------------------------------------------------------------------------

    function _buildCalls(Cfg memory c)
        internal
        returns (IMulticall3.Call3Value[] memory calls, uint256 minUsdcOut)
    {
        uint256 feeValue = c.amountEth * c.bpsFee / 10_000;
        uint256 depositValue = c.amountEth * c.bpsDeposit / 10_000;
        uint256 routerValue = c.amountEth - feeValue - depositValue; // remainder: sums exactly

        // Off-chain floor for the swap leg (WETH amount == routerValue after wrap).
        minUsdcOut = _applySlippage(_quote(c.quoter, c.weth, c.usdc, routerValue, c.poolFee), c.slippageBps);
        require(minUsdcOut > 0, "AMOUNT_ETH too small: swap leg quotes to zero USDC");
        // Sweep min-out: what must remain after the PAY_PORTION cut.
        uint256 sweepFloor = minUsdcOut * (10_000 - c.usdcPortionBps) / 10_000;

        calls = new IMulticall3.Call3Value[](3);
        // 1. exact-% plain ETH send to the fee EOA
        calls[0] = IMulticall3.Call3Value({target: c.feeEoa, allowFailure: false, value: feeValue, callData: ""});
        // 2. exact-% depositNative on the ORIGINAL depository (emits Deposited)
        calls[1] = IMulticall3.Call3Value({
            target: c.depository,
            allowFailure: false,
            value: depositValue,
            callData: abi.encodeCall(ILayerswapDepository.depositNative, (c.depositId, c.receiver))
        });
        // 3. remainder into the Universal Router: wrap -> swap -> dynamic dual payout
        bytes memory commands = abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN, PAY_PORTION, SWEEP);
        bytes[] memory inputs = new bytes[](4);
        inputs[0] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE); // wrap ALL the ETH this call carries
        inputs[1] =
            abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, minUsdcOut, abi.encodePacked(c.weth, c.poolFee, c.usdc), false);
        inputs[2] = abi.encode(c.usdc, c.feeEoa, c.usdcPortionBps); // dynamic %: USDC portion -> fee EOA
        inputs[3] = abi.encode(c.usdc, c.user, sweepFloor); // dynamic rest: USDC -> the payer
        calls[2] = IMulticall3.Call3Value({
            target: c.router,
            allowFailure: false,
            value: routerValue,
            callData: abi.encodeCall(IUniversalRouter.execute, (commands, inputs, block.timestamp + 30 minutes))
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
    // Logging
    // -------------------------------------------------------------------------

    function _logPlan(Cfg memory c, uint256 minUsdcOut) internal pure {
        console2.log("==================================================");
        console2.log("USER-INVOKED native flow via Multicall3 (known contracts only)");
        console2.log("--------------------------------------------------");
        console2.log("  user (SENDS this tx, pays gas):", c.user);
        console2.log("  total native in (wei):", c.amountEth);
        console2.log("  leg 1  fee EOA, exact bps:", c.bpsFee);
        console2.log("  leg 2  ORIGINAL depository depositNative, exact bps:", c.bpsDeposit);
        console2.log("  leg 3  router (remainder): WRAP_ETH -> swap WETH->USDC, minOut:", minUsdcOut);
        console2.log("         PAY_PORTION USDC bps:", c.usdcPortionBps);
        console2.log("         SWEEP remaining USDC -> user");
        console2.log("--------------------------------------------------");
    }

    function _logSummary(Cfg memory c) internal pure {
        console2.log("--------------------------------------------------");
        console2.log("Submitted BY THE USER (single tx, no relayer, no custom contracts).");
        console2.log("  multicall3:", c.multicall3);
        console2.log("  ORIGINAL depository:", c.depository);
        console2.log("  layerswap receiver:", c.receiver);
        console2.log("  deposit id:");
        console2.logBytes32(c.depositId);
        console2.log("  (tx hash printed by forge below after broadcast)");
        console2.log("==================================================");
    }
}
