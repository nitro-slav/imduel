// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {wadLn} from "solmate/src/utils/SignedWadMath.sol";
import {SwarmCast} from "./SwarmCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMainDuelBuyer, ISwarmVault} from "../IMainDuelBuyer.sol";

/// Swarm Duel's money, exactly as the spec defines it: a library of external functions
/// SwarmDuel calls on its own storage (delegatecall), so the game and the money keep their own bytecode. Besides
/// the bookkeeping it runs the two paths that only move tokens (a buy, a claim), so SwarmDuel stays in its size budget;
/// SwarmDuel sends the team's 1% each split returns.
///
/// A split's 60% is the turn's dividends, paid at the turn's close to every dividend share then (the jackpot's 10 seed
/// shares included: their part stays waiting for the jackpot); 3% to the stakers; 1% to the team; the rest waits as
/// IMD and is bought as $IMDUEL in capped steps, into one jackpot across games: the $IMDUEL held less the prizes owed.
/// Shares cost `1 + m/50 + IN/K` IMD each, K = 200 IMD. The winning bid pays max(2 IMD, 20%), keeps its refund, buys
/// dividend shares for its payment and takes 1% of the jackpot. A human win splits 80% of the jackpot equally over the
/// game's played White moves; any other ending pays nothing more.
library SwarmLedger {
    using SwarmCast for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant K = 200 ether;
    uint256 internal constant JACKPOT_SHARES = 10 ether;
    uint256 internal constant ACC = 1e27;
    uint256 internal constant MIN_PAYMENT = 2 ether;
    uint256 internal constant DISCOUNT_BPS = 8_000;
    uint256 internal constant DIVIDEND_BPS = 6_000;
    uint256 internal constant STAKERS_BPS = 300;
    uint256 internal constant TEAM_BPS = 100;
    uint256 internal constant REFERRAL_BPS = 300; // of a referred split, to its referrer, out of the jackpot's part
    uint256 internal constant DRIP_BPS = 100; // of the jackpot, to each turn's winning move
    uint256 internal constant WIN_PCT = 80; // of the jackpot on a human win, over the game's played White moves

    uint8 internal constant PLAIN = 1; // shares at once
    uint8 internal constant BID = 2; // the leading bid, escrowed
    uint8 internal constant WON = 3; // the winning bid, settled
    uint8 internal constant PAID = 1; // flags: a WON's refund and prize claimed
    uint8 internal constant WIN_PAID = 2; // its part of a human win claimed
    uint256 internal constant BUY_GAS = 6_500_000; // a swap with the main duel's queued move and its fallback (5.78M)
    uint256 internal constant BUY_RESERVE = 400_000;
    /// At most this much waiting IMD a buy (user, 2026-11-13): a sandwich that props the price up with liquidity placed in
    /// the same transaction gains in step with the amount bought and pays a fixed cost to set up, so above about 50 IMD
    /// at the pool's depth on 2026-11-13 it paid; at 20 it loses.
    uint256 internal constant BUY_CAP = 20 ether;
    uint256 internal constant SYNC_GAS = 150_000; // the vault's sync, after the buy's bookkeeping (a failure ignored)

    // a player's counts (section 9): bit offsets and widths
    uint256 internal constant MOVES = 0; // 24 bits
    uint256 internal constant PIECES = 24; // 16 bits per piece type 1-6
    uint256 internal constant QUEENS = 120; // 12
    uint256 internal constant GAMES = 132; // 16
    uint256 internal constant WINS = 148; // 12
    uint256 internal constant DRAWS = 160; // 12
    uint256 internal constant MATES = 172; // 12
    uint256 internal constant EVEN_WINS = 184; // 8
    uint256 internal constant LAST_GAME = 192; // 32
    uint256 internal constant FIRST = 224; // 1

    event Bought(address owner, uint256 spent, uint256 out, uint256 toVault);
    event BuyFailed(address owner, uint256 waiting);
    event Claimed(uint256 indexed id, address indexed owner, uint256 imd, uint256 imduel);

    error NotEnoughGas();
    error Busy(); // the pool manager is already unlocked: a call from inside someone's own unlock can't buy
    error NotYours();

    /// The live contracts a buy uses.
    struct Market {
        IERC20 imd;
        IERC20 imduel;
        IMainDuelBuyer buyer;
        address vault;
    }

    /// A game's money: the word every close updates, the accumulator, and a human win's part. IMD's supply (about 2^83
    /// wei) bounds IN and S far below their widths.
    struct Book {
        uint96 taken; // IN: the IMD that bought shares
        uint80 shares; // S: dividend shares, from JACKPOT_SHARES
        uint32 moves; // the game's played White moves
        uint8 result; // 0 running, 1 White won, 2 Black won, 3 drawn
        uint8 level; // its odds
        uint256 acc; // dividends per dividend share, x ACC
        uint96 perMove; // $IMDUEL each played White move gets on a human win
    }

    /// A deposit: shares at once, the leading bid, or the winning bid. Two words; IMD's supply (about 2^83 wei) bounds
    /// every amount far below its width.
    struct Position {
        address owner;
        uint96 amount; // the IMD put in
        uint80 shares; // n: dividend shares
        uint96 debt; // the dividends counted out: its accrual when bought (rounded up), then what it took
        uint32 gameNo;
        uint16 ply; // the humans' turn it was made in
        uint8 kind;
        uint8 flags;
        uint16 move; // the move it was made with, NO_MOVE if none (the record: no money reads it)
    }

    /// What SwarmDuel holds for others: IMD, and the $IMDUEL owed as prizes (the jackpot is the rest of its $IMDUEL,
    /// the waiting IMD the rest of its IMD); four words, each kept by the steps that write it together (referrals alone).
    struct Money {
        uint96 pending; // this turn's dividends, paid at its close (every split)
        uint96 stakersWaiting; // the stakers' part of the waiting IMD (every split and buy)
        uint48 lastBuyBlock; // the block of the last buy: one a block
        uint96 escrow; // the leading bid (every lead and close)
        uint96 refunds; // owed to winning bids
        uint96 dividends; // kept for holders (every close and claim)
        uint96 prizes; // $IMDUEL: prizes and human-win parts not yet claimed
        uint96 referrals; // IMD owed to referrers (every referred split and referral claim)
    }

    /// A turn's close, for its winner.
    struct Close {
        uint64 id; // the winning position
        uint32 gameNo;
        uint16 ply; // the turn
        uint8 piece; // the moved piece's type (1-6)
        bool queen; // it took the swarm's queen
        bool mate; // it mated
        uint256 bid;
        uint256 paid; // pay(bid)
        uint256 cost; // of the payment, taken by the swarm's ask
        bool referred; // the bid came through a referral link: its split pays its referrer
    }

    /// The winning payment for a bid of `bid`: max(2 IMD, the bid less its 80%, the refund rounding down).
    function pay(uint256 bid) internal pure returns (uint256 p) {
        p = bid - bid * DISCOUNT_BPS / 10_000;
        if (p < MIN_PAYMENT) p = MIN_PAYMENT;
    }

    /// Position `p` (its owner and amount `x` written) buys shares with `x` IMD in game `gameNo` at the humans' turn
    /// `ply` (a deposit, a move that doesn't lead, an outbid bid): the split, then the shares, its second word written
    /// whole; returns them and the team's IMD to send.
    function deposit(Book storage b, Money storage k, Position storage p, uint256 x, uint256 gameNo, uint256 ply, bool referred)
        external
        returns (uint256 n, uint256 toTeam, uint256 toRef)
    {
        (toTeam, toRef) = _split(k, x, referred);
        n = _shares(b, x, ply);
        (b.taken, b.shares) = (b.taken + x.toUint96(), b.shares + n.toUint80());
        (p.shares, p.debt, p.gameNo, p.ply, p.kind) = (n.toUint80(), _debt(b, n), uint32(gameNo), uint16(ply), PLAIN);
    }

    /// Settles the winning position `w` at its turn's close (`c`): its dividend shares for its payment, the payment
    /// less the ask's cost split, its prize (1% of the jackpot), the turn's dividends, and its owner's counts. Returns
    /// the team's IMD to send and the prize.
    function settle(
        mapping(uint256 => Book) storage books,
        Money storage k,
        Position storage w,
        mapping(address => uint256) storage players,
        IERC20 imduel,
        Close memory c
    ) external returns (uint256 toTeam, uint256 prize, uint256 toRef) {
        Book storage b = books[c.gameNo];
        uint256 n = _shares(b, c.paid, c.ply);
        (toTeam, toRef) = _split(k, c.paid - c.cost, c.referred);
        (b.taken, b.shares, b.moves) = (b.taken + c.paid.toUint96(), b.shares + n.toUint80(), b.moves + 1);
        (w.kind, w.shares, w.debt) = (WON, n.toUint80(), _debt(b, n));
        prize = jackpot(k, imduel) * DRIP_BPS / 10_000;
        k.prizes += prize.toUint96();
        // the turn's dividends, to every dividend share now (the winner's and this turn's deposits' included); the
        // seed shares' part and the rounding stay waiting for the jackpot
        uint256 all = b.shares;
        uint256 delta = uint256(k.pending) * ACC / all;
        b.acc += delta;
        (k.dividends, k.pending) = (k.dividends + _ceil((all - JACKPOT_SHARES) * delta).toUint96(), 0);
        _count(books, players, w.owner, c);
    }

    /// One capped buy of the waiting IMD for `msg.sender`, who owns its main-duel move:
    /// at most BUY_CAP of it, the stakers' part in proportion; at most one a block; too little gas, or the pool manager already unlocked (a call from inside someone's own
    /// unlock), reverts it when `required` (buy()), else skips it, recording nothing; a success sends the stakers'
    /// part to the vault and keeps the rest, which is the jackpot's. A failure only waits for the next buy.
    function buyStep(Money storage k, Market memory mk, bool required) external {
        uint256 all = waiting(k, mk.imd);
        if (all == 0 || k.lastBuyBlock == block.number) return;
        if (gasleft() < BUY_GAS + BUY_GAS / 63 + BUY_RESERVE) {
            if (required) revert NotEnoughGas();
            return;
        }
        if (!_ready(mk.buyer)) {
            if (required) revert Busy();
            return;
        }
        k.lastBuyBlock = uint48(block.number);
        uint256 w = all < BUY_CAP ? all : BUY_CAP;
        uint256 stakers = k.stakersWaiting; // their share of the buy is stakers / all
        if (stakers > all) stakers = all;
        uint256 imdBefore = mk.imd.balanceOf(address(this));
        uint256 duelBefore = mk.imduel.balanceOf(address(this));
        mk.imd.forceApprove(address(mk.buyer), w);
        bytes memory data = abi.encodeCall(IMainDuelBuyer.buy, (w, msg.sender));
        address to = address(mk.buyer);
        bool ok;
        assembly ("memory-safe") {
            ok := call(BUY_GAS, to, 0, add(data, 32), mload(data), 0, 0) // nothing copied back: balances tell
        }
        mk.imd.forceApprove(address(mk.buyer), 0);
        uint256 imdAfter = mk.imd.balanceOf(address(this));
        uint256 spent = imdBefore > imdAfter ? imdBefore - imdAfter : 0; // IMD sent back: nothing spent, a failure
        if (ok && spent != 0) {
            uint256 duelAfter = mk.imduel.balanceOf(address(this));
            uint256 out = duelAfter > duelBefore ? duelAfter - duelBefore : 0;
            uint256 toVault = out * stakers / all;
            k.stakersWaiting = (stakers - spent * stakers / all).toUint96();
            emit Bought(msg.sender, spent, out, toVault);
            if (toVault != 0) {
                mk.imduel.safeTransfer(mk.vault, toVault);
                try ISwarmVault(mk.vault).sync{gas: SYNC_GAS}() {} catch {}
            }
        } else {
            emit BuyFailed(msg.sender, w);
        }
    }

    /// The end of a game with `result`: on a human win, 80% of the jackpot split equally over the game's played White
    /// moves (owed as prizes); any other result pays nothing more. Returns each move's part and the jackpot left.
    function end(Book storage b, Money storage k, uint8 result, IERC20 imduel)
        external
        returns (uint256 perMove, uint256 left)
    {
        left = jackpot(k, imduel);
        uint256 moves = b.moves;
        if (result == 1 && moves != 0) {
            perMove = left * WIN_PCT / 100 / moves;
            (b.perMove, k.prizes) = (perMove.toUint96(), k.prizes + (perMove * moves).toUint96());
            left -= perMove * moves;
        }
        b.result = result;
    }

    /// Pays `msg.sender`'s positions `ids`: dividends and refunds in IMD, prizes and human-win parts in $IMDUEL;
    /// returns the totals.
    function claimAll(
        mapping(uint256 => Book) storage books,
        mapping(uint256 => Position) storage positions,
        mapping(uint256 => uint256) storage prizes,
        Money storage k,
        uint256[] calldata ids,
        IERC20 imd,
        IERC20 imduel
    ) external returns (uint256 imdTotal, uint256 imduelTotal) {
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            Position storage p = positions[id];
            if (p.owner != msg.sender) revert NotYours();
            (uint256 a, uint256 e) = _take(books[p.gameNo], p, k, prizes[id]);
            if (a + e != 0) emit Claimed(id, msg.sender, a, e);
            (imdTotal, imduelTotal) = (imdTotal + a, imduelTotal + e);
        }
        if (imdTotal != 0) imd.safeTransfer(msg.sender, imdTotal);
        if (imduelTotal != 0) imduel.safeTransfer(msg.sender, imduelTotal);
    }

    /// The IMD waiting to be bought: all IMD held that nobody is owed.
    function waiting(Money storage k, IERC20 imd) public view returns (uint256) {
        uint256 held = imd.balanceOf(address(this));
        uint256 owedNow = uint256(k.escrow) + k.dividends + k.refunds + k.pending + k.referrals;
        return held > owedNow ? held - owedNow : 0;
    }

    /// The jackpot: all $IMDUEL held that isn't owed as prizes.
    function jackpot(Money storage k, IERC20 imduel) public view returns (uint256) {
        uint256 held = imduel.balanceOf(address(this));
        return held > k.prizes ? held - k.prizes : 0;
    }

    /// What position `p` (its prize `prize`) can claim now: dividends and, for a winning move, its refund (IMD), its
    /// prize and, once its game is a human win, its part ($IMDUEL).
    function owed(Book storage b, Position storage p, uint256 prize)
        public
        view
        returns (uint256 dividends, uint256 refund, uint256 won, uint256 part)
    {
        uint256 accrued = uint256(p.shares) * b.acc / ACC;
        if (accrued > p.debt) dividends = accrued - p.debt;
        if (p.kind != WON) return (dividends, 0, 0, 0);
        uint8 flags = p.flags;
        if (flags & PAID == 0) (refund, won) = (p.amount - pay(p.amount), prize);
        if (b.result == 1 && flags & WIN_PAID == 0) part = b.perMove;
    }

    /// The shares `x` IMD would buy now at turn `ply` (the page's quote).
    function quote(Book storage b, uint256 x, uint256 ply) external view returns (uint256) {
        return _shares(b, x, ply);
    }

    /// Takes what position `p` can claim now out of the buckets: returns the IMD and the $IMDUEL to pay.
    function _take(Book storage b, Position storage p, Money storage k, uint256 prize)
        private
        returns (uint256 imd, uint256 imduel)
    {
        (uint256 dividends, uint256 refund, uint256 won, uint256 part) = owed(b, p, prize);
        if (dividends != 0) (p.debt, k.dividends) = (p.debt + dividends.toUint96(), k.dividends - dividends.toUint96());
        if (p.kind == WON) {
            uint8 flags = p.flags | PAID;
            if (part != 0) flags |= WIN_PAID;
            if (flags != p.flags) {
                (p.flags, k.refunds, k.prizes) =
                    (flags, k.refunds - refund.toUint96(), k.prizes - (won + part).toUint96());
            }
        }
        return (dividends + refund, won + part);
    }

    /// The buyer can buy now; one whose check reverts is read as not ready, so it can't revert a deposit or a step.
    function _ready(IMainDuelBuyer buyer) private view returns (bool) {
        try buyer.ready() returns (bool r) {
            return r;
        } catch {
            return false;
        }
    }

    /// Splits `x` IMD: 60% to the turn's dividends (paid at its close), 3% to the stakers' waiting part, 1% returned
    /// for the team, 3% owed to the referrer when `referred` (out of the jackpot's part), the rest waits for the jackpot.
    function _split(Money storage k, uint256 x, bool referred) private returns (uint256 toTeam, uint256 toRef) {
        uint256 d = x * DIVIDEND_BPS / 10_000;
        uint256 s = x * STAKERS_BPS / 10_000;
        toTeam = x * TEAM_BPS / 10_000;
        (k.pending, k.stakersWaiting) = (k.pending + d.toUint96(), k.stakersWaiting + s.toUint96());
        if (referred) {
            toRef = x * REFERRAL_BPS / 10_000;
            k.referrals += toRef.toUint96();
        }
    }

    /// Section 9: the winning move's owner's counts, in the order the game plays them; a new game folds the last
    /// one's result first (it is over: one game at a time).
    function _count(
        mapping(uint256 => Book) storage books,
        mapping(address => uint256) storage players,
        address owner,
        Close memory c
    ) private {
        uint256 w = players[owner];
        uint256 last = uint32(w >> LAST_GAME);
        if (last != c.gameNo) {
            if (last != 0) {
                Book storage lb = books[last];
                uint8 r = lb.result;
                if (r == 1) w = _bump(_bump(w, WINS, 12), EVEN_WINS, lb.level == 0 ? 8 : 0);
                else if (r == 3) w = _bump(w, DRAWS, 12);
            }
            w = (_bump(w, GAMES, 16) & ~(uint256(type(uint32).max) << LAST_GAME)) | (uint256(c.gameNo) << LAST_GAME);
            if (c.gameNo == 1) w |= 1 << FIRST;
        }
        w = _bump(_bump(w, MOVES, 24), PIECES + 16 * (c.piece - 1), 16);
        if (c.queen) w = _bump(w, QUEENS, 12);
        if (c.mate) w = _bump(w, MATES, 12);
        players[owner] = w;
    }

    /// Adds one to the `width`-bit counter at `shift`, saturating; a zero width adds nothing.
    function _bump(uint256 w, uint256 shift, uint256 width) internal pure returns (uint256) {
        uint256 max = (1 << width) - 1;
        return (w >> shift) & max == max ? w : w + (1 << shift);
    }

    /// `K * ln(1 + x / (a*K + IN))` with `a = 1 + m/50`, m the humans' moves played at turn `ply`.
    function _shares(Book storage b, uint256 x, uint256 ply) private view returns (uint256) {
        uint256 base = K + K * (ply >> 1) / 50 + b.taken;
        return K * uint256(wadLn(int256(1e18 + x * 1e18 / base))) / 1e18;
    }

    /// A new holding's dividend debt: its shares' accrual so far, rounded up.
    function _debt(Book storage b, uint256 n) private view returns (uint96) {
        return _ceil(n * b.acc).toUint96();
    }

    function _ceil(uint256 x) private pure returns (uint256) {
        return (x + ACC - 1) / ACC;
    }
}
