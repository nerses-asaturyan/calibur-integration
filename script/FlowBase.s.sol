// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Call, IERC7821} from "../src/interfaces/IERC7821.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IERC3009USDC} from "../src/interfaces/IERC3009USDC.sol";
import {IERC20Permit} from "../src/interfaces/IERC20Permit.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";
import {ILayerswapDepository} from "../src/interfaces/ILayerswapDepository.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IQuoterV2} from "../src/interfaces/IQuoterV2.sol";
import {SplitForwarder, Leg, TokenSplit} from "../src/SplitForwarder.sol";

/// @title FlowBase
/// @notice Shared machinery for the four flow scripts (Flow1..Flow4), each of
///         which runs in three funding modes selected by FUNDING_MODE:
///
///         * "gasless"    — user signs off-chain (EIP-3009 for USDC; Permit2 for
///           plain tokens); the RELAYER's Calibur account (EIP-7702) executes an
///           atomic ERC-7821 batch and pays all gas. USER_PRIVATE_KEY signs,
///           PRIVATE_KEY broadcasts.
///         * "user-erc20" — the USER sends ONE tx: SplitForwarder.runWithPermit.
///           The user's Permit2 signature carries a WITNESS committing to
///           keccak256(abi.encode(splits)) — the entire payout plan. This is
///           PUBLIC-MEMPOOL-SAFE WITH NO SUBMISSION ASSUMPTIONS: a front-runner
///           who copies the pending signature can only execute this exact plan
///           (funds forced to the forwarder; any altered split changes the
///           witness and invalidates the sig), i.e. they'd merely pay the
///           user's gas. One-time prerequisite: user approved Permit2.
///         * "user-eth"   — the USER sends ONE direct SplitForwarder.run{value}
///           call: a native call-only leg carries msg.value into router.execute,
///           then the output split runs. (No signature exists for native ETH, so
///           nothing is stealable regardless of mempool.)
///
///         ZERO DUST INVARIANT (all flows, all modes): every intermediary
///         (Universal Router, SplitForwarder, relayer executor) exits the
///         transaction at exactly 0 — deposits forward the whole live balance
///         via the SplitForwarder into the ORIGINAL depository, splits give the
///         last leg the remainder, fee legs are exact. Swaps are always
///         EXACT-IN; quoted floors are used ONLY as revert guards (min-out).
abstract contract FlowBase is Script {
    // --- ERC-7821 / EIP-3009 ---
    bytes32 internal constant ERC7821_BATCH_MODE =
        0x0100000000000000000000000000000000000000000000000000000000000000;
    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")  (EIP-2612)
    bytes32 internal constant EIP2612_PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // Permit2 SignatureTransfer typehashes.
    bytes32 internal constant PERMIT2_TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 internal constant PERMIT2_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );
    // Permit2 SignatureTransfer WITNESS typehash (witness = bytes32, matching
    // SplitForwarder.WITNESS_TYPESTRING).
    bytes32 internal constant PERMIT2_WITNESS_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,bytes32 witness)TokenPermissions(address token,uint256 amount)"
    );
    // Permit2 AllowanceTransfer typehashes.
    bytes32 internal constant PERMIT2_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 internal constant PERMIT2_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    // --- Universal Router command bytes (Uniswap Commands.sol) ---
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant PERMIT2_TRANSFER_FROM = 0x02;
    bytes1 internal constant SWEEP = 0x04;
    bytes1 internal constant TRANSFER = 0x05;
    bytes1 internal constant PAY_PORTION = 0x06;
    bytes1 internal constant PERMIT2_PERMIT = 0x0a;
    bytes1 internal constant WRAP_ETH = 0x0b;
    bytes1 internal constant UNWRAP_WETH = 0x0c;

    // --- Universal Router sentinels (Constants.sol) ---
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;
    address internal constant MSG_SENDER = address(1);
    address internal constant ADDRESS_THIS = address(2);
    address internal constant NATIVE = address(0);

    // --- Known Sepolia deployments (env-overridable) ---
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant DEFAULT_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address internal constant DEFAULT_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
    address internal constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    string internal constant MODE_GASLESS = "gasless";
    string internal constant MODE_USER_ERC20 = "user-erc20";
    string internal constant MODE_USER_ETH = "user-eth";

    struct Cfg {
        address usdc; // Circle USDC (EIP-3009 + EIP-2612)
        address weth; // canonical WETH9
        address router; // Universal Router
        address quoter; // QuoterV2 (off-chain floors only)
        address permit2; // canonical Permit2
        address depository; // the ORIGINAL depository (plain depositERC20)
        address forwarder; // SplitForwarder (dynamic-amount + split periphery)
        address receiver; // whitelisted Layerswap receiver
        address feeRecipient; // fee EOA
        address executor; // relayer's Calibur account (gasless mode)
        address user; // the payer
        uint24 poolFee; // USDC/WETH pool tier
        uint256 amountIn; // ERC-20 modes: USDC units in
        uint256 amountEth; // user-eth mode: wei in
        uint256 feeBps; // fee leg share (of INPUT for split-first flows,
            // of OUTPUT for swap-first flows)
        uint256 slippageBps;
        bytes32 depositId;
        string mode; // FUNDING_MODE
    }

    // -------------------------------------------------------------------------
    // Config / dispatch
    // -------------------------------------------------------------------------

    /// @dev Test hook: forces the funding mode on THIS script instance, taking
    ///      precedence over the FUNDING_MODE env var. Parallel fork tests can't
    ///      use vm.setEnv for per-test values (env is process-global and races).
    string internal modeOverride;

    function setMode(string memory m) external {
        modeOverride = m;
    }

    function _loadCfg() internal view returns (Cfg memory c, uint256 broadcasterPk, uint256 userPk) {
        userPk = vm.envUint("USER_PRIVATE_KEY");
        c.mode = bytes(modeOverride).length != 0 ? modeOverride : vm.envOr("FUNDING_MODE", MODE_GASLESS);
        // gasless: relayer broadcasts; user modes: the user broadcasts.
        broadcasterPk = _is(c.mode, MODE_GASLESS) ? vm.envUint("PRIVATE_KEY") : userPk;

        c.usdc = vm.envAddress("USDC_SEPOLIA");
        c.weth = vm.envOr("WETH_SEPOLIA", DEFAULT_WETH);
        c.router = vm.envOr("UNIVERSAL_ROUTER", DEFAULT_ROUTER);
        c.quoter = vm.envOr("UNISWAP_QUOTER", DEFAULT_QUOTER);
        c.permit2 = vm.envOr("PERMIT2", DEFAULT_PERMIT2);
        c.depository = vm.envAddress("LAYERSWAP_DEPOSITORY");
        c.forwarder = vm.envOr("DEPOSIT_FORWARDER", address(0));
        c.receiver = vm.envAddress("DEPOSIT_RECEIVER");
        c.feeRecipient = vm.envAddress("FEE_RECIPIENT");
        c.user = vm.addr(userPk);
        c.executor = vm.envOr("CALIBUR_EXECUTOR", vm.addr(vm.envUint("PRIVATE_KEY")));

        c.poolFee = uint24(vm.envOr("POOL_FEE", uint256(500))); // liquid USDC/WETH 0.05%
        c.amountIn = vm.envOr("AMOUNT_IN", uint256(10_000_000)); // 10 USDC
        c.amountEth = vm.envOr("AMOUNT_ETH", uint256(0.002 ether));
        c.feeBps = vm.envOr("FEE_BPS", uint256(1234)); // 12.34%
        c.slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100));
        c.depositId = bytes32(vm.randomUint());

        _validate(c);
    }

    function _validate(Cfg memory c) internal pure {
        require(c.usdc != address(0), "USDC_SEPOLIA is zero");
        require(c.depository != address(0), "LAYERSWAP_DEPOSITORY is zero");
        require(c.receiver != address(0), "DEPOSIT_RECEIVER is zero");
        require(c.feeRecipient != address(0), "FEE_RECIPIENT is zero");
        require(c.user != address(0), "user is zero");
        require(c.user != c.executor, "payer must differ from executor");
        require(c.feeBps > 0 && c.feeBps < 10_000, "FEE_BPS must be in (0,10000)");
        require(c.slippageBps < 10_000, "SLIPPAGE_BPS must be < 10000");
        require(c.amountIn > 0 && c.amountEth > 0, "amounts must be > 0");
        require(
            _is(c.mode, MODE_GASLESS) || _is(c.mode, MODE_USER_ERC20) || _is(c.mode, MODE_USER_ETH),
            "FUNDING_MODE must be gasless | user-erc20 | user-eth"
        );
    }

    function _is(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _preflight(Cfg memory c, bool touchesDepository) internal view {
        if (touchesDepository) {
            ILayerswapDepository dep = ILayerswapDepository(c.depository);
            if (dep.paused()) console2.log("WARNING: depository paused; deposit leg reverts (tx reverts atomically).");
            if (!dep.isWhitelisted(c.receiver)) console2.log("WARNING: DEPOSIT_RECEIVER not whitelisted.");
        }
        if (_is(c.mode, MODE_GASLESS) && c.executor.code.length == 0) {
            console2.log("WARNING: executor not delegated to Calibur. Run EnableDelegation.s.sol first.");
        }
        uint256 priorDust = IERC20(_depositToken(c)).balanceOf(_collector(c));
        if (priorDust > 0 && touchesDepository) {
            console2.log("NOTE: collector holds pre-existing deposit-token balance; depositERC20All sweeps it in:", priorDust);
        }
    }

    /// @dev ERC-20 modes swap USDC -> WETH (deposit/value token = WETH);
    ///      user-eth mode wraps and swaps WETH -> USDC (deposit/value token = USDC).
    function _outToken(Cfg memory c) internal pure returns (address) {
        return _is(c.mode, MODE_USER_ETH) ? c.usdc : c.weth;
    }

    function _inToken(Cfg memory c) internal pure returns (address) {
        return _is(c.mode, MODE_USER_ETH) ? c.weth : c.usdc;
    }

    function _depositToken(Cfg memory c) internal pure returns (address) {
        return _outToken(c);
    }

    /// @dev Who accumulates the swap output before the deposit: always the
    ///      BalanceForwarder — the router pays it directly, and its
    ///      executeWithBalance bridges the dynamic amount into the ORIGINAL
    ///      depository's exact-amount depositERC20.
    function _collector(Cfg memory c) internal pure returns (address) {
        return c.forwarder;
    }

    // -------------------------------------------------------------------------
    // Off-chain pricing (floors are revert guards only — swaps are exact-in)
    // -------------------------------------------------------------------------

    function _quote(Cfg memory c, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        IQuoterV2.QuoteExactInputSingleParams memory p = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            fee: c.poolFee,
            sqrtPriceLimitX96: 0
        });
        (amountOut,,,) = IQuoterV2(c.quoter).quoteExactInputSingle(p);
    }

    function _floor(Cfg memory c, uint256 quoted) internal pure returns (uint256) {
        return quoted * (10_000 - c.slippageBps) / 10_000;
    }

    // -------------------------------------------------------------------------
    // Signature helpers (all signed by the payer's key, off-chain)
    // -------------------------------------------------------------------------

    /// @dev EIP-3009 receiveWithAuthorization over USDC (gasless USDC inbound).
    function _sign3009(Cfg memory c, uint256 userPk, uint256 value, uint256 validBefore, bytes32 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, c.user, c.executor, value, uint256(0), validBefore, nonce)
        );
        bytes32 digest =
            keccak256(abi.encodePacked(hex"1901", IERC3009USDC(c.usdc).DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(userPk, digest);
    }

    /// @dev EIP-2612 permit over USDC (user-sent ERC-20 depository flows;
    ///      spender = Multicall3, consumed in the user's own batch).
    function _sign2612(Cfg memory c, uint256 userPk, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        uint256 nonce = IERC20Permit(c.usdc).nonces(c.user);
        bytes32 structHash =
            keccak256(abi.encode(EIP2612_PERMIT_TYPEHASH, c.user, spender, value, nonce, deadline));
        bytes32 digest =
            keccak256(abi.encodePacked(hex"1901", IERC20Permit(c.usdc).DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(userPk, digest);
    }

    /// @dev Permit2 SignatureTransfer (gasless plain-token inbound; the signature
    ///      binds spender == the executor, so only our executor can consume it).
    function _signPermit2Transfer(
        Cfg memory c,
        uint256 userPk,
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory sig) {
        bytes32 tokenPerms = keccak256(abi.encode(PERMIT2_TOKEN_PERMISSIONS_TYPEHASH, token, amount));
        bytes32 structHash =
            keccak256(abi.encode(PERMIT2_TRANSFER_FROM_TYPEHASH, tokenPerms, c.executor, nonce, deadline));
        bytes32 digest =
            keccak256(abi.encodePacked(hex"1901", IPermit2(c.permit2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Permit2 AllowanceTransfer PermitSingle for the router's PERMIT2_PERMIT
    ///      command (user-sent router-only flows; owner is bound to the router's
    ///      msg.sender, so the signature is useless to anyone but the user).
    function _signPermit2Single(Cfg memory c, uint256 userPk, address token, uint160 amount, uint256 sigDeadline)
        internal
        view
        returns (IPermit2.PermitSingle memory single, bytes memory sig)
    {
        (,, uint48 nonce) = IPermit2(c.permit2).allowance(c.user, token, c.router);
        single = IPermit2.PermitSingle({
            details: IPermit2.PermitDetails({
                token: token,
                amount: amount,
                expiration: uint48(sigDeadline),
                nonce: nonce
            }),
            spender: c.router,
            sigDeadline: sigDeadline
        });
        bytes32 detailsHash = keccak256(abi.encode(PERMIT2_DETAILS_TYPEHASH, single.details));
        bytes32 structHash =
            keccak256(abi.encode(PERMIT2_SINGLE_TYPEHASH, detailsHash, single.spender, single.sigDeadline));
        bytes32 digest =
            keccak256(abi.encodePacked(hex"1901", IPermit2(c.permit2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // -------------------------------------------------------------------------
    // Batch-piece builders
    // -------------------------------------------------------------------------

    /// @dev Gasless USDC inbound leg (EIP-3009): user -> executor, exact amount.
    function _pull3009(Cfg memory c, uint256 userPk, uint256 amount) internal view returns (Call memory) {
        uint256 validBefore = block.timestamp + 10 minutes;
        bytes32 nonce = bytes32(vm.randomUint());
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(c, userPk, amount, validBefore, nonce);
        return Call({
            to: c.usdc,
            value: 0,
            data: abi.encodeCall(
                IERC3009USDC.receiveWithAuthorization, (c.user, c.executor, amount, 0, validBefore, nonce, v, r, s)
            )
        });
    }

    // depositERC20(bytes32 id, address token, address receiver, uint256 amount):
    // the amount word sits at byte offset 4 + 3*32 = 100 of the calldata template.
    uint256 internal constant DEPOSIT_ERC20_AMOUNT_OFFSET = 100;
    uint256 internal constant NO_SUB = type(uint256).max;

    // --- SplitForwarder leg / split builders -------------------------------

    function _plainLeg(address target, uint96 bps) internal pure returns (Leg memory) {
        return Leg({target: target, shareBps: bps, amountOffset: NO_SUB, data: ""});
    }

    /// @dev Hook leg: depositERC20 on the ORIGINAL depository, amount patched
    ///      at run time into offset 100.
    function _depositLeg(Cfg memory c, address token, uint96 bps) internal view returns (Leg memory) {
        return Leg({
            target: c.depository,
            shareBps: bps,
            amountOffset: DEPOSIT_ERC20_AMOUNT_OFFSET,
            data: abi.encodeCall(ILayerswapDepository.depositERC20, (c.depositId, token, c.receiver, 0))
        });
    }

    /// @dev Native hook leg: depositNative — the dynamic amount travels as
    ///      msg.value, nothing to patch. (The capability the extended
    ///      depository fundamentally cannot offer.)
    function _depositNativeLeg(Cfg memory c, uint96 bps) internal view returns (Leg memory) {
        return Leg({
            target: c.depository,
            shareBps: bps,
            amountOffset: NO_SUB,
            data: abi.encodeCall(ILayerswapDepository.depositNative, (c.depositId, c.receiver))
        });
    }

    /// @dev Native hook leg carrying its amount as msg.value INTO a router
    ///      execute() program (the UR rejects plain ETH sends; value must ride
    ///      with the call). Lets a native split leg BE the swap step.
    function _routerHookLeg(Cfg memory c, uint96 bps, bytes memory commands, bytes[] memory inputs)
        internal
        view
        returns (Leg memory)
    {
        return Leg({target: c.router, shareBps: bps, amountOffset: NO_SUB, data: _routerCall(commands, inputs)});
    }

    function _single(address token, Leg[] memory legs) internal pure returns (TokenSplit[] memory splits) {
        splits = new TokenSplit[](1);
        splits[0] = TokenSplit({token: token, legs: legs});
    }

    function _legs1(Leg memory a) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](1);
        legs[0] = a;
    }

    function _legs2(Leg memory a, Leg memory b) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        (legs[0], legs[1]) = (a, b);
    }

    function _sfRunData(Cfg memory c, TokenSplit[] memory splits) internal pure returns (bytes memory) {
        require(c.forwarder != address(0), "DEPOSIT_FORWARDER is zero");
        return abi.encodeCall(SplitForwarder.run, (splits));
    }

    function _sfRunCall(Cfg memory c, TokenSplit[] memory splits) internal pure returns (Call memory) {
        return Call({to: c.forwarder, value: 0, data: _sfRunData(c, splits)});
    }

    /// @dev user-eth flows submit ONE direct call: SplitForwarder.run{value}.
    function _submitSfNative(Cfg memory c, uint256 userPk, TokenSplit[] memory splits, uint256 value) internal {
        vm.startBroadcast(userPk);
        SplitForwarder(payable(c.forwarder)).run{value: value}(splits);
        vm.stopBroadcast();
    }

    /// @dev Call-only leg (shareBps = 0): no amount moves, target is just
    ///      invoked — e.g. router.execute after a plain leg pre-funded it.
    function _callOnlyLeg(address target, bytes memory data) internal pure returns (Leg memory) {
        return Leg({target: target, shareBps: 0, amountOffset: NO_SUB, data: data});
    }

    function _legs3(Leg memory a, Leg memory b, Leg memory x) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](3);
        (legs[0], legs[1], legs[2]) = (a, b, x);
    }

    /// @dev INTENT-BOUND user-erc20 entry: ONE direct SplitForwarder.runWithPermit
    ///      tx. The Permit2 witness signature commits to keccak256(abi.encode(splits)),
    ///      so the pending tx is PUBLIC-MEMPOOL-SAFE: a front-runner can only
    ///      execute this exact payout plan (paying the user's gas). One-time
    ///      prerequisite: user has approved Permit2 for the token.
    function _submitSfRunWithPermit(Cfg memory c, uint256 userPk, uint256 amount, TokenSplit[] memory splits)
        internal
    {
        uint256 deadline = block.timestamp + 10 minutes;
        uint256 nonce = vm.randomUint(); // Permit2 SignatureTransfer nonces are unordered
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: c.usdc, amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signPermit2Witness(c, userPk, permit, keccak256(abi.encode(splits)));

        vm.startBroadcast(userPk);
        SplitForwarder(payable(c.forwarder)).runWithPermit(permit, c.user, splits, sig);
        vm.stopBroadcast();
    }

    function _signPermit2Witness(
        Cfg memory c,
        uint256 userPk,
        IPermit2.PermitTransferFrom memory permit,
        bytes32 witness
    ) internal view returns (bytes memory) {
        bytes32 tokenPerms =
            keccak256(abi.encode(PERMIT2_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount));
        bytes32 structHash = keccak256(
            abi.encode(PERMIT2_WITNESS_TYPEHASH, tokenPerms, c.forwarder, permit.nonce, permit.deadline, witness)
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", IPermit2(c.permit2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Encodes router.execute(commands, inputs, deadline).
    function _routerCall(bytes memory commands, bytes[] memory inputs) internal view returns (bytes memory) {
        return abi.encodeCall(IUniversalRouter.execute, (commands, inputs, block.timestamp + 30 minutes));
    }

    /// @dev V3 exact-in swap input tuple.
    function _swapInput(address recipient, uint256 amountIn, uint256 minOut, bytes memory path, bool payerIsUser)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(recipient, amountIn, minOut, path, payerIsUser);
    }

    function _path(Cfg memory c, address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenIn, c.poolFee, tokenOut);
    }

    /// @dev PERMIT2_PERMIT input for the router (PermitSingle + user signature).
    function _permit2PermitInput(IPermit2.PermitSingle memory single, bytes memory sig)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(single, sig);
    }

    // -------------------------------------------------------------------------
    // Submitters
    // -------------------------------------------------------------------------

    function _submitCalibur(Cfg memory c, uint256 relayerPk, Call[] memory calls) internal {
        vm.startBroadcast(relayerPk);
        IERC7821(c.executor).execute(ERC7821_BATCH_MODE, abi.encode(calls));
        vm.stopBroadcast();
    }

    function _submitRouter(Cfg memory c, uint256 userPk, bytes memory commands, bytes[] memory inputs, uint256 value)
        internal
    {
        vm.startBroadcast(userPk);
        IUniversalRouter(c.router).execute{value: value}(commands, inputs, block.timestamp + 30 minutes);
        vm.stopBroadcast();
    }

    // -------------------------------------------------------------------------
    // Logging
    // -------------------------------------------------------------------------

    function _logHeader(Cfg memory c, string memory flowName) internal pure {
        console2.log("==================================================");
        console2.log(flowName);
        console2.log("  FUNDING_MODE:", c.mode);
        console2.log("  user (payer):", c.user);
        console2.log("  fee recipient:", c.feeRecipient);
        console2.log("  depository (depositERC20All):", c.depository);
        console2.log("  receiver:", c.receiver);
        console2.log("  fee bps:", c.feeBps);
        console2.log("--------------------------------------------------");
    }

    function _logDone(Cfg memory c) internal pure {
        console2.log("--------------------------------------------------");
        console2.log("  deposit id:");
        console2.logBytes32(c.depositId);
        console2.log("  (tx hash printed by forge after broadcast)");
        console2.log("==================================================");
    }
}
