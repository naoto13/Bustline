// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { HouseExchangeTest } from "../HouseExchange.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Re-runs the FULL unit/fuzz suite against the REAL Mezo testnet MUSD bytecode/state, forked from
///         MEZO_FORK_URL (a local anvil fork, or https://rpc.test.mezo.org read-only). Nothing is broadcast.
/// @dev Skip BTC/USD (0x7b7c…0015) is a chain precompile a forked EVM cannot execute → MockOracle (same interface).
///      Demo MUSD is credited with vm.store on the balances mapping (slot 0, verified against the deployed MUSD).
contract HouseExchangeForkTest is HouseExchangeTest {
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;

    function setUp() public override {
        string memory url = vm.envOr("MEZO_FORK_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
        require(block.chainid == 31611, "not a Mezo testnet fork");
        require(MUSD.code.length > 0, "MUSD missing");
        vm.warp(block.timestamp + 1);
        _deploy(MUSD);
    }

    function _fund(address who, uint256 amt) internal override {
        bytes32 slot = keccak256(abi.encode(who, uint256(0)));
        uint256 cur = uint256(vm.load(MUSD, slot));
        vm.store(MUSD, slot, bytes32(cur + amt));
        assertEq(IERC20(MUSD).balanceOf(who), cur + amt, "MUSD balance slot");
    }

    /// @notice Milestone scenario on real MUSD: open → close(win, queued) → close(loss) repays queue → liquidation.
    function test_fork_milestone_open_close_liq_queue() public {
        assertEq(keccak256(bytes(_sym())), keccak256("MUSD"));
        uint256 pa = _open(alice, true, 1_000e18, 50, P0);
        uint256 pb = _open(bob, false, 1_000e18, 50, P0);
        uint256 pc = _open(carol, true, 100e18, 100, P0);
        _close(alice, pa, 101_000e18);
        uint256 owed = ex.queuedOf(alice);
        assertGt(owed, 0, "winner queued (house empty)");
        // crash below carol's bust → liquidation pays part of the queue
        _setPrice(98_000e18);
        vm.prank(liquidator);
        ex.liquidate(pc, NO_UPD);
        assertEq(IERC20(MUSD).balanceOf(liquidator), 0.5e18);
        _close(bob, pb, 98_000e18); // bob (short) wins 2% too → queued behind alice
        _checkAccounting();
        assertGt(ex.queueTotal(), 0);
        // new loser repays FIFO
        uint256 pd = _open(carol, true, 2_000e18, 10, 98_000e18);
        _close(carol, pd, 80_000e18);
        assertEq(ex.queueTotal(), 0, "queue fully paid by later losses");
        assertEq(ex.queuedOf(alice), 0);
        _checkAccounting();
    }

    function _sym() internal view returns (string memory) {
        (bool ok, bytes memory r) = MUSD.staticcall(abi.encodeWithSignature("symbol()"));
        require(ok);
        return abi.decode(r, (string));
    }
}
