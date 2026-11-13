// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Chessboard} from "../Chessboard.sol";
import {SwarmRules} from "../../src/swarm/SwarmRules.sol";
import {SwarmDuel} from "../../src/swarm/SwarmDuel.sol";
import {SwarmLedger} from "../../src/swarm/SwarmLedger.sol";
import {IMainDuelBuyer} from "../../src/IMainDuelBuyer.sol";
import {TestIMD, TestIMDUEL, MockBuyer, MockVault, ScriptedOracle, ScriptedEngine} from "./SwarmDoubles.sol";

/// The fields of the duel's game the suites read.
struct State {
    uint256 board;
    uint32 white;
    uint32 black;
    uint32 gameNo;
    uint16 ply;
    uint8 level;
    uint8 phase;
    uint8 failures;
    uint8 sinceTrip;
    uint40 turnStart;
    uint40 deadline;
}

function stateOf(SwarmDuel duel) view returns (State memory s) {
    (s.board, s.white, s.black, s.gameNo, s.ply,, s.level, s.phase, s.failures, s.sinceTrip,, s.turnStart, s.deadline) =
        duel.game();
}

/// The UCI move (`e2e4`) at byte `at` of `m`, as the contracts encode moves: from << 6 | to.
function uci(bytes memory m, uint256 at) pure returns (uint16) {
    return (uint16(uint8(m[at]) - 97) + 8 * uint16(uint8(m[at + 1]) - 49)) << 6
        | (uint16(uint8(m[at + 2]) - 97) + 8 * uint16(uint8(m[at + 3]) - 49));
}

/// What Swarm Duel's suites share: an open duel with a scripted adapter, engine, buyer and vault, two players with
/// IMD, and helpers to deposit, close a turn, answer for the swarm and let the engine move.
abstract contract SwarmBase is Chessboard {
    using stdStorage for StdStorage;
    /// The contracts a handler needs, in one argument.
    struct Kit {
        SwarmDuel duel;
        TestIMD imd;
        ScriptedOracle oracle;
        ScriptedEngine engine;
        SwarmRules sr;
        MockBuyer buyer;
        MockVault vault;
    }

    uint256 constant PRICE = 0.5 ether;
    address constant TEAM = address(0x7EA1);
    TestIMD imd = new TestIMD();
    TestIMDUEL imduel = new TestIMDUEL();
    SwarmRules sr = new SwarmRules();
    ScriptedEngine engine = new ScriptedEngine(sr);
    MockBuyer buyer = new MockBuyer(imd, imduel);
    MockVault vault = new MockVault(address(imduel));
    SwarmDuel duel;
    ScriptedOracle oracle;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(30_000_000);
        duel = new SwarmDuel(imd, imduel, sr, engine, IMainDuelBuyer(address(buyer)), address(vault), TEAM, address(this), 0);
        oracle = new ScriptedOracle(imd, duel, PRICE);
        duel.open(oracle);
        for (uint256 i; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            imd.mint(who, 1_000 ether);
            vm.prank(who);
            imd.approve(address(duel), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- helpers

    function st() internal view returns (State memory) {
        return stateOf(duel);
    }

    function u(string memory m) internal pure returns (uint16) {
        return uci(bytes(m), 0);
    }

    function bidAs(address who, uint256 amount, string memory m) internal returns (uint256 id) {
        vm.prank(who);
        id = duel.deposit(amount, u(m), address(0));
    }

    function put(address who, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = duel.deposit(amount, 0, address(0));
    }

    /// The engine's move, once its dice are known (two blocks after the close).
    function engineMoves() internal {
        vm.roll(vm.getBlockNumber() + 2);
        duel.advance();
    }

    /// Bids the humans' move and closes the turn at its deadline.
    function humans(string memory m) internal {
        bidAs(alice, 2 ether, m);
        vm.warp(st().deadline);
        duel.advance();
    }

    /// The swarm answers `m` and the answer is played.
    function swarm(string memory m) internal {
        oracle.answer(duel.askId(), u(m));
        duel.advance();
    }

    /// The duel's money, by name.
    function buckets() internal view returns (SwarmLedger.Money memory k) {
        (k.pending, k.stakersWaiting, k.lastBuyBlock, k.escrow, k.refunds, k.dividends, k.prizes, k.referrals) = duel.money();
    }

    function claimAs(address who, uint256 id) internal returns (uint256 a, uint256 b) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(who);
        return duel.claim(ids);
    }

    function noBuys() internal {
        buyer.set(0, 2e18, false, false);
    }

    function nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// Fool's mate with `who`'s bids: the swarm wins in two humans' moves.
    function foolBy(address who) internal {
        string[4] memory fool = ["f2f3", "e7e5", "g2g4", "d8h4"];
        for (uint256 i; i < 4; i += 2) {
            bidAs(who, 2 ether, fool[i]);
            vm.warp(st().deadline);
            duel.advance();
            swarm(fool[i + 1]);
        }
    }

    function foolsMate() internal {
        foolBy(alice);
    }

    /// White to mate with h5f7 (alice's moves e2e4, f1c4, d1h5 played).
    function toScholarsMate() internal {
        humans("e2e4");
        swarm("e7e5");
        humans("f1c4");
        swarm("b8c6");
        humans("d1h5");
        swarm("g8f6");
    }

    /// Scholar's mate with alice's bids: White wins in four.
    function scholarsMate() internal {
        toScholarsMate();
        humans("h5f7");
    }

    /// The `width`-bit field at `shift` of a players' word.
    function field(uint256 w, uint256 shift, uint256 width) internal pure returns (uint256) {
        return (w >> shift) & ((1 << width) - 1);
    }

    /// Writes `who`'s players' word.
    function setWord(address who, uint256 w) internal {
        stdstore.target(address(duel)).sig("players(address)").with_key(who).checked_write(w);
    }

}
