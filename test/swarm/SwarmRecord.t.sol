// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwarmCause} from "../../src/swarm/ISwarmOracle.sol";
import {SwarmBase} from "./SwarmBase.sol";

/// The record SwarmDuel keeps for readers: each swarm turn's ask and how
/// Black's move came, each bid's move, every game's moves. No rule reads it; a page reads it instead of old events.
contract SwarmRecordTest is SwarmBase {
    struct Turn {
        bytes16 id;
        uint40 askedAt;
        uint40 knownAt;
        uint16 move;
        uint16 agreed;
        uint8 by;
        uint8 cause;
    }

    /// A turn's word, unpacked (the layout in SwarmDuel.turns).
    function turn(uint256 gameNo, uint256 ply) internal view returns (Turn memory t) {
        uint256 w = duel.turns((gameNo << 16) | ply);
        (t.move, t.by, t.cause, t.agreed) = (uint16(w), uint8(w >> 16), uint8(w >> 24), uint16(w >> 32));
        (t.askedAt, t.knownAt, t.id) = (uint40(w >> 48), uint40(w >> 88), bytes16(uint128(w >> 128)));
    }

    function moveOf(uint256 id) internal view returns (uint16 m) {
        (,,,,,,,, m) = duel.positions(id);
    }

    function test_aSwarmMoveIsRecordedWithItsAsk() public {
        humans("e2e4");
        bytes32 id = duel.askId();
        uint256 askedAt = vm.getBlockTimestamp(); // via-IR reads block.timestamp late
        Turn memory t = turn(1, 1);
        assertEq(t.id, bytes16(id), "the ask's id, from the ask");
        assertEq(t.askedAt, askedAt);
        assertEq(t.by, 0, "not played yet");
        vm.warp(askedAt + 120);
        oracle.answer(id, u("e7e5"));
        vm.warp(askedAt + 500);
        duel.advance();
        t = turn(1, 1);
        assertEq(t.id, bytes16(id));
        assertEq(t.askedAt, askedAt);
        assertEq(t.knownAt, askedAt + 120, "when the answer came, not when it was played");
        assertEq(t.move, u("e7e5"));
        assertEq(t.agreed, 5, "the panel's count, as the adapter gave it");
        assertEq(t.by, 1, "the swarm");
        assertEq(t.cause, 0);
    }

    function test_aFailedAskKeepsItsIdAndItsCause() public {
        humans("e2e4");
        bytes32 id = duel.askId();
        uint256 failedAt = vm.getBlockTimestamp() + 90;
        vm.warp(failedAt);
        oracle.fail(id, SwarmCause.SPLIT);
        Turn memory t = turn(1, 1);
        assertEq(t.id, bytes16(id), "a split's votes can still be read by its id");
        assertEq(t.cause, SwarmCause.SPLIT);
        assertEq(t.knownAt, failedAt);
        engineMoves();
        t = turn(1, 1);
        assertEq(t.cause, SwarmCause.SPLIT, "kept once the engine has moved");
        assertTrue(t.by == 2 || t.by == 3, "the engine or the seeded pick");
        assertEq(t.move, uint16(duel.historyWords(1)[0] >> 16) & 4095, "the move as played");
        assertEq(t.agreed, 0);
    }

    function test_aLateAnswerIsRecordedAtItsHoursEnd() public {
        humans("e2e4");
        uint256 askedAt = vm.getBlockTimestamp();
        vm.warp(askedAt + 29 hours); // nobody called for a day after the hour ran out
        duel.advance();
        Turn memory t = turn(1, 1);
        assertEq(t.cause, SwarmCause.LATE);
        assertEq(t.knownAt, askedAt + 1 hours, "the hour's end, not the next call");
    }

    function test_anIllegalAnswerIsRecordedAsTheCause() public {
        humans("e2e4");
        uint256 answeredAt = vm.getBlockTimestamp() + 90;
        vm.warp(answeredAt);
        oracle.answer(duel.askId(), u("e7e4"));
        vm.warp(answeredAt + 3 hours);
        duel.advance();
        engineMoves();
        Turn memory t = turn(1, 1);
        assertEq(t.cause, SwarmCause.ILLEGAL);
        assertEq(t.knownAt, answeredAt, "when the answer came, not when it was found illegal");
        assertTrue(t.by == 2 || t.by == 3);
    }

    function test_aForcedMoveIsRecordedWithoutAnAsk() public {
        humans("e2e4");
        swarm("f7f5");
        humans("d1h5"); // g7g6 is Black's only move
        Turn memory t = turn(1, 3);
        assertEq(t.askedAt, vm.getBlockTimestamp(), "every swarm turn has its close's time");
        assertEq(t.id, bytes16(0), "never asked");
        assertEq(t.by, 4, "forced");
        assertEq(t.move, u("g7g6"));
        assertEq(t.cause, 0);
    }

    function test_aBidKeepsItsMove() public {
        uint256 lead = bidAs(alice, 3 ether, "e2e4");
        uint256 under = bidAs(bob, 2 ether, "d2d4"); // doesn't lead: shares at once
        uint256 plain = put(bob, 5 ether);
        assertEq(moveOf(lead), u("e2e4"));
        assertEq(moveOf(under), u("d2d4"));
        assertEq(moveOf(plain), 0, "no move");
        uint256 over = bidAs(bob, 4 ether, "g1f3"); // outbids: alice's bid buys shares
        vm.warp(st().deadline);
        duel.advance();
        assertEq(moveOf(lead), u("e2e4"), "kept when outbid");
        assertEq(moveOf(over), u("g1f3"), "kept when it wins");
    }

    function test_everyGamesMovesAreKept() public {
        foolsMate(); // game 1: the swarm wins
        assertEq(st().gameNo, 2);
        humans("e2e4");
        uint256 first = duel.historyWords(1)[0];
        assertEq(uint16(first), u("f2f3"));
        assertEq(uint16(first >> 16), u("e7e5"));
        assertEq(uint16(first >> 32), u("g2g4"));
        assertEq(uint16(first >> 48), u("d8h4"));
        assertEq(first >> 64, 0, "nothing after the mate");
        assertEq(duel.historyWords(2)[0], u("e2e4"), "game 2 starts its own");
        assertEq(turn(1, 3).move, u("d8h4"), "game 1's turns stay too");
    }
}
