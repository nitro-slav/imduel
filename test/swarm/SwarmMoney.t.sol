// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {wadLn} from "solmate/src/utils/SignedWadMath.sol";
import {SwarmDuel} from "../../src/swarm/SwarmDuel.sol";
import {SwarmLedger} from "../../src/swarm/SwarmLedger.sol";
import {SwarmBase} from "./SwarmBase.sol";

/// Swarm Duel's money: the split with the jackpot's seed shares, the curve, the
/// turn's dividends paid at its close, buying $IMDUEL in capped steps (one a block, the caller owning the main-duel move,
/// the vault's part, nothing tried inside someone's own unlock), the winning bid and its 1% of the jackpot, bids that
/// don't lead or are outbid, no refunds for losing bids, a human win split over the played moves and nothing more on
/// any other ending, the waiting IMD carried across games, claims in two tokens, and the players' counts. Every step
/// checks that what is owed is held.
contract SwarmMoneyTest is SwarmBase {
    uint256 constant K = 200 ether;
    uint256 constant SEED = 10 ether;

    // ---------------------------------------------------------------- helpers

    /// What is owed is held: IMD for the escrow, dividends, refunds and the turn's dividends; $IMDUEL for the prizes.
    function held() internal view {
        SwarmLedger.Money memory k = buckets();
        assertGe(imd.balanceOf(address(duel)), uint256(k.escrow) + k.dividends + k.refunds + k.pending + k.referrals, "IMD owed is held");
        assertGe(imduel.balanceOf(address(duel)), k.prizes, "$IMDUEL owed is held");
        assertEq(duel.jackpot(), imduel.balanceOf(address(duel)) - k.prizes, "the jackpot is the rest");
        assertLe(k.stakersWaiting, duel.waiting(), "the stakers' part is waiting");
    }

    function sharesOf(uint256 id) internal view returns (uint256 n) {
        (,, n,,,,,,) = duel.positions(id);
    }

    /// The curve as the spec writes it: K * ln(1 + x / (a*K + IN)), a = 1 + m/50, K = 200 IMD.
    function curve(uint256 moves, uint256 taken, uint256 x) internal pure returns (uint256) {
        return K * uint256(wadLn(int256(1e18 + x * 1e18 / (K + K * moves / 50 + taken)))) / 1e18;
    }

    // ---------------------------------------------------------------- the split and the curve

    function test_aDepositsDividendsWaitForTheTurnsClose() public {
        noBuys();
        uint256 a = put(alice, 100 ether);
        SwarmLedger.Money memory k = buckets();
        assertEq(k.dividends, 0, "nothing paid before the close");
        assertEq(k.pending, 60 ether, "its 60% waits for the turn's close");
        assertEq(imd.balanceOf(TEAM), 1 ether, "1% sent to the team at once");
        assertEq(k.stakersWaiting, 3 ether, "3% waits for the vault");
        assertEq(duel.waiting(), 39 ether, "the jackpot's 36% and the stakers' 3% wait to be bought");
        assertEq(sharesOf(a), curve(0, 0, 100 ether), "the curve, K = 200");
        assertEq(duel.book(1).shares, SEED + sharesOf(a));
        held();
    }

    function test_theTurnsDividendsArePaidAtItsCloseToEveryoneHoldingThen() public {
        noBuys();
        uint256 a = put(alice, 100 ether);
        uint256 b = put(bob, 50 ether);
        (uint256 da,,,) = duel.owed(a);
        assertEq(da, 0, "nothing before the close");
        uint256 w = bidAs(alice, 2 ether, "e2e4");
        vm.warp(st().deadline);
        duel.advance(); // the close: the winner pays 2, the ask takes 0.5
        uint256 pot = 60 ether + 30 ether + 1.5 ether * 60 / 100;
        uint256 all = duel.book(1).shares;
        (da,,,) = duel.owed(a);
        (uint256 db,,,) = duel.owed(b);
        (uint256 dw,,,) = duel.owed(w);
        assertApproxEqAbs(da, pot * sharesOf(a) / all, 2, "alice: her shares' part of the whole turn, her own deposit's included");
        assertApproxEqAbs(db, pot * sharesOf(b) / all, 2, "bob the same, though he came later in the turn");
        assertApproxEqAbs(dw, pot * sharesOf(w) / all, 2, "the winner too");
        assertEq(buckets().pending, 0);
        assertApproxEqAbs(buckets().dividends, da + db + dw, 3, "the holders' part kept, the seed's left waiting");
        (uint256 imdOut,) = claimAs(alice, a);
        assertEq(imdOut, da);
        held();
    }

    /// The economy review's opening front-run, closed: a bot just ahead of a big opening deposit takes only its shares'
    /// part of the turn, and the big depositor gets most of its own 60% back; splitting changes nothing.
    function test_frontRunningOrSplittingAnOpeningDepositGainsNothing() public {
        noBuys();
        imd.mint(alice, 1_000 ether);
        uint256 snap = vm.snapshotState();
        uint256 whale = put(alice, 300 ether);
        humans("e2e4");
        (uint256 whole,,,) = duel.owed(whale);
        vm.revertToState(snap);
        uint256 first = put(alice, 30 ether);
        for (uint256 i; i < 9; i++) put(alice, 30 ether);
        humans("e2e4");
        uint256 split;
        for (uint256 id = first; id < first + 10; id++) {
            (uint256 d,,,) = duel.owed(id);
            split += d;
        }
        assertApproxEqAbs(split, whole, 1e6, "ten pieces earn what one deposit earns");
        vm.revertToState(snap);
        uint256 bot = put(bob, 19.5 ether);
        whale = put(alice, 300 ether);
        humans("e2e4");
        (uint256 botGot,,,) = duel.owed(bot);
        (uint256 whaleGot,,,) = duel.owed(whale);
        assertLt(botGot, 20 ether, "the bot: its shares' part");
        assertGt(whaleGot, 180 ether * 75 / 100, "the whale gets most of its own 60% back");
        held();
    }

    function testFuzz_splittingADepositBuysNoMore(uint96 x, uint96 y) public {
        x = uint96(bound(x, 1 ether, 100_000 ether));
        y = uint96(bound(y, 1 ether, 100_000 ether));
        noBuys();
        uint256 snap = vm.snapshotState();
        imd.mint(alice, uint256(x) + y);
        uint256 whole = sharesOf(put(alice, uint256(x) + y));
        vm.revertToState(snap);
        imd.mint(alice, uint256(x) + y);
        uint256 first = sharesOf(put(alice, x));
        uint256 second = sharesOf(put(alice, y));
        assertLe(first + second, whole + 400, "no more than once, but wadLn's rounding");
    }

    function test_aPlainDepositHasNoMinimumButMustBuyAShare() public {
        vm.prank(alice);
        vm.expectRevert(SwarmDuel.TooSmall.selector);
        duel.deposit(1, 0, address(0)); // a wei buys no unit of shares
        assertGt(sharesOf(put(alice, 0.001 ether)), 0);
        held();
    }

    // ---------------------------------------------------------------- buying $IMDUEL

    function test_eachBuyIsCappedOneABlockAndTheCallerOwnsItsMove() public {
        put(alice, 100 ether); // 39 waiting (60 for the close); the deposit's own buy takes 14 (the mock's price limit)
        assertEq(buyer.buys(), 1);
        assertEq(buyer.lastOwner(), alice, "the depositor owns that main-duel move");
        assertEq(duel.waiting(), 25 ether);
        put(bob, 10 ether); // same block: no second buy
        assertEq(buyer.buys(), 1, "one buy a block");
        nextBlock();
        vm.prank(bob);
        duel.buy();
        assertEq(buyer.buys(), 2);
        assertEq(buyer.lastOwner(), bob);
        held();
    }

    /// A due turn closes on a claim (user, 2026-11-13): the winning bid's own claim plays its move and pays its refund
    /// and prize in one call; before the deadline a claim leaves the turn as it is.
    function test_aWinnersClaimPlaysItsMoveAndPaysIt() public {
        imduel.mint(address(duel), 100 ether); // a jackpot, so the turn has a prize: 1% of it
        uint256 id = bidAs(alice, 10 ether, "e2e4");
        uint256 sid = put(bob, 10 ether);
        claimAs(bob, sid); // before the deadline
        assertEq(st().phase, 0, "still open");
        vm.warp(st().deadline);
        (uint256 got, uint256 prize) = claimAs(alice, id);
        assertEq(st().phase, 1, "the move played and the swarm asked, in the claim");
        assertEq(prize, duel.prizes(id), "the turn prize, paid in the same call");
        assertGt(prize, 1 ether, "1% of the jackpot: the 100 put in and what the deposits' buys added");
        assertGe(got, 8 ether, "the refund (10 less the 2 paid), and this close's dividends on its shares");
        held();
    }

    /// Any claim moves a due turn on: a holder collecting dividends closes it, and collects this close's too.
    function test_anyClaimClosesADueTurn() public {
        uint256 sid = put(bob, 10 ether);
        bidAs(alice, 10 ether, "e2e4");
        vm.warp(st().deadline);
        uint256 before = imd.balanceOf(bob);
        claimAs(bob, sid);
        assertEq(st().phase, 1, "closed by the claim");
        assertGt(imd.balanceOf(bob) - before, 0, "dividends, this close's included");
        uint256[] memory none = new uint256[](0);
        vm.expectRevert(SwarmDuel.NothingDue.selector);
        duel.advance(); // the swarm is thinking: nothing more is due
        duel.claim(none); // and an empty claim with nothing due is no revert
        held();
    }

    /// A buy offers at most 20 IMD of what waits (user, 2026-11-13: a sandwich gains with the amount bought), the stakers'
    /// part in proportion; the rest waits for later buys.
    function test_aBuyOffersAtMostTwentyIMD() public {
        buyer.set(1_000 ether, 2e18, false, false); // a pool deep enough to take whatever it is offered
        put(alice, 200 ether); // 78 waiting (36% for the jackpot, the stakers' 3%: 6)
        assertEq(buyer.buys(), 1);
        assertEq(imd.balanceOf(address(buyer)), 20 ether, "20 IMD bought, not all 78");
        assertEq(duel.waiting(), 58 ether, "the rest waits");
        assertEq(imduel.balanceOf(address(vault)), uint256(40 ether) * 6 ether / 78 ether, "the vault: its share (6 of 78) of the 40 $IMDUEL");
        assertEq(uint256(buckets().stakersWaiting), 6 ether - uint256(20 ether) * 6 ether / 78 ether, "and that share stops waiting");
        nextBlock();
        duel.buy();
        assertEq(imd.balanceOf(address(buyer)), 40 ether, "the next buy, 20 more");
        held();
    }

    function test_theVaultGetsTheStakersPartAndTheJackpotTheRest() public {
        put(alice, 100 ether); // waiting 39, the stakers' 3 of it; a buy of 14 at 2 $IMDUEL each
        uint256 out = 28 ether;
        uint256 toVault = out * 3 ether / 39 ether;
        assertEq(imduel.balanceOf(address(vault)), toVault, "the stakers' share of what was bought");
        assertEq(vault.syncs(), 1, "the vault synced");
        assertEq(duel.jackpot(), out - toVault, "the rest is the jackpot's, held");
        assertEq(uint256(buckets().stakersWaiting), 3 ether - uint256(14 ether) * 3 ether / 39 ether);
        vault.setRefuse(true);
        nextBlock();
        duel.buy(); // a vault that reverts its sync doesn't stop a buy
        assertEq(buyer.buys(), 2);
        held();
    }

    function test_aFailingBuyNeverBlocksADepositOrAClose() public {
        buyer.set(14 ether, 2e18, true, false); // the main duel reverts
        put(alice, 100 ether);
        humans("e2e4");
        assertEq(st().ply, 1, "the close went through");
        assertGt(duel.waiting(), 39 ether, "the IMD waits for a later buy");
        held();
    }

    /// The reviews' nested-unlock attack, closed: inside someone's own pool-manager unlock the buyer can't run, so a
    /// buy isn't tried at all: `buy()` reverts, a deposit or a step skips it, nothing is recorded, and an honest buy in
    /// the same block still runs (on the live pool: MainDuelBuyerFork).
    function test_aBusyPoolManagerSkipsTheBuyAndRecordsNothing() public {
        noBuys();
        put(alice, 100 ether); // a failed buy at the deposit: waiting stays
        buyer.set(14 ether, 2e18, false, false);
        buyer.setBusy(true);
        nextBlock();
        vm.expectRevert(SwarmLedger.Busy.selector);
        duel.buy();
        uint256 buys = buyer.buys();
        put(bob, 10 ether); // its buy skipped: not tried, the block not taken
        assertEq(buyer.buys(), buys);
        assertTrue(buckets().lastBuyBlock != vm.getBlockNumber(), "the block's buy is still free");
        buyer.setBusy(false);
        duel.buy();
        assertEq(buyer.buys(), buys + 1, "an honest buy in the same block runs");
        held();
    }

    /// A buy with nothing waiting isn't tried: the buyer isn't called and the block stays free.
    function test_nothingWaitingIsNotABuy() public {
        bidAs(alice, 2 ether, "e2e4"); // a lead: escrowed, nothing waits
        assertEq(duel.waiting(), 0);
        nextBlock();
        uint256 buys = buyer.buys();
        duel.buy();
        assertEq(buyer.buys(), buys, "the buyer is never called with nothing");
        assertTrue(buckets().lastBuyBlock != vm.getBlockNumber());
        put(bob, 10 ether);
        assertEq(buyer.buys(), buys + 1, "a deposit later in the block still buys");
    }

    /// The waiting IMD is the jackpot's and the stakers', whatever game it came in: an ending leaves it waiting, and a
    /// later buy puts it in the jackpot (nothing is paid out of it at an ending).
    function test_theWaitingIMDCarriesAcrossGamesIntoTheJackpot() public {
        buyer.set(14 ether, 2e18, true, false); // nothing bought during game 1
        put(alice, 300 ether);
        uint256 before = duel.waiting();
        foolsMate();
        assertEq(st().gameNo, 2);
        assertGt(duel.waiting(), before, "the moves' payments added to it; the ending took none");
        uint256 w = duel.waiting();
        uint256 stakers = buckets().stakersWaiting;
        buyer.set(1_000 ether, 2e18, false, false);
        uint256 vaultBefore = imduel.balanceOf(address(vault));
        uint256 buys;
        while (duel.waiting() != 0) {
            nextBlock();
            duel.buy();
            buys++;
        }
        assertEq(buys, (w + 20 ether - 1) / 20 ether, "20 IMD a buy until none waits");
        uint256 toVault = imduel.balanceOf(address(vault)) - vaultBefore;
        assertEq(duel.jackpot() + toVault, w * 2, "all of it bought: the jackpot's and the vault's");
        assertApproxEqAbs(toVault, w * 2 * stakers / w, buys, "the vault's share, a wei of rounding a buy at most");
        held();
    }

    function test_IMDSentBackInsideABuyOrAnAskStopsNothing() public {
        buyer.setTip(20 ether); // more than the buy takes: the balance rises
        put(alice, 100 ether);
        assertEq(duel.waiting(), 39 ether + 20 ether - 14 ether, "no IMD spent: a failed buy, not a revert; the IMD waits");
        assertEq(uint256(buckets().stakersWaiting), 3 ether, "nothing counted as bought");
        assertEq(duel.jackpot(), 28 ether, "the $IMDUEL that came anyway is held, so it joins the jackpot");
        buyer.setTip(0);
        imd.mint(address(oracle), 5 ether);
        oracle.setTip(1 ether); // the adapter pays itself 0.5 and sends 1 back
        vm.recordLogs();
        humans("e2e4");
        assertEq(st().phase, 1, "the close went through and the swarm is thinking");
        bytes32 settled = keccak256("Settled(uint32,uint16,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 askPaid = 1;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == settled) {
                (,,, askPaid,) = abi.decode(logs[i].data, (uint16, uint256, uint256, uint256, uint256));
            }
        }
        assertEq(askPaid, 0, "the ask cost nothing: the IMD it sent back waits to be bought");
        held();
    }

    /// Section 2: a refund is never negative (the least payment is above the most an ask may cost).
    function test_theConstantsKeepTheWinnersPaymentAboveAnAsk() public view {
        assertGe(duel.MIN_BID(), SwarmLedger.MIN_PAYMENT, "a move pays at least the least payment");
        assertGt(SwarmLedger.MIN_PAYMENT, duel.PRICE_CAP(), "which is above the dearest ask");
    }

    function test_aBuyNeedsItsGasButADepositSkipsIt() public {
        put(alice, 100 ether);
        nextBlock();
        vm.expectRevert(SwarmLedger.NotEnoughGas.selector);
        duel.buy{gas: 3_000_000}();
        vm.prank(bob);
        duel.deposit{gas: 3_000_000}(10 ether, 0, address(0)); // too little gas for a buy: the deposit goes through without one
        assertEq(buyer.buys(), 1, "only the first deposit's buy");
    }

    function test_aBuyThatBurnsItsGasIsAFailureNotAStall() public {
        buyer.set(14 ether, 2e18, false, true);
        put(alice, 100 ether);
        assertEq(duel.jackpot(), 0, "nothing bought");
        assertGt(duel.waiting(), 0);
        held();
    }

    /// The vault is called last and capped: one that burns its gas can't starve the buy's bookkeeping (round 3's
    /// security review).
    function test_aVaultBurningItsGasDoesntStopABuy() public {
        vault.setGasHungry(true);
        put(alice, 100 ether);
        assertEq(buyer.buys(), 1, "the buy ran");
        uint256 out = 28 ether;
        assertEq(duel.jackpot(), out - out * 3 ether / 39 ether, "the stakers' part sent, the rest kept");
        assertEq(vault.syncs(), 0, "its sync ran out of its own gas");
        held();
    }

    /// A deposit of 2^96 wei or more reverts: a position's amount is 96 bits, checked (section 1), a leading bid too
    /// (the ledger's own casts don't see it; mutation review).
    function test_aDepositPastNinetySixBitsReverts() public {
        imd.mint(alice, uint256(1) << 97);
        vm.prank(alice);
        vm.expectRevert();
        duel.deposit(uint256(1) << 96, 0, address(0));
        vm.prank(alice);
        vm.expectRevert();
        duel.deposit(uint256(1) << 96, u("e2e4"), address(0));
    }

    /// A buy skipped for too little gas leaves the block's one buy free (mutation review).
    function test_aBuySkippedForGasLeavesTheBlocksBuyFree() public {
        put(alice, 100 ether);
        nextBlock();
        vm.prank(bob);
        duel.deposit{gas: 3_000_000}(10 ether, 0, address(0)); // its buy skipped for gas
        assertEq(buyer.buys(), 1);
        duel.buy();
        assertEq(buyer.buys(), 2, "the skip didn't take the block");
    }

    /// $IMDUEL sent to the contract joins the jackpot at once (it is the $IMDUEL held less the prizes owed).
    function test_IMDUELSentHereJoinsTheJackpot() public {
        noBuys();
        imduel.mint(address(duel), 50 ether);
        assertEq(duel.jackpot(), 50 ether);
        uint256 id = bidAs(alice, 2 ether, "e2e4");
        vm.warp(st().deadline);
        duel.advance();
        assertEq(duel.prizes(id), 0.5 ether, "the next winning move takes 1% of it");
        held();
    }

    // ---------------------------------------------------------------- the winning bid

    function test_theWinningBidPaysTwentyPercentAndGetsTheRestBack() public {
        noBuys();
        uint256 id = bidAs(alice, 10 ether, "e2e4");
        vm.warp(st().deadline);
        duel.advance();
        assertEq(duel.book(1).taken, 2 ether, "20% paid (an 80% discount); IN counts what was paid");
        assertEq(imd.balanceOf(address(oracle)), PRICE, "the swarm's 0.5 came out of the payment");
        assertEq(sharesOf(id), curve(0, 0, 2 ether), "dividend shares for what it paid");
        (uint256 d, uint256 refund, uint256 prize,) = duel.owed(id);
        assertEq(refund, 8 ether);
        assertEq(prize, 0, "an empty jackpot: no prize");
        assertGt(d, 0, "a holder at its own close: its share of the turn's dividends");
        (uint256 back,) = claimAs(alice, id);
        assertEq(back, 8 ether + d);
        held();
    }

    /// Each turn's winning move takes 1% of the jackpot at its close, in $IMDUEL, with its refund; once.
    function test_theWinningMoveTakesOnePercentOfTheJackpot() public {
        put(bob, 100 ether); // a buy: 28 $IMDUEL, the vault's part sent
        nextBlock();
        uint256 id = bidAs(alice, 10 ether, "e2e4"); // its buy adds to the jackpot
        vm.warp(st().deadline);
        uint256 j = duel.jackpot();
        assertGt(j, 0);
        duel.advance(); // same block: the step's buy is skipped
        uint256 prize = j * 100 / 10_000;
        assertEq(duel.prizes(id), prize, "1% of the jackpot as it stood");
        assertEq(buckets().prizes, prize, "owed");
        assertEq(duel.jackpot(), j - prize, "out of the jackpot");
        (, uint256 refund, uint256 owedPrize, uint256 part) = duel.owed(id);
        assertEq(owedPrize, prize);
        assertEq(part, 0, "nothing more while the game runs");
        (uint256 imdBack, uint256 duelBack) = claimAs(alice, id);
        assertGe(imdBack, refund, "the refund and its dividends in IMD");
        assertEq(duelBack, prize, "the prize in $IMDUEL");
        (imdBack, duelBack) = claimAs(alice, id);
        assertEq(duelBack, 0, "once");
        assertEq(buckets().prizes, 0);
        held();
    }

    /// The winning move pays the larger of 2 IMD and 20%: the full discount from 10 IMD.
    function test_theWinningMovePaysAtLeastTwo() public {
        noBuys();
        uint256[3] memory bids = [uint256(2 ether), 5 ether, 15 ether];
        uint256[3] memory paid = [uint256(2 ether), 2 ether, 3 ether];
        string[3] memory moves = ["e2e4", "g1f3", "f1c4"];
        string[3] memory replies = ["e7e5", "b8c6", "g8f6"];
        for (uint256 i; i < 3; i++) {
            uint256 id = bidAs(alice, bids[i], moves[i]);
            vm.warp(st().deadline);
            uint256 taken = duel.book(1).taken;
            duel.advance();
            assertEq(duel.book(1).taken - taken, paid[i]);
            (, uint256 refund,,) = duel.owed(id);
            assertEq(refund, bids[i] - paid[i]);
            swarm(replies[i]);
        }
        assertEq(duel.book(1).moves, 3, "the game counts its played moves");
        held();
    }

    /// The winning payment's bounds for every bid: at least 2 IMD, at most the bid, 20% or the minimum.
    function testFuzz_theWinningPaymentKeepsItsBounds(uint256 bid) public pure {
        bid = bound(bid, 2 ether, 2 ** 96 - 1);
        uint256 p = SwarmLedger.pay(bid);
        assertGe(p, SwarmLedger.MIN_PAYMENT);
        assertLe(p, bid, "the refund is never negative");
        assertGe(p * 5, bid, "at least 20%");
        if (p != SwarmLedger.MIN_PAYMENT) assertEq(bid - p, bid * 8_000 / 10_000, "else the 80% discount");
    }

    // ---------------------------------------------------------------- bids that don't lead

    function test_aMoveThatDoesntLeadBuysSharesAtOnce() public {
        noBuys();
        bidAs(alice, 10 ether, "e2e4");
        uint256 b = bidAs(bob, 5 ether, "d2d4");
        assertEq(sharesOf(b), curve(0, 0, 5 ether), "at this moment's price");
        assertEq(buckets().escrow, 10 ether, "only the leading bid waits");
        assertEq(duel.book(1).taken, 5 ether);
        held();
    }

    function test_anOutbidBidBuysSharesAtOnceAndIsNeverRefunded() public {
        noBuys();
        uint256 a = bidAs(alice, 10 ether, "e2e4");
        uint256 w = bidAs(bob, 12 ether, "d2d4");
        uint256 n = sharesOf(a);
        assertEq(n, curve(0, 0, 10 ether), "at the price when it was outbid");
        assertEq(buckets().escrow, 12 ether);
        vm.warp(st().deadline);
        duel.advance(); // bob pays 2.4; the turn's dividends (alice's converted 10 and bob's payment) paid at the close
        (uint256 d, uint256 refund, uint256 prize,) = duel.owed(a);
        uint256 pot = (10 ether + 2.4 ether - PRICE) * 60 / 100;
        assertApproxEqAbs(d, pot * n / duel.book(1).shares, 2, "her shares' part of the turn's dividends");
        assertEq(refund + prize, 0, "never refunded, no prize");
        (, uint256 back,,) = duel.owed(w);
        assertEq(back, 9.6 ether, "the winner's 80%");
        held();
    }

    function test_noRefundsOnTheMatingTurn() public {
        toScholarsMate();
        bidAs(alice, 2 ether, "h5f7"); // mate
        uint256 b = bidAs(bob, 2 ether, "a2a3"); // doesn't lead: shares
        vm.warp(st().deadline);
        duel.advance();
        assertEq(st().gameNo, 2, "White mated");
        (uint256 d, uint256 refund, uint256 prize, uint256 part) = duel.owed(b);
        assertEq(refund + prize + part, 0, "no refund, prize or part for a share: only the played moves share a win");
        assertGt(d, 0, "its shares took the turn's dividends");
        held();
    }

    // ---------------------------------------------------------------- the endings

    /// A human win splits 80% of the jackpot (after the mating move's 1%) equally over the game's played White moves.
    function test_aHumanWinSplitsEightyPercentOverThePlayedMoves() public {
        put(bob, 100 ether);
        toScholarsMate();
        uint256 mating = bidAs(alice, 2 ether, "h5f7");
        vm.warp(st().deadline);
        uint256 j = duel.jackpot();
        duel.advance();
        SwarmLedger.Book memory b = duel.book(1);
        assertEq(b.result, 1, "White won");
        assertEq(b.moves, 4, "e2e4, f1c4, d1h5 and the mate");
        uint256 left = j - j * 100 / 10_000; // after the mating move's prize
        uint256 perMove = left * 80 / 100 / 4;
        assertEq(b.perMove, perMove);
        assertEq(duel.jackpot(), left - perMove * 4, "about 20% starts the next game's jackpot");
        uint256 parts;
        for (uint256 id = 1; id <= duel.positionCount(); id++) {
            (,,, uint256 part) = duel.owed(id);
            (,,,,,, uint8 kind,,) = duel.positions(id);
            assertEq(part, kind == SwarmLedger.WON ? perMove : 0, "every played move, and only those");
            parts += part;
        }
        assertEq(parts, perMove * 4);
        (,, uint256 matePrize, uint256 matePart) = duel.owed(mating);
        assertEq(matePrize + matePart, j * 100 / 10_000 + perMove, "the mate: its 1% and its part");
        held();
    }

    /// A swarm win or a draw pays nothing out of the jackpot: only the winning moves' 1% leaves it.
    function test_aSwarmWinOrADrawPaysNothingMore() public {
        put(bob, 100 ether);
        humans("f2f3");
        swarm("e7e5");
        humans("g2g4");
        uint256 j = duel.jackpot();
        swarm("d8h4"); // the swarm mates
        SwarmLedger.Book memory b = duel.book(1);
        assertEq(b.result, 2);
        assertEq(b.perMove, 0);
        assertEq(duel.jackpot(), j, "the ending took nothing");
        string[8] memory line = ["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"];
        for (uint256 i; i < 8; i += 2) {
            humans(line[i]);
            j = duel.jackpot();
            swarm(line[i + 1]);
        }
        b = duel.book(2);
        assertEq(b.result, 3, "drawn by the third repetition");
        assertEq(b.perMove, 0);
        assertEq(duel.jackpot(), j, "the ending took nothing");
        held();
    }

    // ---------------------------------------------------------------- claims

    function test_claimsInAnyOrderOnceAndOnlyTheOwner() public {
        put(bob, 50 ether);
        toScholarsMate();
        uint256 mate = bidAs(alice, 2 ether, "h5f7");
        uint256 b = bidAs(bob, 2 ether, "a2a3");
        vm.warp(st().deadline);
        duel.advance();
        uint256 snap = vm.snapshotState();
        (uint256 a1, uint256 a2) = claimAs(alice, mate);
        (uint256 b1, uint256 b2) = claimAs(bob, b);
        vm.revertToState(snap);
        (uint256 c1, uint256 c2) = claimAs(bob, b);
        (uint256 d1, uint256 d2) = claimAs(alice, mate);
        assertEq(a1 + b1, c1 + d1, "IMD: the order changes nothing");
        assertEq(a2 + b2, c2 + d2, "$IMDUEL: the order changes nothing");
        assertGt(d2, 0, "the mate's prize and part");
        (a1, a2) = claimAs(alice, mate);
        assertEq(a1 + a2, 0, "once");
        uint256[] memory ids = new uint256[](1);
        ids[0] = mate;
        vm.prank(bob);
        vm.expectRevert(SwarmLedger.NotYours.selector);
        duel.claim(ids);
        held();
    }

    /// A refund and a prize claimed while the game runs; its part of the human win claimed after the end.
    function test_aWinningMoveClaimsBeforeAndAfterTheWin() public {
        put(bob, 100 ether);
        humans("e2e4");
        (uint256 a1, uint256 a2) = claimAs(alice, 2); // the first winning move, mid-game
        assertGt(a2, 0, "its prize now");
        swarm("e7e5");
        humans("f1c4");
        swarm("b8c6");
        humans("d1h5");
        swarm("g8f6");
        humans("h5f7");
        (,,, uint256 part) = duel.owed(2);
        assertEq(part, duel.book(1).perMove, "its part of the win, after it");
        (a1, a2) = claimAs(alice, 2);
        assertEq(a2, part, "only the part: the prize was paid");
        (a1, a2) = claimAs(alice, 2);
        assertEq(a2, 0, "once");
        held();
    }

    /// A whole game drained: every position claims; what stays is the jackpot, the waiting IMD and rounding dust.
    function test_everyoneClaimsEverything() public {
        put(alice, 40 ether);
        put(bob, 20 ether);
        toScholarsMate();
        put(bob, 10 ether);
        humans("h5f7");
        uint256 n = duel.positionCount();
        for (uint256 id = 1; id <= n; id++) {
            (address owner,,,,,,,,) = duel.positions(id);
            claimAs(owner, id);
        }
        SwarmLedger.Money memory k = buckets();
        assertLt(uint256(k.dividends) + k.refunds, 1e6, "only dust owed in IMD");
        assertEq(k.pending, 0, "no turn's dividends left unpaid");
        assertEq(k.prizes, 0, "every prize and part paid exactly");
        assertEq(k.escrow, 0);
        held();
    }

    // ---------------------------------------------------------------- the players' counts

    /// Section 9: a word per owner, counted at each close: moves, the piece, the queen taken, the mate, games, and the
    /// last game folded when the owner's next game starts (a reader folds the last itself).
    function test_thePlayersCountsFollowTheirMoves() public {
        humans("e2e4"); // pawn
        swarm("e7e5");
        humans("d1h5"); // queen
        swarm("d8h4");
        humans("h5h4"); // the queen takes the swarm's queen
        swarm("b8c6");
        humans("f1c4"); // bishop
        swarm("g8f6");
        humans("h4f6"); // queen takes the knight
        swarm("g7f6");
        uint256 w = duel.players(alice);
        assertEq(field(w, 0, 24), 5, "moves");
        assertEq(field(w, 24, 16), 1, "pawn moves");
        assertEq(field(w, 40, 16), 1, "bishop moves");
        assertEq(field(w, 88, 16), 3, "queen moves");
        assertEq(field(w, 120, 12), 1, "the swarm's queen taken once");
        assertEq(field(w, 132, 16), 1, "one game");
        assertEq(field(w, 192, 32), 1, "the last game: 1");
        assertEq(field(w, 224, 1), 1, "a move in game 1");
        assertEq(duel.players(bob), 0, "bob played no move");
    }

    function test_aWinIsFoldedWhenTheOwnersNextGameStarts() public {
        toScholarsMate();
        humans("h5f7");
        uint256 w = duel.players(alice);
        assertEq(field(w, 172, 12), 1, "the mate");
        assertEq(field(w, 148, 12), 0, "the win not folded yet: a reader adds book(lastGame)");
        assertEq(duel.book(field(w, 192, 32)).result, 1, "which the reader can see");
        humans("e2e4"); // game 2
        w = duel.players(alice);
        assertEq(field(w, 132, 16), 2, "two games");
        assertEq(field(w, 148, 12), 1, "game 1 won, folded");
        assertEq(field(w, 184, 8), 1, "with no odds");
        assertEq(field(w, 192, 32), 2);
        assertEq(field(w, 0, 24), 5);
    }

    function test_aDrawIsFoldedToo() public {
        string[8] memory line = ["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"];
        for (uint256 i; i < 8; i += 2) {
            humans(line[i]);
            swarm(line[i + 1]);
        }
        assertEq(duel.book(1).result, 3);
        humans("e2e4");
        uint256 w = duel.players(alice);
        assertEq(field(w, 160, 12), 1, "one draw");
        assertEq(field(w, 148, 12), 0, "no win");
        assertEq(field(w, 56, 16), 4, "four knight moves");
    }

    /// A winning move's claim marks it paid even when its refund and prize are both zero (mutation review).
    function test_aWinningMovesClaimIsMarkedEvenWhenItPaysNothing() public {
        noBuys();
        uint256 id = bidAs(alice, 2 ether, "e2e4"); // pays 2: no refund; an empty jackpot: no prize
        vm.warp(st().deadline);
        duel.advance();
        claimAs(alice, id);
        (,,,,,,, uint8 flags,) = duel.positions(id);
        assertEq(flags & SwarmLedger.PAID, SwarmLedger.PAID);
    }

    /// A draw made by the humans' own move is no mate (mutation review): White stalemates the swarm.
    function test_aDrawByTheHumansMoveIsNoMate() public {
        vm.store(address(duel), bytes32(0), bytes32(put(put(put(0, "f7", 6), "g5", 5), "h8", 14)));
        uint256 w1 = uint256(vm.load(address(duel), bytes32(uint256(1))));
        w1 = (w1 & ~uint256(type(uint64).max)) | uint256(side("f7")) | (uint256(side("h8")) << 32);
        vm.store(address(duel), bytes32(uint256(1)), bytes32(w1));
        humans("g5g6");
        assertEq(duel.book(1).result, 3, "stalemate");
        uint256 w = duel.players(alice);
        assertEq(field(w, 172, 12), 0, "no mate");
        assertEq(field(w, 0, 24), 1, "one move");
    }

    /// Every counter stops at its own width: a wider one would spill into the next field (mutation review).
    function test_everyCounterStopsAtItsOwnWidth() public {
        uint256 snap = vm.snapshotState();
        setWord(alice, uint256(4095) << 120 | uint256(1) << 192); // queens at their most, game 1 already counted
        humans("e2e4");
        swarm("e7e5");
        humans("d1h5");
        swarm("d8h4");
        humans("h5h4"); // takes the queen
        uint256 w = duel.players(alice);
        assertEq(field(w, 120, 12), 4095, "queens");
        assertEq(field(w, 132, 16), 0, "games untouched");
        vm.revertToState(snap);
        setWord(alice, uint256(4095) << 172 | uint256(1) << 192); // mates at their most
        toScholarsMate();
        humans("h5f7");
        w = duel.players(alice);
        assertEq(field(w, 172, 12), 4095, "mates");
        assertEq(field(w, 184, 8), 0, "even wins untouched");
        setWord(alice, uint256(4095) << 148 | uint256(1) << 192); // won at its most
        humans("e2e4"); // game 2 folds game 1, won at no odds
        w = duel.players(alice);
        assertEq(field(w, 148, 12), 4095, "won");
        assertEq(field(w, 160, 12), 0, "drawn untouched");
        assertEq(field(w, 184, 8), 1, "an even win");
        assertEq(field(w, 192, 32), 2, "the last game");
        // each next field's lowest bit is clear, or a full neighbour would hide a wider counter (the mutation review)
        vm.revertToState(snap);
        foolsMate(); // game 1, a swarm win: the fold adds no win before the games counter
        setWord(alice, uint256(65535) << 132 | uint256(1) << 192); // games at their most
        humans("e2e4");
        w = duel.players(alice);
        assertEq(field(w, 132, 16), 65535, "games");
        assertEq(field(w, 148, 12), 0, "won untouched");
        vm.revertToState(snap);
        foolBy(bob); // game 1; alice wins game 2
        scholarsMate();
        setWord(alice, uint256(255) << 184 | uint256(2) << 192); // even wins at their most, the last game even
        humans("e2e4"); // game 3 folds game 2
        w = duel.players(alice);
        assertEq(field(w, 184, 8), 255, "even wins");
        assertEq(field(w, 192, 32), 3, "the last game");
        vm.revertToState(snap);
        string[8] memory line = ["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"];
        for (uint256 i; i < 8; i += 2) {
            humans(line[i]);
            swarm(line[i + 1]);
        }
        setWord(alice, uint256(4095) << 160 | uint256(1) << 192); // drawn at its most, game 1 drawn
        humans("e2e4");
        w = duel.players(alice);
        assertEq(field(w, 160, 12), 4095, "drawn");
        assertEq(field(w, 172, 12), 0, "mates untouched");
    }

    /// Counters stop at their width and never spill into the next field.
    function test_aCounterStopsAtItsWidth() public {
        uint256 full = (uint256(1) << 24) - 1 | ((uint256(1) << 16) - 1) << 24 | uint256(1) << 192;
        setWord(alice, full);
        humans("e2e4");
        uint256 w = duel.players(alice);
        assertEq(field(w, 0, 24), (1 << 24) - 1, "moves saturate");
        assertEq(field(w, 24, 16), (1 << 16) - 1, "pawn moves saturate");
        assertEq(field(w, 40, 16), 0, "the next field untouched");
        assertEq(field(w, 132, 16), 0, "same game: no new game counted");
    }

    function test_moneyGasFigures() public {
        vm.prank(alice);
        uint256 g0 = gasleft();
        uint256 a = duel.deposit(10 ether, 0, address(0));
        emit log_named_uint("a game's first deposit, with its buy", g0 - gasleft());
        nextBlock();
        vm.prank(bob);
        g0 = gasleft();
        duel.deposit(10 ether, 0, address(0));
        emit log_named_uint("a deposit, with its buy", g0 - gasleft());
        vm.prank(bob);
        g0 = gasleft();
        duel.deposit(10 ether, 0, address(0));
        emit log_named_uint("a deposit, no buy (same block)", g0 - gasleft());
        bidAs(alice, 2 ether, "e2e4");
        vm.prank(bob);
        g0 = gasleft();
        duel.deposit(5 ether, u("d2d4"), address(0));
        emit log_named_uint("a new lead, the outbid bid buying its shares", g0 - gasleft());
        vm.warp(st().deadline);
        nextBlock();
        g0 = gasleft();
        duel.advance();
        emit log_named_uint("a close settling the winner, its prize and counts, the ask and a buy", g0 - gasleft());
        swarm("e7e5");
        humans("e2e4");
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;
        vm.prank(alice);
        g0 = gasleft();
        duel.claim(ids);
        emit log_named_uint("claiming one position's dividends", g0 - gasleft());
    }

    // ---------------------------------------------------------------- referrals

    function refer(address who, uint256 amount, uint16 move, address referrer) internal returns (uint256 id) {
        vm.prank(who);
        id = duel.deposit(amount, move, referrer);
    }

    function test_aReferredShareBuyOwesItsReferrerThreePercentFromTheJackpotsPart() public {
        noBuys();
        address carol = address(0xCA201);
        vm.expectEmit(true, true, true, true, address(duel));
        emit SwarmDuel.Referrer(1, carol);
        refer(alice, 100 ether, 0, carol);
        SwarmLedger.Money memory k = buckets();
        assertEq(duel.referrals(carol), 3 ether, "3% of what split");
        assertEq(k.referrals, 3 ether, "owed, and held for it");
        assertEq(k.pending, 60 ether, "the holders' 60% is untouched");
        assertEq(k.stakersWaiting, 3 ether, "and the stakers' 3%");
        assertEq(imd.balanceOf(TEAM), 1 ether, "and the team's 1%");
        assertEq(duel.waiting(), 36 ether, "the jackpot's part is 33% (36% less the referral) and the stakers' 3% waits");
        // the referrer takes it with its own claim; a claim of positions leaves it
        uint256[] memory none;
        vm.prank(carol);
        (uint256 got,) = duel.claim(none);
        assertEq(got, 0, "a positions claim pays no referral IMD");
        assertEq(duel.referrals(carol), 3 ether);
        vm.expectEmit(true, true, true, true, address(duel));
        emit SwarmDuel.ReferralClaimed(carol, 3 ether);
        vm.prank(carol);
        assertEq(duel.claimReferrals(), 3 ether);
        assertEq(imd.balanceOf(carol), 3 ether);
        assertEq(duel.referrals(carol), 0, "once");
        assertEq(buckets().referrals, 0);
        vm.prank(carol);
        assertEq(duel.claimReferrals(), 0, "nothing more, and no revert");
        held();
    }

    function test_aReferredLeadPaysItsReferrerWhenItIsSplitOutbidOrWon() public {
        noBuys();
        address carol = address(0xCA201);
        address dan = address(0xDA2);
        uint256 a = refer(alice, 10 ether, u("e2e4"), carol);
        assertEq(duel.referrals(carol), 0, "a lead in escrow hasn't split");
        assertEq(duel.referrerOf(a), carol, "its referrer kept for the split");
        refer(bob, 20 ether, u("d2d4"), dan); // outbids: alice's 10 IMD buys shares now
        assertEq(duel.referrals(carol), 0.3 ether, "the outbid bid's whole amount split: 3% of 10");
        assertEq(duel.referrerOf(a), address(0), "forgotten once split");
        vm.warp(st().deadline);
        duel.advance(); // bob wins: pays 4 IMD, of which the ask takes 0.5; 3.5 splits
        assertEq(duel.referrals(dan), 3.5 ether * 300 / 10_000, "the winning bid's payment less the ask, 3%");
        assertEq(buckets().referrals, 0.3 ether + 3.5 ether * 300 / 10_000);
        held();
    }

    function test_referringOneselfIsAllowedAndTheDuelItselfIsNoReferrer() public {
        noBuys();
        refer(alice, 50 ether, 0, alice);
        assertEq(duel.referrals(alice), 1.5 ether, "the same rebate anyone can take: wallets are free");
        vm.recordLogs();
        refer(bob, 50 ether, 0, address(duel));
        assertEq(duel.referrals(address(duel)), 0, "SwarmDuel's own address counts as none");
        assertEq(buckets().referrals, 1.5 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) assertTrue(logs[i].topics[0] != SwarmDuel.Referrer.selector, "and no Referrer event");
        held();
    }
}
