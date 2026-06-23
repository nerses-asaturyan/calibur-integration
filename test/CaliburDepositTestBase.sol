// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

/// @notice Shared helpers for building & signing EIP-3009 `ReceiveWithAuthorization`
///         digests against any USDC-style domain separator.
abstract contract CaliburDepositTestBase is Test {
    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    function _receiveAuthDigest(
        bytes32 domainSeparator,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _signAuth(
        uint256 pk,
        bytes32 domainSeparator,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = _receiveAuthDigest(domainSeparator, from, to, value, validAfter, validBefore, nonce);
        (v, r, s) = vm.sign(pk, digest);
    }
}
