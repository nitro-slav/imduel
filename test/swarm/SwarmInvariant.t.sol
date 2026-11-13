// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmFeed} from "./SwarmFeed.sol";
import {stateOf, State} from "./SwarmBase.sol";
import {SwarmDuel} from "../../src/swarm/SwarmDuel.sol";
import {SwarmLedger} from "../../src/swarm/SwarmLedger.sol";
import {SwarmRules} from "../../src/swarm/SwarmRules.sol";
import {TestIMD, TestIMDUEL, MockBuyer, MockVault, ScriptedOracle, ScriptedEngine} from "./SwarmDoubles.sol";
import {SwarmBase, State, stateOf, uci} from "./SwarmBase.sol";

/// Random money against whole games (fail_on_revert: every action it makes must succeed). Deposits of any size, with
/// no move, the game's line or any legal move; waits; closes; the swarm answering, its answer stored, an illegal answer,
/// a failure for any cause, an answer too late; the engine's move two blocks after the close; buys by anyone; the main
/// duel's buyer taking any amount, reverting or burning its gas; the vault reverting its sync; the adapter raising its
/// price or refusing; claims, each paying exactly what `owed` said. The games follow lines so they end: a swarm win
/// (fool's mate), a draw (the knights out and back), a human win (scholar's mate, or 1. e4 g5 2. Qh5 once the f7 pawn
/// is gone); the line's move always leads when a turn closes, and the engine is set to the line's reply.
contract SwarmHandler is SwarmFeed {
    bytes constant SWARM_WIN = "f2f3 e7e5 g2g4 d8h4";
    bytes constant DRAW = "g1f3 g8f6 f3g1 f6g8 g1f3 g8f6 f3g1 f6g8";
    bytes constant HUMAN_WIN = "e2e4 e7e5 f1c4 b8c6 d1h5 g8f6 h5f7";
    bytes constant HUMAN_WIN_ODDS = "e2e4 g7g5 d1h5";
    uint8 constant OPEN = 0;
    uint8 constant THINKING = 1;
    uint8 constant ANSWERED = 2;
    uint8 constant FALLBACK = 3;

    SwarmDuel public immutable duel;
    TestIMD immutable imd;
    ScriptedOracle immutable oracle;
    ScriptedEngine immutable engine;
    SwarmRules immutable sr;
    MockBuyer immutable buyer;
    MockVault immutable vault;
    address[3] actors;
    mapping(uint256 => bytes) lineOf; // by game
    uint256 public splits; // deposits, conversions and closes: one split each at most

    constructor(SwarmBase.Kit memory kit, address[3] memory actors_) {
        (duel, imd, oracle, engine, sr, buyer, vault) = (kit.duel, kit.imd, kit.oracle, kit.engine, kit.sr, kit.buyer, kit.vault);
        actors = actors_;
        _started(sr, 1, 0); // game 1 opened before the handler existed
    }

    /// Every action's SwarmDuel events, fed to the model in order (SwarmFeed).
    modifier feeds() {
        vm.recordLogs();
        _;
        _feed(duel, vm.getRecordedLogs());
    }

    /// The contract equals the model, to the wei (SwarmFeed).
    function matchesModel(address team) external view {
        _matchesModel(duel, IERC20(address(imd)), IERC20(buyer.imduel()), team, 0);
    }

    // ---------------------------------------------------------------- the humans

    function deposit(uint256 who, uint256 amount, uint256 pick) external feeds {
        State memory s = _open();
        if (s.phase != OPEN || _due(s)) return;
        uint16 m;
        if (pick % 3 == 1) m = _move(s);
        if (pick % 3 == 2) {
            uint16[] memory legal = sr.legalMoves(s.board, s.white, s.black, false);
            m = legal[pick / 3 % legal.length];
        }
        amount = m == 0 ? bound(amount, 1e12, 100 ether) : bound(amount, 2 ether, 80 ether);
        vm.prank(_actor(who));
        duel.deposit(amount, m, _referrer(pick >> 16));
        splits += 2;
    }

    function wait(uint256 time) external feeds {
        _lineLeads(stateOf(duel), time);
        vm.warp(vm.getBlockTimestamp() + bound(time, 1, 30 hours));
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// A plain deposit whatever the swarm is doing: it first plays what is due there (section 6). Skipped only where
    /// it must revert: the swarm's hour still running, or the engine's dice not yet known.
    function depositAny(uint256 who, uint256 amount) external feeds {
        State memory s = stateOf(duel);
        (, uint40 askedAt,,) = duel.asked();
        (,,, uint48 closeBlock) = duel.stats();
        if (s.phase == THINKING && vm.getBlockTimestamp() <= uint256(askedAt) + 1 hours) return;
        if (s.phase != OPEN && vm.getBlockNumber() < uint256(closeBlock) + 2) return;
        if (s.phase == OPEN && _due(s)) return;
        vm.prank(_actor(who));
        duel.deposit(bound(amount, 1e12, 50 ether), 0, _referrer(amount >> 128));
        splits += 2;
    }

    /// $IMDUEL sent straight to SwarmDuel: it joins the jackpot at once (section 3).
    function sendImduel(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        TestIMDUEL(buyer.imduel()).mint(address(duel), amount);
        model.sent(amount);
    }

    /// IMD sent straight to SwarmDuel: it waits with the jackpot's and is bought into it (section 3).
    function sendImd(uint256 amount) external {
        amount = bound(amount, 1, 100 ether);
        imd.mint(address(duel), amount);
        model.sentImd(amount);
    }

    /// The odds count set anywhere from 0 to 140 humans' moves, so later games start at every level.
    function setOdds(uint256 moves) external {
        bytes32 slot = bytes32(uint256(5)); // stats: its low 32 bits
        uint256 w = uint256(vm.load(address(duel), slot));
        vm.store(address(duel), slot, bytes32((w & ~uint256(type(uint32).max)) | bound(moves, 0, 140)));
    }

    function close(uint256 who) external feeds {
        State memory s = _open();
        if (s.phase != OPEN) return;
        _lineLeads(s, who);
        s = stateOf(duel);
        bytes memory line = _line(s);
        uint256 reply = 5 * (uint256(s.ply) + 1);
        if (reply < line.length) engine.set(1, uci(line, reply));
        if (vm.getBlockTimestamp() < s.deadline) vm.warp(s.deadline);
        duel.advance();
        splits++;
    }

    // ---------------------------------------------------------------- the swarm, the engine, the adapter

    function swarm(uint256 how, uint8 cause) external feeds {
        State memory s = stateOf(duel);
        if (s.phase == FALLBACK) return _through();
        if (s.phase != THINKING) return;
        bytes32 id = duel.askId();
        how %= 7;
        if (how <= 2) oracle.answer(id, uci(_line(s), 5 * uint256(s.ply)));
        else if (how == 3) oracle.answer(id, 0); // illegal: the engine plays
        else if (how == 4) oracle.fail(id, uint8(1 + cause % 6));
        else {
            (, uint40 askedAt,,) = duel.asked();
            vm.warp(uint256(askedAt) + 1 hours + 1);
            if (how == 6) oracle.answer(id, uci(_line(s), 5 * uint256(s.ply))); // too late: ignored
        }
        if (how != 0) _through(); // 0: stored, for the next call to play
    }

    function setPrice(uint256 p) external {
        uint256[3] memory prices = [uint256(0.5 ether), 0.6 ether, 0.9 ether]; // above the stored 0.5 its asks fail
        oracle.setPrice(prices[p % 3]);
    }

    function setRefuse(bool r) external {
        oracle.setRefuse(r);
    }

    // ---------------------------------------------------------------- buying

    function buy(uint256 who) external feeds {
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(_actor(who));
        duel.buy();
    }

    function setBuyer(uint256 perBuy, uint256 mode) external {
        uint256[4] memory amounts = [uint256(0), 5 ether, 14 ether, 50 ether];
        mode %= 8;
        buyer.set(amounts[perBuy % 4], 1e18 + perBuy % 3e18, mode == 6, mode == 7);
        vault.setRefuse(mode == 5);
    }

    // ---------------------------------------------------------------- claims

    function claim(uint256 who) external feeds {
        address a = _actor(who);
        uint256 n = duel.positionCount();
        uint256[] memory ids = new uint256[](n);
        uint256 count;
        uint256 dueImd;
        uint256 dueDuel;
        for (uint256 id = 1; id <= n; id++) {
            (address owner,,,,,,,,) = duel.positions(id);
            if (owner != a) continue;
            ids[count++] = id;
            (uint256 d, uint256 r, uint256 z, uint256 w) = duel.owed(id);
            (dueImd, dueDuel) = (dueImd + d + r, dueDuel + z + w);
        }
        assembly {
            mstore(ids, count)
        }
        // a claim closes a due turn first (2026-11-13): then owed() moved under it, and the model, fed the close's events
        // and the claim's, checks what was paid (SwarmFeed: Settled, then each Claimed against the model)
        State memory now_ = stateOf(duel);
        (uint64 leadId,,,) = duel.lead();
        bool closes = now_.phase == 0 && leadId != 0 && block.timestamp >= now_.deadline;
        if (closes) { // as close() prepares it: the line leads already (wait); the engine set to the line's reply
            bytes memory line = _line(now_);
            uint256 reply = 5 * (uint256(now_.ply) + 1);
            if (reply < line.length) engine.set(1, uci(line, reply));
            splits++;
        }
        uint256 earned = duel.referrals(a);
        vm.prank(a);
        (uint256 gotImd, uint256 gotDuel) = duel.claim(ids);
        if (!closes) {
            assertEq(gotImd, dueImd, "a claim pays the IMD owed() said");
            assertEq(duel.referrals(a), earned, "and leaves what its owner earned as a referrer");
            assertEq(gotDuel, dueDuel, "and the $IMDUEL");
        } else {
            assertEq(stateOf(duel).phase == 0 && stateOf(duel).deadline <= block.timestamp && leadId == 0, false, "the due turn closed");
        }
        for (uint256 i; i < count; i++) {
            (uint256 d, uint256 r, uint256 z, uint256 w) = duel.owed(ids[i]);
            assertEq(d + r + z + w, 0, "once");
        }
    }

    function claimReferrals(uint256 who) external feeds {
        address a = _actor(who);
        uint256 earned = duel.referrals(a);
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        assertEq(duel.claimReferrals(), earned, "a referrer's claim pays what referrals() said");
        assertEq(imd.balanceOf(a) - before, earned, "in IMD");
        assertEq(duel.referrals(a), 0, "once");
    }

    // ---------------------------------------------------------------- helpers

    function _actor(uint256 who) internal view returns (address) {
        return actors[who % 3];
    }

    /// A deposit's referrer: none, any actor (the depositor itself included: allowed), or SwarmDuel (counts as none).
    function _referrer(uint256 seed) internal view returns (address) {
        uint256 r = seed % 5;
        return r == 0 ? address(0) : r == 4 ? address(duel) : actors[r - 1];
    }

    /// What every actor is owed as a referrer (only actors refer).
    function referralsOwed() external view returns (uint256 sum) {
        for (uint256 i; i < 3; i++) sum += duel.referrals(actors[i]);
    }

    function _due(State memory s) internal view returns (bool) {
        (uint64 id,,,) = duel.lead();
        return id != 0 && vm.getBlockTimestamp() >= s.deadline;
    }

    /// A stored answer is played (it may end the game); a due engine move is played.
    function _open() internal returns (State memory s) {
        s = stateOf(duel);
        if (s.phase == ANSWERED || s.phase == FALLBACK) _through();
        return stateOf(duel);
    }

    /// The swarm's turn played through: a pending ask runs out its hour, the engine moves two blocks after the close.
    function _through() internal {
        for (State memory s = stateOf(duel); s.phase != OPEN; s = stateOf(duel)) {
            if (s.phase == THINKING) {
                (, uint40 askedAt,,) = duel.asked();
                if (vm.getBlockTimestamp() <= uint256(askedAt) + 1 hours) vm.warp(uint256(askedAt) + 1 hours + 1);
            }
            vm.roll(vm.getBlockNumber() + 2);
            duel.advance();
        }
    }

    /// The line's move takes the lead if another move holds it (before time can pass, so a closing turn plays the line).
    function _lineLeads(State memory s, uint256 who) internal {
        if (s.phase != OPEN) return;
        uint16 m = _move(s);
        (uint64 id, uint128 leading, uint16 move,) = duel.lead();
        if (id != 0 && move == m) return;
        assertFalse(_due(s), "the line leads whenever a turn runs out");
        vm.prank(_actor(who));
        duel.deposit(2 * uint256(leading) > 2 ether ? 2 * uint256(leading) : 2 ether, m, _referrer(who >> 8));
        splits += 2;
    }

    function _move(State memory s) internal returns (uint16) {
        return uci(_line(s), 5 * uint256(s.ply));
    }

    /// The game's line, picked at its first use; from three pieces' odds on the humans win.
    function _line(State memory s) internal returns (bytes memory line) {
        line = lineOf[s.gameNo];
        if (line.length != 0) return line;
        uint256 pick = uint256(keccak256(abi.encode(s.gameNo, splits, vm.getBlockTimestamp()))) % 3;
        if (s.level == 4) pick = 1; // no queen: no fool's mate, and Kd8 escapes the odds line; the knights draw
        line = pick == 0 ? SWARM_WIN : pick == 1 ? DRAW : s.level == 0 ? HUMAN_WIN : HUMAN_WIN_ODDS;
        lineOf[s.gameNo] = line;
    }
}

/// Swarm Duel's money under random actions.
contract SwarmInvariantTest is SwarmBase {
    SwarmHandler handler;

    function setUp() public override {
        super.setUp();
        address[3] memory actors = [alice, bob, address(0xCA401)];
        for (uint256 i; i < 3; i++) {
            imd.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            imd.approve(address(duel), type(uint256).max);
        }
        handler = new SwarmHandler(Kit(duel, imd, oracle, engine, sr, buyer, vault), actors);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 150
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_whatIsOwedIsHeld() public view {
        SwarmLedger.Money memory k = buckets();
        assertGe(imd.balanceOf(address(duel)), uint256(k.escrow) + k.dividends + k.refunds + k.pending + k.referrals, "IMD");
        assertGe(imduel.balanceOf(address(duel)), k.prizes, "$IMDUEL: the prizes owed (the jackpot is the rest)");
        assertLe(k.stakersWaiting, duel.waiting(), "the stakers' part waits");
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 150
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyClaimIsHeld() public view {
        uint256[4] memory sum;
        uint256 n = duel.positionCount();
        for (uint256 id = 1; id <= n; id++) {
            (uint256 d, uint256 r, uint256 z, uint256 w) = duel.owed(id);
            (sum[0], sum[1], sum[2], sum[3]) = (sum[0] + d, sum[1] + r, sum[2] + z, sum[3] + w);
        }
        SwarmLedger.Money memory k = buckets();
        assertLe(sum[0], k.dividends, "dividends");
        assertLe(k.dividends - sum[0], 2 * n + handler.splits(), "dividends: only rounding unowned (section 13.6)");
        assertEq(sum[1], k.refunds, "refunds, to the wei");
        assertEq(sum[2] + sum[3], k.prizes, "prizes and human-win parts, to the wei");
        assertEq(handler.referralsOwed(), k.referrals, "what referrers are owed, to the wei");
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 150
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theTeamGetsOnePercent() public view {
        uint256 split; // every IMD that split: IN less what the asks took
        for (uint256 g = st().gameNo; g != 0; g--) split += duel.book(g).taken;
        split -= imd.balanceOf(address(oracle));
        uint256 team = imd.balanceOf(TEAM);
        assertLe(team, split / 100, "team");
        assertLe(split / 100 - team, handler.splits() + 1, "team: rounding only");
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 150
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theBooksAddUp() public view {
        (uint64 leader, uint128 leading,,) = duel.lead();
        uint256 games = st().gameNo;
        uint256[] memory shares = new uint256[](games + 1);
        uint256[] memory moves = new uint256[](games + 1);
        uint256[] memory taken = new uint256[](games + 1);
        uint256 bids;
        for (uint256 id = duel.positionCount(); id != 0; id--) {
            (, uint96 amount, uint80 n,, uint32 g,, uint8 kind,,) = duel.positions(id);
            if (kind == 2) {
                assertEq(id, leader, "the only bid not yet shares is the leader");
                bids += amount;
            } else if (kind == 1) {
                (shares[g], taken[g]) = (shares[g] + n, taken[g] + amount);
            } else {
                uint256 paid = amount - amount * 8_000 / 10_000;
                if (paid < 2 ether) paid = 2 ether;
                (shares[g], moves[g], taken[g]) = (shares[g] + n, moves[g] + 1, taken[g] + paid);
            }
        }
        assertEq(bids, leading, "the escrow is the leader");
        assertEq(buckets().escrow, bids);
        for (uint256 g = 1; g <= games; g++) {
            SwarmLedger.Book memory b = duel.book(g);
            assertEq(b.shares, 10 ether + shares[g], "S = the seed + every position's shares");
            assertEq(b.moves, moves[g], "moves = the game's winning positions");
            assertEq(b.taken, taken[g], "IN = plain amounts + winning payments");
        }
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 150
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theMoneyMatchesTheModel() public view {
        handler.matchesModel(TEAM);
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 150
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theTurnMachineKeepsItsShape() public view {
        State memory s = st();
        (uint64 leader,,, uint8 set) = duel.lead();
        if (leader != 0) assertEq(s.phase, 0, "a lead means the humans' turn (13.8)");
        bytes32 id = duel.askId();
        bytes32 none = bytes32(uint256(1));
        if (s.phase == 1) {
            assertTrue(id != 0 && id != bytes32(type(uint256).max) && id != none, "thinking: a real pending id (13.9)");
        } else {
            assertEq(id, none, "no pending id otherwise: the marker, never zero (set at deploy)");
        }
        assertEq(set, 1, "the lead's word never returns to zero (set at deploy)");
    }

    /// The handler reaches every ending: a fixed walk of its actions plays games to each result.
    function test_theHandlerPlaysGamesToEveryEnding() public {
        for (uint256 i; i < 700; i++) {
            uint256 r = uint256(keccak256(abi.encode(i)));
            uint256 a = r % 15;
            if (a < 3) handler.deposit(r >> 8, r >> 16, r >> 24);
            else if (a == 3) handler.wait(r >> 8);
            else if (a < 6) handler.close(r >> 8);
            else if (a < 8) handler.swarm(r >> 8, uint8(r >> 16));
            else if (a == 8) handler.claim(r >> 8);
            else if (a == 9) handler.buy(r >> 8);
            else if (a == 12) handler.depositAny(r >> 8, r >> 16);
            else if (a == 13) handler.sendImduel(r >> 8);
            else if (a == 10) handler.sendImd(r >> 8);
            else if (a == 14) handler.setOdds(r >> 8);
            else if ((r >> 8) % 4 == 0) handler.setPrice(r >> 16);
            else if ((r >> 8) % 4 == 1) handler.setRefuse((r >> 16) % 3 == 0);
            else handler.setBuyer(r >> 16, r >> 24);
        }
        uint256[4] memory ended;
        uint256 games = st().gameNo;
        for (uint256 g = 1; g < games; g++) ended[duel.book(g).result]++;
        emit log_named_uint("games ended", games - 1);
        emit log_named_uint("swarm wins", ended[2]);
        emit log_named_uint("draws", ended[3]);
        emit log_named_uint("human wins", ended[1]);
        emit log_named_uint("positions", duel.positionCount());
        assertGt(ended[1], 0, "a human win");
        assertGt(ended[2], 0, "a swarm win");
        assertGt(ended[3], 0, "a draw");
        invariant_whatIsOwedIsHeld();
        invariant_everyClaimIsHeld();
        invariant_theTeamGetsOnePercent();
        invariant_theBooksAddUp();
        invariant_theMoneyMatchesTheModel();
        invariant_theTurnMachineKeepsItsShape();
    }
}
