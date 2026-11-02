// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base } from "./Base.t.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockPriceFeed, MockSortedTroves, MockTroveManager, MockStabilityPool } from "./mocks/MezoMocks.sol";

/// @notice spec 5.2 (B): house MUSD in the MUSD Stability Pool (mocked).
contract StabilityPoolTest is Base {
    MockStabilityPool sp;
    MockPriceFeed pf;
    MockSortedTroves sorted;
    MockTroveManager tm;
    address lowTrove = makeAddr("lowTrove");

    function setUp() public {
        vm.warp(1_800_000_000);
        _deploy(address(new MockERC20("Mezo USD", "MUSD", 18)));
        sp = new MockStabilityPool(address(musd));
        pf = new MockPriceFeed(P0);
        sorted = new MockSortedTroves();
        tm = new MockTroveManager();
        sorted.setLast(lowTrove);
        vm.deal(address(sp), 100 ether); // BTC for simulated liquidation gains
        vm.startPrank(owner);
        ex.setStabilityPool(address(sp), address(pf), address(sorted), address(tm));
        ex.setSpParams(true, 100e18, 5_000, 2_000); // keep 100 on hand, ≤50% in SP, ±20% band
        vm.stopPrank();
    }

    function _fund(address who, uint256 amt) internal override {
        MockERC20(address(musd)).mint(who, amt);
    }

    /// @dev A trader loses `amt` in full (no stakers → no fee): houseCash += amt.
    function _seedHouse(uint256 amt) internal {
        uint256 pid = _open(carol, false, amt, 10, P0);
        _close(carol, pid, P0 * 12 / 10);
        _setPrice(P0);
    }

    function _check() internal view {
        _checkAccounting();
    }

    // ------------------------------------------------------------------ deposit / band / cap
    function test_sp_depositsAboveBand_cappedByMaxShare() public {
        _seedHouse(1_000e18);
        assertEq(ex.houseCash(), 1_000e18);
        (uint8 a, uint256 amt) = ex.rebalanceAction();
        assertEq(a, 1);
        assertEq(amt, 500e18, "cap: 50% of 1000 (not 1000-100)");
        vm.expectEmit(address(ex));
        emit HouseExchange.SpDeposited(500e18);
        ex.rebalance();
        assertEq(ex.spDeposit(), 500e18);
        assertEq(ex.houseCash(), 500e18);
        assertEq(ex.houseEquity(), 1_000e18, "equity = cash + SP deposit");
        _check();
        (a,) = ex.rebalanceAction();
        assertEq(a, 0, "at the cap: nothing more");
        ex.rebalance();
        assertEq(ex.spDeposit(), 500e18);
    }

    function test_sp_depositsDownToMinLiquidWhenUncapped() public {
        vm.prank(owner);
        ex.setSpParams(true, 100e18, 10_000, 2_000);
        _seedHouse(1_000e18);
        ex.rebalance();
        assertEq(ex.houseCash(), 100e18, "down to spMinLiquid");
        assertEq(ex.spDeposit(), 900e18);
        _check();
    }

    function test_sp_bandHysteresis() public {
        _seedHouse(110e18);
        _seedHouse(10e18); // 120 == 100 * 1.2: not above
        (uint8 a,) = ex.rebalanceAction();
        assertEq(a, 0);
        vm.prank(owner);
        ex.setSpParams(true, 100e18, 5_000, 2_000);
        _seedHouse(10e18); // 130 > 120
        (a,) = ex.rebalanceAction();
        assertEq(a, 1);
        vm.prank(owner);
        ex.setSpParams(true, 100e18, 10_000, 2_000);
        ex.rebalance();
        assertEq(ex.houseCash(), 100e18);
        assertEq(ex.spDeposit(), 30e18);
        // between 80 and 120: nothing happens either way
        vm.prank(owner);
        ex.setSpParams(true, 124e18, 10_000, 2_000); // lo = 99.2 → cash 100 is inside the band
        (a,) = ex.rebalanceAction();
        assertEq(a, 0);
        vm.prank(owner);
        ex.setSpParams(true, 126e18, 10_000, 2_000); // lo = 100.8 → withdraw toward 126, capped by the deposit
        (uint8 a2, uint256 amt) = ex.rebalanceAction();
        assertEq(a2, 2);
        assertEq(amt, 26e18, "126 - 100");
        ex.rebalance();
        assertEq(ex.houseCash(), 126e18);
        assertEq(ex.spDeposit(), 4e18);
        _check();
    }

    function test_sp_noDepositWhileWithdrawalsBlocked() public {
        _seedHouse(1_000e18);
        tm.setIcr(1.09e18); // lowest trove under MCR
        (uint8 a,) = ex.rebalanceAction();
        assertEq(a, 0, "ICR < MCR: do not deposit");
        assertFalse(ex.spWithdrawable());
        ex.rebalance();
        assertEq(ex.spDeposit(), 0);
        tm.setIcr(1.1e18);
        assertTrue(ex.spWithdrawable());
        pf.setReverting(true);
        (a,) = ex.rebalanceAction();
        assertEq(a, 0, "PriceFeed down (SP withdrawals would revert too): do not deposit");
        pf.setReverting(false);
        sorted.setLast(address(0));
        assertTrue(ex.spWithdrawable(), "no troves at all");
    }

    function test_sp_noDepositWhileQueueActive() public {
        // winner queued with an empty house, then a small loss leaves cash < queue
        uint256 pa = _open(alice, true, 1_000e18, 10, P0);
        _close(alice, pa, 110_000e18);
        assertGt(ex.queueTotal(), 0);
        vm.prank(owner);
        ex.setSpParams(true, 0, 10_000, 0);
        (uint8 a,) = ex.rebalanceAction();
        assertEq(a, 0);
    }

    function test_sp_withdrawsBelowBand() public {
        _seedHouse(1_000e18);
        ex.rebalance(); // cash 500, SP 500
        vm.prank(owner);
        ex.setSpParams(true, 700e18, 5_000, 2_000); // lo = 560 > 500
        (uint8 a, uint256 amt) = ex.rebalanceAction();
        assertEq(a, 2);
        assertEq(amt, 200e18);
        vm.expectEmit(address(ex));
        emit HouseExchange.SpWithdrawn(200e18, 200e18);
        ex.rebalance();
        assertEq(ex.houseCash(), 700e18);
        assertEq(ex.spDeposit(), 300e18);
        _check();
    }

    function test_sp_withdrawRevert_isCaughtAndEmitted() public {
        _seedHouse(1_000e18);
        ex.rebalance();
        vm.prank(owner);
        ex.setSpParams(true, 700e18, 5_000, 2_000);
        sp.setBlocked(true);
        vm.expectEmit(address(ex));
        emit HouseExchange.SpWithdrawBlocked(200e18);
        ex.rebalance();
        assertEq(ex.houseCash(), 500e18, "unchanged");
        assertEq(ex.spDeposit(), 500e18);
        _check();
    }

    function test_sp_underGassedWithdrawRevertsInsteadOfBeingSwallowed() public {
        _seedHouse(1_000e18);
        ex.rebalance();
        vm.prank(owner);
        ex.setSpParams(true, 700e18, 5_000, 2_000);
        (bool ok, bytes memory ret) = address(ex).call{ gas: 900_000 }(abi.encodeCall(ex.rebalance, ()));
        assertFalse(ok);
        assertEq(bytes4(ret), HouseExchange.InsufficientGasForSp.selector);
        assertEq(ex.spDeposit(), 500e18);
    }

    function test_sp_disabledWithdrawsEverything() public {
        _seedHouse(1_000e18);
        ex.rebalance();
        vm.prank(owner);
        ex.setSpParams(false, 100e18, 5_000, 2_000);
        (uint8 a, uint256 amt) = ex.rebalanceAction();
        assertEq(a, 2);
        assertEq(amt, 500e18);
        ex.rebalance();
        assertEq(ex.spDeposit(), 0);
        assertEq(ex.houseCash(), 1_000e18);
        _check();
    }

    // ------------------------------------------------------------------ winners and the queue
    function _bigWinner() internal returns (uint256 pid) {
        pid = _open(alice, true, 1_000e18, 10, P0); // 10k long
    }

    function test_sp_winnerToppedUpFromSp() public {
        _seedHouse(1_000e18);
        ex.rebalance(); // cash 500, SP 500
        uint256 pid = _bigWinner();
        (, uint256 receive_) = ex.previewClose(pid, 108_000e18);
        uint256 payout = receive_ - 1_000e18;
        assertGt(payout, 500e18, "needs the SP");
        _close(alice, pid, 108_000e18);
        assertEq(ex.queueTotal(), 0, "paid in full");
        assertEq(musd.balanceOf(alice), receive_);
        assertEq(ex.spDeposit(), 1_000e18 - payout - ex.houseCash());
        _check();
    }

    function test_sp_withdrawBlocked_winnerStillSettles_restQueued_thenHarvestTopsUp() public {
        _seedHouse(1_000e18);
        ex.rebalance(); // cash 500, SP 500
        uint256 pid = _bigWinner();
        (, uint256 receive_) = ex.previewClose(pid, 108_000e18);
        uint256 payout = receive_ - 1_000e18;
        sp.setBlocked(true);
        _close(alice, pid, 108_000e18);
        assertFalse(ex.getPosition(pid).open, "settled");
        assertEq(musd.balanceOf(alice), 1_000e18 + 500e18, "margin + all cash on hand");
        assertEq(ex.queueTotal(), payout - 500e18, "rest queued");
        assertEq(ex.houseCash(), 0);
        _check();
        // harvest while still blocked: no-op
        ex.harvest(10);
        assertEq(ex.queueTotal(), payout - 500e18);
        // unblock: harvest tops up from the SP and pays the queue
        sp.setBlocked(false);
        ex.harvest(10);
        assertEq(ex.queueTotal(), 0);
        assertEq(musd.balanceOf(alice), receive_);
        assertEq(ex.spDeposit(), 500e18 - (payout - 500e18));
        _check();
    }

    function test_sp_rebalanceWithdrawsForQueue() public {
        _seedHouse(1_000e18);
        ex.rebalance();
        uint256 pid = _bigWinner();
        sp.setBlocked(true);
        _close(alice, pid, 108_000e18);
        uint256 q = ex.queueTotal();
        sp.setBlocked(false);
        (uint8 a, uint256 amt) = ex.rebalanceAction();
        assertEq(a, 2);
        assertEq(amt, 100e18 + q, "spMinLiquid + queueTotal - cash(0)");
        ex.rebalance();
        assertEq(ex.queueTotal(), 0, "rebalance harvests");
        assertEq(ex.houseCash(), 100e18);
        _check();
    }

    // ------------------------------------------------------------------ SP losses and BTC
    function test_sp_liquidationLossShowsInEquity() public {
        _seedHouse(1_000e18);
        ex.rebalance();
        sp.liquidate(address(ex), 100e18, 0.01 ether);
        assertEq(ex.spDeposit(), 400e18);
        assertEq(ex.houseEquity(), 900e18, "loss is the house's");
        _check(); // MUSD in the contract is unaffected
        // compounded deposit can go to zero; withdrawFromSP(0) still collects the BTC
        sp.liquidate(address(ex), 1_000e18, 0.02 ether);
        assertEq(ex.spDeposit(), 0);
        ex.forwardBtc(); // no stakers: kept
        assertEq(address(ex).balance, 0.03 ether);
        _check();
    }

    function _stake(address who, uint256 amt) internal {
        uint256 pid = _open(who, true, amt, 10, P0);
        _close(who, pid, P0 * 8 / 10); // full loss → rebate tokens
        _setPrice(P0);
        uint256 bal = rt.balanceOf(who);
        vm.startPrank(who);
        rt.approve(address(st), bal);
        st.stake(bal);
        vm.stopPrank();
    }

    function test_sp_btcGainForwardedToStakers() public {
        _seedHouse(1_000e18);
        ex.rebalance();
        sp.liquidate(address(ex), 50e18, 0.5 ether);
        // gains arrive inside a nonReentrant SP call (here: forwardBtc → withdrawFromSP(0) → receive)
        assertEq(ex.forwardableBtc(), 0, "no stakers yet");
        assertEq(ex.forwardBtc(), 0);
        assertEq(address(ex).balance, 0.5 ether, "kept for later");
        _stake(bob, 100e18);
        sp.liquidate(address(ex), 50e18, 0.25 ether);
        assertEq(ex.forwardableBtc(), 0.75 ether);
        vm.expectEmit(address(ex));
        emit HouseExchange.BtcForwarded(0.75 ether);
        assertEq(ex.forwardBtc(), 0.75 ether);
        assertEq(address(ex).balance, 0);
        assertEq(address(st).balance, 0.75 ether);
        assertEq(ex.totalBtcToStakers(), 0.75 ether);
        uint256 b0 = bob.balance;
        vm.prank(bob);
        (, uint256 btc) = st.claim();
        assertApproxEqAbs(btc, 0.75 ether, 1);
        assertEq(bob.balance - b0, btc);
        _check();
    }

    function test_sp_btcArrivingDuringRebalanceDeposit() public {
        _seedHouse(1_000e18);
        ex.rebalance(); // 500 in
        sp.liquidate(address(ex), 0, 0.1 ether);
        _seedHouse(1_000e18); // cash 1500, SP 500 → cap 1000 → deposit 500 more; pending BTC is pushed to us
        ex.rebalance();
        assertEq(address(ex).balance, 0.1 ether);
        assertEq(ex.spDeposit(), 1_000e18);
        _check();
    }

    function test_sp_receiveOnlyFromStabilityPool() public {
        address rando = makeAddr("rando");
        vm.deal(rando, 1 ether);
        vm.prank(rando);
        (bool ok, bytes memory ret) = address(ex).call{ value: 1 }("");
        assertFalse(ok);
        assertEq(bytes4(ret), HouseExchange.NotStabilityPool.selector);
        vm.prank(address(sp));
        (ok,) = address(ex).call{ value: 1 }("");
        assertTrue(ok);
    }

    // ------------------------------------------------------------------ sweep, admin
    function test_sp_sweepExcessCountsSpButSendsOnlyCash() public {
        _seedHouse(1_000e18);
        ex.rebalance(); // cash 500, SP 500
        _stake(bob, 10e18); // +10 cash
        vm.prank(owner);
        ex.setFees(200, 200, 200, 50, 600e18);
        // assets 1010 > cap 600 → 410, all from cash (510)
        assertEq(ex.sweepExcess(), 410e18);
        assertEq(ex.houseCash(), 100e18);
        assertEq(ex.spDeposit(), 500e18);
        vm.prank(owner);
        ex.setFees(200, 200, 200, 50, 0);
        assertEq(ex.sweepExcess(), 100e18, "never more than the cash on hand");
        assertEq(ex.houseCash(), 0);
        _check();
    }

    function test_sp_setStabilityPoolRefusedWithDeposit() public {
        _seedHouse(1_000e18);
        ex.rebalance();
        vm.prank(owner);
        vm.expectRevert(HouseExchange.SpDepositOutstanding.selector);
        ex.setStabilityPool(address(0), address(0), address(0), address(0));
    }

    function test_sp_adminOnlyOwner() public {
        vm.expectRevert();
        ex.setSpParams(true, 0, 10_000, 0);
        vm.expectRevert();
        ex.setStabilityPool(address(0), address(0), address(0), address(0));
        vm.prank(owner);
        vm.expectRevert(bytes("sp"));
        ex.setSpParams(true, 0, 10_001, 0);
    }

    /// Griefing check: anyone may call rebalance; it can never take cash below spMinLiquid, and never deposits
    /// while withdrawals are blocked or a winner is queued.
    function testFuzz_sp_rebalanceNeverDrainsBelowMinLiquid(uint256 seed, uint256 minLiquid, uint256 share) public {
        minLiquid = bound(minLiquid, 0, 2_000e18);
        share = bound(share, 0, 10_000);
        vm.prank(owner);
        ex.setSpParams(true, minLiquid, share, (seed >> 8) % 5_000);
        _seedHouse(10e18 + seed % 3_000e18);
        uint256 cash0 = ex.houseCash();
        ex.rebalance();
        ex.rebalance();
        if (cash0 >= minLiquid) assertGe(ex.houseCash(), minLiquid);
        assertLe(ex.spDeposit(), (cash0 * share) / 10_000);
        _check();
    }
}
