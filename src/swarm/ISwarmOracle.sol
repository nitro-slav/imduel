// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwarmRules} from "./SwarmRules.sol";

/// The port between Swarm Duel and whatever asks the swarm:
/// SwarmDuel asks for Black's move; the adapter answers later with the move or a failure. SwarmDuel knows nothing else
/// about the swarm, so an adapter can be replaced (by the deployer, after a 3-day notice) without touching the game.
interface ISwarmOracle {
    /// What one ask costs, in IMD (immutable per adapter).
    function price() external view returns (uint256);

    /// Asks for Black's move in `g` (a position SwarmRules keeps), paying exactly `price` pulled from the caller.
    /// `legal`: Black's legal moves in SwarmRules' order; `history`: the game's moves so far, sixteen to a word (bits
    /// 0-11 the move, bit 12 a promotion). Returns the ask's id; reverts, paying nothing, when it can't ask.
    function ask(SwarmRules.Game calldata g, uint16[] calldata legal, uint256[] calldata history)
        external
        returns (bytes32 id);
}

/// The port's other half, which SwarmDuel implements: only the game's adapter calls it, only for the pending id.
interface ISwarmOracleClient {
    /// The swarm's move for ask `id` (Chess.sol encoding; legality is SwarmDuel's to check) and how many of the panel
    /// gave it (`agreed`, kept for the record only).
    function answered(bytes32 id, uint16 move, uint16 agreed) external;

    /// Ask `id` gave no move; `cause` is one of SwarmCause.
    function failed(bytes32 id, uint8 cause) external;
}

/// Why an ask gave no move. SwarmDuel's breaker counts the causes that say the oracle is broken (DECLINED, REFUSED,
/// INVALID, LATE) and never the panel's own choices (SPLIT, ILLEGAL).
library SwarmCause {
    uint8 internal constant DECLINED = 1; // the ask reverted or was declined before paying
    uint8 internal constant REFUSED = 2; // IMD refused the question after payment (or any status it doesn't explain)
    uint8 internal constant SPLIT = 3; // the panel disagreed: no move reached the quorum
    uint8 internal constant INVALID = 4; // an answer our checks reject (signer, hash, settings, format)
    uint8 internal constant LATE = 5; // no answer within the hour
    uint8 internal constant ILLEGAL = 6; // a signed move that is not legal here
}
