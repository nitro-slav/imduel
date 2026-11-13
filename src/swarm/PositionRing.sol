// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// A game's last sixteen positions as 64-bit keys (Chess.positionKey), four to a word: lane (ply % 16) holds the position
/// after that half-move, even lanes in words 0-1 and odd lanes in words 2-3, so each side's eight are two reads. The
/// main duel's ring as a library for Swarm Duel; the live hook keeps its own frozen copy (IMDuelHook `recentPositions`,
/// `_laneAt`, `_key`, `_history`, `_repeated`).
library PositionRing {
    /// The word and bit offset of the lane of half-move `ply`.
    function laneAt(uint256 ply) internal pure returns (uint256 word, uint256 shift) {
        uint256 l = ply % 16;
        uint256 k = l >> 1;
        (word, shift) = ((l & 1) * 2 + (k >> 2), (k & 3) * 64);
    }

    /// The k-th (0-7) key of the lanes with the parity of `ply`.
    function key(uint256[4] memory ring, uint256 ply, uint256 k) internal pure returns (uint64) {
        uint256 w = (ply & 1) * 2 + (k >> 2);
        return uint64(ring[w] >> ((k & 3) * 64));
    }

    /// Writes `k` into the lane of half-move `ply`, over the key sixteen half-moves older.
    function write(uint256[4] memory ring, uint256 ply, uint64 k) internal pure {
        (uint256 w, uint256 shift) = laneAt(ply);
        ring[w] = (ring[w] & ~(uint256(type(uint64).max) << shift)) | (uint256(k) << shift);
    }

    /// The side to move's last eight positions, most recent first, as the engine takes them (`previous`). None can
    /// repeat until four reversible half-moves have passed, so they are left empty before that.
    function previous(uint256[4] memory ring, uint256 ply, uint256 quiet) internal pure returns (uint64[8] memory p) {
        if (quiet < 3) return p;
        for (uint256 i; i < 8; i++) p[i] = key(ring, ply, ((ply + 14 - i * 2) % 16) >> 1);
    }

    /// Whether position `k`, just reached at half-move count `ply` (after the move), is there for the third time:
    /// counting itself, the ring's eight positions with the same side to move (up to sixteen half-moves back, the
    /// oldest written over only after this check), and the game's start position from any distance (`atStart`).
    function repeated(uint256[4] memory ring, uint256 ply, uint256 quiet, uint64 k, bool atStart)
        internal
        pure
        returns (bool)
    {
        // a position needs four reversible half-moves to recur, and nothing before the last capture or pawn move can
        if (quiet < 4) return false;
        uint256 seen = atStart ? 1 : 0;
        // the key's side to move is `ply`'s; those positions were made by half-moves of the other parity
        for (uint256 i; i < 8; i++) {
            if (key(ring, ply + 1, i) == k && ++seen == 2) return true;
        }
        return false;
    }
}
