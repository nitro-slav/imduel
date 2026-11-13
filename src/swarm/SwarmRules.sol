// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Bitboard} from "../Bitboard.sol";
import {Chess} from "../Chess.sol";
import {Rules} from "../Rules.sol";
import {PositionRing} from "./PositionRing.sol";

/// Swarm Duel's chess, stateless, called by staticcall.
/// The main duel's rules (Rules, Bitboard; encoding in Chess.sol) and its draw rules, with two differences: a game
/// may start with odds, and a game's own start position is the one that counts for repetition from any distance.
/// Fixed: a changeable rules contract would be power over the game.
contract SwarmRules {
    /// A game as SwarmDuel keeps it, before the move.
    struct Game {
        uint256 board;
        uint32 white; // side states (Chess.sol)
        uint32 black;
        uint16 ply; // half-moves played; White moves on even plies
        uint16 quiet; // half-moves since the last capture or pawn move
        uint32 gameNo; // in every position key, so no game repeats another's positions
        uint8 level; // the swarm's odds this game (start)
    }

    /// A game after a move.
    struct Outcome {
        uint256 board;
        uint32 white;
        uint32 black;
        uint16 quiet;
        bool check; // the side now to move is in check
        uint8 result; // 0 the game goes on, 1 White wins, 2 Black wins, 3 a draw
        uint8 reason; // a draw's: 1 stalemate, 2 too few pieces to mate, 3 a third repetition, 4 the quiet limit, 5 the move cap
        uint256[4] ring; // the positions the next move is judged against (PositionRing); kept as it was once the game ends
    }

    /// The highest odds level: the swarm without its f7 pawn, b8 knight, a8 rook and queen.
    uint8 public constant MAX_LEVEL = 4;
    /// The squares the swarm gives up, level by level: f7, b8, a8, d8.
    uint256 internal constant F7 = 53;
    uint256 internal constant B8 = 57;
    uint256 internal constant A8 = 56;
    uint256 internal constant D8 = 59;
    /// Black's queen-side rook flag (Bitboard: a flagged rook byte never castles).
    uint32 internal constant NO_LONG_CASTLE = 0x80000000;

    error BadLevel();
    error NoLegalMove();

    /// The start position for odds `level` (0 none, then one more piece of the swarm's at each level up to 4). With
    /// the a8 rook gone, Black can't castle long.
    function start(uint8 level) public pure returns (uint256 board, uint32 white, uint32 black) {
        if (level > MAX_LEVEL) revert BadLevel();
        (board, white, black) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
        if (level >= 1) board = _clear(board, F7);
        if (level >= 2) board = _clear(board, B8);
        if (level >= 3) (board, black) = (_clear(board, A8), black | NO_LONG_CASTLE);
        if (level >= 4) board = _clear(board, D8);
    }

    /// The side to move's legal moves, in Bitboard's order (by from-square); a promotion is one move (to a queen).
    function legalMoves(uint256 board, uint32 white, uint32 black, bool blackToMove)
        external
        pure
        returns (uint16[] memory)
    {
        return Bitboard.legalMoves(Bitboard.fromBoard(board, white, black), !blackToMove);
    }

    /// Whether `m` is legal for the side to move.
    function isLegal(uint256 board, uint32 white, uint32 black, bool blackToMove, uint16 m) public pure returns (bool) {
        return m < 4096 && Bitboard.isLegal(Bitboard.fromBoard(board, white, black), m, !blackToMove);
    }

    /// A legal move chosen by `seed`, for when neither the swarm nor the engine gives one: it can't fail on a position
    /// that has a move (a game without one has already ended).
    function pick(uint256 board, uint32 white, uint32 black, bool blackToMove, uint256 seed)
        external
        pure
        returns (uint16)
    {
        uint16[] memory moves = Bitboard.legalMoves(Bitboard.fromBoard(board, white, black), !blackToMove);
        if (moves.length == 0) revert NoLegalMove();
        return moves[seed % moves.length];
    }

    /// Plays `m` for the side to move of `g` and judges the game, in the main duel's order: mate, stalemate, too few
    /// pieces, a third repetition, the quiet limit, the move cap. An illegal move returns `legal` false and changes
    /// nothing, so the caller never has to tell a rejected move from a failed call.
    function play(Game calldata g, uint256[4] calldata ring, uint16 m)
        external
        pure
        returns (bool legal, Outcome memory o)
    {
        bool black = g.ply & 1 == 1;
        Bitboard.Pos memory p = Bitboard.fromBoard(g.board, g.white, g.black);
        if (m >= 4096 || !Bitboard.isLegal(p, m, !black)) return (false, o);
        Rules.Played memory r = Rules.playLegal(g.board, p, m, black);
        (o.board, o.check, o.ring) = (r.board, r.check, ring);
        (o.white, o.black) = black ? (r.other, r.mover) : (r.mover, r.other);
        o.quiet = _captured(g.board, m) != 0 || Chess.typeAt(g.board, m >> 6) == 1 ? 0 : g.quiet + 1;
        uint16 ply = g.ply + 1;
        if (r.status == 2) {
            o.result = black ? 2 : 1;
            return (true, o);
        }
        uint64 k = Chess.positionKey(o.board, o.white, o.black, ply & 1 == 1, g.gameNo);
        if (r.status == 1) o.reason = 1;
        else if (r.insufficient) o.reason = 2;
        else if (PositionRing.repeated(o.ring, ply, o.quiet, k, _atStart(o, ply, g.level))) o.reason = 3;
        else if (o.quiet >= Chess.MAX_QUIET_PLY) o.reason = 4;
        else if (ply >= Chess.MAX_PLY) o.reason = 5;
        if (o.reason != 0) o.result = 3;
        else PositionRing.write(o.ring, ply - 1, k); // the position after this move joins the memory, in its half-move's lane
        legal = true;
    }

    /// Whether the game stands at its own start position, White to move.
    function _atStart(Outcome memory o, uint16 ply, uint8 level) private pure returns (bool) {
        if (ply & 1 == 1) return false;
        (uint256 board, uint32 white, uint32 black) = start(level);
        return o.board == board && o.white == white && o.black == black;
    }

    /// The piece type `move` captures on `board`: the piece on the target square, or a pawn taken en passant. (The
    /// hook's `_captured`, frozen there.)
    function _captured(uint256 board, uint16 move) private pure returns (uint8) {
        uint256 from = move >> 6;
        uint256 to = move & 63;
        uint8 target = Chess.typeAt(board, to);
        if (target != 0) return target;
        if (Chess.typeAt(board, from) == 1 && (from & 7) != (to & 7)) return 1; // a pawn's diagonal step to an empty square
        return 0;
    }

    function _clear(uint256 board, uint256 sq) private pure returns (uint256) {
        return board & ~(uint256(0xf) << (sq << 2));
    }
}
