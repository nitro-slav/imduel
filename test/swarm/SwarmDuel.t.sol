// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IMainDuelBuyer} from "../../src/IMainDuelBuyer.sol";
import {SwarmDuel} from "../../src/swarm/SwarmDuel.sol";
import {ISwarmOracle, SwarmCause} from "../../src/swarm/ISwarmOracle.sol";
import {ScriptedOracle, MockVault} from "./SwarmDoubles.sol";
import {SwarmBase, State} from "./SwarmBase.sol";

/// SwarmDuel's turn machine: opening, deposits and the lead, the clock, the close, the
/// ask, answers and failures, the breaker, the engine in a later call with its dice from the block after the close,
/// the seeded pick, the odds by moves played, the adapter per game, re-entry and the gas guards.
contract SwarmDuelTest is SwarmBase {
    function closeBlock() internal view returns (uint256 b) {
        (,,, uint48 c) = duel.stats();
        b = c;
    }

    function movesSinceWin() internal view returns (uint256 m) {
        (uint32 n,,,) = duel.stats();
        m = n;
    }

    /// Writes the odds count (the low 32 bits of `stats`, slot 5: after the game's two slots, the ask, its id and the
    /// lead).
    function setMovesSinceWin(uint32 n) internal {
        bytes32 slot = bytes32(uint256(5));
        uint256 w = uint256(vm.load(address(duel), slot));
        vm.store(address(duel), slot, bytes32((w & ~uint256(type(uint32).max)) | n));
        assertEq(movesSinceWin(), n, "the odds count's slot");
    }

    // ---------------------------------------------------------------- opening

    function test_openNamesTheFirstAdapterOnceAndNothingBefore() public {
        SwarmDuel fresh =
            new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(vault), TEAM, address(this), 0);
        vm.prank(alice);
        imd.approve(address(fresh), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(SwarmDuel.NotOpen.selector);
        fresh.deposit(1 ether, 0, address(0));
        vm.prank(alice);
        vm.expectRevert(SwarmDuel.NotDeployer.selector);
        fresh.open(oracle);
        fresh.open(oracle);
        assertEq(address(fresh.oracle()), address(oracle));
        assertEq(fresh.oraclePrice(), PRICE, "the price stored when named");
        (,,, uint32 gameNo,,,,,,,,,) = fresh.game();
        assertEq(gameNo, 1);
        vm.expectRevert(SwarmDuel.AlreadyOpen.selector);
        fresh.open(oracle);
    }

    /// The launch time (user, 2026-11-13): opened early, announced with a countdown; no deposit, of shares or a move,
    /// before it, and both from its very second. Nothing else waits: nothing is due before a first deposit.
    function test_depositsWaitForTheLaunchTime() public {
        uint256 at = vm.getBlockTimestamp() + 3 days;
        SwarmDuel fresh =
            new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(vault), TEAM, address(this), at);
        assertEq(fresh.launchAt(), at);
        fresh.open(oracle);
        vm.startPrank(alice);
        imd.approve(address(fresh), type(uint256).max);
        vm.expectRevert(SwarmDuel.NotOpen.selector);
        fresh.deposit(10 ether, 0, address(0));
        vm.warp(at - 1);
        vm.expectRevert(SwarmDuel.NotOpen.selector);
        fresh.deposit(2 ether, u("e2e4"), address(0));
        vm.expectRevert(SwarmDuel.NothingDue.selector);
        fresh.advance(); // nothing is due before a first deposit
        (,,,,,,,,,,, uint40 turnStart,) = fresh.game();
        assertEq(turnStart, 0, "the clock waits for the first lead");
        vm.warp(at);
        fresh.deposit(10 ether, 0, address(0));
        fresh.deposit(2 ether, u("e2e4"), address(0));
        vm.stopPrank();
        (,,,,,,,,,,, turnStart,) = fresh.game();
        assertEq(turnStart, at, "the first lead starts the clock at launch");
    }

    /// A launch time more than 30 days ahead is refused at deploy: a time in milliseconds would lock deposits for good.
    function test_aLaunchTimeTooFarAheadIsRefused() public {
        uint256 at = vm.getBlockTimestamp();
        new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(vault), TEAM, address(this), at + 30 days);
        vm.expectRevert(SwarmDuel.BadSetup.selector);
        new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(vault), TEAM, address(this), at + 30 days + 1);
        vm.expectRevert(SwarmDuel.BadSetup.selector);
        new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(vault), TEAM, address(this), (at + 2 days) * 1000);
    }

    function test_theConstructorChecksTheLiveContracts() public {
        MockVault wrong = new MockVault(address(imd));
        vm.expectRevert(SwarmDuel.BadSetup.selector);
        new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(wrong), TEAM, address(this), 0);
        vm.expectRevert(SwarmDuel.BadSetup.selector);
        new SwarmDuel(imduel, imd, sr, engine, IMainDuelBuyer(address(buyer)), address(vault), TEAM, address(this), 0);
    }

    // ---------------------------------------------------------------- deposits and the lead

    function test_aMoveNeedsToBeLegalAndTwoIMD() public {
        vm.startPrank(alice);
        vm.expectRevert(SwarmDuel.IllegalMove.selector);
        duel.deposit(2 ether, u("e2e5"), address(0));
        vm.expectRevert(SwarmDuel.IllegalMove.selector);
        duel.deposit(2 ether, u("e7e5"), address(0)); // Black's move in White's turn
        vm.expectRevert(SwarmDuel.TooSmall.selector);
        duel.deposit(1.999 ether, u("e2e4"), address(0));
        vm.expectRevert(SwarmDuel.TooSmall.selector);
        duel.deposit(0, 0, address(0));
        uint256 id = duel.deposit(2 ether, u("e2e4"), address(0));
        vm.stopPrank();
        (address owner, uint96 amount,,,,, uint8 kind,,) = duel.positions(id);
        assertEq(owner, alice);
        assertEq(kind, 2, "the leading bid");
        assertEq(amount, 2 ether);
        (,,, uint96 escrow,,,,) = duel.money();
        assertEq(escrow, 2 ether, "escrowed");
    }

    function test_aNewLeadBeatsTheLastByMoreThanTenPercent() public {
        uint256 a = bidAs(alice, 10 ether, "e2e4");
        uint256 b = bidAs(bob, 11 ether, "d2d4"); // exactly 10% more: not a lead, shares now
        (uint64 leadId,,,) = duel.lead();
        assertEq(leadId, a);
        (,,,,,, uint8 kind,,) = duel.positions(b);
        assertEq(kind, 1, "a move that doesn't lead buys shares");
        uint256 c = bidAs(bob, 11.01 ether, "d2d4");
        (leadId,,,) = duel.lead();
        assertEq(leadId, c);
        (,,,,,, kind,,) = duel.positions(a);
        assertEq(kind, 1, "the outbid bid became shares");
    }

    function test_theLeaderTopsUpByOutbiddingItself() public {
        uint256 a = bidAs(alice, 10 ether, "e2e4");
        uint256 b = bidAs(alice, 11.01 ether, "e2e4");
        (uint64 leadId, uint128 amount,,) = duel.lead();
        assertEq(leadId, b);
        assertEq(amount, 11.01 ether);
        (,,,,,, uint8 kind,,) = duel.positions(a);
        assertEq(kind, 1, "its old bid is shares");
        (,,, uint96 escrow,,,,) = duel.money();
        assertEq(escrow, 11.01 ether, "only the new lead in escrow");
    }

    // ---------------------------------------------------------------- the clock

    function test_theFirstBidStartsTheClock() public {
        assertEq(st().turnStart, 0, "a new game waits for its first bid");
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(SwarmDuel.NothingDue.selector);
        duel.advance(); // no bid, no close, no forfeit
        bidAs(alice, 2 ether, "e2e4");
        assertEq(st().deadline, block.timestamp + 24 hours);
        vm.warp(block.timestamp + 24 hours - 1);
        vm.expectRevert(SwarmDuel.NothingDue.selector);
        duel.advance();
        vm.warp(block.timestamp + 1);
        duel.advance();
        assertEq(st().ply, 1);
    }

    function test_aLeadInTheLastHourMovesTheDeadline() public {
        bidAs(alice, 2 ether, "e2e4");
        uint256 deadline = st().deadline;
        vm.warp(deadline - 30 minutes);
        bidAs(bob, 2.1 ether, "d2d4"); // not a lead: the deadline stays
        assertEq(st().deadline, deadline);
        bidAs(bob, 4 ether, "d2d4");
        assertEq(st().deadline, block.timestamp + 1 hours, "an hour to answer it");
        vm.warp(st().deadline);
        vm.prank(alice);
        vm.expectRevert(SwarmDuel.Due.selector);
        duel.deposit(5 ether, u("c2c4"), address(0)); // the turn is closing
    }

    function test_aFirstBidAfterTheDeadlineGetsAnHour() public {
        humans("e2e4");
        swarm("e7e5");
        vm.warp(block.timestamp + 3 days); // the humans' turn passed with no bid
        bidAs(alice, 2 ether, "g1f3");
        assertEq(st().deadline, block.timestamp + 1 hours);
    }

    // ---------------------------------------------------------------- the close and the ask

    function test_theClosePlaysTheMoveAndAsksTheSwarm() public {
        humans("e2e4");
        State memory s = st();
        assertEq(s.ply, 1);
        assertEq(s.phase, 1, "thinking");
        assertEq(oracle.asks(), 1);
        assertEq(imd.balanceOf(address(oracle)), PRICE, "exactly the price");
        assertEq(imd.allowance(address(duel), address(oracle)), 0, "no allowance left");
        uint16[] memory legal = oracle.lastLegal();
        (uint256 board, uint32 white, uint32 black,,,,) = oracle.lastGame();
        assertEq(legal.length, sr.legalMoves(board, white, black, true).length, "Black's legal moves");
        assertEq(oracle.lastHistory()[0], u("e2e4"), "the game so far");
        vm.prank(bob);
        vm.expectRevert(SwarmDuel.Thinking.selector);
        duel.deposit(2 ether, u("d2d4"), address(0));
    }

    function test_theAnswerIsPlayedByTheNextCallAndOpensTheTurn() public {
        humans("e2e4");
        vm.warp(block.timestamp + 5 minutes);
        oracle.answer(duel.askId(), u("e7e5"));
        uint256 known = vm.getBlockTimestamp();
        vm.warp(block.timestamp + 2 hours);
        bidAs(bob, 2 ether, "g1f3"); // a deposit plays the stored answer first
        State memory s = st();
        assertEq(s.ply, 2);
        assertEq(s.turnStart, known, "the humans' 24 hours start when the answer arrived");
        assertEq(s.deadline, known + 24 hours);
    }

    function test_anIllegalAnswerGoesToTheEngineUncounted() public {
        humans("e2e4");
        oracle.answer(duel.askId(), u("e7e4"));
        vm.prank(bob);
        vm.expectRevert(SwarmDuel.Due.selector);
        duel.deposit(2 ether, u("d2d4"), address(0)); // the illegal answer hands the move to the engine, whose dice aren't known
        duel.advance(); // same block as the close: the engine's dice aren't known yet
        State memory s = st();
        assertEq(s.phase, 3, "fallback");
        assertEq(s.failures, 0, "the panel's choice, not a broken oracle");
        engineMoves();
        assertEq(st().ply, 2, "the engine moved");
        assertEq(st().phase, 0);
    }

    function test_aLateAnswerIsIgnoredAndTheEnginePlays() public {
        humans("e2e4");
        bytes32 id = duel.askId();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(vm.getBlockNumber() + 2);
        oracle.answer(id, u("e7e5"));
        assertEq(st().phase, 1, "still thinking: a late answer changes nothing");
        duel.advance();
        assertEq(st().failures, 1, "the hour counts");
        assertEq(st().ply, 2, "the engine in the same call: its dice were known");
        assertEq(st().turnStart, block.timestamp, "the turn starts when the engine's move is played");
    }

    function test_onlyThePendingAskFromTheAskedAdapter() public {
        humans("e2e4");
        bytes32 id = duel.askId();
        duel.answered(id, u("e7e5"), 5); // not the adapter
        oracle.answer(bytes32(uint256(77)), u("e7e5")); // not the pending id
        assertEq(st().phase, 1);
        oracle.answer(id, u("e7e5"));
        assertEq(st().phase, 2);
        oracle.answer(id, u("d7d5")); // again: ignored
        duel.advance();
        assertEq(st().ply, 2);
    }

    function test_onlyOneLegalMoveIsPlayedWithoutAsking() public {
        humans("e2e4");
        swarm("f7f5");
        humans("d1h5"); // check along h5-e8: g7g6 is Black's only move
        assertEq(oracle.asks(), 1, "no second ask");
        assertEq(st().ply, 4);
        assertEq(st().phase, 0, "the humans' turn");
    }

    // ---------------------------------------------------------------- a deposit plays what is due first

    function test_aDepositPlaysTheEnginesMoveOnceItsDiceAreKnown() public {
        oracle.setRefuse(true);
        humans("e2e4"); // the ask is declined: the engine's move is due two blocks after the close
        vm.prank(bob);
        vm.expectRevert(SwarmDuel.Due.selector);
        duel.deposit(2 ether, u("d2d4"), address(0)); // the close's own block
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        vm.expectRevert(SwarmDuel.Due.selector);
        duel.deposit(2 ether, 0, address(0)); // the block after the close holds the dice: not known inside it
        vm.roll(vm.getBlockNumber() + 1);
        bidAs(bob, 2 ether, "d2d4"); // two blocks after: the deposit plays the engine's move, then bids
        State memory s = st();
        assertEq(s.ply, 2, "the engine's move, played by the deposit");
        assertEq(s.phase, 0);
        assertEq(s.turnStart, block.timestamp, "the humans' turn opened with it");
        (, uint128 leading, uint16 m,) = duel.lead();
        assertEq(m, u("d2d4"), "and the bid leads the new turn");
        assertEq(leading, 2 ether);
    }

    function test_aDepositAfterTheHourHandsTheMoveToTheEngine() public {
        humans("e2e4");
        vm.prank(bob);
        vm.expectRevert(SwarmDuel.Thinking.selector);
        duel.deposit(2 ether, u("d2d4"), address(0)); // the swarm has its hour
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(vm.getBlockNumber() + 2);
        bidAs(bob, 2 ether, "d2d4");
        assertEq(st().ply, 2, "late: the engine moved, inside the deposit");
        assertEq(st().failures, 1, "the hour counts");
    }

    function test_aDepositHandsAnIllegalAnswerToTheEngine() public {
        humans("e2e4");
        oracle.answer(duel.askId(), u("e7e4"));
        vm.roll(vm.getBlockNumber() + 2);
        bidAs(bob, 2 ether, "d2d4");
        assertEq(st().ply, 2, "the engine moved instead");
        assertEq(st().failures, 0, "uncounted");
    }

    function test_aDepositNamesItsOwnerAsATopic() public {
        vm.recordLogs();
        uint256 id = put(bob, 3 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 deposited = keccak256("Deposited(uint256,uint32,uint16,address,uint256,uint16,bool,uint256)");
        uint256 found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(duel) || logs[i].topics[0] != deposited) continue;
            assertEq(logs[i].topics[1], bytes32(id));
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(bob))), "the page finds a player's positions by owner");
            found++;
        }
        assertEq(found, 1);
    }

    // ---------------------------------------------------------------- failures and the breaker

    function test_aSplitIsNotCountedARefusalIs() public {
        humans("e2e4");
        oracle.fail(duel.askId(), SwarmCause.SPLIT);
        assertEq(st().failures, 0);
        engineMoves();
        humans("g1f3");
        oracle.fail(duel.askId(), SwarmCause.REFUSED);
        assertEq(st().failures, 1);
        engineMoves();
        humans("f1c4");
        swarm("g8f6");
        assertEq(st().failures, 0, "an answer clears the count");
    }

    function test_theBreakerStopsAskingThenProbesEveryEighthMove() public {
        // White pushes pawns (no repetition), the engine shuffles Black's g-knight
        string[12] memory w = ["a2a3", "b2b3", "c2c3", "d2d3", "e2e3", "f2f3", "g2g3", "h2h3", "a3a4", "b3b4", "c3c4", "d3d4"];
        engine.set(3, 0);
        for (uint256 i; i < 3; i++) {
            humans(w[i]);
            oracle.fail(duel.askId(), SwarmCause.INVALID);
            engineMoves();
        }
        assertEq(st().failures, 3, "tripped");
        uint256 asks = oracle.asks();
        for (uint256 i = 3; i < 10; i++) {
            humans(w[i]);
            assertEq(st().phase, 3, "no ask: the engine is due");
            engineMoves();
        }
        assertEq(oracle.asks(), asks, "no asks while stopped");
        humans(w[10]); // the 8th swarm move since the trip: a probe
        assertEq(oracle.asks(), asks + 1, "asked again");
        swarm("b8c6");
        assertEq(st().failures, 0, "an answer clears the breaker");
    }

    function test_anAskWithoutAUsableIdFails() public {
        uint256 snap = vm.snapshotState();
        for (uint8 mode = 1; mode <= 3; mode++) {
            vm.revertToState(snap);
            oracle.setIdMode(mode); // zero, or the client's own markers for "asking" and "no ask"
            humans("e2e4");
            State memory s = st();
            assertEq(s.phase, 3, "no usable id: the engine is due");
            assertEq(s.failures, 1, "counted as a declined ask");
            assertEq(duel.askId(), bytes32(uint256(1)), "no ask pending: the marker, never zero again");
        }
    }

    /// An adapter returning 600 KB instead of an id: only 32 bytes are copied, so the close stays cheap and the ask is
    /// a failed one (round 3's security review).
    function test_anAskReturningMegabytesIsAFailedAskNotAStall() public {
        oracle.setBig(true);
        bidAs(alice, 2 ether, "e2e4");
        vm.warp(st().deadline);
        uint256 g0 = gasleft();
        duel.advance{gas: 6_000_000}();
        uint256 used = g0 - gasleft();
        assertEq(st().phase, 3, "no id: the engine is due");
        assertEq(st().failures, 1, "counted as a declined ask");
        assertLt(used, 4_500_000, "the copy is bounded: the adapter's own memory is the cost");
    }

    function test_theSwarmsHourIncludesItsLastSecond() public {
        humans("e2e4");
        (, uint40 askedAt,,) = duel.asked();
        bytes32 id = duel.askId();
        uint256 snap = vm.snapshotState();
        vm.warp(uint256(askedAt) + 1 hours);
        vm.roll(vm.getBlockNumber() + 2);
        vm.prank(bob);
        vm.expectRevert(SwarmDuel.Thinking.selector);
        duel.deposit(2 ether, u("d2d4"), address(0)); // the hour's last second is still the swarm's
        oracle.answer(id, u("e7e5"));
        assertEq(st().phase, 2, "an answer in that second counts");
        vm.revertToState(snap);
        vm.warp(uint256(askedAt) + 1 hours + 1);
        vm.roll(vm.getBlockNumber() + 2);
        oracle.answer(id, u("e7e5"));
        assertEq(st().phase, 1, "a second later it is ignored");
        bidAs(bob, 2 ether, "d2d4"); // and a deposit hands the move to the engine
        assertEq(st().ply, 2);
    }

    function test_aFailedProbeStopsAskingForSevenMoreTurns() public {
        string[19] memory w = [
            "a2a3", "b2b3", "c2c3", "d2d3", "e2e3", "f2f3", "g2g3", "h2h3", "a3a4", "b3b4",
            "c3c4", "d3d4", "e3e4", "f3f4", "h3h4", "a4a5", "b4b5", "c4c5", "d4d5"
        ];
        engine.set(3, 0); // Black's g-knight out and back
        for (uint256 i; i < 3; i++) {
            humans(w[i]);
            oracle.fail(duel.askId(), SwarmCause.INVALID);
            engineMoves();
        }
        for (uint256 i = 3; i < 10; i++) {
            humans(w[i]);
            engineMoves();
        }
        uint256 asks = oracle.asks();
        humans(w[10]); // the probe
        assertEq(oracle.asks(), asks + 1);
        oracle.fail(duel.askId(), SwarmCause.INVALID); // it fails too
        engineMoves();
        for (uint256 i = 11; i < 18; i++) {
            humans(w[i]);
            assertEq(st().phase, 3, "seven more turns without an ask");
            engineMoves();
        }
        assertEq(oracle.asks(), asks + 1);
        humans(w[18]);
        assertEq(oracle.asks(), asks + 2, "the next probe, eight swarm moves after the last");
    }

    function test_anAskThatRevertsLeavesTheEngineForALaterCall() public {
        oracle.setRefuse(true);
        humans("e2e4");
        State memory s = st();
        assertEq(s.ply, 1);
        assertEq(s.phase, 3, "the engine is due");
        assertEq(s.failures, 1, "a declined ask counts");
        assertEq(imd.balanceOf(address(oracle)), 0, "nothing paid");
        assertEq(imd.allowance(address(duel), address(oracle)), 0);
        vm.expectRevert(SwarmDuel.NothingDue.selector);
        duel.advance(); // the close's own block
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(SwarmDuel.NothingDue.selector);
        duel.advance(); // the block after the close is the dice's: not known inside it
        vm.roll(vm.getBlockNumber() + 1);
        duel.advance();
        assertEq(st().ply, 2, "the engine's move, two blocks after the close");
    }

    function test_anAdapterIsPaidOnlyItsStoredPrice() public {
        oracle.setPrice(0.8 ether); // raised after being named at 0.5
        humans("e2e4");
        assertEq(oracle.asks(), 0, "its pull of 0.8 fails against the 0.5 approved");
        assertEq(imd.balanceOf(address(oracle)), 0);
        assertEq(st().phase, 3);
    }

    function test_aFailingEngineGivesTheSeededPick() public {
        engine.set(2, 0);
        humans("e2e4");
        oracle.fail(duel.askId(), SwarmCause.SPLIT);
        vm.roll(vm.getBlockNumber() + 2);
        uint256 dice = uint256(keccak256(abi.encode(uint256(1), uint256(1), blockhash(closeBlock() + 1))));
        (uint256 board, uint32 white, uint32 black,,,,,,,,,,) = duel.game();
        uint16 pick = sr.pick(board, white, black, true, dice);
        vm.expectEmit(address(duel));
        emit SwarmDuel.Moved(1, 1, pick, 3);
        duel.advance();
    }

    function test_anIllegalEngineMoveGivesTheSeededPick() public {
        engine.set(1, u("e2e4")); // White's move
        humans("d2d4");
        oracle.fail(duel.askId(), SwarmCause.SPLIT);
        engineMoves();
        assertEq(st().ply, 2);
    }

    function test_theEnginesDiceDontDependOnWhenItIsCalled() public {
        engine.set(2, 0); // the pick plays, so the dice show in the move
        humans("e2e4");
        oracle.fail(duel.askId(), SwarmCause.SPLIT);
        uint256 snap = vm.snapshotState();
        vm.roll(vm.getBlockNumber() + 2);
        duel.advance();
        uint256 first = st().board;
        vm.revertToState(snap);
        vm.roll(vm.getBlockNumber() + 5); // later blocks give the same dice
        duel.advance();
        assertEq(st().board, first, "no caller chooses the block");
    }

    /// Round 3's security review: once neither `blockhash` nor EIP-2935 serve the block after the close (8,191
    /// blocks, about 27 hours), the dice read a zero hash, so the block a closer picks for the close can't choose them.
    function test_theCloseBlockCantChooseTheDiceOnceTheHashIsForgotten() public {
        engine.set(2, 0); // the pick plays, so the dice show in the move
        bidAs(alice, 2 ether, "e2e4");
        vm.warp(st().deadline);
        uint256 snap = vm.snapshotState();
        uint256[2] memory boards;
        for (uint256 i; i < 2; i++) {
            vm.revertToState(snap);
            vm.roll(vm.getBlockNumber() + 1 + i * 7); // two closers, two close blocks
            duel.advance();
            oracle.fail(duel.askId(), SwarmCause.SPLIT);
            vm.roll(vm.getBlockNumber() + 9_000); // past both histories
            duel.advance();
            boards[i] = st().board;
        }
        assertEq(boards[0], boards[1], "the same dice whichever block closed");
        uint256 dice = uint256(keccak256(abi.encode(uint256(1), uint256(1), bytes32(0))));
        vm.revertToState(snap);
        duel.advance();
        oracle.fail(duel.askId(), SwarmCause.SPLIT);
        vm.roll(vm.getBlockNumber() + 9_000);
        (uint256 board, uint32 white, uint32 black,,,,,,,,,,) = duel.game();
        uint16 pick = sr.pick(board, white, black, true, dice);
        vm.expectEmit(address(duel));
        emit SwarmDuel.Moved(1, 1, pick, 3);
        duel.advance();
    }

    // ---------------------------------------------------------------- the end of a game and the odds

    function test_theOddsAreEarnedByMovesPlayed() public {
        foolsMate();
        assertEq(st().gameNo, 2);
        assertEq(st().level, 0, "a two-move loss earns no piece");
        assertEq(movesSinceWin(), 2);
        for (uint256 i; i < 14; i++) foolsMate(); // 30 humans' moves since the last win
        assertEq(movesSinceWin(), 30);
        State memory s = st();
        assertEq(s.gameNo, 16);
        assertEq(s.level, 1, "30 moves: the swarm gives a pawn");
        (uint256 start,,) = sr.start(1);
        assertEq(s.board, start);
        // level 1, no f7 pawn: 1. e4 g5 2. Qh5 is mate, White wins
        humans("e2e4");
        swarm("g7g5");
        humans("d1h5");
        s = st();
        assertEq(s.gameNo, 17);
        assertEq(s.level, 0, "a human win resets the odds");
        assertEq(movesSinceWin(), 0);
        assertEq(s.turnStart, 0, "the next game waits for its first bid");
    }

    function test_theOddsLevelIsMovesOverThirtyUpToFour() public {
        uint32[4] memory before = [uint32(27), 28, 88, 148]; // each fool's mate adds two humans' moves
        uint8[4] memory level = [0, 1, 3, 4];
        for (uint256 i; i < 4; i++) {
            setMovesSinceWin(before[i]);
            foolsMate();
            State memory s = st();
            assertEq(s.level, level[i], "floor(moves / 30), at most 4");
            (uint256 start,,) = sr.start(level[i]);
            assertEq(s.board, start);
        }
        assertEq(movesSinceWin(), 150, "150 moves: level 5 would be past the last start, so 4");
    }

    // ---------------------------------------------------------------- the adapter

    function test_aNewAdapterTakesOverAtTheFirstGameAfterItsNotice() public {
        ScriptedOracle next = new ScriptedOracle(imd, duel, PRICE);
        humans("f2f3"); // asked the first adapter
        duel.propose(next);
        assertEq(duel.nextAt(), block.timestamp + 3 days);
        swarm("e7e5");
        vm.warp(duel.nextAt() + 1);
        humans("g2g4");
        assertEq(oracle.asks(), 2, "the running game keeps its adapter after the notice");
        swarm("d8h4"); // game 2 starts: the new adapter
        assertEq(address(duel.oracle()), address(next));
        assertEq(duel.nextAt(), 0);
        humans("e2e4");
        assertEq(next.asks(), 1, "game 2 asks the new one");
    }

    function test_aGameStartingInsideTheNoticeKeepsItsAdapter() public {
        ScriptedOracle next = new ScriptedOracle(imd, duel, PRICE);
        duel.propose(next);
        uint256 at = duel.nextAt();
        foolsMate(); // two days: game 2 starts inside the 3-day notice
        assertEq(st().gameNo, 2);
        assertLt(block.timestamp, at);
        assertEq(address(duel.oracle()), address(oracle), "inside the notice: the old adapter");
        assertEq(duel.nextAt(), at, "still proposed");
        vm.warp(at);
        foolsMate(); // game 3 starts after it
        assertEq(address(duel.oracle()), address(next), "the first game after the notice switches");
    }

    function test_renounceDropsAPendingProposal() public {
        ScriptedOracle next = new ScriptedOracle(imd, duel, PRICE);
        duel.propose(next);
        duel.renounce();
        assertEq(address(duel.nextOracle()), address(0));
        assertEq(duel.nextAt(), 0);
        vm.warp(block.timestamp + 4 days);
        foolsMate();
        assertEq(address(duel.oracle()), address(oracle), "renounced: the proposal never takes over");
    }

    function test_onlyTheDeployerNamesAndRenounceIsForGood() public {
        ScriptedOracle next = new ScriptedOracle(imd, duel, PRICE);
        vm.prank(alice);
        vm.expectRevert(SwarmDuel.NotDeployer.selector);
        duel.propose(next);
        next.setPrice(0.8 ether);
        vm.expectRevert(SwarmDuel.BadOracle.selector);
        duel.propose(next);
        vm.expectRevert(SwarmDuel.BadOracle.selector);
        duel.propose(ISwarmOracle(address(0xdead))); // no code
        next.setPrice(PRICE);
        duel.propose(next);
        duel.propose(oracle); // the current one: cancels
        assertEq(duel.nextAt(), 0);
        duel.renounce();
        vm.expectRevert(SwarmDuel.NotDeployer.selector);
        duel.propose(next);
    }

    // ---------------------------------------------------------------- re-entry and gas

    function test_anAdapterCantReEnter() public {
        oracle.setReenter(true);
        humans("e2e4");
        assertEq(st().phase, 1, "asked: the re-entry was ignored and refused");
        oracle.answer(duel.askId(), u("e7e5"));
        assertEq(st().phase, 2);
    }

    /// The close and the engine's step at every gas limit: the same game, or a revert (no caller picks a branch by gas;
    /// only an inner buy may be skipped).
    function test_gasNeverPicksABranch() public {
        bidAs(alice, 2 ether, "e2e4");
        vm.warp(st().deadline);
        uint256 snap = vm.snapshotState();
        (bool ok,) = address(duel).call{gas: 30_000_000}(abi.encodeCall(SwarmDuel.advance, ()));
        assertTrue(ok);
        State memory want = st();
        uint256 asks = oracle.asks();
        for (uint256 limit = 300_000; limit < 9_000_000; limit += 150_000) {
            vm.revertToState(snap);
            (ok,) = address(duel).call{gas: limit}(abi.encodeCall(SwarmDuel.advance, ()));
            if (!ok) continue;
            assertEq(st().phase, want.phase, "same phase");
            assertEq(st().ply, want.ply, "same ply");
            assertEq(oracle.asks(), asks, "asked the same");
        }
        vm.revertToState(snap);
        duel.advance();
        oracle.fail(duel.askId(), SwarmCause.SPLIT);
        vm.roll(vm.getBlockNumber() + 2);
        snap = vm.snapshotState();
        duel.advance();
        uint256 board = st().board;
        for (uint256 limit = 300_000; limit < 9_000_000; limit += 150_000) {
            vm.revertToState(snap);
            (ok,) = address(duel).call{gas: limit}(abi.encodeCall(SwarmDuel.advance, ()));
            if (ok) assertEq(st().board, board, "the engine's move, not the pick");
        }
    }

    /// The same with an adapter that needs most of ASK_GAS to ask: a caller sending too little gas can't make the ask
    /// fail (the engine's move instead of the swarm's); the guard reverts the whole close instead.
    function test_gasNeverPicksTheAsksBranch() public {
        oracle.setHeavy(true);
        bidAs(alice, 2 ether, "e2e4");
        vm.warp(st().deadline);
        uint256 snap = vm.snapshotState();
        duel.advance{gas: 30_000_000}();
        assertEq(st().phase, 1, "with gas to spare it asks");
        uint256 reverted;
        for (uint256 limit = 300_000; limit < 6_000_000; limit += 100_000) {
            vm.revertToState(snap);
            (bool ok,) = address(duel).call{gas: limit}(abi.encodeCall(SwarmDuel.advance, ()));
            if (!ok) {
                reverted++;
                continue;
            }
            assertEq(st().phase, 1, "it asked: never the declined branch for want of gas");
        }
        assertGt(reverted, 0, "short of gas, the close reverts");
    }

    function test_gasFigures() public {
        vm.prank(alice);
        uint256 g0 = gasleft();
        duel.deposit(2 ether, u("e2e4"), address(0));
        emit log_named_uint("a game's first bid, with its buy", g0 - gasleft());
        vm.prank(bob);
        g0 = gasleft();
        duel.deposit(3 ether, u("d2d4"), address(0));
        emit log_named_uint("a new lead, the outbid bid's shares (no buy: same block)", g0 - gasleft());
        vm.warp(st().deadline);
        vm.roll(vm.getBlockNumber() + 1);
        g0 = gasleft();
        duel.advance();
        emit log_named_uint("close and ask (scripted adapter), with its buy", g0 - gasleft());
        bytes32 id = duel.askId();
        vm.prank(address(oracle));
        g0 = gasleft();
        duel.answered(id, u("e7e5"), 5);
        emit log_named_uint("answered (SwarmDuel's side of the callback)", g0 - gasleft());
        assertLt(g0 - gasleft(), 50_000, "within the callback chain's budget");
        g0 = gasleft();
        duel.advance();
        emit log_named_uint("playing a stored answer", g0 - gasleft());
        assertLt(g0 - gasleft(), 150_000);
    }
}
