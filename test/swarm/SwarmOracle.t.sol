// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Chessboard} from "../Chessboard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmRules} from "../../src/swarm/SwarmRules.sol";
import {SwarmOracle} from "../../src/swarm/SwarmOracle.sol";
import {IIntake, Attestation} from "../../src/swarm/IIntake.sol";
import {ISwarmOracleClient, SwarmCause} from "../../src/swarm/ISwarmOracle.sol";
import {TestIMD} from "./SwarmDoubles.sol";

/// IMD's Intake as its docs describe it: pulls exactly the amount from the buyer, keeps it, and later calls the
/// callback (or the failure hook) once, with 200,000 gas, inside a try.
contract MockIntake is IIntake {
    struct Request {
        address target;
        bytes4 result;
        bytes4 failure;
    }

    mapping(bytes32 => Request) public requests;
    uint256 public count;
    bool public refuseOnChain; // PriceNotMet and the like
    uint256 public lastBodyLength; // the body itself goes out in an event, as an Intake would log it
    bytes32 public lastAction;
    uint256 public lastGasUsed;
    bool public lastDelivered;

    error PriceNotMet();

    event Requested(bytes32 indexed id, bytes body);

    function setRefuse(bool r) external {
        refuseOnChain = r;
    }

    function requestWithFailure(bytes32 action, bytes calldata body, Callback calldata callback, bytes4 onFailure, address asset, uint256 amount)
        external
        returns (bytes32 id)
    {
        if (refuseOnChain) revert PriceNotMet();
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        id = bytes32(++count);
        requests[id] = Request(callback.target, callback.selector, onFailure);
        (lastBodyLength, lastAction) = (body.length, action);
        emit Requested(id, body);
    }

    function complete(bytes32 id, Attestation calldata a, bytes calldata signature) external {
        Request memory r = requests[id];
        _deliver(r.target, abi.encodeWithSelector(r.result, id, a, signature));
    }

    function fail(bytes32 id, uint8 status, bytes32 reason, uint16 agreed, uint16 answered) external {
        Request memory r = requests[id];
        _deliver(r.target, abi.encodeWithSelector(r.failure, id, status, reason, agreed, answered, bytes("")));
    }

    function _deliver(address target, bytes memory data) internal {
        uint256 before = gasleft();
        (lastDelivered,) = target.call{gas: 200_000}(data);
        lastGasUsed = before - gasleft();
    }
}

/// SwarmDuel's side of the port, as a recorder: it pays for asks and remembers what came back. Its slots start
/// non-zero, so a delivery costs what SwarmDuel's own store will (updating a game word that already exists).
contract StubClient is ISwarmOracleClient {
    SwarmOracle public oracle;
    bytes32 public lastId = bytes32(uint256(1));
    uint16 public lastMove = 1;
    uint8 public lastCause = 1;
    uint256 public calls = 1;

    function setOracle(SwarmOracle o) external {
        oracle = o;
    }

    function ask(SwarmRules.Game calldata g, uint16[] calldata legal, uint256[] calldata history) external returns (bytes32) {
        IERC20(address(oracle.imd())).approve(address(oracle), oracle.price());
        return oracle.ask(g, legal, history);
    }

    function answered(bytes32 id, uint16 move, uint16) external {
        require(msg.sender == address(oracle));
        (lastId, lastMove, lastCause) = (id, move, 0);
        calls++;
    }

    function failed(bytes32 id, uint8 cause) external {
        require(msg.sender == address(oracle));
        (lastId, lastMove, lastCause) = (id, 0, cause);
        calls++;
    }
}

/// SwarmOracle: the ask pays exactly and holds
/// nothing, declines over IMD's limits without paying, hears back only from the Intake for its own pending request,
/// once; every field of the attestation is checked; failures map to the breaker's causes; the callback fits the
/// Intake's 200k; the EIP-712 digest matches a real IMD attestation (71740a16).
contract SwarmOracleTest is Chessboard {
    uint256 constant PK = 0xA11CE;
    uint256 constant PRICE = 0.5 ether;
    SwarmRules sr = new SwarmRules();
    TestIMD imd = new TestIMD();
    MockIntake intake = new MockIntake();
    StubClient client = new StubClient();
    SwarmOracle oracle;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_350_000);
        vm.warp(1_793_400_000);
        oracle = new SwarmOracle(intake, imd, vm.addr(PK), client, sr, PRICE);
        client.setOracle(oracle);
        imd.mint(address(client), 10 ether);
    }

    /// Black to move after 1. e4 (level `level`).
    function opening(uint8 level) internal view returns (SwarmRules.Game memory g, uint16[] memory legal, uint256[] memory history) {
        (g.board, g.white, g.black) = sr.start(level);
        (g.gameNo, g.level) = (1, level);
        uint256[4] memory r;
        (, SwarmRules.Outcome memory o) = sr.play(g, r, mv("e2", "e4"));
        (g.board, g.white, g.black, g.quiet, g.ply) = (o.board, o.white, o.black, o.quiet, 1);
        legal = sr.legalMoves(g.board, g.white, g.black, true);
        history = new uint256[](1);
        history[0] = mv("e2", "e4");
    }

    function askOpening() internal returns (bytes32 id) {
        (SwarmRules.Game memory g, uint16[] memory legal, uint256[] memory history) = opening(0);
        id = client.ask(g, legal, history);
    }

    function ascii(string memory s) internal pure returns (bytes32 x) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; i++) x |= bytes32(b[i]) >> (i * 8);
    }

    function attestation(bytes32 id, string memory move) internal view returns (Attestation memory a) {
        a.requestId = bytes16(0x775fba6258c1402ea9b7f186c9371350);
        a.chainId = 1;
        a.questionHash = oracle.pending(id);
        a.answerType = 2;
        a.answer = abi.encode(ascii(move));
        (a.fromBlock, a.toBlock, a.blockHash) = (26_349_994, 26_349_994, keccak256("block"));
        a.panelJobId = bytes16(0xb036b976e6714d10a298bae8a37d803b);
        (a.panelSize, a.quorum, a.agreed) = (7, 3, 3);
        (a.issuedAt, a.expiresAt) = (uint64(block.timestamp), uint64(block.timestamp + 1 days));
    }

    function sign(Attestation memory a, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, oracle.digest(a));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- asking

    function test_askPaysExactlyAndHoldsNothing() public {
        uint256 before = imd.balanceOf(address(client));
        bytes32 id = askOpening();
        assertEq(imd.balanceOf(address(intake)), PRICE, "the intake got the price");
        assertEq(before - imd.balanceOf(address(client)), PRICE, "the client paid the price");
        assertEq(imd.balanceOf(address(oracle)), 0, "nothing held");
        assertEq(imd.allowance(address(oracle), address(intake)), 0, "no allowance left");
        assertEq(imd.allowance(address(client), address(oracle)), 0, "the client's approval used up");
        assertTrue(oracle.pending(id) != 0, "pending with its question hash");
        assertEq(intake.lastAction(), bytes32("oracle.request@oracle-1"));
        assertEq(oracle.asks((uint256(1) << 16) | 1), id, "the full Intake id kept by its turn, where IMD finds the panel");
    }

    function test_theFullIdOutlivesTheAnswer() public {
        bytes32 id = askOpening();
        Attestation memory a = attestation(id, "e7e5");
        intake.complete(id, a, sign(a, PK));
        assertEq(oracle.pending(id), 0, "settled");
        assertEq(oracle.asks((uint256(1) << 16) | 1), id, "still readable");
    }

    function test_onlyTheClientAsks() public {
        (SwarmRules.Game memory g, uint16[] memory legal, uint256[] memory history) = opening(0);
        vm.expectRevert(SwarmOracle.NotClient.selector);
        oracle.ask(g, legal, history);
    }

    function test_declinesPastIMDsLimitsWithoutPaying() public {
        // Black with 218 legal moves: the body passes 16 KiB (test/swarm/SwarmText.t.sol)
        uint256 b;
        string[9] memory queens = ["d2", "b3", "g3", "e4", "c5", "h5", "a6", "f6", "d7"];
        for (uint256 i; i < 9; i++) b = put(b, queens[i], 13);
        b = put(put(put(put(put(put(put(b, "a1", 12), "h1", 12), "b8", 10), "g8", 10), "c8", 11), "d8", 11), "f8", 14);
        b = put(put(put(b, "a8", 6), "a7", 1), "b7", 1);
        SwarmRules.Game memory g;
        (g.board, g.white, g.black, g.ply, g.gameNo) = (b, side("a8"), side("f8"), 1, 1);
        uint16[] memory legal = sr.legalMoves(b, g.white, g.black, true);
        uint256 before = imd.balanceOf(address(client));
        vm.expectRevert(SwarmOracle.Declined.selector);
        client.ask(g, legal, new uint256[](1));
        assertEq(imd.balanceOf(address(client)), before, "nothing paid");
        vm.expectRevert(SwarmOracle.Declined.selector);
        client.ask(g, new uint16[](0), new uint256[](1));
    }

    function test_anOnChainRefusalRevertsTheAsk() public {
        intake.setRefuse(true);
        (SwarmRules.Game memory g, uint16[] memory legal, uint256[] memory history) = opening(0);
        uint256 before = imd.balanceOf(address(client));
        vm.expectRevert(MockIntake.PriceNotMet.selector);
        client.ask(g, legal, history);
        assertEq(imd.balanceOf(address(client)), before, "nothing paid");
    }

    /// The heaviest ask a game makes: ply 199, every half-move written as a promotion, a middlegame-sized legal list.
    function test_askGasBudgets() public {
        (SwarmRules.Game memory g, uint16[] memory legal,) = opening(4);
        uint256[] memory history = new uint256[](13);
        uint256 promotion = (uint256(mv("a7", "a8")) | 4096);
        for (uint256 i; i < 199; i++) history[i >> 4] |= promotion << ((i & 15) << 4);
        g.ply = 199;
        uint256 gasBefore = gasleft();
        client.ask(g, legal, history);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("ask at ply 199 with odds, our side (mock intake)", used);
        assertLt(used, 750_000, "the ask's budget, before the real Intake's own storage");
    }

    function test_oddsGamesAskToo() public {
        (SwarmRules.Game memory g, uint16[] memory legal, uint256[] memory history) = opening(4);
        uint256 gasBefore = gasleft();
        client.ask(g, legal, history);
        emit log_named_uint("ask at ply 1 with odds, our side (mock intake)", gasBefore - gasleft());
        assertGt(intake.lastBodyLength(), 2_000);
    }

    // ---------------------------------------------------------------- hearing back

    function test_aSignedAnswerReachesTheClientOnce() public {
        bytes32 id = askOpening();
        Attestation memory a = attestation(id, "e7e5");
        bytes memory sig = sign(a, PK);
        intake.complete(id, a, sig);
        assertTrue(intake.lastDelivered(), "delivered within 200k");
        emit log_named_uint("callback chain gas", intake.lastGasUsed());
        assertLt(intake.lastGasUsed(), 100_000, "the chain's budget");
        assertEq(client.lastId(), id);
        assertEq(client.lastMove(), mv("e7", "e5"));
        assertEq(client.calls(), 2);
        assertEq(oracle.pending(id), 0, "settled");
        intake.complete(id, a, sig); // delivered again: ignored
        assertEq(client.calls(), 2);
    }

    function test_onlyTheIntake() public {
        bytes32 id = askOpening();
        Attestation memory a = attestation(id, "e7e5");
        bytes memory sig = sign(a, PK);
        vm.expectRevert(SwarmOracle.NotIntake.selector);
        oracle.onOracleResult(id, a, sig);
        vm.expectRevert(SwarmOracle.NotIntake.selector);
        oracle.onFailure(id, 2, "disagreed", 2, 7, "");
    }

    function test_anotherRequestsAnswerIsIgnored() public {
        bytes32 id = askOpening();
        Attestation memory a = attestation(id, "e7e5");
        bytes memory sig = sign(a, PK);
        // someone else paid for the same question: its request id was never ours
        vm.prank(address(intake));
        oracle.onOracleResult(bytes32(uint256(999)), a, sig);
        assertEq(client.calls(), 1, "nothing delivered");
        assertTrue(oracle.pending(id) != 0, "ours still pending");
    }

    /// Every field the adapter checks, one at a time: each rejection reaches the client as INVALID, once.
    function test_everyCheckRejects() public {
        for (uint256 k; k < 13; k++) {
            bytes32 id = askOpening();
            Attestation memory a = attestation(id, "e7e5");
            uint256 pk = PK;
            if (k == 0) pk = 0xB0B; // another signer
            if (k == 1) a.questionHash = keccak256("another question");
            if (k == 2) a.answerType = 3;
            if (k == 3) a.answer = abi.encode(ascii("e7e5"), uint256(0));
            if (k == 4) a.panelSize = 8;
            if (k == 5) a.quorum = 2;
            if (k == 6) a.agreed = 2;
            if (k == 7) a.expiresAt = uint64(block.timestamp - 1);
            if (k == 8) a.answer = abi.encode(ascii("E7E5"));
            if (k == 9) a.answer = abi.encode(ascii("e7e5x"));
            if (k == 10) a.answer = abi.encode(ascii("e9e5"));
            if (k == 11) a.answer = abi.encode(ascii("e7e5") | bytes32(uint256(1)));
            bytes memory sig = sign(a, pk);
            if (k == 12) sig = abi.encodePacked(sig, uint8(0)); // 66 bytes
            intake.complete(id, a, sig);
            assertEq(client.lastCause(), SwarmCause.INVALID, vm.toString(k));
            assertEq(client.lastId(), id);
            assertEq(oracle.pending(id), 0);
        }
        assertEq(client.calls(), 14);
    }

    function test_failuresMapToCauses() public {
        // only IMD's "disagreed" (its panel short of the quorum) is a split; "blocked", and IMD's own failures even after
        // some seats answered ("cancelled", "failed"), count like a refusal, as do status 1 and any status IMD doesn't name
        uint8[6] memory status = [1, 2, 2, 2, 2, 9];
        bytes32[6] memory reason = [bytes32("refused"), "disagreed", "blocked", "cancelled", "failed", "disagreed"];
        uint16[6] memory answered = [uint16(7), 7, 0, 2, 1, 7];
        uint8[6] memory cause = [SwarmCause.REFUSED, SwarmCause.SPLIT, SwarmCause.REFUSED, SwarmCause.REFUSED, SwarmCause.REFUSED, SwarmCause.REFUSED];
        for (uint256 i; i < 6; i++) {
            bytes32 id = askOpening();
            intake.fail(id, status[i], reason[i], 2, answered[i]);
            assertTrue(intake.lastDelivered());
            assertEq(client.lastCause(), cause[i]);
            assertEq(oracle.pending(id), 0);
            intake.fail(id, status[i], reason[i], 2, answered[i]); // again: ignored
            assertEq(client.calls(), i + 2);
        }
    }

    function test_promotionAndCastlingDecode() public view {
        (bool ok, uint16 m) = oracle.decode(ascii("a2a1q"));
        assertTrue(ok);
        assertEq(m, mv("a2", "a1"), "the q needs no bit: always a queen");
        (ok, m) = oracle.decode(ascii("e8g8"));
        assertTrue(ok);
        assertEq(m, mv("e8", "g8"));
        (ok,) = oracle.decode(ascii("a2a1r"));
        assertFalse(ok, "only a queen");
    }

    // ---------------------------------------------------------------- the real thing

    /// IMD's attestation 71740a16 (knowledge-base/raw/2026-11-04/oracle_detail/), signed for 0x7f53...faa on chain 1:
    /// with the adapter's code at that address, its digest recovers IMD's attester.
    function test_digestMatchesARealAttestation() public {
        address at = 0x7F53FA1543c682bb5DE3f50c2Cf3D1842Ae57faA;
        deployCodeTo("SwarmOracle.sol:SwarmOracle", abi.encode(intake, imd, address(1), client, sr, PRICE), at);
        Attestation memory a;
        a.requestId = bytes16(0x71740a16b7d34c628492cf32e9bbecc1);
        a.chainId = 1;
        a.questionHash = 0xd7a19bbd90e60bb9483083889a99ebb0ed512792a149c765d2e0528388ff6485;
        a.answerType = 0; // bool
        a.answer = abi.encode(true);
        (a.fromBlock, a.toBlock) = (26_305_989, 26_306_289);
        a.blockHash = 0x6fc247804a50906601b2d50086d31c39235566674e487c6642829edc2c0dde25;
        a.panelJobId = bytes16(0xb036b976e6714d10a298bae8a37d803b);
        (a.panelSize, a.quorum, a.agreed) = (15, 11, 11);
        (a.issuedAt, a.expiresAt) = (1_793_372_346, 1_793_458_746);
        bytes memory sig = hex"30dd7bb59d32af6cb09be614f356ec5823106bc56ee1303a594d6962bc6458380254f7a7ed8845a875989e51f4c90fed484bfac2292a8d5435dcdbe7eb955c301b";
        bytes32 d = SwarmOracle(at).digest(a);
        (bytes32 r, bytes32 s) = (bytes32(_slice(sig, 0)), bytes32(_slice(sig, 32)));
        assertEq(ecrecover(d, uint8(sig[64]), r, s), 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982, "IMD's attester");
    }

    function _slice(bytes memory b, uint256 at) internal pure returns (uint256 x) {
        assembly ("memory-safe") {
            x := mload(add(add(b, 32), at))
        }
    }
}
