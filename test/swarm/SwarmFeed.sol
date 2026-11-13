// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmModel} from "./SwarmModel.sol";
import {SwarmDuel} from "../../src/swarm/SwarmDuel.sol";
import {SwarmLedger} from "../../src/swarm/SwarmLedger.sol";
import {SwarmRules} from "../../src/swarm/SwarmRules.sol";

/// The reference model (SwarmModel, written from the spec) fed what a SwarmDuel did, from its events, and compared
/// with it: the invariant run's handler and the fork game share this one place. The feed replays the game's moves on
/// its own board (SwarmRules), so it knows which piece each humans' move moved and whether it took the queen.
abstract contract SwarmFeed is Test {
    SwarmModel public immutable model = new SwarmModel();
    SwarmRules.Game internal replay; // the feed's own copy of the board
    uint256 internal nextPiece; // the last humans' move: the piece it moved, whether it took a queen, whether it mated
    bool internal nextQueen;
    bool internal nextMate;

    /// Feeds the model `duel`'s events among `logs`, in order; every amount the contract reports must be the model's.
    function _feed(SwarmDuel duel, Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(duel)) _feedOne(duel.rules(), logs[i]);
        }
    }

    function _feedOne(SwarmRules rules, Vm.Log memory l) internal {
        bytes32 t = l.topics[0];
        if (t == keccak256("GameStarted(uint32,uint8,address)")) {
            (uint8 level,) = abi.decode(l.data, (uint8, address));
            _started(rules, uint32(uint256(l.topics[1])), level);
        } else if (t == keccak256("Moved(uint32,uint16,uint16,uint8)")) {
            (, uint16 move, uint8 by) = abi.decode(l.data, (uint16, uint16, uint8));
            if (by == 0) (nextPiece, nextQueen) = (_typeAt(replay.board, move >> 6), _typeAt(replay.board, move & 63) == 5);
            uint256[4] memory ring;
            (bool legal, SwarmRules.Outcome memory o) = rules.play(replay, ring, move);
            assertTrue(legal, "every played move is legal on the feed's board");
            if (by == 0) nextMate = o.result == 1;
            (replay.board, replay.white, replay.black, replay.quiet, replay.ply) =
                (o.board, o.white, o.black, o.quiet, replay.ply + 1);
        } else if (t == keccak256("Referrer(uint256,address)")) {
            model.referred(uint256(l.topics[1]), address(uint160(uint256(l.topics[2]))));
        } else if (t == keccak256("ReferralClaimed(address,uint256)")) {
            assertEq(abi.decode(l.data, (uint256)), model.referralClaimed(address(uint160(uint256(l.topics[1])))), "a referral claim is the model's");
        } else if (t == keccak256("Deposited(uint256,uint32,uint16,address,uint256,uint16,bool,uint256)")) {
            (uint16 ply, uint256 amount,, bool leads, uint256 n) = abi.decode(l.data, (uint16, uint256, uint16, bool, uint256));
            uint256 id = uint256(l.topics[1]);
            model.deposited(id, address(uint160(uint256(l.topics[3]))), amount, ply, leads);
            (,,,,, uint256 mn,,,,) = model.pos(id);
            assertEq(n, leads ? 0 : mn, "a deposit's shares are the model's");
        } else if (t == keccak256("Converted(uint256,uint256,uint256)")) {
            (, uint256 n) = abi.decode(l.data, (uint256, uint256));
            uint256 id = uint256(l.topics[1]);
            model.converted(id);
            (,,,,, uint256 mn,,,,) = model.pos(id);
            assertEq(n, mn, "an outbid bid's shares are the model's");
        } else if (t == keccak256("Settled(uint32,uint16,uint256,uint256,uint256,uint256)")) {
            (uint16 ply, uint256 id, uint256 paid, uint256 askPaid, uint256 prize) =
                abi.decode(l.data, (uint16, uint256, uint256, uint256, uint256));
            (,,,, uint256 amount,,,,,) = model.pos(id);
            assertEq(paid, model.pay(amount), "the winning payment is the model's");
            assertEq(prize, model.settled(id, ply, askPaid, nextPiece, nextQueen, nextMate), "the prize is the model's");
        } else if (t == keccak256("Bought(address,uint256,uint256,uint256)")) {
            (, uint256 spent, uint256 out, uint256 toVault) = abi.decode(l.data, (address, uint256, uint256, uint256));
            assertEq(toVault, model.bought(spent, out), "the vault's part is the model's");
        } else if (t == keccak256("GameOver(uint32,uint8,uint8,uint16,uint256,uint256)")) {
            (uint8 result,,, uint256 perMove, uint256 jackpot) =
                abi.decode(l.data, (uint8, uint8, uint16, uint256, uint256));
            assertEq(perMove, model.ended(result), "a human win's part is the model's");
            assertEq(jackpot, model.jackpot(), "the jackpot after the ending is the model's");
        } else if (t == keccak256("Claimed(uint256,address,uint256,uint256)")) {
            (uint256 a, uint256 b) = abi.decode(l.data, (uint256, uint256));
            (uint256 ma, uint256 mb) = model.claimed(uint256(l.topics[1]));
            assertEq(a, ma, "a claim's IMD is the model's");
            assertEq(b, mb, "a claim's $IMDUEL is the model's");
        }
    }

    /// A game started: the model's book and the feed's own board (also for a game that started before the feed ran).
    function _started(SwarmRules rules, uint32 g, uint8 level) internal {
        model.started(g, level);
        (uint256 board, uint32 white, uint32 black) = rules.start(level);
        replay = SwarmRules.Game(board, white, black, 0, 0, g, level);
    }

    function _typeAt(uint256 board, uint256 sq) internal pure returns (uint256) {
        return (board >> (sq * 4)) & 7;
    }

    /// `duel`'s money, books, positions and players' counts equal the model's, to the wei, and so do its IMD and
    /// $IMDUEL; `team` holds the team's 1% and nothing else.
    function _matchesModel(SwarmDuel duel, IERC20 imd, IERC20 imduel, address team, uint256 teamBefore) internal view {
        SwarmLedger.Money memory k;
        (k.pending, k.stakersWaiting, k.lastBuyBlock, k.escrow, k.refunds, k.dividends, k.prizes, k.referrals) = duel.money();
        assertEq(k.escrow, model.escrow(), "escrow");
        assertEq(k.pending, model.pending(), "the turn's dividends, paid at its close");
        assertEq(k.dividends, model.dividends(), "dividends");
        assertEq(k.refunds, model.refunds(), "refunds");
        assertEq(k.stakersWaiting, model.stakersWaiting(), "the stakers' waiting part");
        assertEq(k.prizes, model.prizes(), "prizes owed");
        assertEq(k.referrals, model.referrals(), "owed to referrers");
        assertEq(duel.jackpot(), model.jackpot(), "jackpot");
        assertEq(imd.balanceOf(address(duel)), model.held(), "IMD held");
        assertEq(imduel.balanceOf(address(duel)), model.heldDuel(), "$IMDUEL held: the jackpot and the prizes");
        assertEq(imd.balanceOf(team) - teamBefore, model.team(), "the team's 1%");
        assertEq(duel.waiting(), model.waiting(), "the waiting IMD");
        (,,, uint32 games,,,,,,,,,) = duel.game();
        for (uint256 g = games; g != 0; g--) {
            SwarmLedger.Book memory b = duel.book(g);
            (uint256 taken, uint256 shares, uint256 acc, uint256 perMove, uint256 moves, uint256 result, uint256 level) =
                model.books(g);
            assertEq(b.taken, taken, "IN");
            assertEq(b.shares, shares, "S");
            assertEq(b.acc, acc, "acc");
            assertEq(b.perMove, perMove, "perMove");
            assertEq(b.moves, moves, "moves");
            assertEq(b.result, result, "result");
            assertEq(b.level, level, "level");
        }
        for (uint256 id = duel.positionCount(); id != 0; id--) {
            (uint256 d, uint256 r, uint256 z, uint256 w) = duel.owed(id);
            (uint256 md, uint256 mr, uint256 mz, uint256 mw) = model.owed(id);
            assertEq(d, md, "a position's dividends");
            assertEq(r, mr, "a position's refund");
            assertEq(z, mz, "a position's prize");
            assertEq(w, mw, "a position's part of a human win");
        }
        for (uint256 i = model.ownerCount(); i != 0; i--) {
            address o = model.owners(i - 1);
            assertEq(duel.players(o), model.word(o), "a player's counts");
            assertEq(duel.referrals(o), model.referralOf(o), "what a referrer is owed");
        }
    }
}
