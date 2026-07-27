// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice One payout leg of a split.
/// @dev `data.length == 0` => plain transfer of the leg's amount to `target`
///      (native `.call{value}` or `SafeERC20.safeTransfer`).
///      `data.length > 0`  => call hook: `target` is called with `data`, after the
///      run-time-computed amount is written into `data` at byte `amountOffset`
///      (skipped when `amountOffset == NO_SUBSTITUTION`). For ERC-20 splits the
///      splitter grants `target` an exact allowance for the call and resets it to
///      zero afterwards; for native splits the amount is sent as `msg.value`.
struct Leg {
    address target; // recipient (plain leg) or contract to call (hook leg)
    uint96 shareBps; // this leg's share in bps; ALL legs must sum to exactly 10_000
    uint256 amountOffset; // hook only: byte offset of the uint256 amount word in `data`;
        // NO_SUBSTITUTION (type(uint256).max) = leave `data` untouched
    bytes data; // hook calldata template; empty for plain legs
}

/// @title IPayoutSplitter
/// @notice Stateless, permissionless N-way percentage splitter. Splits the
///         contract's OWN current balance of one token (ERC-20, or native via
///         `token == address(0)`) across the legs. The LAST leg receives the
///         arithmetic remainder instead of its own bps computation, so rounding
///         dust is impossible; a terminal zero-balance check enforces that hooks
///         consumed their amounts.
interface IPayoutSplitter {
    event LegPaid(uint256 indexed index, address indexed target, address indexed token, uint256 amount, bool isHook);
    event Split(address indexed token, address indexed caller, uint256 total, uint256 legCount);

    error NoLegs();
    error SharesMustSumTo10000(uint256 actualSum);
    error ZeroTotalBalance();
    error ZeroTarget(uint256 index);
    error ZeroLegAmount(uint256 index);
    error InvalidAmountOffset(uint256 index); // offset < 4 or offset + 32 > data.length
    error NativeTransferFailed(uint256 index);
    error DustLeft(uint256 remaining); // terminal zero-balance invariant violated

    /// @notice Sentinel for `Leg.amountOffset`: do not patch the calldata template.
    function NO_SUBSTITUTION() external pure returns (uint256);

    /// @notice Split the contract's whole current balance of `token` across `legs`.
    /// @param token ERC-20 token address, or address(0) for native ETH.
    /// @param legs  The payout legs; `shareBps` must sum to exactly 10_000.
    function split(address token, Leg[] calldata legs) external payable;
}
