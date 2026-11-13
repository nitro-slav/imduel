// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Chessboard} from "../Chessboard.sol";
import {Chess} from "../../src/Chess.sol";
import {SwarmRules} from "../../src/swarm/SwarmRules.sol";
import {PositionRing} from "../../src/swarm/PositionRing.sol";

/// The ring's library functions as a contract.
contract RingHarness {
    function write(uint256[4] memory ring, uint256 ply, uint64 k) external pure returns (uint256[4] memory) {
        PositionRing.write(ring, ply, k);
        return ring;
    }

    function repeated(uint256[4] memory ring, uint256 ply, uint256 quiet, uint64 k, bool atStart)
        external
        pure
        returns (bool)
    {
        return PositionRing.repeated(ring, ply, quiet, k, atStart);
    }

    function previous(uint256[4] memory ring, uint256 ply, uint256 quiet) external pure returns (uint64[8] memory) {
        return PositionRing.previous(ring, ply, quiet);
    }
}

/// SwarmRules: the odds starts, every position of 40 random
/// games from them against chess.js (scripts/gen-swarm-odds.mjs), each way a game ends from the main duel's own test
/// positions (test/Draws.t.sol), the repetition memory, the seeded pick and the legality check.
contract SwarmRulesTest is Chessboard {
    SwarmRules sr = new SwarmRules();
    RingHarness ring = new RingHarness();
    uint256[4] empty;

    // ---------------------------------------------------------------- odds starts

    function test_oddsStarts() public view {
        uint256 b = Chess.START_BOARD;
        (uint256 board, uint32 w, uint32 k) = sr.start(0);
        assertEq(board, b);
        assertEq(w, Chess.START_WHITE);
        assertEq(k, Chess.START_BLACK);
        string[4] memory gone = ["f7", "b8", "a8", "d8"];
        uint8[4] memory piece = [9, 11, 12, 13]; // black pawn, knight, rook, queen
        for (uint8 level = 1; level <= 4; level++) {
            assertEq((b >> (sq(gone[level - 1]) * 4)) & 15, piece[level - 1], "the piece was there");
            b &= ~(uint256(15) << (sq(gone[level - 1]) * 4));
            (board, w, k) = sr.start(level);
            assertEq(board, b, "board");
            assertEq(w, Chess.START_WHITE, "White keeps everything");
            assertEq(k, level >= 3 ? Chess.START_BLACK | 0x80000000 : Chess.START_BLACK, "Black's long castling");
        }
    }

    function test_noLevelPastTheQueen() public {
        vm.expectRevert(SwarmRules.BadLevel.selector);
        sr.start(5);
    }

    function test_noLongCastleWithoutTheRook() public view {
        // level 3, the swarm's queen side cleared: e8c8 stays illegal for want of the rook, and the flag says so
        (uint256 b, uint32 w, uint32 k) = sr.start(3);
        b &= ~(uint256(15) << (sq("c8") * 4)) & ~(uint256(15) << (sq("d8") * 4)); // bishop and queen moved away
        assertFalse(sr.isLegal(b, w, k, true, mv("e8", "c8")));
    }

    // ---------------------------------------------------------------- against chess.js

    function test_oddsGamesAgainstChessJs() public {
        string memory data = vm.readFile("./test/data/swarm-odds.json");
        uint256[] memory levels = vm.parseJsonUintArray(data, ".levels");
        uint256[] memory status = vm.parseJsonUintArray(data, ".status");
        uint256[] memory thin = vm.parseJsonUintArray(data, ".insufficient");
        uint256 p; // position index in the file
        uint256 positions;
        uint256 ended;
        for (uint256 gi; gi < levels.length; gi++) {
            uint256[] memory moves = vm.parseJsonUintArray(data, string.concat(".moves[", vm.toString(gi), "]"));
            SwarmRules.Game memory g;
            (g.board, g.white, g.black) = sr.start(uint8(levels[gi]));
            (g.gameNo, g.level) = (uint32(gi + 1), uint8(levels[gi]));
            uint256[4] memory r;
            for (uint256 i; ; i++) {
                uint256[] memory want = vm.parseJsonUintArray(data, string.concat(".legal[", vm.toString(p + i), "]"));
                uint16[] memory got = sr.legalMoves(g.board, g.white, g.black, i % 2 == 1);
                assertEq(got.length, want.length, "legal count");
                for (uint256 j; j < got.length; j++) assertEq(got[j], want[j], "legal move");
                positions++;
                if (i == moves.length) break;
                (bool legal, SwarmRules.Outcome memory o) = sr.play(g, r, uint16(moves[i]));
                assertTrue(legal, "chess.js's move is legal");
                uint256 next = p + i + 1;
                if (status[next] == 2) assertEq(o.result, i % 2 == 0 ? 1 : 2, "chess.js mate");
                if (status[next] == 1) assertTrue(o.result == 3 && o.reason == 1, "chess.js stalemate");
                if (o.result == 3 && o.reason == 2) assertEq(thin[next], 1, "too few pieces, as chess.js counts them too");
                if (o.result != 0) {
                    ended++;
                    break; // our draw rules (repetition, the quiet limit, the cap) may end a game chess.js plays on
                }
                (g.board, g.white, g.black, g.quiet, r) = (o.board, o.white, o.black, o.quiet, o.ring);
                g.ply++;
            }
            p += moves.length + 1;
        }
        assertEq(p, status.length, "every position read");
        emit log_named_uint("positions checked", positions);
        emit log_named_uint("games ended by our rules", ended);
    }

    // ---------------------------------------------------------------- each way a game ends (test/Draws.t.sol's positions)

    function game(uint256 b, uint32 w, uint32 k, uint16 ply, uint16 quiet) internal pure returns (SwarmRules.Game memory g) {
        (g.board, g.white, g.black, g.ply, g.quiet, g.gameNo) = (b, w, k, ply, quiet, 1);
    }

    function ends(SwarmRules.Game memory g, uint16 m, uint8 result, uint8 reason) internal view {
        (bool legal, SwarmRules.Outcome memory o) = sr.play(g, empty, m);
        assertTrue(legal, "legal");
        assertEq(o.result, result, "result");
        assertEq(o.reason, reason, "reason");
    }

    function test_checkmateByWhite() public view {
        uint256 b = put(put(put(put(put(0, "g1", 6), "a1", 4), "h8", 14), "g7", 9), "h7", 9);
        ends(game(b, side("g1"), side("h8"), 0, 0), mv("a1", "a8"), 1, 0);
    }

    function test_checkmateByBlack() public view {
        (uint256 b, uint32 w, uint32 k) = mirror(put(put(put(put(put(0, "g1", 6), "a1", 4), "h8", 14), "g7", 9), "h7", 9), side("g1"), side("h8"));
        ends(game(b, w, k, 1, 0), mv("a8", "a1"), 2, 0);
    }

    function test_stalemate() public view {
        uint256 b = put(put(put(0, "f7", 6), "g5", 5), "h8", 14);
        ends(game(b, side("f7"), side("h8"), 0, 0), mv("g5", "g6"), 3, 1);
    }

    function test_tooFewPieces() public view {
        uint256 b = put(put(put(put(0, "e1", 6), "d4", 3), "e8", 14), "c6", 9);
        ends(game(b, side("e1"), side("e8"), 0, 0), mv("d4", "c6"), 3, 2);
    }

    function test_quietLimit() public view {
        ends(game(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, 0, Chess.MAX_QUIET_PLY - 1), mv("g1", "f3"), 3, 4);
    }

    function test_moveCap() public view {
        ends(game(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, Chess.MAX_PLY - 1, 0), mv("g8", "f6"), 3, 5);
    }

    function test_ordinaryMoveGoesOn() public view {
        ends(game(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, 0, 0), mv("e2", "e4"), 0, 0);
    }

    /// Plays `moves` from the start of `level`, every one but the last going on, and returns the last outcome.
    function shuffle(uint8 level, uint16[] memory moves) internal view returns (SwarmRules.Outcome memory o) {
        SwarmRules.Game memory g;
        (g.board, g.white, g.black) = sr.start(level);
        (g.gameNo, g.level) = (7, level);
        uint256[4] memory r;
        for (uint256 i; i < moves.length; i++) {
            bool legal;
            (legal, o) = sr.play(g, r, moves[i]);
            assertTrue(legal, "legal");
            if (i + 1 < moves.length) assertEq(o.result, 0, "goes on");
            (g.board, g.white, g.black, g.quiet, r) = (o.board, o.white, o.black, o.quiet, o.ring);
            g.ply++;
        }
    }

    function knights(uint256 cycles) internal pure returns (uint16[] memory m) {
        m = new uint16[](cycles * 4);
        for (uint256 i; i < m.length; i += 4) (m[i], m[i + 1], m[i + 2], m[i + 3]) = (mv("g1", "f3"), mv("g8", "f6"), mv("f3", "g1"), mv("f6", "g8"));
    }

    function test_startPositionAThirdTime() public view {
        SwarmRules.Outcome memory o = shuffle(0, knights(2)); // the start at ply 0, 4 and 8
        assertEq(o.result, 3);
        assertEq(o.reason, 3);
    }

    function test_oddsStartCountsLikeTheStart() public view {
        // level 2 (no f7, no b8): its own start position a third time is a draw, the plain start never appears
        SwarmRules.Outcome memory o = shuffle(2, knights(2));
        assertEq(o.result, 3);
        assertEq(o.reason, 3);
    }

    function opening(uint16 a, uint16 b, uint256 cycles) internal pure returns (uint16[] memory m) {
        m = new uint16[](2 + cycles * 4);
        (m[0], m[1]) = (a, b);
        uint16[] memory k = knights(cycles);
        for (uint256 i; i < k.length; i++) m[i + 2] = k[i];
    }

    function test_aRepetitionAwayFromTheStart() public view {
        // 1. Nc3 Nc6, then the g-knights out and back twice: the position after 1... Nc6 a third time at ply 10
        SwarmRules.Outcome memory o = shuffle(0, opening(mv("b1", "c3"), mv("b8", "c6"), 2));
        assertEq(o.result, 3);
        assertEq(o.reason, 3);
    }

    function test_enPassantRightMakesAPositionDifferent() public view {
        // 1. e4 e5: Black's state still holds the en passant square, so the position after 1... e5 differs from the
        // same pieces later (full side states, as the main duel counts them): two shuffles don't end the game; the
        // first position to come a third time is the one after 2. Nf3, at half-move 11
        SwarmRules.Outcome memory o = shuffle(0, opening(mv("e2", "e4"), mv("e7", "e5"), 2));
        assertEq(o.result, 0, "after two shuffles: the same pieces after 1... e5 only twice");
        uint16[] memory m = opening(mv("e2", "e4"), mv("e7", "e5"), 3);
        assembly ("memory-safe") { mstore(m, 11) }
        o = shuffle(0, m);
        assertEq(o.result, 3);
        assertEq(o.reason, 3);
    }

    // ---------------------------------------------------------------- the ring

    function test_ringForgetsPastSixteenHalfMoves() public view {
        uint256[4] memory r;
        uint64 key = 0xabcdef;
        r = ring.write(r, 1, key); // the position after half-move 1
        assertTrue(ring.repeated(ring.write(r, 3, key), 4, 4, key, false), "twice within sixteen: the third is a repetition");
        for (uint256 ply = 3; ply <= 17; ply += 2) r = ring.write(r, ply, uint64(ply)); // half-move 17 writes over lane 1
        assertFalse(ring.repeated(r, 18, 17, key, true), "gone after sixteen half-moves, even with the start counted");
    }

    function test_ringNeedsFourQuietHalfMoves() public view {
        uint256[4] memory r = ring.write(ring.write(empty, 1, 9), 3, 9);
        assertFalse(ring.repeated(r, 4, 3, 9, false));
        assertTrue(ring.repeated(r, 4, 4, 9, false));
    }

    function test_previousIsMostRecentFirst() public view {
        uint256[4] memory r;
        for (uint256 ply; ply < 16; ply++) r = ring.write(r, ply, uint64(ply + 100));
        uint64[8] memory p = ring.previous(r, 16, 10); // White to move at ply 16: the positions after half-moves 15, 13, ...
        for (uint256 i; i < 8; i++) assertEq(p[i], 114 - 2 * i, "the lane of half-move 14, 12, ...");
        uint64[8] memory none = ring.previous(r, 16, 2);
        for (uint256 i; i < 8; i++) assertEq(none[i], 0, "nothing before three quiet half-moves");
    }

    // ---------------------------------------------------------------- the pick and legality

    function testFuzz_pickIsLegal(uint256 seed, uint8 plies) public view {
        SwarmRules.Game memory g;
        (g.board, g.white, g.black) = sr.start(uint8(seed % 5));
        g.level = uint8(seed % 5);
        uint256[4] memory r;
        for (uint256 i; i < plies % 40; i++) {
            uint16[] memory moves = sr.legalMoves(g.board, g.white, g.black, g.ply & 1 == 1);
            uint16 m = sr.pick(g.board, g.white, g.black, g.ply & 1 == 1, uint256(keccak256(abi.encode(seed, i))));
            assertEq(m, moves[uint256(keccak256(abi.encode(seed, i))) % moves.length], "legal[seed % n]");
            assertTrue(sr.isLegal(g.board, g.white, g.black, g.ply & 1 == 1, m), "legal");
            (bool legal, SwarmRules.Outcome memory o) = sr.play(g, r, m);
            assertTrue(legal);
            if (o.result != 0) return;
            (g.board, g.white, g.black, g.quiet, r) = (o.board, o.white, o.black, o.quiet, o.ring);
            g.ply++;
        }
    }

    function test_illegalMovesChangeNothing() public view {
        SwarmRules.Game memory g = game(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, 0, 0);
        uint16[3] memory bad = [mv("e2", "e5"), mv("e7", "e5"), uint16(4096)]; // too far, the wrong side, off the board
        for (uint256 i; i < 3; i++) {
            (bool legal, SwarmRules.Outcome memory o) = sr.play(g, empty, bad[i]);
            assertFalse(legal);
            assertEq(o.board, 0);
            assertFalse(sr.isLegal(g.board, g.white, g.black, false, bad[i]));
        }
    }
}
