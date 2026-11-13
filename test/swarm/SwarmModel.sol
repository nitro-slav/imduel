// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {wadLn} from "solmate/src/utils/SignedWadMath.sol";

/// Swarm Duel's money as the spec writes it, kept apart from the contract: plain storage, plain
/// arithmetic, no packing, no shared code with SwarmLedger. The invariant run feeds it what happened in each call (from
/// SwarmDuel's events: who deposited what at which turn, who won a turn with which piece and what its ask took, what a
/// buy spent and got, how a game ended, who claimed) and checks that the contract's money and the players' counts
/// equal the model's to the wei. The model works out every amount itself; the events' own amounts are only compared.
contract SwarmModel {
    uint256 constant K = 200e18;
    uint256 constant SEED = 10e18;
    uint256 constant ACC = 1e27;

    struct Book {
        uint256 taken;
        uint256 shares;
        uint256 acc;
        uint256 perMove;
        uint256 moves;
        uint256 result;
        uint256 level;
    }

    struct Pos {
        address owner;
        uint256 gameNo;
        uint256 ply;
        uint256 kind; // 1 plain, 2 the leading bid, 3 won
        uint256 amount;
        uint256 n;
        uint256 debt;
        uint256 prize;
        bool paid; // refund and prize
        bool winPaid; // its part of a human win
    }

    struct Player {
        uint256 moves;
        uint256[7] pieces; // by type 1-6
        uint256 queens;
        uint256 games;
        uint256 won;
        uint256 drawn;
        uint256 mates;
        uint256 evenWins;
        uint256 lastGame;
        bool first;
    }

    mapping(uint256 => Book) public books;
    mapping(uint256 => Pos) public pos;
    mapping(address => Player) internal players;
    address[] public owners;
    mapping(address => bool) internal known;
    uint256 public gameNo;
    uint256 public leader;
    uint256 public escrow;
    uint256 public dividends;
    uint256 public refunds;
    uint256 public stakersWaiting;
    uint256 public pending; // this turn's dividends, paid at its close
    uint256 public prizes; // $IMDUEL owed
    uint256 public held; // IMD
    uint256 public heldDuel; // $IMDUEL
    uint256 public team;
    mapping(uint256 => address) public refOf; // a deposit's referrer (the Referrer event)
    mapping(address => uint256) public referralOf; // IMD owed to each referrer
    uint256 public referrals; // their total

    // ---------------------------------------------------------------- the spec's definitions

    function shares(Book storage b, uint256 x, uint256 ply) internal view returns (uint256) {
        uint256 base = K + K * (ply / 2) / 50 + b.taken;
        int256 ln = wadLn(int256(1e18 + x * 1e18 / base));
        return K * uint256(ln) / 1e18;
    }

    function pay(uint256 d) public pure returns (uint256) {
        uint256 p = d - d * 8000 / 10000;
        return p < 2e18 ? 2e18 : p;
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// 60% to the turn's dividends (paid at its close), 3% to the stakers, 1% to the team, 3% to the referrer if any
    /// (it comes out of what waits for the jackpot).
    function split(uint256 x, address ref) internal {
        pending += x * 6000 / 10000;
        stakersWaiting += x * 300 / 10000;
        uint256 t = x * 100 / 10000;
        team += t;
        held -= t;
        if (ref != address(0)) {
            uint256 r = x * 300 / 10000;
            referralOf[ref] += r;
            referrals += r;
        }
    }

    /// The turn's close pays its dividends to every dividend share then; the seed shares' part waits for the jackpot.
    function payTurn(Book storage b) internal {
        uint256 delta = pending * ACC / b.shares;
        b.acc += delta;
        dividends += ceilDiv((b.shares - SEED) * delta, ACC);
        pending = 0;
    }

    function buyShares(uint256 id, uint256 x, uint256 ply) internal {
        Book storage b = books[gameNo];
        split(x, refOf[id]);
        uint256 n = shares(b, x, ply);
        b.taken += x;
        b.shares += n;
        Pos storage p = pos[id];
        (p.gameNo, p.ply, p.kind, p.amount, p.n, p.debt) = (gameNo, ply, 1, x, n, ceilDiv(n * b.acc, ACC));
    }

    function waiting() public view returns (uint256) {
        uint256 owedNow = escrow + dividends + refunds + pending + referrals;
        return held > owedNow ? held - owedNow : 0;
    }

    function jackpot() public view returns (uint256) {
        return heldDuel - prizes;
    }

    function inc(uint256 x, uint256 bits) internal pure returns (uint256) {
        return x == (1 << bits) - 1 ? x : x + 1;
    }

    // ---------------------------------------------------------------- what happened

    function started(uint256 g, uint256 level) external {
        gameNo = g;
        (books[g].shares, books[g].level) = (SEED, level);
    }

    /// A deposit came through `ref`'s link (emitted before its Deposited).
    function referred(uint256 id, address ref) external {
        refOf[id] = ref;
    }

    /// A referrer took what it earned: returns the IMD.
    function referralClaimed(address ref) external returns (uint256 r) {
        r = referralOf[ref];
        (referralOf[ref], referrals, held) = (0, referrals - r, held - r);
    }

    /// A deposit: no move or a move that doesn't lead buys shares; a leading one is escrowed.
    function deposited(uint256 id, address owner, uint256 amount, uint256 ply, bool leads) external {
        held += amount;
        pos[id].owner = owner;
        if (!known[owner]) {
            known[owner] = true;
            owners.push(owner);
        }
        if (leads) {
            (leader, escrow) = (id, amount);
            Pos storage p = pos[id];
            (p.gameNo, p.ply, p.kind, p.amount) = (gameNo, ply, 2, amount);
        } else {
            buyShares(id, amount, ply);
        }
    }

    /// The outbid leader buys shares with its whole amount (escrow already replaced by the new lead).
    function converted(uint256 id) external {
        buyShares(id, pos[id].amount, pos[id].ply);
    }

    /// The close settles the winner: its payment and refund, what the ask took, its shares from IN before it, its
    /// prize, the turn's dividends, its owner's counts (`piece` moved, `queen` taken, `mate`). Returns the prize.
    function settled(uint256 id, uint256 ply, uint256 askPaid, uint256 piece, bool queen, bool mate)
        external
        returns (uint256)
    {
        require(id == leader, "the leader wins");
        Book storage b = books[gameNo];
        Pos storage p = pos[id];
        uint256 d = p.amount;
        uint256 pPay = pay(d);
        (escrow, leader) = (0, 0);
        refunds += d - pPay;
        held -= askPaid;
        uint256 n = shares(b, pPay, ply);
        split(pPay - askPaid, refOf[id]);
        b.taken += pPay;
        b.shares += n;
        b.moves += 1;
        (p.kind, p.n, p.debt) = (3, n, ceilDiv(n * b.acc, ACC));
        p.prize = jackpot() * 100 / 10000;
        prizes += p.prize;
        payTurn(b);
        count(p.owner, piece, queen, mate);
        return p.prize;
    }

    function count(address owner, uint256 piece, bool queen, bool mate) internal {
        Player storage q = players[owner];
        if (q.lastGame != gameNo) {
            if (q.lastGame != 0) {
                Book storage lb = books[q.lastGame];
                if (lb.result == 1) {
                    q.won = inc(q.won, 12);
                    if (lb.level == 0) q.evenWins = inc(q.evenWins, 8);
                } else if (lb.result == 3) {
                    q.drawn = inc(q.drawn, 12);
                }
            }
            (q.games, q.lastGame) = (inc(q.games, 16), gameNo);
            if (gameNo == 1) q.first = true;
        }
        q.moves = inc(q.moves, 24);
        q.pieces[piece] = inc(q.pieces[piece], 16);
        if (queen) q.queens = inc(q.queens, 12);
        if (mate) q.mates = inc(q.mates, 12);
    }

    /// A buy spent `spent` of the waiting IMD for `out` $IMDUEL; returns the vault's part.
    function bought(uint256 spent, uint256 out) external returns (uint256 toVault) {
        uint256 all = waiting(); // the buy offered at most 20 IMD of it; the stakers' share of anything bought is theirs / all
        uint256 s = stakersWaiting < all ? stakersWaiting : all;
        toVault = out * s / all;
        stakersWaiting = s - spent * s / all;
        heldDuel += out - toVault;
        held -= spent;
    }

    /// $IMDUEL sent straight to the contract: it joins the jackpot at once.
    function sent(uint256 amount) external {
        heldDuel += amount;
    }

    /// IMD sent straight to the contract: it waits to be bought, as the jackpot's.
    function sentImd(uint256 amount) external {
        held += amount;
    }

    /// The ending: on a human win each played move's part of 80% of the jackpot.
    function ended(uint256 result) external returns (uint256 perMove) {
        Book storage b = books[gameNo];
        if (result == 1 && b.moves != 0) {
            perMove = jackpot() * 80 / 100 / b.moves;
            prizes += perMove * b.moves;
            b.perMove = perMove;
        }
        b.result = result;
        (leader, escrow) = (0, 0);
    }

    /// What position `id` can claim now.
    function owed(uint256 id) public view returns (uint256 div, uint256 refund, uint256 prize, uint256 part) {
        Pos storage p = pos[id];
        Book storage b = books[p.gameNo];
        uint256 accrued = p.n * b.acc / ACC;
        div = accrued > p.debt ? accrued - p.debt : 0;
        if (p.kind != 3) return (div, 0, 0, 0);
        if (!p.paid) (refund, prize) = (p.amount - pay(p.amount), p.prize);
        if (b.result == 1 && !p.winPaid) part = b.perMove;
    }

    /// A claim: returns the IMD and the $IMDUEL it pays.
    function claimed(uint256 id) external returns (uint256 imd, uint256 imduel) {
        (uint256 div, uint256 refund, uint256 prize, uint256 part) = owed(id);
        Pos storage p = pos[id];
        p.debt += div;
        dividends -= div;
        if (p.kind == 3) {
            p.paid = true;
            if (part != 0) p.winPaid = true;
            refunds -= refund;
            prizes -= prize + part;
        }
        held -= div + refund;
        heldDuel -= prize + part;
        return (div + refund, prize + part);
    }

    /// `owner`'s counts in the contract's word layout (section 9), the model's own packing.
    function word(address owner) external view returns (uint256 w) {
        Player storage q = players[owner];
        w = q.moves | q.queens << 120 | q.games << 132 | q.won << 148 | q.drawn << 160 | q.mates << 172
            | q.evenWins << 184 | q.lastGame << 192 | (q.first ? 1 << 224 : 0);
        for (uint256 t = 1; t <= 6; t++) w |= q.pieces[t] << (24 + 16 * (t - 1));
    }

    function ownerCount() external view returns (uint256) {
        return owners.length;
    }
}
