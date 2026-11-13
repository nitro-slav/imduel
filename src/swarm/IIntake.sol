// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// IMD's Intake, the part a buyer calls (imd.fun/docs, version 2 since 2026-10-10; captured in
/// knowledge-base/raw/2026-11-04/docs-llms.txt). Selector 0x9a78c321.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);
}

/// The oracle's signed answer (domain "IdentityMD Oracle", version 2). `requestId` and `panelJobId` are IMD's UUIDs as
/// sixteen raw bytes, left-aligned; `answer` is `abi.encode` of the value; `answerType` 2 is bytes32.
struct Attestation {
    bytes32 requestId;
    uint256 chainId;
    bytes32 questionHash;
    uint8 answerType;
    bytes answer;
    uint256 figure;
    uint64 fromBlock;
    uint64 toBlock;
    bytes32 blockHash;
    bytes32 panelJobId;
    uint16 panelSize;
    uint16 quorum;
    uint16 agreed;
    uint64 issuedAt;
    uint64 expiresAt;
}
