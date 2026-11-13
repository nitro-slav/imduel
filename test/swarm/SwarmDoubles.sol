// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Rules} from "../../src/Rules.sol";
import {IChessEngine} from "../../src/IChessEngine.sol";
import {SwarmRules} from "../../src/swarm/SwarmRules.sol";
import {ISwarmOracle, ISwarmOracleClient} from "../../src/swarm/ISwarmOracle.sol";
import {IMainDuelBuyer, ISwarmVault} from "../../src/IMainDuelBuyer.sol";

/// Test doubles shared by Swarm's suites.

contract TestIMD is ERC20("IMD", "IMD") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TestIMDUEL is ERC20("IMDuel", "IMDUEL") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// The main duel on a script: each buy takes at most `perBuy` IMD (standing in for the one-fee price limit) at `rate`
/// $IMDUEL per IMD (x 1e18), and remembers the owner it was given. Modes: refuse (it reverts), gasHungry (it burns
/// all the gas it is given, as a starved main-duel move would), tip (it sends IMD back inside the buy).
contract MockBuyer is IMainDuelBuyer {
    TestIMD public immutable imdToken;
    TestIMDUEL public immutable imduelToken;
    uint256 public perBuy = 14 ether;
    uint256 public rate = 2e18;
    bool public refuse;
    bool public gasHungry;
    address public lastOwner;
    uint256 public buys;
    uint256 public tip; // IMD it sends back inside a buy
    bool public busy; // as inside someone's own pool-manager unlock: not ready

    constructor(TestIMD imd_, TestIMDUEL imduel_) {
        (imdToken, imduelToken) = (imd_, imduel_);
    }

    function set(uint256 perBuy_, uint256 rate_, bool refuse_, bool gasHungry_) external {
        (perBuy, rate, refuse, gasHungry) = (perBuy_, rate_, refuse_, gasHungry_);
    }

    function setTip(uint256 t) external {
        tip = t;
    }

    function setBusy(bool b) external {
        busy = b;
    }

    function ready() external view returns (bool) {
        return !busy;
    }

    function buy(uint256 maxIn, address owner) external returns (uint256 spent, uint256 out) {
        require(!refuse, "pool down");
        if (gasHungry) while (true) {}
        spent = maxIn < perBuy ? maxIn : perBuy;
        out = spent * rate / 1e18;
        imdToken.transferFrom(msg.sender, address(this), spent);
        if (tip != 0) imdToken.mint(msg.sender, tip);
        imduelToken.mint(msg.sender, out);
        (lastOwner, buys) = (owner, buys + 1);
    }

    function imd() external view returns (address) {
        return address(imdToken);
    }

    function imduel() external view returns (address) {
        return address(imduelToken);
    }
}

/// The staking vault on a script: counts `sync()` calls, or reverts them, or burns all the gas it is given.
contract MockVault is ISwarmVault {
    address public immutable asset;
    uint256 public syncs;
    bool public refuse;
    bool public gasHungry;

    constructor(address asset_) {
        asset = asset_;
    }

    function setRefuse(bool r) external {
        refuse = r;
    }

    function setGasHungry(bool h) external {
        gasHungry = h;
    }

    function sync() external {
        require(!refuse, "vault down");
        if (gasHungry) while (true) {}
        syncs++;
    }
}

/// An adapter on a script: it takes its price like the real one, remembers what it was asked, and answers or fails
/// when the test says (as the Intake's callback would, later). Modes: refuse (the ask reverts), reenter (it calls the
/// client back inside the ask), tip (it sends IMD back inside the ask), idMode (it returns zero or the client's
/// placeholder as its id), gasHungry (it burns all the gas it is given).
contract ScriptedOracle is ISwarmOracle {
    IERC20 public immutable imd;
    ISwarmOracleClient public immutable client;
    uint256 public price;
    uint256 public asks;
    bool public refuse;
    bool public reenter;
    uint256 public tip; // IMD it sends back inside an ask (from its own)
    uint8 public idMode; // 0 a fresh id, 1 zero, 2 all ones (the client's "asking"), 3 one (its "no ask")
    bool public gasHungry; // burns all the gas it is given
    bool public heavy; // needs 1.2M gas to ask (a real adapter writing a long question), then asks
    bool public big; // returns 600 KB instead of an id
    SwarmRules.Game public lastGame;
    uint16[] internal _lastLegal;
    uint256[] internal _lastHistory;

    constructor(IERC20 imd_, ISwarmOracleClient client_, uint256 price_) {
        (imd, client, price) = (imd_, client_, price_);
    }

    function setRefuse(bool r) external {
        refuse = r;
    }

    function setReenter(bool r) external {
        reenter = r;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function setTip(uint256 t) external {
        tip = t;
    }

    function setIdMode(uint8 m) external {
        idMode = m;
    }

    function setGasHungry(bool h) external {
        gasHungry = h;
    }

    function setHeavy(bool h) external {
        heavy = h;
    }

    function setBig(bool b) external {
        big = b;
    }

    function ask(SwarmRules.Game calldata g, uint16[] calldata legal, uint256[] calldata history) external returns (bytes32 id) {
        require(!refuse, "refused");
        if (gasHungry) while (true) {}
        if (big) {
            assembly {
                return(0, 600000)
            }
        }
        if (heavy) {
            uint256 stop = gasleft() - 1_200_000; // too little gas: an underflow, the ask fails
            while (gasleft() > stop) {}
        }
        imd.transferFrom(msg.sender, address(this), price);
        if (tip != 0) imd.transfer(msg.sender, tip);
        id = idMode == 1 ? bytes32(0) : idMode == 2 ? bytes32(type(uint256).max) : idMode == 3 ? bytes32(uint256(1)) : bytes32(++asks + 1);
        (lastGame, _lastLegal, _lastHistory) = (g, legal, history);
        if (reenter) {
            client.answered(id, 0, 0); // the pending id isn't set yet: ignored
            (bool ok,) = address(client).call(abi.encodeWithSignature("advance()"));
            require(!ok, "re-entered");
        }
    }

    function lastLegal() external view returns (uint16[] memory) {
        return _lastLegal;
    }

    function lastHistory() external view returns (uint256[] memory) {
        return _lastHistory;
    }

    function answer(bytes32 id, uint16 move) external {
        client.answered(id, move, 5);
    }

    function fail(bytes32 id, uint8 cause) external {
        client.failed(id, cause);
    }
}

/// The engine on a script: by default the first legal move (SwarmRules' order); or a set move, or a revert, or Black's
/// g-knight out to h6 and back (a reply that never gets in White's way).
contract ScriptedEngine is IChessEngine {
    SwarmRules public immutable rules;
    uint8 public mode; // 0 the first legal move, 1 `move`, 2 revert, 3 the knight shuffle
    uint16 public move;

    constructor(SwarmRules rules_) {
        rules = rules_;
    }

    function set(uint8 mode_, uint16 move_) external {
        (mode, move) = (mode_, move_);
    }

    function play(uint256 board, uint32 mover, uint32 other, bool black, uint256, uint256, uint64[8] calldata, uint32, uint16)
        external
        view
        returns (uint16 m, Rules.Played memory p)
    {
        require(mode != 2, "engine down");
        if (mode == 1) return (move, p);
        if (mode == 3) return ((board >> (62 * 4)) & 15 == 11 ? uint16(62 << 6 | 47) : uint16(47 << 6 | 62), p);
        (uint32 w, uint32 b) = black ? (other, mover) : (mover, other);
        m = rules.legalMoves(board, w, b, black)[0];
    }

    function playAny(uint256, uint32, uint32, bool, uint256) external pure returns (uint16, Rules.Played memory p) {
        return (0, p);
    }
}
