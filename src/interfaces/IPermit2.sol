// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IPermit2
/// @notice Minimal surface of Uniswap's canonical Permit2
///         (0x000000000022D473030F116dDEE9F6B43aC78BA3, same on all chains).
///         Two independent sub-protocols are used by the flows:
///
///         * SignatureTransfer (`permitTransferFrom`): one-shot transfer by
///           signature; the signature binds the SPENDER (= msg.sender of the
///           call), unordered random nonces. Used by the gasless Permit2
///           inbound (spender = our executor).
///         * AllowanceTransfer (`permit` + allowance): sets a time-boxed
///           allowance from a signature; the Universal Router's PERMIT2_PERMIT
///           command feeds this (owner = router's msg.sender). Sequential
///           48-bit nonces per (owner, token, spender).
interface IPermit2 {
    // --- SignatureTransfer ---
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    // --- AllowanceTransfer ---
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    function permit(address owner, PermitSingle memory permitSingle, bytes calldata signature) external;

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
