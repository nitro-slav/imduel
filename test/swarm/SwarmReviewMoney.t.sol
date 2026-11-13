// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {wadLn} from "solmate/src/utils/SignedWadMath.sol";
import {SwarmLedger} from "../../src/swarm/SwarmLedger.sol";
import {SwarmBase} from "./SwarmBase.sol";

/// Audit 2026-11-13, money role: the split with referrals and the ask's cost to the wei, donations of both tokens
/// through a whole game and a full drain, the money's storage words, and the curve's ln at its edges.
contract AuditMoneyTest is SwarmBase {
    uint256 constant K = 200 ether;
    uint256 constant SEED = 10 ether;
    uint256 constant ACC = 1e27;
    address carol = address(0xCA201);
    address dan = address(0xDA2);

    struct Sum {
        uint256 team;
        uint256 pending;
        uint256 stakers;
        uint256 refCarol;
        uint256 refDan;
    }

    function curve(uint256 ply, uint256 taken, uint256 x) internal pure returns (uint256) {
        return K * uint256(wadLn(int256(1e18 + x * 1e18 / (K + K * (ply / 2) / 50 + taken)))) / 1e18;
    }

    function split(Sum memory s, uint256 x, uint8 ref) internal pure {
        s.pending += x * 6000 / 10_000;
        s.stakers += x * 300 / 10_000;
        s.team += x * 100 / 10_000;
        if (ref == 1) s.refCarol += x * 300 / 10_000;
        if (ref == 2) s.refDan += x * 300 / 10_000;
    }

    function owedIsHeld() internal view {
        SwarmLedger.Money memory k = buckets();
        uint256 owedNow = uint256(k.escrow) + k.dividends + k.refunds + k.pending + k.referrals;
        uint256 h = imd.balanceOf(address(duel));
        assertGe(h, owedNow, "IMD owed is held");
        assertEq(duel.waiting(), h - owedNow, "waiting is the rest");
        assertLe(k.stakersWaiting, duel.waiting(), "the stakers' part waits");
        assertGe(imduel.balanceOf(address(duel)), k.prizes, "$IMDUEL owed is held");
        assertEq(duel.jackpot(), imduel.balanceOf(address(duel)) - k.prizes);
    }

    /// Three referred splits (a share buy, an outbid bid, a winning payment less the ask) at odd wei amounts: every
    /// bucket, the team's balance, each referrer's claim and the waiting IMD equal an independent sum to the wei.
    function test_referredSplitsAndTheAskAddUpToTheWei() public {
        noBuys();
        uint256 xA = 7.777777777777777777 ether; // alice's bid via carol, outbid
        uint256 xB = 13.333333333333333331 ether; // bob's plain deposit via dan
        uint256 xC = 23.456789012345678901 ether; // bob's winning bid via dan
        imd.mint(bob, 100 ether);
        vm.prank(alice);
        uint256 a = duel.deposit(xA, u("e2e4"), carol);
        vm.prank(bob);
        uint256 b = duel.deposit(xB, 0, dan);
        vm.prank(bob);
        uint256 c = duel.deposit(xC, u("d2d4"), dan);
        vm.warp(st().deadline);
        duel.advance(); // bob's d2d4 wins; the swarm is asked (0.5 IMD)

        Sum memory s;
        split(s, xB, 2);
        uint256 nB = curve(0, 0, xB);
        split(s, xA, 1);
        uint256 nA = curve(0, xB, xA);
        uint256 p = xC - xC * 8000 / 10_000;
        uint256 cost = PRICE;
        uint256 nW = curve(0, xB + xA, p);
        split(s, p - cost, 2);
        uint256 S = SEED + nA + nB + nW;
        uint256 delta = s.pending * ACC / S;
        uint256 kept = ((S - SEED) * delta + ACC - 1) / ACC;
        uint256 held = xA + xB + xC - s.team - cost;
        uint256 owedNow = (xC - p) + kept + s.refCarol + s.refDan;

        SwarmLedger.Money memory k = buckets();
        assertEq(imd.balanceOf(TEAM), s.team, "the team's 1% of each split");
        assertEq(duel.referrals(carol), s.refCarol, "carol: 3% of the outbid bid");
        assertEq(duel.referrals(dan), s.refDan, "dan: 3% of the deposit and of the payment less the ask");
        assertEq(k.referrals, s.refCarol + s.refDan, "the bucket is their sum");
        assertEq(k.pending, 0, "paid at the close");
        assertEq(k.dividends, kept, "kept, rounded up");
        assertLe(kept, s.pending, "kept <= pending");
        assertEq(k.refunds, xC - p, "the refund");
        assertEq(k.stakersWaiting, s.stakers, "the stakers' 3% of each split");
        assertEq(imd.balanceOf(address(duel)), held, "held: deposits less the team and the ask");
        assertEq(duel.waiting(), held - owedNow, "waiting: 33% or 36% of each split, the seed's part, the rounding");
        assertEq(duel.book(1).taken, xB + xA + p, "IN");
        assertEq(duel.book(1).shares, S, "S");

        uint256 sumDiv;
        uint256[3] memory ids = [a, b, c];
        for (uint256 i; i < 3; i++) {
            (uint256 d,,,) = duel.owed(ids[i]);
            sumDiv += d;
        }
        assertLe(sumDiv, kept, "holders can't take more than kept");
        assertLt(kept - sumDiv, 1 + 2 * 3, "dust under closes + 2 x positions");
        owedIsHeld();

        // everyone takes everything; what is left is the waiting IMD and the dividends' dust
        claimAs(alice, a);
        uint256[] memory two = new uint256[](2);
        (two[0], two[1]) = (b, c);
        vm.prank(bob);
        duel.claim(two);
        vm.prank(carol);
        duel.claimReferrals();
        vm.prank(dan);
        duel.claimReferrals();
        k = buckets();
        assertEq(k.referrals, 0);
        assertEq(k.refunds, 0);
        assertEq(k.dividends, kept - sumDiv, "only the dust stays owed");
        assertEq(imd.balanceOf(address(duel)), duel.waiting() + k.dividends, "the rest waits for the jackpot");
        owedIsHeld();
    }

    /// Donations of IMD and $IMDUEL at every stage of a human win (before bids, during a turn, before the mate, after
    /// the ending), with self-referral and buys running: what is owed stays held after each step, every claim pays
    /// owed(), and once everyone has claimed and the buys have run, only the dividends' dust is left in IMD and the
    /// $IMDUEL left is exactly the jackpot.
    function test_donationsThroughAHumanWinAndAFullDrain() public {
        imd.mint(address(this), 1_000 ether);
        imd.mint(alice, 1_000 ether);
        imd.mint(bob, 1_000 ether);
        imduel.mint(address(this), 1_000 ether);
        imd.transfer(address(duel), 5.5 ether);
        imduel.transfer(address(duel), 100 ether);
        vm.prank(alice);
        duel.deposit(40 ether, 0, carol);
        owedIsHeld();
        humans("e2e4");
        imd.transfer(address(duel), 1 ether + 1);
        swarm("e7e5");
        vm.prank(bob);
        duel.deposit(10 ether, 0, bob); // self-referral
        humans("f1c4");
        swarm("b8c6");
        owedIsHeld();
        humans("d1h5");
        swarm("g8f6");
        nextBlock();
        imduel.transfer(address(duel), 7 ether + 3); // right before the mating close
        vm.prank(bob);
        duel.deposit(3 ether, u("h5f7"), carol);
        vm.warp(st().deadline);
        uint256 j = duel.jackpot();
        duel.advance();
        SwarmLedger.Book memory bk = duel.book(1);
        assertEq(bk.result, 1, "White won");
        uint256 left = j - j / 100;
        assertEq(bk.perMove, left * 80 / 100 / bk.moves, "80% of the jackpot with the donation, over the moves");
        owedIsHeld();
        imduel.transfer(address(duel), 1 ether); // after the ending: the next game's jackpot

        // every position claims what owed() says
        for (uint256 id = 1; id <= duel.positionCount(); id++) {
            (address owner,,,,,,,,) = duel.positions(id);
            (uint256 d, uint256 r, uint256 z, uint256 w) = duel.owed(id);
            uint256 imdBefore = imd.balanceOf(owner);
            uint256 duelBefore = imduel.balanceOf(owner);
            claimAs(owner, id);
            assertEq(imd.balanceOf(owner) - imdBefore, d + r, "IMD as owed()");
            assertEq(imduel.balanceOf(owner) - duelBefore, z + w, "$IMDUEL as owed()");
            owedIsHeld();
        }
        address[3] memory refs = [carol, bob, dan];
        for (uint256 i; i < 3; i++) {
            uint256 due = duel.referrals(refs[i]);
            uint256 before = imd.balanceOf(refs[i]);
            vm.prank(refs[i]);
            assertEq(duel.claimReferrals(), due);
            assertEq(imd.balanceOf(refs[i]) - before, due);
        }
        for (uint256 i; i < 60 && duel.waiting() != 0; i++) {
            nextBlock();
            duel.buy();
        }
        SwarmLedger.Money memory k = buckets();
        assertEq(duel.waiting(), 0, "all bought");
        assertEq(k.stakersWaiting, 0, "the stakers' part with it");
        assertEq(uint256(k.escrow) + k.refunds + k.pending + k.referrals + k.prizes, 0, "nothing else owed");
        assertEq(imd.balanceOf(address(duel)), k.dividends, "only the dividends' dust is left in IMD");
        assertLt(k.dividends, 100, "a few wei");
        assertEq(imduel.balanceOf(address(duel)), duel.jackpot(), "the $IMDUEL left is the jackpot");
    }

    /// The money takes four storage words, not the three the spec (section 3) and the struct's comment say:
    /// (pending, stakersWaiting, lastBuyBlock), (escrow, refunds), (dividends, prizes), (referrals). The referrals word
    /// returns to zero when every referrer has claimed, so the next referred split writes it fresh.
    function test_theMoneyIsFourWords() public {
        noBuys();
        vm.prank(alice);
        duel.deposit(100 ether, 0, carol);
        uint256 slot = type(uint256).max;
        for (uint256 i; i < 200; i++) {
            if (uint256(vm.load(address(duel), bytes32(i))) == 3 ether) {
                slot = i;
                break;
            }
        }
        assertTrue(slot != type(uint256).max, "a word holding the referrals alone");
        assertEq(uint256(vm.load(address(duel), bytes32(slot - 3))), 60 ether | (3 ether << 96) | (block.number << 192));
        assertEq(uint256(vm.load(address(duel), bytes32(slot - 2))), 0, "escrow and refunds");
        assertEq(uint256(vm.load(address(duel), bytes32(slot - 1))), 0, "dividends and prizes");
        vm.prank(carol);
        duel.claimReferrals();
        assertEq(uint256(vm.load(address(duel), bytes32(slot))), 0, "back to zero after the claim");
    }

    /// The curve's ln at its edges: zero at one, never negative above it, monotone on the smallest inputs and across
    /// every octave the deposits can reach; the zero-share edge sits at `x * 1e18 < base`.
    function test_theCurvesLnAtItsEdges() public pure {
        assertEq(wadLn(1e18), 0, "ln 1 = 0");
        int256 last;
        for (uint256 i; i <= 300; i++) {
            int256 v = wadLn(int256(1e18 + i));
            assertGe(v, last, "monotone from 1");
            last = v;
        }
        for (uint256 e = 60; e <= 89; e++) {
            int256 prev = wadLn(int256((1 << e) - 3));
            for (uint256 d = 2; d <= 6; d++) {
                int256 v = wadLn(int256((1 << e) + d - 4));
                assertGe(v, prev, "monotone across an octave");
                prev = v;
            }
        }
        assertEq(curve(0, 0, 199), 0, "199 wei buys nothing at IN 0");
        assertGt(curve(0, 0, 200), 0, "200 wei buys a unit");
        assertGt(curve(400, type(uint96).max - 2 ether, 2 ether), 1e9, "a 2 IMD payment still buys shares at the widest IN (5e9 units)");
        assertLt(curve(0, 0, type(uint96).max), type(uint80).max / 300, "the largest deposit (2^96 wei) buys 3,959 shares, 2^80 / 305");
    }
}
