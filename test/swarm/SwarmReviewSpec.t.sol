// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmBase} from "./SwarmBase.sol";
import {SwarmDuel} from "../../src/swarm/SwarmDuel.sol";
import {SwarmRules} from "../../src/swarm/SwarmRules.sol";
import {SwarmOracle} from "../../src/swarm/SwarmOracle.sol";
import {SwarmText} from "../../src/swarm/SwarmText.sol";
import {IMainDuelBuyer} from "../../src/IMainDuelBuyer.sol";
import {IIntake, Attestation} from "../../src/swarm/IIntake.sol";
import {ISwarmOracle, ISwarmOracleClient, SwarmCause} from "../../src/swarm/ISwarmOracle.sol";

/// Audit 2026-11-13, spec and tests role: tests that pass now and would fail on mutations the existing suites miss.

/// An adapter whose ids use all 32 bytes, as IMD's Intake ids do (ScriptedOracle's are small numbers, so the record's
/// first sixteen bytes are zero whatever the code writes there).
contract WideOracle is ISwarmOracle {
    IERC20 immutable imd;
    ISwarmOracleClient immutable client;
    uint256 public price;
    uint256 n;
    bool public refuse;

    constructor(IERC20 imd_, ISwarmOracleClient client_, uint256 price_) {
        (imd, client, price) = (imd_, client_, price_);
    }

    function setRefuse(bool r) external {
        refuse = r;
    }

    function ask(SwarmRules.Game calldata, uint16[] calldata, uint256[] calldata) external returns (bytes32 id) {
        require(!refuse, "refused");
        imd.transferFrom(msg.sender, address(this), price);
        id = keccak256(abi.encode("wide", ++n));
    }

    function answer(bytes32 id, uint16 m, uint16 agreed) external {
        client.answered(id, m, agreed);
    }

    function fail(bytes32 id, uint8 cause) external {
        client.failed(id, cause);
    }
}

/// IMD's Intake with keccak ids, delivering with 200k gas and measuring the chain.
contract WideIntake is IIntake {
    struct Req {
        address target;
        bytes4 result;
        bytes4 failure;
    }

    mapping(bytes32 => Req) public reqs;
    uint256 n;
    uint256 public lastGasUsed;

    function requestWithFailure(bytes32, bytes calldata, Callback calldata cb, bytes4 onFailure, address asset, uint256 amount)
        external
        returns (bytes32 id)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        id = keccak256(abi.encode("intake", ++n));
        reqs[id] = Req(cb.target, cb.selector, onFailure);
    }

    function complete(bytes32 id, Attestation calldata a, bytes calldata sig) external {
        Req memory r = reqs[id];
        _deliver(r.target, abi.encodeWithSelector(r.result, id, a, sig));
    }

    function fail(bytes32 id, uint8 status, uint16 agreed, uint16 answered) external {
        Req memory r = reqs[id];
        _deliver(r.target, abi.encodeWithSelector(r.failure, id, status, bytes32("disagreed"), agreed, answered, bytes("")));
    }

    function _deliver(address target, bytes memory data) internal {
        uint256 g0 = gasleft();
        (bool ok,) = target.call{gas: 200_000}(data);
        lastGasUsed = g0 - gasleft();
        require(ok, "delivery failed");
    }
}

contract TextHarness13 {
    function write(SwarmText.Ask memory a) external pure returns (SwarmText.Written memory) {
        return SwarmText.write(a);
    }
}

/// The shared helpers: a turn's word unpacked, a fresh duel with any adapter.
abstract contract Audit13Base is SwarmBase {
    struct Turn {
        bytes16 id;
        uint40 closedAt;
        uint40 knownAt;
        uint16 move;
        uint16 agreed;
        uint8 by;
        uint8 cause;
    }

    function turn(uint256 gameNo, uint256 ply) internal view returns (Turn memory t) {
        uint256 w = duel.turns((gameNo << 16) | ply);
        (t.move, t.by, t.cause, t.agreed) = (uint16(w), uint8(w >> 16), uint8(w >> 24), uint16(w >> 32));
        (t.closedAt, t.knownAt, t.id) = (uint40(w >> 48), uint40(w >> 88), bytes16(uint128(w >> 128)));
    }

    function freshDuel() internal {
        vm.warp(1_800_000_000);
        vm.roll(30_000_000);
        duel = new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(vault), TEAM, address(this), 0);
        for (uint256 i; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            imd.mint(who, 1_000 ether);
            vm.prank(who);
            imd.approve(address(duel), type(uint256).max);
        }
    }
}

/// The record with ids that fill the word's top half.
contract AuditSpecRecordTest is Audit13Base {
    WideOracle wide;

    function setUp() public override {
        freshDuel();
        wide = new WideOracle(imd, duel, PRICE);
        duel.open(wide);
    }

    function answer(string memory m, uint16 agreed) internal {
        wide.answer(duel.askId(), u(m), agreed);
        duel.advance();
    }

    /// Gap: dropping `turns[..] |= id >> 128 << 128` in `_ask` passes SwarmRecord (its ids' first 16 bytes are zero).
    function test_theRecordKeepsTheAsksFirstSixteenBytes() public {
        humans("e2e4");
        bytes32 id = duel.askId();
        assertTrue(bytes16(id) != bytes16(0), "a wide id");
        assertEq(turn(1, 1).id, bytes16(id), "the record's id is the ask's first sixteen bytes");
        answer("e7e5", 4);
        Turn memory t = turn(1, 1);
        assertEq(t.id, bytes16(id), "kept once played");
        assertEq(t.agreed, 4, "the adapter's count");
    }

    /// Gap: `_fail` writing the word with `=` instead of `|=` (losing the close's time and the id) passes SwarmRecord.
    function test_aFailureKeepsTheClosesTimeAndTheId() public {
        humans("e2e4");
        uint256 closedAt = vm.getBlockTimestamp();
        bytes32 id = duel.askId();
        vm.warp(closedAt + 90);
        wide.fail(id, SwarmCause.REFUSED);
        Turn memory t = turn(1, 1);
        assertEq(t.closedAt, closedAt);
        assertEq(t.id, bytes16(id));
        assertEq(t.cause, SwarmCause.REFUSED);
        assertEq(t.knownAt, closedAt + 90);
        engineMoves();
        t = turn(1, 1);
        assertEq(t.closedAt, closedAt);
        assertEq(t.id, bytes16(id));
        assertEq(t.knownAt, closedAt + 90);
        assertTrue(t.by == 2 || t.by == 3);
        assertEq(t.move, uint16(duel.historyWords(1)[0] >> 16) & 4095);
    }

    /// Not covered before: LATE's record time is the call that found it late (`knownAt = now`).
    function test_aLateAskIsRecordedWhenFoundLate() public {
        humans("e2e4");
        uint256 closedAt = vm.getBlockTimestamp();
        bytes32 id = duel.askId();
        vm.warp(closedAt + 2 hours);
        vm.roll(vm.getBlockNumber() + 2);
        duel.advance(); // LATE, then the engine (its dice known)
        Turn memory t = turn(1, 1);
        assertEq(t.cause, SwarmCause.LATE);
        assertEq(t.knownAt, closedAt + 1 hours, "when the hour ran out, not when it was found");
        assertEq(t.closedAt, closedAt);
        assertEq(t.id, bytes16(id));
        assertTrue(t.by == 2 || t.by == 3);
    }

    /// Not covered before: a declined ask has no id, its cause, and its failure at the close.
    function test_aDeclinedAskIsRecordedAtTheClose() public {
        wide.setRefuse(true);
        humans("e2e4");
        uint256 closedAt = vm.getBlockTimestamp();
        Turn memory t = turn(1, 1);
        assertEq(t.id, bytes16(0));
        assertEq(t.cause, SwarmCause.DECLINED);
        assertEq(t.knownAt, closedAt);
        assertEq(t.closedAt, closedAt);
        engineMoves();
        assertTrue(turn(1, 1).by == 2 || turn(1, 1).by == 3);
    }

    /// Not covered before: a turn the breaker skips: no id, no cause, no time but the close's.
    function test_aTurnTheBreakerSkipsHasOnlyItsClose() public {
        wide.setRefuse(true);
        string[4] memory white = ["e2e4", "d2d4", "g1f3", "b1c3"];
        for (uint256 i; i < 3; i++) {
            humans(white[i]);
            engineMoves();
        }
        assertEq(st().failures, 3, "the breaker tripped");
        humans(white[3]);
        uint256 closedAt = vm.getBlockTimestamp();
        Turn memory t = turn(1, 7);
        assertEq(t.id, bytes16(0));
        assertEq(t.cause, 0);
        assertEq(t.knownAt, 0);
        assertEq(t.closedAt, closedAt);
        engineMoves();
        assertTrue(turn(1, 7).by == 2 || turn(1, 7).by == 3);
    }

    /// Gap: writing a turn word for the humans' moves too (dropping `by != BY_HUMANS`) passes every suite.
    function test_theHumansMovesWriteNoTurnWord() public {
        humans("e2e4");
        answer("e7e5", 3);
        humans("g1f3");
        assertEq(duel.turns(1 << 16), 0, "ply 0");
        assertEq(duel.turns((1 << 16) | 2), 0, "ply 2");
    }

    /// Gap: no game in any suite promotes, so the history's promotion bit (bit 12, `_apply`) is never checked.
    function test_aPromotionIsMarkedInTheHistory() public {
        humans("h2h4");
        answer("g7g5", 3);
        humans("h4g5");
        answer("h7h6", 3);
        humans("g5h6");
        answer("f8g7", 3);
        humans("h6g7");
        answer("g8f6", 3);
        humans("g7h8"); // takes the rook and promotes, with check: Ng8 is Black's only move
        uint256 w = duel.historyWords(1)[0];
        assertEq((w >> 128) & 0xffff, uint256(u("g7h8")) | 4096, "the promotion's bit");
        assertEq((w >> 112) & 0xffff, u("g8f6"), "no bit on a plain move");
        Turn memory t = turn(1, 9);
        assertEq(t.by, 4);
        assertEq(t.move, u("f6g8"));
    }
}

/// SwarmDuel with the real SwarmOracle: the record's key and the adapter's `asks` key are one, the panel's count reaches
/// the record, and SwarmDuel's own failure path fits the callback chain's budget.
contract AuditSpecPortTest is Audit13Base {
    uint256 constant PK = 0xA11CE;
    WideIntake intake;
    SwarmOracle real;

    function setUp() public override {
        freshDuel();
        intake = new WideIntake();
        real = new SwarmOracle(intake, imd, vm.addr(PK), duel, sr, PRICE);
        duel.open(real);
    }

    function ascii(string memory s) internal pure returns (bytes32 x) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; i++) x |= bytes32(b[i]) >> (i * 8);
    }

    function signedAnswer(bytes32 id, string memory move, uint16 agreed) internal {
        Attestation memory a;
        a.requestId = bytes16(0x775fba6258c1402ea9b7f186c9371350);
        a.chainId = block.chainid;
        a.questionHash = real.pending(id);
        a.answerType = 2;
        a.answer = abi.encode(ascii(move));
        a.panelJobId = bytes16(0xb036b976e6714d10a298bae8a37d803b);
        (a.panelSize, a.quorum, a.agreed) = (7, 3, agreed);
        (a.issuedAt, a.expiresAt) = (uint64(vm.getBlockTimestamp()), uint64(vm.getBlockTimestamp() + 1 days));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, real.digest(a));
        intake.complete(id, a, abi.encodePacked(r, s, v));
    }

    /// Gaps: SwarmOracle's `asks` key with its halves swapped (gameNo 1, ply 1 is the only case tested), and
    /// SwarmOracle forwarding a constant instead of `a.agreed` (its StubClient drops the count) both pass today.
    function test_theAdaptersKeyIsTheRecordsKeyAndTheCountArrives() public {
        humans("e2e4");
        bytes32 id1 = duel.askId();
        assertEq(real.asks((1 << 16) | 1), id1);
        signedAnswer(id1, "e7e5", 4);
        duel.advance();
        Turn memory t = turn(1, 1);
        assertEq(t.move, u("e7e5"));
        assertEq(t.by, 1);
        assertEq(t.agreed, 4, "the attestation's count, not the quorum");
        humans("g1f3");
        bytes32 id2 = duel.askId();
        uint256 key = (1 << 16) | 3;
        assertEq(real.asks(key), id2, "game 1, Black's ply 3");
        assertEq(real.asks((3 << 16) | 1), bytes32(0), "not ply 1 of game 3");
        assertEq(bytes16(real.asks(key)), turn(1, 3).id, "the record's prefix of the adapter's full id, by one key");
    }

    /// Not asserted before: the callback chain through SwarmDuel's own `failed` (which updates the turn's word) fits
    /// the 100k the chain is held to in SwarmOracle.t.sol (that test uses a stub client).
    function test_aFailureThroughSwarmDuelFitsTheChainsBudget() public {
        humans("e2e4");
        bytes32 id = duel.askId();
        intake.fail(id, 2, 2, 3); // IMD's "disagreed": valid answers short of the quorum, a split
        emit log_named_uint("failure chain with SwarmDuel", intake.lastGasUsed());
        assertLt(intake.lastGasUsed(), 100_000);
        Turn memory t = turn(1, 1);
        assertEq(t.cause, SwarmCause.SPLIT);
        assertEq(t.id, bytes16(id));
        assertEq(st().phase, 3, "fallback");
    }
}

/// The question's capture marks and board in Solidity: today they are checked only by
/// scripts/check-swarm-bodies.mjs, which runs only through swarm-test.sh after SwarmTextTest rewrites its cache.
contract AuditSpecTextTest is Audit13Base {
    TextHarness13 th = new TextHarness13();

    function body(string[] memory moves) internal view returns (bytes memory) {
        SwarmText.Ask memory a;
        (a.g.board, a.g.white, a.g.black) = sr.start(0);
        a.g.gameNo = 1;
        a.history = new uint256[](1);
        uint256[4] memory r;
        for (uint256 i; i < moves.length; i++) {
            uint16 m = u(moves[i]);
            (bool legal, SwarmRules.Outcome memory o) = sr.play(a.g, r, m);
            assertTrue(legal);
            (a.g.board, a.g.white, a.g.black, a.g.quiet, r) = (o.board, o.white, o.black, o.quiet, o.ring);
            a.history[0] |= uint256(m) << (16 * i);
            a.g.ply++;
        }
        a.legal = sr.legalMoves(a.g.board, a.g.white, a.g.black, true);
        (a.windowBlock, a.chainId) = (26_350_000, 1);
        return th.write(a).body;
    }

    function has(bytes memory h, string memory needle) internal pure returns (bool) {
        bytes memory n = bytes(needle);
        for (uint256 i; i + n.length <= h.length; i++) {
            uint256 j;
            while (j < n.length && h[i + j] == n[j]) j++;
            if (j == n.length) return true;
        }
        return false;
    }

    function test_captureMarksAndTheBoard() public view {
        string[] memory line = new string[](3);
        (line[0], line[1], line[2]) = ("e2e4", "d7d5", "d1g4");
        bytes memory b = body(line);
        assertTrue(has(b, " c8g4xQ "), "the hanging queen, in capitals");
        assertTrue(has(b, " d5e4xP"), "a pawn taken");
        assertFalse(has(b, "d5d4x"), "a push is plain");
        assertTrue(
            has(
                b,
                '"board":"Rank 8 to rank 1, files a to h; White in capitals, Black in lower case, a dot for an empty square: '
                "8 rnbqkbnr, 7 ppp.pppp, 6 ........, 5 ...p...., 4 ....P.Q., 3 ........, 2 PPPP.PPP, 1 RNB.KBNR.\""
            ),
            "the board, rank 8 first"
        );
        assertTrue(has(b, '"0x63386734000000'), "the allow list stays plain UCI (c8g4)");
    }

    function test_enPassantIsMarkedAsAPawn() public view {
        string[] memory line = new string[](5);
        (line[0], line[1], line[2], line[3], line[4]) = ("a2a3", "d7d5", "a3a4", "d5d4", "e2e4");
        bytes memory b = body(line);
        assertTrue(has(b, " d4e3xP"), "en passant takes a pawn");
        assertFalse(has(b, "d4d3x"), "the push beside it is plain");
    }
}
