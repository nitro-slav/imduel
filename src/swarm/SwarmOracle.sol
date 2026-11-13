// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IIntake, Attestation} from "./IIntake.sol";
import {ISwarmOracle, ISwarmOracleClient, SwarmCause} from "./ISwarmOracle.sol";
import {SwarmRules} from "./SwarmRules.sol";
import {SwarmText} from "./SwarmText.sol";

/// Swarm Duel's adapter to IMD's oracle: everything IMD-specific in one place. It writes the question (SwarmText), checks IMD's limits before
/// paying, pays the Intake exactly, receives the callback for its own pending request only, checks the attestation
/// (the attester's signature in this contract's own EIP-712 domain, the stored question hash, bytes32, a panel of
/// exactly 7 with a quorum of exactly 3, at least 3 agreeing, not expired), decodes the move and tells SwarmDuel. It
/// holds no money between calls and has no owner; SwarmDuel's deployer can replace it there, after a notice.
contract SwarmOracle is ISwarmOracle {
    using SafeERC20 for IERC20;

    bytes32 internal constant ACTION = "oracle.request@oracle-1";
    uint16 internal constant PANEL = 7;
    uint16 internal constant QUORUM = 3;
    uint8 internal constant BYTES32 = 2; // the attestation's answerType for bytes32
    uint256 internal constant WINDOW_DEPTH = 6; // IMD reads the ask with toBlock at least 5 blocks deep
    uint256 internal constant MAX_QUESTION = 2_000;
    uint256 internal constant MAX_DEFINITION = 512;
    uint256 internal constant MAX_BODY = 16_384;
    uint256 internal constant MAX_ALLOW = 256;
    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,"
        "uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,"
        "uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    IIntake public immutable intake;
    IERC20 public immutable imd;
    address public immutable attester;
    ISwarmOracleClient public immutable client;
    SwarmRules public immutable rules;
    uint256 public immutable price;
    bytes32 internal immutable DOMAIN;

    /// The question hash of each request this adapter paid for and hasn't heard back on (IMD's binding of an answer to
    /// a request; SwarmDuel keeps the game's).
    mapping(bytes32 requestId => bytes32 questionHash) public pending;
    /// Each ask's Intake request id in full, by `gameNo << 16 | Black's ply` (SwarmDuel's record keeps its first sixteen
    /// bytes): IMD finds its panel only from the full id. For readers; nothing here reads it.
    mapping(uint256 turn => bytes32 requestId) public asks;

    event Asked(bytes32 indexed id, uint32 gameNo, uint16 ply, bytes32 questionHash);
    event Answered(bytes32 indexed id, uint16 move, uint16 agreed);
    event Failed(bytes32 indexed id, uint8 cause, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);

    error InvalidSetup();
    error NotClient();
    error NotIntake();
    error Declined(); // the question would break one of IMD's limits: nothing paid, the engine plays

    constructor(
        IIntake intake_,
        IERC20 imd_,
        address attester_,
        ISwarmOracleClient client_,
        SwarmRules rules_,
        uint256 price_
    ) {
        if (
            address(intake_) == address(0) || address(imd_) == address(0) || attester_ == address(0)
                || address(client_) == address(0) || address(rules_) == address(0) || price_ == 0
        ) revert InvalidSetup();
        (intake, imd, attester, client, rules, price) = (intake_, imd_, attester_, client_, rules_, price_);
        DOMAIN = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
    }

    // ---------------------------------------------------------------- asking

    /// @inheritdoc ISwarmOracle
    function ask(SwarmRules.Game calldata g, uint16[] calldata legal, uint256[] calldata history)
        external
        returns (bytes32 id)
    {
        if (msg.sender != address(client)) revert NotClient();
        if (legal.length == 0 || legal.length > MAX_ALLOW) revert Declined();
        SwarmText.Ask memory a;
        (a.g, a.legal, a.history, a.windowBlock, a.chainId) = (g, legal, history, block.number - WINDOW_DEPTH, block.chainid);
        if (g.level > 0) (a.startBoard, a.startWhite, a.startBlack) = rules.start(g.level);
        SwarmText.Written memory w = SwarmText.write(a);
        if (w.questionLength > MAX_QUESTION || w.longestDefinition > MAX_DEFINITION || w.body.length > MAX_BODY) {
            revert Declined();
        }
        imd.safeTransferFrom(msg.sender, address(this), price);
        imd.forceApprove(address(intake), price);
        id = intake.requestWithFailure(
            ACTION,
            w.body,
            IIntake.Callback(address(this), this.onOracleResult.selector),
            this.onFailure.selector,
            address(imd),
            price
        );
        if (imd.allowance(address(this), address(intake)) != 0) imd.forceApprove(address(intake), 0);
        (pending[id], asks[(uint256(g.gameNo) << 16) | g.ply]) = (w.questionHash, id);
        emit Asked(id, g.gameNo, g.ply, w.questionHash);
    }

    // ---------------------------------------------------------------- hearing back (the Intake, 200k gas, once)

    /// The oracle's answer for request `id`: only from the Intake, only for a request of ours, once.
    function onOracleResult(bytes32 id, Attestation calldata a, bytes calldata signature) external {
        if (msg.sender != address(intake)) revert NotIntake();
        bytes32 questionHash = pending[id];
        if (questionHash == 0) return;
        delete pending[id];
        (bool ok, uint16 move) = _check(questionHash, a, signature);
        if (ok) {
            emit Answered(id, move, a.agreed);
            client.answered(id, move, a.agreed);
        } else {
            emit Failed(id, SwarmCause.INVALID, 0, 0, a.agreed, 0);
            client.failed(id, SwarmCause.INVALID);
        }
    }

    /// No answer for request `id`: status 1 refused (paid), 2 no result. Only IMD's `disagreed` (its panel's answers fell
    /// short of the quorum) is a split, the panel's own choice, never counted by the breaker; every other reason
    /// (`failed`, `cancelled`, `blocked`, ...: IMD's side, even after some seats answered) counts as a refusal
    ///. Unsigned, so it only hands the move to the engine.
    function onFailure(bytes32 id, uint8 status, bytes32 reason, uint16 agreed, uint16 answered, bytes calldata)
        external
    {
        if (msg.sender != address(intake)) revert NotIntake();
        if (pending[id] == 0) return;
        delete pending[id];
        uint8 cause = status == 2 && reason == "disagreed" ? SwarmCause.SPLIT : SwarmCause.REFUSED;
        emit Failed(id, cause, status, reason, agreed, answered);
        client.failed(id, cause);
    }

    /// The EIP-712 digest the attester signs for this contract (a view for tests and the page).
    function digest(Attestation calldata a) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    TYPEHASH, a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock
                ),
                abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN, structHash));
    }

    /// The move in `a`, if `a` is the attester's answer to our question in exactly our settings.
    function _check(bytes32 questionHash, Attestation calldata a, bytes calldata signature)
        internal
        view
        returns (bool, uint16)
    {
        if (
            a.questionHash != questionHash || a.answerType != BYTES32 || a.answer.length != 32 || a.panelSize != PANEL
                || a.quorum != QUORUM || a.agreed < QUORUM || block.timestamp > a.expiresAt
        ) return (false, 0);
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest(a), signature);
        if (err != ECDSA.RecoverError.NoError || signer != attester) return (false, 0);
        return decode(bytes32(a.answer));
    }

    /// A move from its UCI bytes32, strictly: four lowercase file/rank characters, then nothing or a q, then zeros
    /// (a promotion is always to a queen, so the q needs no bit; legality is SwarmDuel's to check).
    function decode(bytes32 x) public pure returns (bool, uint16) {
        uint8 f1 = uint8(x[0]);
        uint8 r1 = uint8(x[1]);
        uint8 f2 = uint8(x[2]);
        uint8 r2 = uint8(x[3]);
        uint8 p = uint8(x[4]);
        if (
            f1 < 97 || f1 > 104 || f2 < 97 || f2 > 104 || r1 < 49 || r1 > 56 || r2 < 49 || r2 > 56
                || (p != 0 && p != 113) || uint256(x) << 40 != 0
        ) return (false, 0);
        uint16 from = uint16(f1 - 97) + 8 * uint16(r1 - 49);
        uint16 to = uint16(f2 - 97) + 8 * uint16(r2 - 49);
        return (true, (from << 6) | to);
    }
}
