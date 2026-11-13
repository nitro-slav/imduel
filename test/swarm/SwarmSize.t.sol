// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SwarmDuel} from "../../src/swarm/SwarmDuel.sol";
import {SwarmRules} from "../../src/swarm/SwarmRules.sol";
import {SwarmLedger} from "../../src/swarm/SwarmLedger.sol";
import {SwarmOracle} from "../../src/swarm/SwarmOracle.sol";
import {MainDuelBuyer} from "../../src/MainDuelBuyer.sol";
import {IMainDuelBuyer} from "../../src/IMainDuelBuyer.sol";
import {IIntake} from "../../src/swarm/IIntake.sol";
import {ISwarmOracleClient} from "../../src/swarm/ISwarmOracle.sol";
import {TestIMD, TestIMDUEL, MockBuyer, MockVault, ScriptedEngine} from "./SwarmDoubles.sol";

/// Swarm's bytecode budgets, asserted so every change is
/// held to them. Ethereum rejects contracts over 24,576 bytes (EIP-170).
contract SwarmSizeTest is Test {
    uint256 constant LIMIT = 24_576;
    uint256 constant DUEL_BUDGET = 22_000; // the game, the port, the admin, buying
    uint256 constant LEDGER_BUDGET = 8_000; // the money, delegatecalled on SwarmDuel's storage
    uint256 constant RULES_BUDGET = 24_000; // Rules and Bitboard inside, like the engine
    uint256 constant ORACLE_BUDGET = 14_000; // the writer and the adapter
    uint256 constant BUYER_BUDGET = 6_000;

    function test_deployedCodeFitsTheBudgets() public {
        SwarmRules rules = new SwarmRules();
        TestIMD imd = new TestIMD();
        TestIMDUEL imduel = new TestIMDUEL();
        MockBuyer mock = new MockBuyer(imd, imduel);
        uint256 duel = address(
            new SwarmDuel(
                imd, imduel, rules, new ScriptedEngine(rules), IMainDuelBuyer(address(mock)), address(new MockVault(address(imduel))), address(7), address(this), 0
            )
        ).code.length;
        uint256 ledger = type(SwarmLedger).runtimeCode.length;
        uint256 oracle = address(
            new SwarmOracle(IIntake(address(1)), IERC20(address(2)), address(3), ISwarmOracleClient(address(4)), SwarmRules(address(5)), 0.5 ether)
        ).code.length;
        uint256 buyer = address(new MainDuelBuyer(IPoolManager(address(1)), address(2), address(3), 12_500, 60, IHooks(address(4)))).code.length;
        emit log_named_uint("SwarmDuel", duel);
        emit log_named_uint("SwarmLedger", ledger);
        emit log_named_uint("SwarmRules", address(rules).code.length);
        emit log_named_uint("SwarmOracle", oracle);
        emit log_named_uint("MainDuelBuyer", buyer);
        assertLe(duel, DUEL_BUDGET, "SwarmDuel");
        assertLe(ledger, LEDGER_BUDGET, "SwarmLedger");
        assertLe(address(rules).code.length, RULES_BUDGET, "SwarmRules");
        assertLe(oracle, ORACLE_BUDGET, "SwarmOracle");
        assertLe(buyer, BUYER_BUDGET, "MainDuelBuyer");
        assertLe(DUEL_BUDGET, LIMIT);
        assertLe(RULES_BUDGET, LIMIT);
    }
}
