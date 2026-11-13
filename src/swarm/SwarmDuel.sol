// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SwarmCast} from "./SwarmCast.sol";
import {Chess} from "../Chess.sol";
import {IChessEngine} from "../IChessEngine.sol";
import {IMainDuelBuyer, ISwarmVault} from "../IMainDuelBuyer.sol";
import {GuardedCall} from "./GuardedCall.sol";
import {ISwarmOracle, ISwarmOracleClient, SwarmCause} from "./ISwarmOracle.sol";
import {PositionRing} from "./PositionRing.sol";
import {SwarmLedger} from "./SwarmLedger.sol";
import {SwarmRules} from "./SwarmRules.sol";

/// Swarm Duel: humans (White) against the IMD swarm (Black), one game at a time. Everything here follows the spec
///, the source of truth; section numbers below are the spec's.
///
/// The turn machine (section 7): deposits with a move lead or buy shares; the 24-hour clock with its last hour; the
/// close plays the humans' move, asks the swarm's adapter and settles the winning bid; the answer is played by the next
/// call; when the swarm gives no move, the engine plays in a later call, its dice from the block after the close.
/// Phases: OPEN, the humans' turn; THINKING, an ask pending; ANSWERED, the swarm's move stored; FALLBACK, the engine's
/// move due. The money is SwarmLedger's; the waiting IMD is bought as $IMDUEL in capped steps (section 5), into one
/// jackpot across games. `askId` and the lead never return to zero, so each turn updates their words (section 10).
contract SwarmDuel is ISwarmOracleClient {
    using SafeERC20 for IERC20;
    using SwarmCast for uint256;

    uint8 internal constant OPEN = 0;
    uint8 internal constant THINKING = 1;
    uint8 internal constant ANSWERED = 2;
    uint8 internal constant FALLBACK = 3;

    // who played a move (Moved)
    uint8 internal constant BY_HUMANS = 0;
    uint8 internal constant BY_SWARM = 1;
    uint8 internal constant BY_ENGINE = 2;
    uint8 internal constant BY_PICK = 3;
    uint8 internal constant BY_FORCE = 4;

    uint256 public constant TURN = 24 hours;
    uint256 public constant LAST_HOUR = 1 hours;
    uint256 public constant ANSWER_TIME = 1 hours;
    uint256 public constant NOTICE = 3 days;
    uint256 public constant MIN_BID = 2 ether;
    uint256 public constant PRICE_CAP = 0.777 ether;
    uint256 public constant RAISE_PCT = 10;
    uint8 public constant BREAKER = 3;
    uint8 public constant PROBE_EVERY = 8;
    uint256 public constant ODDS_MOVES = 30; // one more piece per 30 humans' moves since the humans last won
    uint8 public constant MAX_LEVEL = 4;
    uint16 public constant NO_MOVE = 0; // a1a1: never legal
    uint256 internal constant ASK_GAS = 3_000_000; // a cap for Glamsterdam's state gas (section 10)
    uint256 internal constant ENGINE_GAS = 3_000_000;
    uint256 internal constant RESERVE = 400_000;
    uint256 internal constant ENGINE_STRENGTH = 10_000;
    bytes32 internal constant ASKING = bytes32(type(uint256).max);
    bytes32 internal constant NO_ASK = bytes32(uint256(1));
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935; // EIP-2935 block hashes

    struct Game {
        uint256 board;
        uint32 white;
        uint32 black;
        uint32 gameNo;
        uint16 ply;
        uint16 quiet;
        uint8 level;
        uint8 phase;
        uint8 failures;
        uint8 sinceTrip;
        uint16 answer;
        uint40 turnStart;
        uint40 deadline;
    }

    struct Ask {
        ISwarmOracle oracle;
        uint40 askedAt;
        uint40 knownAt;
        uint16 agreed; // how many of the panel gave the answer
    }


    struct Lead {
        uint64 id;
        uint128 amount;
        uint16 move;
        uint8 set; // 1 at every write: the word never returns to zero
    }

    struct Stats {
        uint32 movesSinceWin; // humans' moves since the humans last won: the odds
        uint32 swarmMoves;
        uint32 engineMoves; // the seeded pick included
        uint48 closeBlock; // the last close: the engine's dice come from the block after it
    }

    IERC20 public immutable imd;
    IERC20 public immutable imduel;
    SwarmRules public immutable rules;
    IChessEngine public immutable engine;
    IMainDuelBuyer public immutable buyer;
    address public immutable vault;
    address public immutable team;
    /// No deposit before this time (user, 2026-11-13: deployed and opened early, announced with a countdown).
    uint256 public immutable launchAt;

    Game public game;
    Ask public asked;
    bytes32 public askId;
    Lead public lead;
    Stats public stats;
    uint256[4] internal ring;
    mapping(uint256 gameNo => uint256[13]) internal history; // every game's moves, sixteen to a word
    /// The record of each swarm turn, for readers (no rule reads it): one word by `gameNo << 16 | Black's ply`. From
    /// the low bits: Black's move as played (16), who played it (8: BY_SWARM, BY_ENGINE, BY_PICK or BY_FORCE), why the
    /// swarm didn't (8: SwarmCause, zero if it did or wasn't asked), how many of the panel gave the move (16, a swarm
    /// move only), when the humans' turn closed (40: the ask, if any, was sent then), when the answer or the failure
    /// came (40), the ask's id (128: the first sixteen bytes of the Intake's request id, kept whole by the adapter's
    /// `asks`; zero if the swarm wasn't asked).
    mapping(uint256 => uint256) public turns;
    mapping(uint256 => SwarmLedger.Position) public positions;
    uint256 public positionCount;
    mapping(uint256 => SwarmLedger.Book) internal books;
    mapping(uint256 => uint256) public prizes; // a winning move's prize ($IMDUEL)
    mapping(address => uint256) public players; // counts for badges (section 9)
    mapping(uint256 => address) public referrerOf; // a leading bid's referrer, until its IMD is split (outbid or won)
    mapping(address => uint256) public referrals; // IMD owed to each referrer: 3% of every split of what it referred
    SwarmLedger.Money public money;

    ISwarmOracle public oracle;
    uint96 public oraclePrice;
    ISwarmOracle public nextOracle;
    uint96 public nextPrice;
    address public deployer;
    uint64 public nextAt;
    bool public opened;

    event GameStarted(uint32 indexed gameNo, uint8 level, address oracle);
    event Deposited(
        uint256 indexed id,
        uint32 indexed gameNo,
        uint16 ply,
        address indexed owner,
        uint256 amount,
        uint16 move,
        bool leads,
        uint256 shares
    );
    event Converted(uint256 indexed id, uint256 amount, uint256 shares);
    event Referrer(uint256 indexed id, address indexed referrer); // a deposit came through `referrer`'s link
    event ReferralClaimed(address indexed referrer, uint256 amount);
    event Settled(uint32 indexed gameNo, uint16 ply, uint256 id, uint256 paid, uint256 askPaid, uint256 prize);
    event Moved(uint32 indexed gameNo, uint16 ply, uint16 move, uint8 by);
    event Asked(uint32 indexed gameNo, uint16 ply, bytes32 id, address oracle);
    event Answered(uint32 indexed gameNo, uint16 ply, uint16 move);
    event Fallback(uint32 indexed gameNo, uint16 ply, uint8 cause);
    event GameOver(uint32 indexed gameNo, uint8 result, uint8 reason, uint16 plies, uint256 perMove, uint256 jackpot);
    event OracleProposed(address oracle, uint256 price, uint64 at);
    event OracleNamed(address oracle, uint256 price);
    event Renounced();

    error NotOpen();
    error AlreadyOpen();
    error TooSmall();
    error IllegalMove();
    error Due();
    error Thinking();
    error NothingDue();
    error NotDeployer();
    error BadOracle();
    error BadSetup();
    error Locked();

    /// Section 12: the live contracts, checked; no game opens before `open`.
    constructor(
        IERC20 imd_,
        IERC20 imduel_,
        SwarmRules rules_,
        IChessEngine engine_,
        IMainDuelBuyer buyer_,
        address vault_,
        address team_,
        address deployer_,
        uint256 launchAt_
    ) {
        if (
            team_ == address(0) || deployer_ == address(0) || address(imd_).code.length == 0
                || address(imduel_).code.length == 0 || address(rules_).code.length == 0
                || address(engine_).code.length == 0 || address(buyer_).code.length == 0 || vault_.code.length == 0
                || buyer_.imd() != address(imd_) || buyer_.imduel() != address(imduel_)
                || ISwarmVault(vault_).asset() != address(imduel_) || rules_.MAX_LEVEL() != MAX_LEVEL
                || launchAt_ > block.timestamp + 30 days // a launch time in milliseconds, or a year off, would lock it for good
        ) revert BadSetup();
        (imd, imduel, rules, engine, buyer, vault, team, deployer, launchAt) =
            (imd_, imduel_, rules_, engine_, buyer_, vault_, team_, deployer_, launchAt_);
        askId = NO_ASK; // both words written at deploy, so every later write is an update (section 10)
        _clearLead();
    }

    /// One entry at a time (a transient lock).
    modifier nonReentrant() {
        if (_locked()) revert Locked();
        assembly ("memory-safe") {
            tstore(0, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(0, 0)
        }
    }

    // ---------------------------------------------------------------- section 6: the entry points

    /// Names the first adapter and opens game 1 (the deployer, once).
    function open(ISwarmOracle first) external nonReentrant {
        if (msg.sender != deployer) revert NotDeployer();
        if (opened) revert AlreadyOpen();
        uint96 price = _priceOf(first);
        (oracle, oraclePrice, opened) = (first, price, true);
        emit OracleNamed(address(first), price);
        _startGame(1, 0);
    }

    /// Puts `amount` IMD in, with `move` for White or NO_MOVE, after playing what is due on the swarm's side: a move
    /// that leads waits in escrow for the close (the bid it outbids buys shares now); anything else buys shares now.
    /// `referrer` (none: the zero address) earns 3% of each split of it, from the jackpot's part; wallets are free, so
    /// referring oneself is allowed and is the same rebate for anyone. Then one capped buy of the waiting IMD.
    function deposit(uint256 amount, uint16 move, address referrer) external nonReentrant returns (uint256 id) {
        if (!opened || block.timestamp < launchAt) revert NotOpen();
        if (amount == 0 || (move != NO_MOVE && amount < MIN_BID)) revert TooSmall();
        Game storage g = game;
        _catchUp(g);
        uint8 phase = g.phase;
        if (phase == THINKING) revert Thinking();
        Lead memory l = lead;
        if (phase == FALLBACK || (l.id != 0 && block.timestamp >= g.deadline)) revert Due();
        if (move != NO_MOVE && !rules.isLegal(g.board, g.white, g.black, false, move)) revert IllegalMove();
        imd.safeTransferFrom(msg.sender, address(this), amount);
        id = ++positionCount;
        if (referrer == address(this)) referrer = address(0);
        if (referrer != address(0)) emit Referrer(id, referrer);
        SwarmLedger.Position storage p = positions[id];
        (p.owner, p.amount) = (msg.sender, amount.toUint96()); // checked (section 1): escrow and refunds rely on it
        if (move != NO_MOVE) p.move = move;
        bool leads = move != NO_MOVE && (l.id == 0 || amount * 100 > uint256(l.amount) * (100 + RAISE_PCT));
        uint256 n;
        if (leads) {
            (money.escrow, p.gameNo, p.ply, p.kind) = (uint96(amount), g.gameNo, g.ply, SwarmLedger.BID);
            if (referrer != address(0)) referrerOf[id] = referrer; // read when its IMD is split
            if (l.id != 0) emit Converted(l.id, l.amount, _shares(g, l.id, l.amount, _takeReferrer(l.id)));
            lead = Lead(uint64(id), uint128(amount), move, 1);
            _clockOnLead(g);
        } else {
            n = _shares(g, id, amount, referrer);
        }
        emit Deposited(id, g.gameNo, g.ply, msg.sender, amount, move, leads, n);
        _buy(false);
    }

    /// Does what is due, one step (section 6), then one capped buy.
    function advance() external nonReentrant {
        Game storage g = game;
        if (!_catchUp(g) && !_closeIfDue(g)) revert NothingDue();
        _buy(false);
    }

    /// One capped buy of the waiting IMD for the caller, who owns its main-duel move.
    function buy() external nonReentrant {
        _buy(true);
    }

    /// Pays the caller's positions: dividends and refunds in IMD, prizes and human-win parts in $IMDUEL. A turn that is
    /// due closes first (user, 2026-11-13): a winning bid's claim plays its move and pays it in one call, and any claim
    /// moves the game on.
    function claim(uint256[] calldata ids) external nonReentrant returns (uint256 imdTotal, uint256 imduelTotal) {
        _closeIfDue(game);
        return SwarmLedger.claimAll(books, positions, prizes, money, ids, imd, imduel);
    }

    /// Pays the IMD the caller earned as a referrer (its own claim, so the page's Referrals card claims only its own).
    function claimReferrals() external nonReentrant returns (uint256 earned) {
        earned = referrals[msg.sender];
        if (earned == 0) return 0;
        (referrals[msg.sender], money.referrals) = (0, money.referrals - uint96(earned)); // cleared before the transfer
        imd.safeTransfer(msg.sender, earned);
        emit ReferralClaimed(msg.sender, earned);
    }

    /// @inheritdoc ISwarmOracleClient
    function answered(bytes32 id, uint16 move, uint16 agreed) external {
        Game storage g = game;
        if (!_isPending(g, id)) return;
        (g.answer, g.phase, g.failures, g.sinceTrip) = (move, ANSWERED, 0, 0);
        (asked.knownAt, asked.agreed) = (uint40(block.timestamp), agreed);
        askId = NO_ASK;
        emit Answered(g.gameNo, g.ply, move);
    }

    /// @inheritdoc ISwarmOracleClient
    function failed(bytes32 id, uint8 cause) external {
        Game storage g = game;
        if (_isPending(g, id)) _fail(g, cause);
    }

    /// Proposes the adapter for games that start 3 days from now (the deployer); the current one cancels.
    function propose(ISwarmOracle next) external {
        if (msg.sender != deployer) revert NotDeployer();
        uint96 price = _priceOf(next);
        if (next == oracle) {
            (nextOracle, nextPrice, nextAt) = (ISwarmOracle(address(0)), 0, 0);
            emit OracleProposed(address(next), 0, 0);
            return;
        }
        (nextOracle, nextPrice, nextAt) = (next, price, uint64(block.timestamp + NOTICE));
        emit OracleProposed(address(next), price, nextAt);
    }

    /// Gives the power to name adapters up for good.
    function renounce() external {
        if (msg.sender != deployer) revert NotDeployer();
        (deployer, nextOracle, nextPrice, nextAt) = (address(0), ISwarmOracle(address(0)), 0, 0);
        emit Renounced();
    }

    // ---------------------------------------------------------------- views

    /// The IMD waiting to be bought (the jackpot's and the stakers'): all IMD held that nobody is owed.
    function waiting() external view returns (uint256) {
        return SwarmLedger.waiting(money, imd);
    }

    /// What position `id` can claim now: dividends and refund (IMD), prize and human-win part ($IMDUEL).
    function owed(uint256 id) external view returns (uint256 dividends, uint256 refund, uint256 prize, uint256 part) {
        SwarmLedger.Position storage p = positions[id];
        return SwarmLedger.owed(books[p.gameNo], p, prizes[id]);
    }

    /// The jackpot: the $IMDUEL held that isn't owed as prizes.
    function jackpot() external view returns (uint256) {
        return SwarmLedger.jackpot(money, imduel);
    }

    /// The shares `x` IMD would buy now.
    function quote(uint256 x) external view returns (uint256) {
        return SwarmLedger.quote(books[game.gameNo], x, game.ply);
    }

    function book(uint256 gameNo) external view returns (SwarmLedger.Book memory) {
        return books[gameNo];
    }

    /// Game `gameNo`'s moves, sixteen to a word (bits 0-11 the move, bit 12 a promotion; zero: not played).
    function historyWords(uint256 gameNo) external view returns (uint256[13] memory) {
        return history[gameNo];
    }

    function recentPositions() external view returns (uint256[4] memory) {
        return ring;
    }

    // ---------------------------------------------------------------- section 7: the turn machine

    /// The swarm's side, if a step is due there: the stored answer (an illegal one is the failure, then the engine if
    /// its dice are known), an ask past its hour (the failure, then the engine the same way), or the engine's move
    /// once its dice are known. Returns whether it took a step.
    function _catchUp(Game storage g) internal returns (bool) {
        uint8 phase = g.phase;
        if (phase == ANSWERED) {
            if (!_playAnswer(g)) _engineWhenKnown(g);
        } else if (phase == THINKING && block.timestamp > asked.askedAt + ANSWER_TIME) {
            _fail(g, SwarmCause.LATE);
            _engineWhenKnown(g);
        } else if (phase == FALLBACK && block.number >= uint256(stats.closeBlock) + 2) {
            _engineMove(g);
        } else {
            return false;
        }
        return true;
    }

    /// Closes the humans' turn if it is due: open, with a lead, its deadline passed. Returns whether it did.
    function _closeIfDue(Game storage g) internal returns (bool due) {
        due = g.phase == OPEN && lead.id != 0 && block.timestamp >= g.deadline;
        if (due) _close(g);
    }

    /// Closes the humans' turn: the payment and refund recorded, the move played; the game ends, or a forced move, or
    /// the ask; the winner settled with what the ask took; the engine's move left for a later call.
    function _close(Game storage g) internal {
        Lead memory l = lead;
        _clearLead();
        address referrer = _takeReferrer(l.id);
        (stats.closeBlock, stats.movesSinceWin) = (uint48(block.number), stats.movesSinceWin + 1);
        uint256 board = g.board;
        SwarmLedger.Close memory c = SwarmLedger.Close({
            id: l.id,
            gameNo: g.gameNo,
            ply: g.ply,
            piece: Chess.typeAt(board, l.move >> 6),
            queen: Chess.typeAt(board, l.move & 63) == 5,
            mate: false,
            bid: l.amount,
            paid: SwarmLedger.pay(l.amount),
            cost: 0,
            referred: referrer != address(0)
        });
        (money.escrow, money.refunds) = (0, money.refunds + uint96(l.amount - c.paid));
        (, uint8 result, uint8 reason) = _apply(g, l.move, BY_HUMANS);
        if (result != 0) {
            c.mate = result == 1;
            _settle(c, referrer);
            return _end(g, result, reason);
        }
        turns[_turn(g, g.ply)] = uint256(uint40(block.timestamp)) << 48; // the record: the swarm's turn starts now
        uint16[] memory legal = rules.legalMoves(g.board, g.white, g.black, true);
        if (legal.length == 1) {
            _settle(c, referrer);
            (, uint8 forced, uint8 why) = _apply(g, legal[0], BY_FORCE);
            return _after(g, forced, why, block.timestamp);
        }
        bool asking = _mayAsk(g);
        bool thinking;
        if (asking) (thinking, c.cost) = _ask(g, legal);
        _settle(c, referrer);
        if (thinking) return;
        if (asking) _fail(g, SwarmCause.DECLINED);
        else g.phase = FALLBACK;
    }

    /// The breaker: an adapter is named and asks haven't failed three times in a row, or seven turns have gone by
    /// without an ask since (the 8th asks).
    function _mayAsk(Game storage g) internal returns (bool) {
        if (address(oracle) == address(0)) return false;
        if (g.failures < BREAKER) return true;
        if (++g.sinceTrip < PROBE_EVERY) return false;
        g.sinceTrip = 0;
        return true;
    }

    /// The ask under the gas guard, the adapter approved exactly its stored price; returns whether it succeeded and the
    /// IMD it took.
    function _ask(Game storage g, uint16[] memory legal) internal returns (bool ok, uint256 cost) {
        ISwarmOracle o = oracle;
        g.phase = THINKING;
        askId = ASKING;
        uint256 before = imd.balanceOf(address(this));
        imd.forceApprove(address(o), oraclePrice);
        (bool called, uint256 size, bytes memory ret) = GuardedCall.call(
            address(o), ASK_GAS, RESERVE, abi.encodeCall(ISwarmOracle.ask, (_view(g), legal, _historyWords(g.ply))), 32
        );
        imd.forceApprove(address(o), 0);
        uint256 left = imd.balanceOf(address(this));
        cost = before > left ? before - left : 0; // IMD sent back only waits to be bought
        bytes32 id = called && size == 32 ? abi.decode(ret, (bytes32)) : bytes32(0);
        if (id == 0 || id == ASKING || id == NO_ASK) return (false, cost); // an id that can't be told from none: failed
        ok = true;
        askId = id;
        (asked.oracle, asked.askedAt) = (o, uint40(block.timestamp));
        turns[_turn(g, g.ply)] |= uint256(id) >> 128 << 128;
        emit Asked(g.gameNo, g.ply, id, address(o));
    }

    /// Plays the stored answer; an illegal one is the failure ILLEGAL (false).
    function _playAnswer(Game storage g) internal returns (bool) {
        (bool legal, uint8 result, uint8 reason) = _apply(g, g.answer, BY_SWARM);
        if (!legal) {
            _fail(g, SwarmCause.ILLEGAL);
            return false;
        }
        stats.swarmMoves++;
        _after(g, result, reason, asked.knownAt);
        return true;
    }

    /// The engine's move once its dice are known (two blocks after the close), else left for a later call.
    function _engineWhenKnown(Game storage g) internal {
        if (block.number >= uint256(stats.closeBlock) + 2) _engineMove(g);
    }

    /// The engine's move, its dice from the block after the close; if the engine fails or gives an illegal move, the
    /// seeded pick. The humans' turn opens now.
    function _engineMove(Game storage g) internal {
        askId = NO_ASK;
        uint256 dice = uint256(keccak256(abi.encode(uint256(g.gameNo), uint256(g.ply), _hashAfterClose())));
        (bool ok, uint256 size, bytes memory ret) = GuardedCall.staticcall(
            address(engine),
            ENGINE_GAS,
            RESERVE,
            abi.encodeCall(
                IChessEngine.play,
                (g.board, g.black, g.white, true, ENGINE_STRENGTH, dice, PositionRing.previous(ring, g.ply, g.quiet), g.gameNo, g.quiet)
            ),
            224
        );
        uint256 m = ok && size == 224 ? abi.decode(ret, (uint256)) : 4096;
        (bool legal, uint8 result, uint8 reason) = m < 4096 ? _apply(g, uint16(m), BY_ENGINE) : (false, 0, 0);
        if (!legal) (legal, result, reason) = _apply(g, rules.pick(g.board, g.white, g.black, true, dice), BY_PICK);
        stats.engineMoves++;
        _after(g, result, reason, block.timestamp);
    }

    /// The hash of the block after the last close: `blockhash` within 256 blocks, else EIP-2935's history, else zero,
    /// so the close's own block can't choose the dice once both have forgotten it (round 3's security review).
    function _hashAfterClose() internal view returns (bytes32 h) {
        uint256 n = uint256(stats.closeBlock) + 1;
        if (block.number - n <= 256) return blockhash(n);
        (bool ok, bytes memory out) = HISTORY.staticcall(abi.encode(n));
        if (ok && out.length == 32) h = abi.decode(out, (bytes32));
    }

    /// After the swarm's move: the game ends, or the humans' turn opens at `since`.
    function _after(Game storage g, uint8 result, uint8 reason, uint256 since) internal {
        if (result != 0) _end(g, result, reason);
        else (g.phase, g.turnStart, g.deadline) = (OPEN, uint40(since), uint40(since + TURN));
    }

    /// The one move path: plays `m` through SwarmRules and records it; an illegal `m` changes nothing.
    function _apply(Game storage g, uint16 m, uint8 by) internal returns (bool legal, uint8 result, uint8 reason) {
        uint256 board = g.board;
        SwarmRules.Outcome memory o;
        (legal, o) = rules.play(_view(g), ring, m);
        if (!legal) return (false, 0, 0);
        uint256 to = m & 63;
        uint256 entry = Chess.typeAt(board, m >> 6) == 1 && (to < 8 || to >= 56) ? uint256(m) | 4096 : m;
        uint256 at = g.ply;
        uint256 shift = (at & 15) << 4;
        uint256[13] storage h = history[g.gameNo];
        h[at >> 4] = (h[at >> 4] & ~(uint256(0xffff) << shift)) | (entry << shift);
        if (by != BY_HUMANS) {
            uint256 turn = uint256(m) | (uint256(by) << 16);
            if (by == BY_SWARM) turn |= (uint256(asked.agreed) << 32) | (uint256(asked.knownAt) << 88);
            turns[_turn(g, at)] |= turn;
        }
        (g.board, g.white, g.black, g.quiet) = (o.board, o.white, o.black, o.quiet);
        g.ply = uint16(at + 1);
        ring = o.ring;
        emit Moved(g.gameNo, uint16(at), m, by);
        return (true, o.result, o.reason);
    }

    /// Section 8: a game's first lead starts its turn; a lead in the last hour (or after the deadline) gets an hour.
    function _clockOnLead(Game storage g) internal {
        if (g.turnStart == 0) (g.turnStart, g.deadline) = (uint40(block.timestamp), uint40(block.timestamp + TURN));
        if (block.timestamp + LAST_HOUR > g.deadline) g.deadline = uint40(block.timestamp + LAST_HOUR);
    }

    /// The failure: the engine's move is due; a cause that says the oracle is broken counts toward the breaker.
    function _fail(Game storage g, uint8 cause) internal {
        g.phase = FALLBACK;
        askId = NO_ASK;
        if (cause != SwarmCause.SPLIT && cause != SwarmCause.ILLEGAL && g.failures < type(uint8).max) g.failures++;
        // when the failure came: an illegal answer's arrival, a late one's hour running out, else now
        uint256 at = cause == SwarmCause.ILLEGAL ? asked.knownAt : cause == SwarmCause.LATE ? asked.askedAt + ANSWER_TIME : block.timestamp;
        turns[_turn(g, g.ply)] |= (uint256(cause) << 24) | (uint256(uint40(at)) << 88);
        emit Fallback(g.gameNo, g.ply, cause);
    }

    function _isPending(Game storage g, bytes32 id) internal view returns (bool) {
        return !_locked() && g.phase == THINKING && id == askId && id != ASKING && id != NO_ASK
            && msg.sender == address(asked.oracle)
            && block.timestamp <= asked.askedAt + ANSWER_TIME;
    }

    // ---------------------------------------------------------------- the money (SwarmLedger) and buying (section 5)

    /// Position `id` buys shares with `amount` IMD now (at least one unit); the team's 1% sent, `referrer`'s 3% owed.
    function _shares(Game storage g, uint256 id, uint256 amount, address referrer) internal returns (uint256 n) {
        uint256 toTeam;
        uint256 toRef;
        (n, toTeam, toRef) = SwarmLedger.deposit(books[g.gameNo], money, positions[id], amount, g.gameNo, g.ply, referrer != address(0));
        if (n == 0) revert TooSmall();
        if (toRef != 0) referrals[referrer] += toRef; // owed before anything is sent
        _sendTeam(toTeam);
    }

    /// A leading bid's referrer, forgotten as its IMD is split.
    function _takeReferrer(uint256 id) internal returns (address referrer) {
        referrer = referrerOf[id];
        if (referrer != address(0)) delete referrerOf[id];
    }

    /// Settles the winning bid at its turn's close: its shares, its prize, the turn's dividends, its owner's counts;
    /// `referrer`'s 3% of its payment owed.
    function _settle(SwarmLedger.Close memory c, address referrer) internal {
        uint256 toRef;
        uint256 toTeam;
        uint256 prize;
        (toTeam, prize, toRef) = SwarmLedger.settle(books, money, positions[c.id], players, imduel, c);
        if (prize != 0) prizes[c.id] = prize;
        if (toRef != 0) referrals[referrer] += toRef; // owed before anything is sent
        _sendTeam(toTeam);
        emit Settled(c.gameNo, c.ply, c.id, c.paid, c.cost, prize);
    }

    /// The lead cleared, its word kept non-zero.
    function _clearLead() internal {
        lead = Lead(0, 0, NO_MOVE, 1);
    }

    function _sendTeam(uint256 amount) internal {
        if (amount != 0) imd.safeTransfer(team, amount);
    }

    /// One capped buy (section 5, SwarmLedger.buyStep).
    function _buy(bool required) internal {
        SwarmLedger.buyStep(money, SwarmLedger.Market(imd, imduel, buyer, vault), required);
    }

    // ---------------------------------------------------------------- section 9: endings and new games

    /// The ending: on a human win the jackpot's 80% over the game's played moves; the odds by moves played; the next
    /// game.
    function _end(Game storage g, uint8 result, uint8 reason) internal {
        (uint256 perMove, uint256 left) = SwarmLedger.end(books[g.gameNo], money, result, imduel);
        uint32 since = result == 1 ? 0 : stats.movesSinceWin;
        stats.movesSinceWin = since;
        uint256 level = since / ODDS_MOVES;
        emit GameOver(g.gameNo, result, reason, g.ply, perMove, left);
        _clearLead();
        askId = NO_ASK;
        _startGame(g.gameNo + 1, level < MAX_LEVEL ? uint8(level) : MAX_LEVEL);
    }

    function _startGame(uint32 gameNo, uint8 level) internal {
        Game storage g = game;
        (g.board, g.white, g.black) = rules.start(level);
        (g.gameNo, g.level, g.ply, g.quiet, g.phase, g.answer, g.turnStart, g.deadline) =
            (gameNo, level, 0, 0, OPEN, 0, 0, 0);
        (g.failures, g.sinceTrip) = (0, 0);
        (books[gameNo].shares, books[gameNo].level) = (uint80(SwarmLedger.JACKPOT_SHARES), level);
        uint64 at = nextAt;
        if (at != 0 && block.timestamp >= at) {
            (oracle, oraclePrice) = (nextOracle, nextPrice);
            (nextOracle, nextPrice, nextAt) = (ISwarmOracle(address(0)), 0, 0);
            emit OracleNamed(address(oracle), oraclePrice);
        }
        emit GameStarted(gameNo, level, address(oracle));
    }

    // ---------------------------------------------------------------- helpers

    /// An adapter's price, checked: zero (no adapter) or a contract charging at most PRICE_CAP.
    function _priceOf(ISwarmOracle o) internal view returns (uint96) {
        if (address(o) == address(0)) return 0;
        if (address(o).code.length == 0) revert BadOracle();
        uint256 price = o.price();
        if (price > PRICE_CAP) revert BadOracle();
        return uint96(price);
    }

    function _locked() internal view returns (bool locked) {
        assembly ("memory-safe") {
            locked := tload(0)
        }
    }

    function _view(Game storage g) internal view returns (SwarmRules.Game memory v) {
        (v.board, v.white, v.black, v.ply, v.quiet, v.gameNo, v.level) =
            (g.board, g.white, g.black, g.ply, g.quiet, g.gameNo, g.level);
    }

    /// The key of a swarm turn's record.
    function _turn(Game storage g, uint256 ply) internal view returns (uint256) {
        return (uint256(g.gameNo) << 16) | ply;
    }

    function _historyWords(uint256 ply) internal view returns (uint256[] memory words) {
        words = new uint256[]((ply + 15) >> 4);
        uint256[13] storage h = history[game.gameNo];
        for (uint256 i; i < words.length; i++) words[i] = h[i];
    }
}
