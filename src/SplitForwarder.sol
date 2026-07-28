// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPermit2} from "./interfaces/IPermit2.sol";
import {IERC20Permit} from "./interfaces/IERC20Permit.sol";

/// @notice One payout leg of a token split. `data.length == 0` => plain
///         transfer of the leg's amount to `target` (ERC-20 safeTransfer or
///         native call{value}). Non-empty `data` => call hook: `target` is
///         called with `data` after the leg's run-time amount is written into
///         it at byte `amountOffset` (skipped when NO_SUBSTITUTION — e.g.
///         `depositNative`, where the amount travels as msg.value). ERC-20
///         hooks get an exact allowance for the call, reset to zero after;
///         native hooks receive the amount as msg.value.
///
///         `shareBps == 0` => CALL-ONLY leg: no amount is computed or moved —
///         `target` is simply called with `data` (must be a hook). This lets a
///         split fund a venue with a plain leg and then invoke it (e.g. a
///         prior leg transfers ERC-20 to the router, a call-only leg runs
///         router.execute). Zero-bps legs are excluded from the remainder rule.
struct Leg {
    address target;
    uint96 shareBps; // non-zero legs of one TokenSplit must sum to exactly 10_000
    uint256 amountOffset; // hook only; NO_SUBSTITUTION = don't patch calldata
    bytes data;
}

/// @notice One token's split. `token == address(0)` = native ETH. The split's
///         total is THIS CONTRACT's live balance of the token, read when the
///         split is processed — so an earlier split's hook (e.g. a swap that
///         pays this contract) can produce the balance a later split consumes.
struct TokenSplit {
    address token;
    Leg[] legs;
}

/// @title SplitForwarder
/// @notice The single stateless periphery of the flow system: splits and/or
///         forwards this contract's live balances — several tokens AND native
///         ETH in one call — where every leg is either a plain transfer or an
///         exact-amount contract call with the run-time amount substituted
///         into its calldata. The last leg of each split receives the
///         arithmetic remainder (rounding dust is impossible) and a terminal
///         zero-balance check per token guarantees nothing stays behind.
///
///         This makes the payout side VENUE-INDEPENDENT: any swap venue that
///         can deliver output to an address (Universal Router, 0x Settler, …)
///         plugs in; no venue payment commands (PAY_PORTION/SWEEP) are needed.
///
/// @dev TRUST MODEL — identical to the Universal Router / Multicall3:
///      stateless, no owner, permissionless. It must NEVER hold funds across
///      transactions (anyone could direct its balance) — fund and consume
///      within ONE atomic transaction. A malicious (target, data) can only
///      redirect funds the caller itself routed here in the same tx.
///
/// @dev SCOPE OF THE ZERO-DUST GUARANTEE (read carefully):
///      At the end of a run the contract asserts zero balance of every token
///      NAMED in `splits`, PLUS native ETH always (`runWithPermit`/
///      `permitAndRun` also assert the pulled intake token). It does NOT and
///      cannot enumerate arbitrary tokens a hook might produce — so the caller
///      MUST name every token its hooks create (e.g. a swap's output token) as
///      a split, or that residue is left and is permissionlessly claimable
///      (I-01). "Nothing left behind" holds only for named + native + intake.
///
/// @dev KNOWN, ACCEPTED PROPERTIES (audit dispositions):
///      - I-01 leftover balances are permissionlessly claimable (Multicall3-
///        style model); do not park funds across txs.
///      - I-02 `LegPaid.amount` for a hook is the PROGRAMMED input amount, not
///        a measured delivery — indexers must not treat it as a receipt.
///      - I-03 out-of-scope tokens include blacklist / pausable / transfer-hook
///        tokens as well as fee-on-transfer / rebasing (I-04).
///      - I-05 the Permit2 witness is an opaque hash in wallet UIs (binding is
///        sound on-chain; the wallet may not render leg details).
///      - I-06 witness binding prevents PLAN SUBSTITUTION, but does not prevent
///        sandwich MEV on a hook's swap if its min-out/slippage is loose — set
///        tight min-outs in hook calldata.
///      - L-02 very large split/leg arrays can exhaust caller gas (no cap;
///        bounded by the block gas limit).
///      - L-03 one reverting recipient aborts the whole atomic batch (by
///        design — all-or-nothing, zero-dust).
///      - L-04 dust totals with several paying legs can floor an early leg to
///        zero and revert (`ZeroLegAmount`); retry with a larger amount.
contract SplitForwarder {
    using SafeERC20 for IERC20;

    uint256 public constant NO_SUBSTITUTION = type(uint256).max;
    uint256 private constant BPS = 10_000;

    /// @dev Canonical Permit2 (same address on all chains).
    IPermit2 public constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /// @dev Witness typestring for permitWitnessTransferFrom: the user's
    ///      signature covers `witness = keccak256(abi.encode(splits))`, binding
    ///      the ENTIRE payout plan (recipients, bips, hook calldata incl. swap
    ///      programs and min-outs) into the authorization.
    string public constant WITNESS_TYPESTRING =
        "bytes32 witness)TokenPermissions(address token,uint256 amount)";

    event LegPaid(address indexed token, uint256 indexed splitIndex, address indexed target, uint256 amount, bool isHook);

    error NoSplits();
    error NoLegs(uint256 splitIndex);
    error SharesMustSumTo10000(uint256 splitIndex, uint256 actualSum);
    error ZeroTarget(uint256 splitIndex, uint256 legIndex);
    error ZeroLegAmount(uint256 splitIndex, uint256 legIndex);
    error ZeroTotalBalance(uint256 splitIndex);
    error InvalidAmountOffset(uint256 splitIndex, uint256 legIndex);
    error NativeTransferFailed(uint256 splitIndex, uint256 legIndex);
    error BalanceNotConsumed(address token, uint256 remaining);

    /// @notice Router UNWRAP_WETH / plain sends fund the native balance.
    receive() external payable {}

    /// @notice INTENT-BOUND user entry: pulls `permit.permitted.amount` of the
    ///         user's token via Permit2 permitWitnessTransferFrom and executes
    ///         `splits` — where the user's signature cryptographically commits
    ///         to `keccak256(abi.encode(splits))`.
    ///
    ///         MEMPOOL-SAFE WITHOUT ANY SUBMISSION ASSUMPTIONS: anyone who
    ///         extracts the signature from a pending transaction can only
    ///         execute this EXACT payout plan (funds are forced to this
    ///         contract, and any altered splits change the witness and
    ///         invalidate the signature) — i.e. a front-runner merely pays the
    ///         user's gas for them.
    ///
    ///         One-time prerequisite per token: owner has approved Permit2.
    function runWithPermit(
        IPermit2.PermitTransferFrom calldata permit,
        address owner,
        TokenSplit[] calldata splits,
        bytes calldata signature
    ) external {
        bytes32 witness = keccak256(abi.encode(splits));
        PERMIT2.permitWitnessTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: permit.permitted.amount}),
            owner,
            witness,
            WITNESS_TYPESTRING,
            signature
        );
        _runAll(splits);
        // The pulled intake token MUST be fully distributed even if the caller
        // omitted it from `splits` (closes the omitted-intake-token hole).
        _assertConsumed(permit.permitted.token);
    }

    /// @notice USER-SENT entry for EIP-2612 tokens — NO Permit2, NO prior
    ///         approve, NO witness. The user (paying gas) submits this directly:
    ///         their 2612 permit is consumed here, `value` is pulled from THEM,
    ///         and their `splits` run.
    ///
    ///         PUBLIC-MEMPOOL-SAFE WITHOUT A WITNESS because the binding is
    ///         structural — the pull is `transferFrom(msg.sender, …)`, so the
    ///         permit owner is forced to the caller:
    ///           * a replayer calling with the user's (v,r,s) does
    ///             `permit(attacker, this, …)`, which fails to recover the
    ///             user's signature (owner = user ≠ attacker) — caught — then
    ///             pulls from the ATTACKER, never the user;
    ///           * submitting the raw permit straight to the token only sets
    ///             allowance[user][this], and NO function here ever does
    ///             transferFrom(user, …) for an arbitrary owner (`run`/`_runAll`
    ///             move only this contract's own balance) — so it is not drainable.
    ///
    ///         The permit is wrapped in try/catch (trustless-permit): a griefer
    ///         who front-runs just the permit consumes the nonce, but the
    ///         transferFrom still succeeds on the set allowance.
    ///
    ///         MUST be called DIRECTLY by the user. Wrapped in another contract
    ///         (Multicall3, etc.) `msg.sender` is that contract → the permit and
    ///         pull bind to it; it fails safe (reverts), never drains a third party.
    function permitAndRun(
        address token,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        TokenSplit[] calldata splits
    ) external {
        try IERC20Permit(token).permit(msg.sender, address(this), value, deadline, v, r, s) {} catch {}
        IERC20(token).safeTransferFrom(msg.sender, address(this), value);
        _runAll(splits);
        // The pulled intake token MUST be fully distributed even if omitted
        // from `splits` (closes the omitted-intake-token hole).
        _assertConsumed(token);
    }

    /// @dev Reverts unless this contract holds zero of `token` — the explicit
    ///      guard for intake tokens that a caller may have left out of `splits`.
    function _assertConsumed(address token) internal view {
        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (remaining != 0) revert BalanceNotConsumed(token, remaining);
    }

    /// @notice Processes the splits SEQUENTIALLY: split i's hooks may produce
    ///         the balance split i+1 distributes (e.g. a swap hook paying this
    ///         contract). After all splits, every touched token must be at 0.
    function run(TokenSplit[] calldata splits) external payable {
        _runAll(splits);
    }

    function _runAll(TokenSplit[] calldata splits) internal {
        uint256 n = splits.length;
        if (n == 0) revert NoSplits();

        for (uint256 i; i < n; ++i) {
            _split(splits[i], i);
        }

        // Terminal zero-dust invariant, per named token (checked after ALL
        // splits so later splits may consume what earlier hooks produced).
        for (uint256 i; i < n; ++i) {
            uint256 remaining = _balance(splits[i].token);
            if (remaining != 0) revert BalanceNotConsumed(splits[i].token, remaining);
        }

        // Native is ALWAYS checked, even when no native split is named — this
        // closes the msg.value / hook-produced-ETH leftover hole: any ETH the
        // call brought in or an unwrap produced must be fully distributed.
        if (address(this).balance != 0) revert BalanceNotConsumed(address(0), address(this).balance);
    }

    function _split(TokenSplit calldata s, uint256 si) internal {
        uint256 n = s.legs.length;
        if (n == 0) revert NoLegs(si);

        // Validate before moving anything. Zero-bps legs are CALL-ONLY steps:
        // they must be hooks without amount substitution and don't count toward
        // the bips sum or the remainder rule.
        uint256 sum;
        uint256 lastPaying = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            Leg calldata leg = s.legs[i];
            if (leg.target == address(0)) revert ZeroTarget(si, i);
            if (leg.shareBps == 0) {
                if (leg.data.length == 0 || leg.amountOffset != NO_SUBSTITUTION) revert ZeroLegAmount(si, i);
                continue;
            }
            sum += leg.shareBps;
            lastPaying = i;
            if (leg.data.length != 0 && leg.amountOffset != NO_SUBSTITUTION) {
                if (leg.amountOffset < 4 || leg.amountOffset + 32 > leg.data.length) {
                    revert InvalidAmountOffset(si, i);
                }
            }
        }
        if (sum != BPS) revert SharesMustSumTo10000(si, sum);

        uint256 total = _balance(s.token);
        if (total == 0) revert ZeroTotalBalance(si);

        uint256 distributed;
        for (uint256 i; i < n; ++i) {
            Leg calldata leg = s.legs[i];

            if (leg.shareBps == 0) {
                // Call-only step: no amount moves; just invoke target with data.
                (bool ok, bytes memory ret) = leg.target.call(leg.data);
                if (!ok) {
                    assembly ("memory-safe") {
                        revert(add(ret, 0x20), mload(ret))
                    }
                }
                emit LegPaid(s.token, si, leg.target, 0, true);
                continue;
            }

            // mulDiv (L-01): full-precision, no overflow on pathological totals.
            uint256 amount = (i == lastPaying) ? total - distributed : Math.mulDiv(total, leg.shareBps, BPS);
            if (amount == 0) revert ZeroLegAmount(si, i);
            distributed += amount;

            bool isHook = leg.data.length != 0;
            if (isHook) {
                _hook(s.token, leg, amount);
            } else if (s.token == address(0)) {
                (bool ok,) = leg.target.call{value: amount}("");
                if (!ok) revert NativeTransferFailed(si, i);
            } else {
                IERC20(s.token).safeTransfer(leg.target, amount);
            }
            emit LegPaid(s.token, si, leg.target, amount, isHook);
        }
    }

    /// @dev Patch the amount into the template (unless NO_SUBSTITUTION), grant
    ///      an exact allowance for ERC-20 hooks (reset after), send the amount
    ///      as msg.value for native hooks, bubble the target's revert verbatim.
    function _hook(address token, Leg calldata leg, uint256 amount) internal {
        bytes memory payload = leg.data; // fresh memory copy
        if (leg.amountOffset != NO_SUBSTITUTION) {
            uint256 offset = leg.amountOffset; // bounds pre-validated
            assembly ("memory-safe") {
                mstore(add(add(payload, 0x20), offset), amount)
            }
        }

        bool ok;
        bytes memory ret;
        if (token == address(0)) {
            (ok, ret) = leg.target.call{value: amount}(payload);
        } else {
            IERC20(token).forceApprove(leg.target, amount);
            (ok, ret) = leg.target.call(payload);
            IERC20(token).forceApprove(leg.target, 0);
        }
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }
}
