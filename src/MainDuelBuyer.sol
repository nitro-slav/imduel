// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {IMainDuelBuyer} from "./IMainDuelBuyer.sol";

/// Buys $IMDUEL with its caller's IMD in the main duel's pool: one `unlock` and `swap` a
/// call, exact input, of the IMD that raises $IMDUEL's price by about one pool fee (at most what the caller offers)
/// from the price it finds. That price can be propped up in the same transaction, with liquidity placed above it, so a
/// caller bounds what it offers (Swarm: 20 IMD a buy, SwarmLedger.BUY_CAP). The main duel's hook refuses a swap its
/// price limit stops early, so the amount is worked out first, through every initialized tick up to that one-fee
/// price (the liquidity changes only there), and the limit only backs it up: no liquidity shape, however thin above
/// the price, makes a buy stop early. The owner the caller names goes in `hookData`, so it owns the main-duel move the trade bids
/// and any prize. Pulls only from its caller, pays only its caller, holds nothing between calls; no owner, no admin,
/// so any later feature can use it.
contract MainDuelBuyer is IMainDuelBuyer, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;
    address public immutable imduel; // currency0
    address public immutable imd; // currency1
    uint24 public immutable fee; // millionths
    int24 public immutable tickSpacing;
    IHooks public immutable hooks;
    PoolId public immutable poolId;

    error NotManager();
    error BadPool();

    constructor(IPoolManager manager_, address imduel_, address imd_, uint24 fee_, int24 tickSpacing_, IHooks hooks_) {
        if (imduel_ >= imd_ || fee_ == 0 || fee_ >= 1_000_000) revert BadPool(); // $IMDUEL sorts first, a static fee
        (manager, imduel, imd, fee, tickSpacing, hooks) = (manager_, imduel_, imd_, fee_, tickSpacing_, hooks_);
        poolId = _key(imduel_, imd_, fee_, tickSpacing_, hooks_).toId();
    }

    /// @inheritdoc IMainDuelBuyer
    function buy(uint256 maxIn, address owner) external returns (uint256 spent, uint256 out) {
        (uint160 price, int24 tick,,) = StateLibrary.getSlot0(manager, poolId);
        uint256 limit = uint256(price) + uint256(price) * fee / 2_000_000;
        if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        uint256 amount = _inputTo(price, tick, limit);
        if (amount > maxIn) amount = maxIn;
        if (amount == 0) return (0, 0);
        (spent, out) = abi.decode(manager.unlock(abi.encode(msg.sender, amount, owner, uint160(limit))), (uint256, uint256));
    }

    /// @inheritdoc IMainDuelBuyer
    function ready() external view returns (bool) {
        return !TransientStateLibrary.isUnlocked(manager);
    }

    /// The swap, inside the PoolManager's unlock: the IMD owed settled from the payer, the $IMDUEL taken to it.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (address payer, uint256 maxIn, address owner, uint160 limit) = abi.decode(data, (address, uint256, address, uint160));
        BalanceDelta delta = manager.swap(
            _key(imduel, imd, fee, tickSpacing, hooks),
            SwapParams({zeroForOne: false, amountSpecified: -int256(maxIn), sqrtPriceLimitX96: limit}),
            abi.encodePacked(owner)
        );
        uint256 spent = uint256(uint128(-delta.amount1()));
        uint256 out = uint256(uint128(delta.amount0()));
        manager.sync(Currency.wrap(imd));
        IERC20(imd).safeTransferFrom(payer, address(manager), spent);
        manager.settle();
        manager.take(Currency.wrap(imduel), payer, out);
        return abi.encode(spent, out);
    }

    /// The IMD, before fees, that raises the sqrt price from `price` (in `tick`) to `limit`: each stretch's liquidity
    /// times its rise in sqrt price, through every initialized tick on the way (the next one found in the tick
    /// bitmap, a word at a time; crossing one upward adds its net liquidity). The fees taken from the input keep the
    /// swap's price under `limit`.
    function _inputTo(uint160 price, int24 tick, uint256 limit) internal view returns (uint256 amount) {
        uint256 liquidity = StateLibrary.getLiquidity(manager, poolId);
        uint256 at = price;
        int24 compressed = TickBitmap.compress(tick, tickSpacing);
        while (true) {
            (int16 word, uint8 bit) = TickBitmap.position(++compressed);
            uint256 initialized = StateLibrary.getTickBitmap(manager, poolId, word) & ~((uint256(1) << bit) - 1);
            // the next initialized tick in this word, else the word's last tick (none in between)
            compressed += int24(uint24(initialized != 0 ? BitMath.leastSignificantBit(initialized) - bit : 255 - bit));
            int24 next = compressed * tickSpacing;
            if (next >= TickMath.MAX_TICK) break;
            uint256 edge = TickMath.getSqrtPriceAtTick(next);
            if (edge >= limit) break;
            amount += FullMath.mulDiv(liquidity, edge - at, FixedPoint96.Q96);
            if (initialized != 0) {
                (, int128 net) = StateLibrary.getTickLiquidity(manager, poolId, next);
                liquidity = net < 0 ? liquidity - uint128(-net) : liquidity + uint128(net);
            }
            at = edge;
        }
        amount += FullMath.mulDiv(liquidity, limit - at, FixedPoint96.Q96);
    }

    function _key(address c0, address c1, uint24 f, int24 spacing, IHooks h) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), f, spacing, h);
    }
}
