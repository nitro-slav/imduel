// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// The two checked casts Swarm Duel uses, as OpenZeppelin's SafeCast writes them (same error). Its own name: the hook's
/// build already has v4-core's SafeCast, and IMD's launch check refuses two artifacts of one name in a build.
library SwarmCast {
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    function toUint96(uint256 value) internal pure returns (uint96) {
        if (value > type(uint96).max) revert SafeCastOverflowedUintDowncast(96, value);
        return uint96(value);
    }

    function toUint80(uint256 value) internal pure returns (uint80) {
        if (value > type(uint80).max) revert SafeCastOverflowedUintDowncast(80, value);
        return uint80(value);
    }
}
