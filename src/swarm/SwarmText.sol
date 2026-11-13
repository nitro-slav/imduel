// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwarmRules} from "./SwarmRules.sol";

/// The swarm's question, written on chain: IMD's request
/// body for one move, in one preallocated buffer. The body opens with IMD's question document exactly as IMD hashes
/// it (compact JSON, keys sorted, ASCII only, nothing to escape), so the question hash is the keccak of that prefix;
/// the members IMD doesn't hash follow. Encoding of boards, side states and moves: Chess.sol.
/// The writing is unchecked arithmetic: every value is bounded (squares under 64, plies at most 200, lengths under
/// CAPACITY) and `_room` guards the buffer before every write. Moves and hex go out a word at a time.
library SwarmText {
    /// A text being written: the buffer and how much of it is used.
    struct Text {
        bytes buf;
        uint256 n;
    }

    /// What a question needs: the position now with Black's legal moves, the game so far, the odds start, the block
    /// the window names and the chain.
    struct Ask {
        SwarmRules.Game g;
        uint16[] legal;
        uint256[] history; // sixteen moves a word: bits 0-11 the move, bit 12 a promotion
        uint256 startBoard; // the game's start; only written when g.level > 0
        uint32 startWhite;
        uint32 startBlack;
        uint256 windowBlock;
        uint256 chainId;
    }

    /// The written body, its question hash, and the lengths IMD limits.
    struct Written {
        bytes body;
        bytes32 questionHash;
        uint256 questionLength; // IMD: at most 2,000 characters
        uint256 longestDefinition; // IMD: at most 512 characters a value
    }

    error TextTooLong();

    uint256 internal constant CAPACITY = 24_576; // past IMD's 16 KiB body limit, so any position fits before the check
    uint256 internal constant PLIES_PER_KEY = 60; // a history definition: 30 numbered pairs, at most 510 characters
    bytes16 internal constant PIECES = ".PBNRQK..pbnrqk."; // Chess.sol codes: type in the low three bits, +8 for Black
    bytes32 internal constant ZEROS = "00000000000000000000000000000000"; // half of a bytes32 in hex

    // Fixed definitions (IMD: 1-512 characters each). Sorted with the others by key when written.
    bytes internal constant ANSWER = "One of guards.allow: your move in UCI, lowercase (from square, to square, and q when a pawn promotes), "
        "without the x mark, as ASCII bytes left-aligned and zero-padded to 32 bytes; the format, shown with a White "
        "move: e2e4 is 0x6532653400000000000000000000000000000000000000000000000000000000.";
    bytes internal constant NOTATION = "Moves are in UCI. In the game so far, White moves first in each numbered pair. "
        "Castling is written as the king's move: e8g8 is Black castling short, e8c8 long. In Black's legal moves, a "
        "capture is followed by x and the piece it takes, White's in capitals: a6b5xN takes a White knight.";
    bytes internal constant POSITION = "The FEN (drawn in definitions board) and the game so far are the whole game. The "
        "block window only dates the question; no chain data or outside source is needed.";
    bytes internal constant BOARD = "Rank 8 to rank 1, files a to h; White in capitals, Black in lower case, a dot for an "
        "empty square:";
    bytes internal constant RULES = "Chess rules, with these differences: a pawn always promotes to a queen; the game is "
        "drawn by stalemate, too few pieces to mate (kings with at most one bishop or knight), a position's third "
        "appearance within the last 16 half-moves (the game's first position counts at any distance; a position just "
        "after a pawn's two-square move never repeats), 60 half-moves without a capture or pawn move, or 200 half-moves in "
        "all.";

    /// Writes the body for `a` and hashes its question document.
    function write(Ask memory a) internal pure returns (Written memory w) {
        Text memory t = Text(new bytes(CAPACITY), 0);
        SwarmRules.Game memory g = a.g;
        uint256 keys = (g.ply + PLIES_PER_KEY - 1) / PLIES_PER_KEY; // history definitions, moves1 ...

        put(t, '{"answerType":"bytes32","chainId":');
        num(t, a.chainId);
        put(t, ',"definitions":{"answer":"');
        put(t, ANSWER);
        w.longestDefinition = ANSWER.length;
        put(t, '","board":"');
        _board(t, g.board);
        for (uint256 k; k < keys; k++) {
            put(t, '","moves');
            num(t, k + 1);
            put(t, '":"');
            uint256 from = t.n;
            _moves(t, a.history, k * PLIES_PER_KEY, _min(g.ply, (k + 1) * PLIES_PER_KEY));
            w.longestDefinition = _max(w.longestDefinition, t.n - from);
        }
        put(t, '","notation":"');
        put(t, NOTATION);
        put(t, '","position":"');
        put(t, POSITION);
        put(t, '","rules":"');
        put(t, RULES);
        w.longestDefinition = _max(w.longestDefinition, RULES.length);
        if (g.level > 0) {
            put(t, '","start":"');
            fen(t, a.startBoard, a.startWhite, a.startBlack, false, 0, 0, new uint16[](0));
        }
        put(t, '"},"evidence":"panel","question":"Swarm Duel game ');
        uint256 question = t.n - 16; // from "Swarm Duel game "
        num(t, g.gameNo);
        put(t, ", move ");
        num(t, g.ply / 2 + 1);
        put(t, ". You play Black against human players, who play White. Decide by your own reasoning: no chess engine, opening book or other tool.");
        if (g.level > 0) put(t, " You gave odds: the game started from the position in definitions start.");
        if (keys > 0) {
            put(t, " The game so far is in definitions moves1");
            if (keys > 1) {
                put(t, " to moves");
                num(t, keys);
            }
            put(t, ".");
        }
        put(t, " Position now (FEN): ");
        fen(t, g.board, g.white, g.black, g.ply & 1 == 1, g.quiet, g.ply, a.legal);
        put(t, ". Black's legal moves:");
        for (uint256 i; i < a.legal.length; i++) {
            char(t, " ");
            uci(t, a.legal[i], _promotes(g.board, a.legal[i]));
            _taken(t, g.board, a.legal[i]);
        }
        put(t, ". What is your move for Black?");
        w.questionLength = t.n - question;
        put(t, '","v":1,"window":{"fromBlock":');
        num(t, a.windowBlock);
        put(t, ',"toBlock":');
        num(t, a.windowBlock);
        put(t, "}}");
        w.questionHash = _hash(t);

        // the members IMD doesn't hash: the document's closing brace becomes a comma
        t.buf[t.n - 1] = ",";
        put(t, '"allowAmbiguous":true,"guards":{"allow":[');
        for (uint256 i; i < a.legal.length; i++) {
            if (i > 0) char(t, ",");
            char(t, '"');
            allowed(t, a.legal[i], _promotes(g.board, a.legal[i]));
            char(t, '"');
        }
        put(t, ']},"panelSize":7,"quorum":3,"validForSeconds":86400}');
        w.body = close(t);
    }

    /// FEN of a position: placement, side to move, castling rights (a rook byte without its flag, Bitboard), the en
    /// passant square only when a legal move takes there (as chess.js and python-chess write it), the quiet count
    /// and the move number.
    function fen(
        Text memory t,
        uint256 board,
        uint32 white,
        uint32 black,
        bool blackToMove,
        uint256 quiet,
        uint256 ply,
        uint16[] memory legal
    ) internal pure {
        unchecked {
            for (uint256 rank = 8; rank > 0; rank--) {
                uint256 empty;
                for (uint256 file; file < 8; file++) {
                    uint256 p = (board >> ((((rank - 1) << 3) | file) << 2)) & 15;
                    if (p == 0) {
                        empty++;
                        continue;
                    }
                    if (empty != 0) char(t, bytes1(uint8(48 + empty)));
                    empty = 0;
                    char(t, PIECES[p]);
                }
                if (empty != 0) char(t, bytes1(uint8(48 + empty)));
                if (rank > 1) char(t, "/");
            }
            put(t, blackToMove ? bytes(" b ") : bytes(" w "));
            uint256 rights = t.n;
            if ((white >> 16) & 0xff < 64) char(t, "K");
            if ((white >> 24) & 0xff < 64) char(t, "Q");
            if ((black >> 16) & 0xff < 64) char(t, "k");
            if ((black >> 24) & 0xff < 64) char(t, "q");
            if (t.n == rights) char(t, "-");
            char(t, " ");
            uint256 ep = (blackToMove ? white : black) & 0xff; // the square behind the other side's double step
            if (ep < 64 && _takes(board, legal, ep)) square(t, ep);
            else char(t, "-");
            char(t, " ");
            num(t, quiet);
            char(t, " ");
            num(t, ply / 2 + 1);
        }
    }

    /// The position as eight rows after BOARD, rank 8 first: "8 rnbqkbnr, 7 pppppppp, ..., 1 RNBQKBNR." (a fixed length).
    function _board(Text memory t, uint256 board) private pure {
        unchecked {
            put(t, BOARD);
            for (uint256 rank = 8; rank > 0; rank--) {
                char(t, " ");
                char(t, bytes1(uint8(48 + rank)));
                char(t, " ");
                for (uint256 file; file < 8; file++) {
                    uint256 p = (board >> ((((rank - 1) << 3) | file) << 2)) & 15;
                    char(t, p == 0 ? bytes1(".") : PIECES[p]);
                }
                char(t, rank > 1 ? bytes1(",") : bytes1("."));
            }
        }
    }

    /// After a capture in Black's legal moves: x and the White piece it takes (en passant: a pawn); nothing otherwise.
    function _taken(Text memory t, uint256 board, uint16 m) private pure {
        uint256 from = (m >> 6) & 63;
        uint256 to = m & 63;
        uint256 p = (board >> (to << 2)) & 15;
        if (p == 0 && (board >> (from << 2)) & 7 == 1 && (from & 7) != (to & 7)) p = 1; // a pawn moving aside: en passant
        if (p == 0) return;
        char(t, "x");
        char(t, PIECES[p]);
    }

    /// `m` in UCI: from, to, and q for a promotion (one word written).
    function uci(Text memory t, uint16 m, bool promotes) internal pure {
        _word(t, _uciWord(m, promotes), promotes ? 5 : 4);
    }

    /// `m` as the oracle's bytes32 answer, in hex: its UCI's ASCII left-aligned, zero-padded (four words written).
    function allowed(Text memory t, uint16 m, bool promotes) internal pure {
        unchecked {
            uint256 len = promotes ? 5 : 4;
            uint256 ascii = _uciWord(m, promotes);
            uint256 hex_;
            for (uint256 i; i < len; i++) {
                uint256 b = (ascii >> (248 - 8 * i)) & 0xff;
                hex_ |= (uint256(uint8(_hex(b >> 4))) << (248 - 16 * i)) | (uint256(uint8(_hex(b & 15))) << (240 - 16 * i));
            }
            _word(t, uint256(bytes32("0x")), 2);
            _word(t, hex_, 2 * len);
            _word(t, uint256(ZEROS), 32);
            _word(t, uint256(ZEROS), 32 - 2 * len);
        }
    }

    function square(Text memory t, uint256 sq) internal pure {
        unchecked {
            _word(t, ((97 + (sq & 7)) << 248) | ((49 + (sq >> 3)) << 240), 2);
        }
    }

    function num(Text memory t, uint256 v) internal pure {
        unchecked {
            uint256 digits = 1;
            for (uint256 x = v; x >= 10; x /= 10) digits++;
            _room(t, digits);
            bytes memory buf = t.buf;
            uint256 end = t.n + digits;
            for (uint256 i = end; i > t.n; i--) {
                uint256 d = 48 + v % 10;
                assembly ("memory-safe") {
                    mstore8(add(add(buf, 31), i), d)
                }
                v /= 10;
            }
            t.n = end;
        }
    }

    function put(Text memory t, bytes memory s) internal pure {
        _copy(t, s, s.length);
    }

    function char(Text memory t, bytes1 c) internal pure {
        unchecked {
            uint256 n = t.n;
            _room(t, 1);
            bytes memory buf = t.buf;
            assembly ("memory-safe") {
                mstore8(add(add(buf, 32), n), shr(248, c))
            }
            t.n = n + 1;
        }
    }

    /// The written bytes (the buffer shortened in place).
    function close(Text memory t) internal pure returns (bytes memory b) {
        b = t.buf;
        uint256 n = t.n;
        assembly ("memory-safe") {
            mstore(b, n)
        }
    }

    /// The game's moves from half-move `from` up to `to` (exclusive), numbered: "1. e2e4 e7e5 2. g1f3".
    function _moves(Text memory t, uint256[] memory history, uint256 from, uint256 to) private pure {
        unchecked {
            for (uint256 k = from; k < to; k++) {
                if (k > from) char(t, " ");
                if (k & 1 == 0) {
                    num(t, k / 2 + 1);
                    _word(t, uint256(bytes32(". ")), 2);
                }
                uint256 m = (history[k >> 4] >> ((k & 15) << 4)) & 0xffff;
                uci(t, uint16(m & 4095), m & 4096 != 0);
            }
        }
    }

    /// Whether a pawn of the side to move takes en passant on `ep` by one of the legal moves.
    function _takes(uint256 board, uint16[] memory legal, uint256 ep) private pure returns (bool) {
        unchecked {
            for (uint256 i; i < legal.length; i++) {
                if (legal[i] & 63 == ep && (board >> ((legal[i] >> 6) << 2)) & 7 == 1) return true;
            }
            return false;
        }
    }

    /// Whether `m` on `board` is a pawn reaching the last rank.
    function _promotes(uint256 board, uint16 m) private pure returns (bool) {
        unchecked {
            uint256 to = m & 63;
            return (board >> ((m >> 6) << 2)) & 7 == 1 && (to < 8 || to >= 56);
        }
    }

    function _hash(Text memory t) private pure returns (bytes32 h) {
        bytes memory buf = t.buf;
        uint256 n = t.n;
        assembly ("memory-safe") {
            h := keccak256(add(buf, 32), n)
        }
    }

    function _room(Text memory t, uint256 len) private pure {
        if (t.n + len > t.buf.length) revert TextTooLong();
    }

    /// A move's UCI characters, left-aligned in a word.
    function _uciWord(uint16 m, bool promotes) private pure returns (uint256) {
        unchecked {
            uint256 from = (m >> 6) & 63;
            uint256 to = m & 63;
            return ((97 + (from & 7)) << 248) | ((49 + (from >> 3)) << 240) | ((97 + (to & 7)) << 232)
                | ((49 + (to >> 3)) << 224) | (promotes ? uint256(113) << 216 : 0);
        }
    }

    /// The first `len` bytes of word `w` (the whole word is stored; the rest is written over by what follows).
    function _word(Text memory t, uint256 w, uint256 len) private pure {
        unchecked {
            uint256 n = t.n;
            _room(t, 32);
            bytes memory buf = t.buf;
            assembly ("memory-safe") {
                mstore(add(add(buf, 32), n), w)
            }
            t.n = n + len;
        }
    }

    function _hex(uint256 v) private pure returns (bytes1) {
        unchecked {
            return bytes1(uint8(v < 10 ? 48 + v : 87 + v));
        }
    }

    /// The first `len` bytes of `s`.
    function _copy(Text memory t, bytes memory s, uint256 len) private pure {
        unchecked {
            uint256 n = t.n;
            _room(t, len);
            bytes memory buf = t.buf;
            assembly ("memory-safe") {
                mcopy(add(add(buf, 32), n), add(s, 32), len)
            }
            t.n = n + len;
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }
}
