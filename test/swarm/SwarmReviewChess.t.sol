// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwarmBase} from "./SwarmBase.sol";
import {SwarmRules} from "../../src/swarm/SwarmRules.sol";
import {SwarmText} from "../../src/swarm/SwarmText.sol";

contract AuditTextHarness {
    function write(SwarmText.Ask memory a) external pure returns (SwarmText.Written memory) {
        return SwarmText.write(a);
    }
}

/// Audit 2026-11-13, chess role: the rules as the question states them, and the question's limits at the worst cases.
contract AuditChessTest is SwarmBase {
    AuditTextHarness th = new AuditTextHarness();

    function _play(uint8 level, uint16[] memory moves)
        internal
        view
        returns (SwarmRules.Game memory g, SwarmRules.Outcome memory o, uint256[] memory history)
    {
        (g.board, g.white, g.black) = sr.start(level);
        (g.gameNo, g.level) = (9, level);
        history = new uint256[](13);
        uint256[4] memory r;
        for (uint256 i; i < moves.length; i++) {
            bool legal;
            (legal, o) = sr.play(g, r, moves[i]);
            assertTrue(legal, "legal");
            if (i + 1 < moves.length) assertEq(o.result, 0, "goes on");
            (g.board, g.white, g.black, g.quiet, r) = (o.board, o.white, o.black, o.quiet, o.ring);
            history[i >> 4] |= uint256(moves[i]) << ((i & 15) << 4);
            g.ply++;
        }
    }

    function _ask(SwarmRules.Game memory g, uint256[] memory history) internal view returns (SwarmText.Written memory) {
        SwarmText.Ask memory a;
        a.legal = sr.legalMoves(g.board, g.white, g.black, true);
        (a.g, a.history, a.windowBlock, a.chainId) = (g, history, 26_350_000, 1);
        if (g.level > 0) (a.startBoard, a.startWhite, a.startBlack) = sr.start(g.level);
        return th.write(a);
    }

    /// The bodies as an agent reads them: the free queen at odds 3, and en passant.
    function test_printBodies() public {
        uint16[] memory m = new uint16[](3);
        (m[0], m[1], m[2]) = (mv("e2", "e4"), mv("d7", "d5"), mv("d1", "g4"));
        (SwarmRules.Game memory g,, uint256[] memory h) = _play(3, m);
        SwarmText.Written memory w = _ask(g, h);
        emit log_string(string(w.body));
        emit log_named_uint("question", w.questionLength);

        m = new uint16[](5);
        (m[0], m[1], m[2], m[3], m[4]) = (mv("g1", "f3"), mv("d7", "d5"), mv("b1", "c3"), mv("d5", "d4"), mv("e2", "e4"));
        (g,, h) = _play(0, m);
        w = _ask(g, h);
        emit log_string(string(w.body));
    }

    /// RULES tells the agent "a position's third appearance within 16 half-moves (the start position at any
    /// distance)". The start at plies 0, 20 and 40 is its third appearance, each 20 apart: the game goes on.
    function test_startPositionThirdTimePastSixteenIsNoDraw() public view {
        uint16[] memory m = new uint16[](40);
        // 20 half-moves a cycle, the start seen at 0, 20 and 40 only
        // (found with chess.js: knight moves only, every position of the cycle distinct)
        string[20] memory loop = [
            "b1a3", "b8c6", "a3b5", "g8h6", "b5d4", "c6b8", "d4b5", "b8a6", "b5d4", "a6c5",
            "d4b5", "h6g8", "b5d4", "g8f6", "d4b5", "c5a6", "b5c3", "a6b8", "c3b1", "f6g8"
        ];
        for (uint256 i; i < 40; i++) m[i] = _uci(loop[i % 20]);
        (SwarmRules.Game memory g, SwarmRules.Outcome memory o,) = _play(0, m);
        assertEq(g.ply, 40);
        (uint256 b, uint32 w, uint32 k) = sr.start(0);
        assertEq(o.board, b, "the start again");
        assertEq(o.white, w);
        assertEq(o.black, k);
        assertEq(o.result, 0, "third appearance of the start (plies 0, 20, 40): no draw");
    }

    /// After 1. e4 (no Black pawn can take en passant) the FEN reads "- 0 1"; the same pieces after 3. Ng1 and 5. Ng1
    /// read the same FEN placement, side and rights: a FIDE third appearance, not a draw here (full side states).
    function test_epByteHidesAThirdAppearance() public view {
        uint16[] memory m = new uint16[](9);
        (m[0], m[1], m[2], m[3], m[4]) = (mv("e2", "e4"), mv("g8", "f6"), mv("g1", "f3"), mv("f6", "g8"), mv("f3", "g1"));
        (m[5], m[6], m[7], m[8]) = (mv("g8", "f6"), mv("g1", "f3"), mv("f6", "g8"), mv("f3", "g1"));
        (, SwarmRules.Outcome memory o,) = _play(0, m);
        assertEq(o.result, 0, "FIDE: third time; here: second");
    }

    /// The fixed definitions and the board are not measured by longestDefinition; all are well under 512.
    function test_fixedDefinitionLengths() public {
        uint16[] memory m = new uint16[](1);
        m[0] = mv("e2", "e4");
        (SwarmRules.Game memory g,, uint256[] memory h) = _play(4, m);
        SwarmText.Written memory w = _ask(g, h);
        bytes memory body = w.body;
        string[8] memory keys = ["answer", "board", "moves1", "notation", "position", "rules", "start", "question"];
        for (uint256 i; i < keys.length; i++) {
            emit log_named_uint(keys[i], _valueLength(body, string.concat('"', keys[i], '":"')));
            if (i < 7) assertLe(_valueLength(body, string.concat('"', keys[i], '":"')), 512);
        }
    }

    /// The worst buffer: 218 legal moves, 199 half-moves all promotions, odds 4. CAPACITY holds it; gas measured.
    function test_worstBuffer() public {
        uint256 b;
        string[9] memory queens = ["d2", "b3", "g3", "e4", "c5", "h5", "a6", "f6", "d7"];
        for (uint256 i; i < 9; i++) b = put(b, queens[i], 13);
        b = put(put(put(put(put(put(put(b, "a1", 12), "h1", 12), "b8", 10), "g8", 10), "c8", 11), "d8", 11), "f8", 14);
        b = put(put(put(b, "a8", 6), "a7", 1), "b7", 1);
        SwarmText.Ask memory a;
        a.legal = sr.legalMoves(b, side("a8"), side("f8"), true);
        (a.g.board, a.g.white, a.g.black, a.g.ply, a.g.gameNo, a.g.level, a.g.quiet) =
            (b, side("a8"), side("f8"), 199, type(uint32).max, 4, 59);
        a.history = new uint256[](13);
        uint256 promotion = (uint256(sq("a7")) << 6 | sq("a8")) | 4096;
        for (uint256 i; i < 199; i++) a.history[i >> 4] |= promotion << ((i & 15) << 4);
        (a.startBoard, a.startWhite, a.startBlack) = sr.start(4);
        (a.windowBlock, a.chainId) = (type(uint64).max, type(uint64).max);
        uint256 gas = gasleft();
        SwarmText.Written memory w = th.write(a);
        gas -= gasleft();
        emit log_named_uint("worst body", w.body.length);
        emit log_named_uint("worst question", w.questionLength);
        emit log_named_uint("write gas", gas);
        assertLt(w.body.length, SwarmText.CAPACITY);
        // the largest body IMD admits from that position: the legal list cut to fit 16 KiB
        uint16[] memory all = a.legal;
        uint256 n = all.length;
        while (w.body.length > 16_384) {
            n--;
            uint16[] memory cut = new uint16[](n);
            for (uint256 i; i < n; i++) cut[i] = all[i];
            a.legal = cut;
            gas = gasleft();
            w = th.write(a);
            gas -= gasleft();
        }
        emit log_named_uint("admissible legal moves", n);
        emit log_named_uint("admissible body", w.body.length);
        emit log_named_uint("admissible write gas", gas);
    }

    /// Random games (seeded picks) from every odds level, each Black turn's question and board, and each game's end,
    /// logged for a chess.js replay (scratch script; run with AUDIT_DUMP=true).
    function test_randomGamesDump() public {
        if (!vm.envOr("AUDIT_DUMP", false)) return;
        for (uint256 gi; gi < 60; gi++) {
            uint8 level = uint8(gi % 5);
            SwarmRules.Game memory g;
            (g.board, g.white, g.black) = sr.start(level);
            (g.gameNo, g.level) = (uint32(gi + 1), level);
            uint256[] memory h = new uint256[](13);
            uint256[4] memory r;
            string memory moves = "";
            SwarmRules.Outcome memory o;
            while (true) {
                bool black = g.ply & 1 == 1;
                uint16[] memory legal = sr.legalMoves(g.board, g.white, g.black, black);
                // prefer a promotion or a capture now and then, so they come up
                uint256 seed = uint256(keccak256(abi.encode(gi, g.ply)));
                uint16 m = legal[seed % legal.length];
                if (seed % 3 == 0) {
                    for (uint256 i; i < legal.length; i++) {
                        uint256 to = legal[i] & 63;
                        bool pawn = (g.board >> ((legal[i] >> 6) << 2)) & 7 == 1;
                        if ((pawn && (to < 8 || to >= 56)) || (g.board >> (to << 2)) & 7 != 0) { m = legal[i]; break; }
                    }
                }
                if (black) {
                    SwarmText.Written memory w = _ask(g, h);
                    emit log_string(string.concat("Q ", vm.toString(gi), " ", vm.toString(g.ply), " ", _value(w.body, '"question":"'), "|", _value(w.body, '"board":"')));
                }
                bool legalOk;
                (legalOk, o) = sr.play(g, r, m);
                assertTrue(legalOk);
                uint256 to2 = m & 63;
                uint256 entry = (g.board >> ((m >> 6) << 2)) & 7 == 1 && (to2 < 8 || to2 >= 56) ? uint256(m) | 4096 : m;
                h[g.ply >> 4] |= entry << ((g.ply & 15) << 4);
                moves = string.concat(moves, g.ply > 0 ? "," : "", vm.toString(entry));
                (g.board, g.white, g.black, g.quiet, r) = (o.board, o.white, o.black, o.quiet, o.ring);
                g.ply++;
                if (o.result != 0) break;
            }
            emit log_string(string.concat("G ", vm.toString(gi), " ", vm.toString(level), " ", vm.toString(o.result), " ", vm.toString(o.reason), " ", moves));
        }
    }

    function _value(bytes memory body, string memory key) internal pure returns (string memory) {
        bytes memory k = bytes(key);
        for (uint256 i; i + k.length <= body.length; i++) {
            bool hit = true;
            for (uint256 j; j < k.length && hit; j++) hit = body[i + j] == k[j];
            if (!hit) continue;
            uint256 n;
            while (body[i + k.length + n] != '"') n++;
            bytes memory out = new bytes(n);
            for (uint256 j; j < n; j++) out[j] = body[i + k.length + j];
            return string(out);
        }
        return "";
    }

    function _uci(string memory u) internal pure returns (uint16) {
        bytes memory b = bytes(u);
        return mv(string(abi.encodePacked(b[0], b[1])), string(abi.encodePacked(b[2], b[3])));
    }

    function _valueLength(bytes memory body, string memory key) internal pure returns (uint256) {
        bytes memory k = bytes(key);
        for (uint256 i; i + k.length <= body.length; i++) {
            bool hit = true;
            for (uint256 j; j < k.length && hit; j++) hit = body[i + j] == k[j];
            if (!hit) continue;
            uint256 n;
            while (body[i + k.length + n] != '"') n++;
            return n;
        }
        return 0;
    }
}
