// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// A call that no caller can make fail by its gas limit (the main duel's guard as a library; the live hook keeps its
/// frozen copy, IMDuelHook `_engine` and `_enoughGas`). Before the call the caller must have left enough for the callee
/// to get exactly `cap` under the 63/64 rule, plus `reserve` to finish; so a failure is the callee's own, never a
/// starved one, and a transaction sent with too little gas reverts instead of taking the failure's branch. At most
/// `maxOut` bytes of what it returns are copied (`ret`), so a callee returning megabytes can't spend the reserve on
/// the caller's memory; `size` is what it really returned.
library GuardedCall {
    error NotEnoughGas();

    function call(address target, uint256 cap, uint256 reserve, bytes memory data, uint256 maxOut)
        internal
        returns (bool ok, uint256 size, bytes memory ret)
    {
        if (gasleft() < cap + cap / 63 + reserve) revert NotEnoughGas();
        ret = new bytes(maxOut);
        assembly ("memory-safe") {
            ok := call(cap, target, 0, add(data, 32), mload(data), add(ret, 32), maxOut)
            size := returndatasize()
        }
    }

    function staticcall(address target, uint256 cap, uint256 reserve, bytes memory data, uint256 maxOut)
        internal
        view
        returns (bool ok, uint256 size, bytes memory ret)
    {
        if (gasleft() < cap + cap / 63 + reserve) revert NotEnoughGas();
        ret = new bytes(maxOut);
        assembly ("memory-safe") {
            ok := staticcall(cap, target, add(data, 32), mload(data), add(ret, 32), maxOut)
            size := returndatasize()
        }
    }
}
