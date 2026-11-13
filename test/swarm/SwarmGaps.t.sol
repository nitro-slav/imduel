// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {wadLn} from "solmate/src/utils/SignedWadMath.sol";
import {SwarmDuel} from "../../src/swarm/SwarmDuel.sol";
import {ISwarmOracle} from "../../src/swarm/ISwarmOracle.sol";
import {IMainDuelBuyer, ISwarmVault} from "../../src/IMainDuelBuyer.sol";
import {SwarmBase} from "./SwarmBase.sol";

/// A vault that reads the duel's books inside its sync (what a view called from there would see).
contract SpyVault is ISwarmVault {
    address public immutable asset;
    SwarmDuel public duel;
    uint96 public seen;
    uint256 public syncs;

    constructor(address asset_) {
        asset = asset_;
    }

    function watch(SwarmDuel d) external {
        duel = d;
    }

    function sync() external {
        (, uint96 s,,,,,,) = duel.money();
        (seen, syncs) = (s, syncs + 1);
    }
}

/// Code review 3's gaps: each test kills a mutant the other suites let
/// through, or pins a path only the random walk reached.
contract SwarmGapsTest is SwarmBase {
    uint256 constant QUEENS = 120;
    uint256 constant GAMES = 132;
    uint256 constant WINS = 148;
    uint256 constant DRAWS = 160;
    uint256 constant MATES = 172;
    uint256 constant EVEN = 184;
    uint256 constant LAST = 192;

    // ---------------------------------------------------------------- M31: the vault is called last

    function test_theVaultSyncsAfterTheBuysBookkeeping() public {
        SpyVault spy = new SpyVault(address(imduel));
        SwarmDuel d =
            new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(spy), TEAM, address(this), 0);
        spy.watch(d);
        d.open(ISwarmOracle(address(0)));
        vm.startPrank(alice);
        imd.approve(address(d), type(uint256).max);
        d.deposit(100 ether, 0, address(0)); // 39 waiting, 3 the stakers'; a buy of 14
        vm.stopPrank();
        (, uint96 after_,,,,,,) = d.money();
        assertEq(spy.syncs(), 1);
        assertEq(after_, 3 ether - uint256(14 ether) * 3 ether / 39 ether);
        assertEq(spy.seen(), after_, "the books were final when the vault ran");
    }

    // ---------------------------------------------------------------- M29: the stakers' part is at most W

    /// IMD is a bridged token: should SwarmDuel's balance ever fall (a burn, a freeze), the stakers' part is still
    /// capped at the waiting IMD, so the vault never takes $IMDUEL owed as prizes or the jackpot's.
    function test_theStakersPartIsCappedAtTheWaitingIMD() public {
        buyer.set(14 ether, 2e18, true, false); // buys fail
        put(alice, 100 ether); // 39 waiting, 3 the stakers'
        deal(address(imd), address(duel), imd.balanceOf(address(duel)) - 37 ether); // 2 waiting
        assertLt(duel.waiting(), buckets().stakersWaiting);
        imduel.mint(address(duel), 10 ether); // a jackpot the vault must not reach
        buyer.set(14 ether, 2e18, false, false);
        vm.roll(vm.getBlockNumber() + 1);
        duel.buy(); // spends the 2, gets 4
        assertEq(imduel.balanceOf(address(vault)), 4 ether, "the stakers get what was bought, no more");
        assertEq(buckets().stakersWaiting, 0);
        assertEq(duel.jackpot(), 10 ether, "the jackpot untouched");
    }

    // ---------------------------------------------------------------- scenarios only the random walk reaches

    /// M06/M44 deterministically: a human win with odds (level 1) folds into `won`, never `evenWins`.
    function test_aWinWithOddsIsNoEvenWin() public {
        bytes32 slot = bytes32(uint256(5)); // stats: movesSinceWin in its low 32 bits
        vm.store(address(duel), slot, bytes32((uint256(vm.load(address(duel), slot)) & ~uint256(type(uint32).max)) | 28));
        foolBy(bob); // 30 moves since a win
        assertEq(st().level, 1);
        humans("e2e4");
        swarm("g7g5");
        humans("d1h5"); // no f7 pawn: mate
        assertEq(duel.book(2).result, 1);
        assertEq(duel.book(2).level, 1, "the book keeps its odds");
        humans("e2e4"); // game 3 folds game 2
        uint256 w = duel.players(alice);
        assertEq(field(w, WINS, 12), 1);
        assertEq(field(w, EVEN, 8), 0, "a win with odds is no even win");
    }

    /// M14 deterministically: `first` marks a move in game 1 only.
    function test_firstMarksOnlyGameOne() public {
        foolBy(bob);
        humans("e2e4"); // alice's first move, in game 2
        assertEq(field(duel.players(alice), 224, 1), 0, "not in game 1");
        assertEq(field(duel.players(bob), 224, 1), 1);
    }

    /// The engine mates the humans: the jackpot carries on, the markers are back, the next game is open.
    function test_theEnginesMateKeepsTheJackpot() public {
        buyer.set(0, 2e18, false, false);
        imduel.mint(address(duel), 100 ether);
        humans("f2f3");
        swarm("e7e5");
        humans("g2g4");
        oracle.fail(duel.askId(), 3); // SPLIT: the engine plays
        engine.set(1, u("d8h4"));
        uint256 j = duel.jackpot();
        engineMoves();
        assertEq(duel.book(1).result, 2, "the engine mated");
        assertEq(duel.book(1).perMove, 0);
        assertEq(duel.jackpot(), j, "nothing paid out");
        assertEq(st().gameNo, 2);
        (uint64 id,,, uint8 set) = duel.lead();
        assertEq(id, 0);
        assertEq(set, 1, "the lead's word kept");
        assertEq(duel.askId(), bytes32(uint256(1)), "no ask");
        (uint96 pending,,,,,,,) = duel.money();
        assertEq(pending, 0);
    }

    /// Two human wins in a row: game 2's 80% is of the jackpot net of game 1's unclaimed prizes and parts, and
    /// every prize and part of both games is paid exactly.
    function test_twoHumanWinsInARowPayEachGameItsOwn() public {
        buyer.set(0, 2e18, false, false);
        imduel.mint(address(duel), 1_000 ether);
        scholarsMate();
        uint256 j = duel.jackpot();
        for (uint256 i; i < 4; i++) j -= j * 100 / 10_000; // game 2's four winning moves
        scholarsMate();
        assertEq(duel.book(2).perMove, j * 80 / 100 / 4, "80% of what is left, net of game 1's parts");
        uint256[] memory ids = new uint256[](duel.positionCount());
        (uint256 dueImd, uint256 dueDuel) = (0, 0);
        for (uint256 i; i < ids.length; i++) {
            ids[i] = i + 1;
            (uint256 d, uint256 r, uint256 z, uint256 w) = duel.owed(i + 1);
            (dueImd, dueDuel) = (dueImd + d + r, dueDuel + z + w);
        }
        vm.prank(alice);
        (uint256 gotImd, uint256 gotDuel) = duel.claim(ids);
        assertEq(gotImd, dueImd, "one claim of many ids pays their sum (M54)");
        assertEq(gotDuel, dueDuel);
        (,,,,,, uint96 prizes,) = duel.money();
        assertEq(prizes, 0, "both games' prizes and parts paid");
        assertEq(imduel.balanceOf(address(duel)), duel.jackpot());
    }

    /// M39/M51: the markers are set at deploy (before `open`) and an answer puts the pending id back to NO_ASK.
    function test_theMarkersAtDeployAndAfterAnAnswer() public {
        SwarmDuel fresh =
            new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(vault), TEAM, address(this), 0);
        assertEq(fresh.askId(), bytes32(uint256(1)), "NO_ASK at deploy");
        (,,, uint8 set) = fresh.lead();
        assertEq(set, 1, "the lead's word at deploy");
        humans("e2e4");
        oracle.answer(duel.askId(), u("e7e5"));
        assertEq(duel.askId(), bytes32(uint256(1)), "an answer clears the pending id");
    }

    /// M07: a swarm win folds into neither `won` nor `drawn`.
    function test_aSwarmWinFoldsAsNothing() public {
        foolBy(bob);
        foolBy(bob); // game 2 folds game 1
        uint256 w = duel.players(bob);
        assertEq(field(w, GAMES, 16), 2);
        assertEq(field(w, WINS, 12) + field(w, DRAWS, 12), 0);
    }

    /// M24/M25/M49: the payment's rounding, the refunds bucket, and the curve past the first turn, to the wei.
    function test_theRoundingTheRefundsAndTheCurveToTheWei() public {
        buyer.set(0, 2e18, false, false);
        uint256 bid = 10 ether + 3; // 20% isn't whole
        uint256 id = bidAs(alice, bid, "e2e4");
        vm.warp(st().deadline);
        duel.advance();
        (, uint256 refund,,) = duel.owed(id);
        assertEq(refund, bid * 8_000 / 10_000, "the refund rounds down");
        (,,,, uint96 refunds,,,) = duel.money();
        assertEq(refunds, refund, "the bucket holds exactly the refund");
        swarm("e7e5"); // ply 2: one humans' move played
        uint256 taken = duel.book(1).taken;
        (,, uint80 n,,,,,,) = duel.positions(put(bob, 10 ether));
        uint256 base = 200 ether + 200 ether * 1 / 50 + taken;
        assertEq(n, 200 ether * uint256(wadLn(int256(1e18 + 10 ether * 1e18 / base))) / 1e18, "a = 1 + m/50, m = ply / 2");
    }

    /// $IMDUEL given just before the mating close: the mate's 1% takes it into account first, then the 80% (the
    /// mutation review's gap 4).
    function test_aDonationBeforeTheMatingClose() public {
        noBuys();
        toScholarsMate();
        uint256 mate = bidAs(alice, 2 ether, "h5f7");
        imduel.mint(address(duel), 300 ether);
        vm.warp(st().deadline);
        duel.advance();
        uint256 prize = 300 ether * 100 / 10_000;
        assertEq(duel.prizes(mate), prize);
        assertEq(duel.book(1).perMove, (300 ether - prize) * 80 / 100 / 4);
    }

    /// Claims at the edges (gap 5): the leading bid mid-turn, one id twice in a call, a human win with an empty
    /// jackpot, a winning move claimed games later.
    function test_claimsAtTheEdges() public {
        noBuys();
        uint256 lead = bidAs(bob, 5 ether, "e2e4");
        (uint256 a, uint256 b) = claimAs(bob, lead);
        assertEq(a + b, 0, "an escrowed bid has nothing to claim yet, and the claim doesn't revert");
        vm.warp(st().deadline);
        duel.advance();
        uint256[] memory twice = new uint256[](2);
        (twice[0], twice[1]) = (lead, lead);
        vm.prank(bob);
        (uint256 imdTwice,) = duel.claim(twice);
        (, uint256 refund,,) = duel.owed(lead);
        assertEq(refund, 0, "paid once");
        assertGe(imdTwice, 3 ether, "its refund (5 less the least payment, 2), once");
        assertLt(imdTwice, 6 ether, "not twice");
        swarm("e7e5");
        humans("f1c4");
        swarm("b8c6");
        humans("d1h5");
        swarm("g8f6");
        humans("h5f7"); // a human win with an empty jackpot
        assertEq(duel.book(1).perMove, 0);
        foolsMate();
        foolsMate(); // two games later
        (a, b) = claimAs(bob, lead);
        assertEq(b, 0, "no part of an empty jackpot");
        (uint256 d,,,) = duel.owed(lead);
        assertEq(d, 0, "everything it had is paid");
    }
}
