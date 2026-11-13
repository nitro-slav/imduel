// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMainDuelBuyer} from "../../src/IMainDuelBuyer.sol";
import {SwarmDuel} from "../../src/swarm/SwarmDuel.sol";
import {SwarmOracle} from "../../src/swarm/SwarmOracle.sol";
import {IIntake, Attestation} from "../../src/swarm/IIntake.sol";
import {ISwarmOracleClient, SwarmCause} from "../../src/swarm/ISwarmOracle.sol";
import {SwarmBase, stateOf, State} from "./SwarmBase.sol";

/// An Intake as IMD's docs describe it, with ids that are never SwarmDuel's markers (the suite's MockIntake numbers
/// its ids from 1, which is NO_ASK).
contract AuditIntake is IIntake {
    struct Request {
        address target;
        bytes4 result;
        bytes4 failure;
    }

    mapping(bytes32 => Request) public requests;
    uint256 public count;

    function requestWithFailure(bytes32, bytes calldata, Callback calldata callback, bytes4 onFailure, address asset, uint256 amount)
        external
        returns (bytes32 id)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        id = keccak256(abi.encode(++count));
        requests[id] = Request(callback.target, callback.selector, onFailure);
    }

    function fail(bytes32 id, uint8 status, bytes32 reason, uint16 agreed, uint16 answered) external {
        Request memory r = requests[id];
        (bool ok,) = r.target.call{gas: 200_000}(abi.encodeWithSelector(r.failure, id, status, reason, agreed, answered, bytes("")));
        require(ok, "delivery");
    }
}

/// Records what an adapter tells its client.
contract Recorder is ISwarmOracleClient {
    bytes32 public lastId;
    uint16 public lastMove;
    uint16 public lastAgreed;
    uint8 public lastCause;
    uint256 public calls;

    function answered(bytes32 id, uint16 move, uint16 agreed) external {
        (lastId, lastMove, lastAgreed, lastCause) = (id, move, agreed, 0);
        calls++;
    }

    function failed(bytes32 id, uint8 cause) external {
        (lastId, lastCause) = (id, cause);
        calls++;
    }
}

/// The turns specialist's proofs.
contract AuditTurnsTest is SwarmBase {
    uint256 constant PK = 0xA11CE;

    // ---------------------------------------------------------------- helpers

    /// A fresh duel with the real SwarmOracle on an Intake that reports failures as IMD's docs do.
    function realAdapter() internal returns (SwarmDuel d, SwarmOracle o, AuditIntake k) {
        k = new AuditIntake();
        d = new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(vault), TEAM, address(this), 0);
        o = new SwarmOracle(k, imd, vm.addr(PK), d, sr, PRICE);
        d.open(o);
        vm.prank(alice);
        imd.approve(address(d), type(uint256).max);
        engine.set(3, 0); // Black's g-knight out and back
    }

    function closeOn(SwarmDuel d, string memory m) internal {
        vm.prank(alice);
        d.deposit(2 ether, u(m), address(0));
        vm.warp(stateOf(d).deadline);
        d.advance();
    }

    function engineOn(SwarmDuel d) internal {
        vm.roll(vm.getBlockNumber() + 2);
        d.advance();
    }

    // ---------------------------------------------------------------- finding 1: the cause mapping

    /// IMD's status 2 covers "failed", "cancelled", "deleted", "superseded" and "mismatch" as well as "disagreed"; the
    /// adapter calls every status 2 with at least one valid answer a SPLIT. A job IMD cancels or fails after one seat
    /// answered is then the panel's own choice: never counted, so the breaker never stops paying 0.5 IMD a turn.
    /// Fixed 2026-11-13 (L-1): IMD cancelling a job after one seat answered is IMD's failure, not the panel's split, so it
    /// counts: three trip the breaker and the fourth turn isn't asked (it paid 6 IMD for nothing before the fix).
    function test_aCancelledJobWithOneAnswerCountsTowardTheBreaker() public {
        (SwarmDuel d,, AuditIntake k) = realAdapter();
        string[4] memory w = ["e2e4", "d2d4", "g1f3", "b1c3"];
        for (uint256 i; i < 3; i++) {
            closeOn(d, w[i]);
            assertEq(stateOf(d).phase, 1, "asked");
            k.fail(d.askId(), 2, "cancelled", 1, 1);
            assertEq(stateOf(d).failures, i + 1, "counted");
            uint256 word = d.turns((uint256(1) << 16) | (2 * i + 1));
            assertEq(uint8(word >> 24), SwarmCause.REFUSED, "recorded as a refusal");
            engineOn(d);
        }
        closeOn(d, w[3]);
        assertEq(stateOf(d).phase, 3, "not asked: the breaker is open");
        assertEq(imd.balanceOf(address(k)), 3 * PRICE);
    }

    /// The panel's own split (IMD's "disagreed") still never counts.
    function test_aDisagreedPanelIsASplitAndNeverCounts() public {
        (SwarmDuel d,, AuditIntake k) = realAdapter();
        closeOn(d, "e2e4");
        k.fail(d.askId(), 2, "disagreed", 2, 4);
        assertEq(stateOf(d).failures, 0);
        assertEq(uint8(d.turns((uint256(1) << 16) | 1) >> 24), SwarmCause.SPLIT);
    }

    /// The same failure with no answer at all is a refusal: three trip the breaker and the fourth turn isn't asked.
    function test_theSameFailureWithNoAnswerTripsTheBreaker() public {
        (SwarmDuel d,, AuditIntake k) = realAdapter();
        string[4] memory w = ["e2e4", "d2d4", "g1f3", "b1c3"];
        for (uint256 i; i < 3; i++) {
            closeOn(d, w[i]);
            k.fail(d.askId(), 2, "cancelled", 0, 0);
            engineOn(d);
        }
        assertEq(stateOf(d).failures, 3);
        closeOn(d, w[3]);
        assertEq(stateOf(d).phase, 3, "not asked: the breaker is open");
        assertEq(imd.balanceOf(address(k)), 3 * PRICE);
    }

    // ---------------------------------------------------------------- finding 2: a probe that splits

    /// After a trip, the probe reaches IMD and its panel answers but splits: the oracle works, yet `failures` stays at
    /// 3 (only an answer clears it), so the next seven turns are again not asked.
    function test_aSplitProbeKeepsTheBreakerOpen() public {
        string[19] memory w = [
            "a2a3", "b2b3", "c2c3", "d2d3", "e2e3", "f2f3", "g2g3", "h2h3", "a3a4", "b3b4",
            "c3c4", "d3d4", "e3e4", "f3f4", "h3h4", "a4a5", "b4b5", "c4c5", "d4d5"
        ];
        engine.set(3, 0);
        for (uint256 i; i < 3; i++) {
            humans(w[i]);
            oracle.fail(duel.askId(), SwarmCause.REFUSED);
            engineMoves();
        }
        for (uint256 i = 3; i < 10; i++) {
            humans(w[i]);
            engineMoves();
        }
        uint256 asks = oracle.asks();
        humans(w[10]); // the probe
        assertEq(oracle.asks(), asks + 1, "probed");
        oracle.fail(duel.askId(), SwarmCause.SPLIT); // IMD ran the panel: it is up
        engineMoves();
        assertEq(st().failures, 3, "still tripped");
        for (uint256 i = 11; i < 18; i++) {
            humans(w[i]);
            assertEq(st().phase, 3, "seven more turns without an ask");
            engineMoves();
        }
        assertEq(oracle.asks(), asks + 1);
    }

    // ---------------------------------------------------------------- finding 3: the record's time of a late ask

    /// A late ask's failure time is when someone next called, not the end of the swarm's hour.
    function test_aLateAsksRecordedTimeIsTheHoursEnd() public {
        humans("e2e4");
        (, uint40 askedAt,,) = duel.asked();
        vm.warp(uint256(askedAt) + 30 hours);
        vm.roll(vm.getBlockNumber() + 2);
        duel.advance(); // LATE, then the engine
        uint256 word = duel.turns((uint256(1) << 16) | 1);
        assertEq(uint8(word >> 24), SwarmCause.LATE);
        assertEq(uint40(word >> 88), uint256(askedAt) + 1 hours, "the hour's end, not the poke 29 hours later (fixed 2026-11-13)");
        assertEq(uint40(word >> 48), askedAt, "closedAt");
    }

    // ---------------------------------------------------------------- holds: IMD's real bytes32 answer

    /// The paid test's first answer (IMD request 93e86b4d, 2026-11-13, e7e5 with 4 agreeing), read from
    /// api.imd.fun/oracle/requests/93e86b4d-98a8-4dbd-948a-e9a02e569feb/attestation. It was paid with no callback, so IMD
    /// signed it for verifyingContract 0. With SwarmOracle's code at that address and the question pending,
    /// onOracleResult passes every check of `_check` on IMD's own bytes32 attestation and decodes e7e5.
    function test_imdsRealBytes32AnswerPassesEveryCheck() public {
        vm.chainId(1);
        Recorder rec = new Recorder();
        address at = address(0);
        deployCodeTo("SwarmOracle.sol:SwarmOracle", abi.encode(address(this), imd, 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982, rec, sr, PRICE), at);
        SwarmOracle o = SwarmOracle(at);
        Attestation memory a;
        a.requestId = bytes32(bytes16(0x93e86b4d98a84dbd948ae9a02e569feb));
        a.chainId = 1;
        a.questionHash = 0x260b8b3ef5225ff571e1c0f043a90566137b75ea535d6caf86ac3e2e08be1c65;
        a.answerType = 2;
        a.answer = abi.encode(bytes32(0x6537653500000000000000000000000000000000000000000000000000000000));
        (a.fromBlock, a.toBlock) = (26_405_062, 26_405_062);
        a.blockHash = 0x6a1c1ba57241d3a2eb6f36ed3aa70c98066c0c5172873f0d6e8d86297d50bdc3;
        a.panelJobId = bytes32(bytes16(0x35300d62e1114addbbf42b43b973f191));
        (a.panelSize, a.quorum, a.agreed) = (7, 3, 4);
        (a.issuedAt, a.expiresAt) = (1_794_561_342, 1_794_647_742);
        bytes memory sig =
            hex"04bcb2509de01016de33d7f745c6c2cf637a6449517560cf52678c10e62a1d92110d4d62633e3826106dce0e78575ad37ea31d666306b8c2d7a77b59675c48ae1c";
        // the Intake's id for that payment, pending with IMD's question hash (slot 0: `pending`)
        bytes32 id = 0x040a6d9deff5b3d39142c8d3c1e82d051f92cb9ad25fc18324161130d8c98bbf;
        vm.store(at, keccak256(abi.encode(id, uint256(0))), a.questionHash);
        assertEq(o.pending(id), a.questionHash);
        vm.warp(1_794_561_400);
        o.onOracleResult(id, a, sig); // this test is the adapter's Intake
        assertEq(rec.calls(), 1);
        assertEq(rec.lastCause(), 0, "accepted, not INVALID");
        assertEq(rec.lastMove(), u("e7e5"));
        assertEq(rec.lastAgreed(), 4);
        assertEq(o.pending(id), 0);
    }
}
