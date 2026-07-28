// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPermit2} from "./interfaces/IPermit2.sol";

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
///      Fee-on-transfer / rebasing tokens are out of scope.
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

        // Terminal zero-dust invariant, per touched token (checked after ALL
        // splits so later splits may consume what earlier hooks produced).
        for (uint256 i; i < n; ++i) {
            uint256 remaining = _balance(splits[i].token);
            if (remaining != 0) revert BalanceNotConsumed(splits[i].token, remaining);
        }
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

            uint256 amount = (i == lastPaying) ? total - distributed : (total * leg.shareBps) / BPS;
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
