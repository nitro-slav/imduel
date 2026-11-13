// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Buys $IMDUEL with its caller's IMD in the main duel, at most one pool fee of price rise a call.
interface IMainDuelBuyer {
    /// Pulls at most `maxIn` IMD from the caller and swaps it for $IMDUEL, stopping where the price has risen by about
    /// one pool fee; `owner` owns the main-duel move the trade bids. Returns the IMD spent and the $IMDUEL sent back.
    function buy(uint256 maxIn, address owner) external returns (uint256 spent, uint256 out);

    /// Whether a buy can run now: false inside someone's own pool-manager unlock, where the buyer's unlock reverts.
    function ready() external view returns (bool);

    function imd() external view returns (address);

    function imduel() external view returns (address);
}

/// The staking vault's part SwarmDuel uses.
interface ISwarmVault {
    function asset() external view returns (address);

    function sync() external;
}
