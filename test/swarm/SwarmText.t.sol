// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Chessboard} from "../Chessboard.sol";
import {SwarmRules} from "../../src/swarm/SwarmRules.sol";
import {SwarmText} from "../../src/swarm/SwarmText.sol";

/// SwarmText's functions as a contract.
contract TextHarness {
    function fen(uint256 b, uint32 w, uint32 k, bool black, uint256 quiet, uint256 ply, uint16[] memory legal)
        external
        pure
        returns (bytes memory)
    {
        SwarmText.Text memory t = SwarmText.Text(new bytes(128), 0);
        SwarmText.fen(t, b, w, k, black, quiet, ply, legal);
        return SwarmText.close(t);
    }

    function uciList(uint256 board, uint16[] memory legal) external pure returns (bytes memory) {
        SwarmText.Text memory t = SwarmText.Text(new bytes(2048), 0);
        for (uint256 i; i < legal.length; i++) {
            if (i > 0) SwarmText.char(t, " ");
            uint256 to = legal[i] & 63;
            SwarmText.uci(t, legal[i], (board >> ((legal[i] >> 6) << 2)) & 7 == 1 && (to < 8 || to >= 56));
        }
        return SwarmText.close(t);
    }

    function write(SwarmText.Ask memory a) external pure returns (SwarmText.Written memory) {
        return SwarmText.write(a);
    }
}

/// The swarm's question: the position text against chess.js on
/// 285 Black-to-move positions from the odds games and hand-made cases (scripts/gen-swarm-fens.mjs), IMD's limits at
/// the worst cases, and every body written to cache/swarm-bodies.json for scripts/check-swarm-bodies.mjs, which parses
/// each one and checks IMD's hash rule, the FEN, the legal moves, the allow list and the history independently.
contract SwarmTextTest is Chessboard {
    SwarmRules sr = new SwarmRules();
    TextHarness text = new TextHarness();

    /// Replays `moves` (bit 12 a promotion) from odds `level`'s start: the game and its history words.
    function replay(uint8 level, uint256[] memory moves)
        internal
        view
        returns (SwarmRules.Game memory g, uint256[] memory history)
    {
        (g.board, g.white, g.black) = sr.start(level);
        (g.gameNo, g.level) = (3, level);
        history = new uint256[]((moves.length + 15) / 16);
        uint256[4] memory r;
        for (uint256 i; i < moves.length; i++) {
            (bool legal, SwarmRules.Outcome memory o) = sr.play(g, r, uint16(moves[i] & 4095));
            assertTrue(legal, "fixture move legal");
            (g.board, g.white, g.black, g.quiet, r) = (o.board, o.white, o.black, o.quiet, o.ring);
            g.ply++;
            history[i >> 4] |= moves[i] << ((i & 15) << 4);
        }
    }

    function ask(SwarmRules.Game memory g, uint16[] memory legal, uint256[] memory history)
        internal
        view
        returns (SwarmText.Ask memory a)
    {
        (a.g, a.legal, a.history, a.windowBlock, a.chainId) = (g, legal, history, 26_350_000, 1);
        if (g.level > 0) (a.startBoard, a.startWhite, a.startBlack) = sr.start(g.level);
    }

    function test_againstChessJs() public {
        string memory data = vm.readFile("./test/data/swarm-fens.json");
        uint256[] memory levels = vm.parseJsonUintArray(data, ".levels");
        string memory out = '{"cases":[';
        for (uint256 i; i < levels.length; i++) {
            string memory at = string.concat("[", vm.toString(i), "]");
            uint256[] memory moves = vm.parseJsonUintArray(data, string.concat(".moves", at));
            (SwarmRules.Game memory g, uint256[] memory history) = replay(uint8(levels[i]), moves);
            assertEq(g.ply & 1, 1, "Black to move");
            uint16[] memory legal = sr.legalMoves(g.board, g.white, g.black, true);
            assertEq(string(text.fen(g.board, g.white, g.black, true, g.quiet, g.ply, legal)), vm.parseJsonString(data, string.concat(".fens", at)), "FEN");
            assertEq(string(text.uciList(g.board, legal)), vm.parseJsonString(data, string.concat(".legal", at)), "legal moves in UCI");
            SwarmText.Written memory w = text.write(ask(g, legal, history));
            assertLe(w.questionLength, 2_000, "question");
            assertLe(w.longestDefinition, 512, "definition");
            assertLe(w.body.length, 16_384, "body");
            out = string.concat(out, i > 0 ? "," : "", '{"level":', vm.toString(levels[i]), ',"moves":', _list(moves), ',"body":"',
                vm.toString(w.body), '","hash":"', vm.toString(w.questionHash), '","questionLength":', vm.toString(w.questionLength), "}");
        }
        // for scripts/check-swarm-bodies.mjs, when scripts/swarm-test.sh asks (a clean checkout has no cache/)
        if (vm.envOr("SWARM_BODIES", false)) vm.writeFile("./cache/swarm-bodies.json", string.concat(out, "]}"));
    }

    function _list(uint256[] memory xs) internal pure returns (string memory s) {
        s = "[";
        for (uint256 i; i < xs.length; i++) s = string.concat(s, i > 0 ? "," : "", vm.toString(xs[i]));
        s = string.concat(s, "]");
    }

    /// The longest history: 199 half-moves, every one written as a promotion (the most characters a move takes).
    function test_longestHistoryFitsItsDefinitions() public {
        SwarmRules.Game memory g;
        (g.board, g.white, g.black) = sr.start(0);
        (g.ply, g.gameNo) = (199, 4_294_967_295);
        uint256[] memory history = new uint256[](13);
        uint256 promotion = (uint256(sq("a7")) << 6 | sq("a8")) | 4096;
        for (uint256 i; i < 199; i++) history[i >> 4] |= promotion << ((i & 15) << 4);
        uint16[] memory legal = sr.legalMoves(g.board, g.white, g.black, true);
        SwarmText.Written memory w = text.write(ask(g, legal, history));
        emit log_named_uint("longest definition", w.longestDefinition);
        emit log_named_uint("body", w.body.length);
        assertLe(w.longestDefinition, 512);
        assertLe(w.questionLength, 2_000);
    }

    /// Black with the most legal moves a position has (218, the known record, colours swapped): the question still
    /// fits 2,000 characters, the body passes 16 KiB (so the adapter declines and the engine plays).
    function test_mostLegalMoves() public {
        uint256 b;
        string[10] memory queens = ["d2", "b3", "g3", "e4", "c5", "h5", "a6", "f6", "d7", "d7"];
        for (uint256 i; i < 9; i++) b = put(b, queens[i], 13);
        b = put(put(put(put(put(put(put(b, "a1", 12), "h1", 12), "b8", 10), "g8", 10), "c8", 11), "d8", 11), "f8", 14);
        b = put(put(put(b, "a8", 6), "a7", 1), "b7", 1);
        uint16[] memory legal = sr.legalMoves(b, side("a8"), side("f8"), true);
        assertEq(legal.length, 218, "the record position");
        SwarmRules.Game memory g;
        (g.board, g.white, g.black, g.ply, g.gameNo) = (b, side("a8"), side("f8"), 1, 1);
        SwarmText.Written memory w = text.write(ask(g, legal, new uint256[](1)));
        emit log_named_uint("question", w.questionLength);
        emit log_named_uint("body", w.body.length);
        assertLe(w.questionLength, 2_000, "question");
        assertGt(w.body.length, 16_384, "past IMD's body limit");
    }
}
