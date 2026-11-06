// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base } from "./Base.t.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { ImpactLib } from "../src/libraries/ImpactLib.sol";
import { MockPriceFeed, MockSortedTroves, MockTroveManager, MockStabilityPool } from "./mocks/MezoMocks.sol";

/// @notice v3.1 (spec 5.5): emergency pause (guardian) and the 1% protocol fee on winning profit.
contract PauseAndProtocolFeeTest is Base {
    address guardian = makeAddr("guardian");
    MockStabilityPool sp;

    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        vm.warp(1_800_000_000);
        _deploy(address(new MockERC20("Mezo USD", "MUSD", 18)));
        sp = new MockStabilityPool(address(musd));
        MockSortedTroves sorted = new MockSortedTroves();
        sorted.setLast(makeAddr("lowTrove"));
        vm.deal(address(sp), 10 ether);
        vm.startPrank(owner);
        ex.setGuardian(guardian);
        ex.setStabilityPool(address(sp), address(new MockPriceFeed(P0)), address(sorted), address(new MockTroveManager()));
        ex.setSpParams(true, 100e18, 5_000, 2_000);
        vm.stopPrank();
    }

    function _fund(address who, uint256 amt) internal override {
        MockERC20(address(musd)).mint(who, amt);
    }

    /// @dev A trader loses `amt` in full (no stakers → no loss fee): houseCash += amt.
    function _seedHouse(uint256 amt) internal {
        uint256 pid = _open(carol, false, amt, 10, P0);
        _close(carol, pid, P0 * 12 / 10);
        _setPrice(P0);
    }

    function _stake(address who, uint256 amt) internal {
        uint256 pid = _open(who, true, amt, 10, P0);
        _close(who, pid, P0 * 8 / 10); // full loss → rebate tokens (house += amt)
        _setPrice(P0);
        uint256 bal = rt.balanceOf(who);
        vm.startPrank(who);
        rt.approve(address(st), bal);
        st.stake(bal);
        vm.stopPrank();
    }

    function _gain(uint256 size, uint256 entry, uint256 exit) internal view returns (uint256) {
        (uint256 b, uint256 rm, uint256 pm, uint256 rn, uint256 dd) = ex.impact();
        return ImpactLib.adjustedGain(ImpactLib.Params(b, rm, pm, rn, dd), true, size, entry, exit);
    }

    function _pause() internal {
        vm.prank(guardian);
        ex.pause();
    }

    // ================================================================== pause: roles
    function test_pause_guardianOrOwnerPauses_onlyOwnerUnpauses() public {
        vm.prank(alice);
        vm.expectRevert(HouseExchange.NotGuardian.selector);
        ex.pause();

        vm.expectEmit(address(ex));
        emit Paused(guardian);
        _pause();
        assertTrue(ex.paused());

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        ex.unpause();

        vm.expectEmit(address(ex));
        emit Unpaused(owner);
        vm.prank(owner);
        ex.unpause();
        assertFalse(ex.paused());

        vm.prank(owner); // owner may pause too
        ex.pause();
        assertTrue(ex.paused());
    }

    function test_setGuardian_onlyOwner_emits_andRevocable() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ex.setGuardian(alice);
        vm.expectEmit(address(ex));
        emit HouseExchange.GuardianSet(guardian, address(0));
        vm.prank(owner);
        ex.setGuardian(address(0));
        vm.prank(guardian);
        vm.expectRevert(HouseExchange.NotGuardian.selector);
        ex.pause();
    }

    // ================================================================== pause: blocked list
    function test_pause_blocksOpenFillsLiquidationAndSweep() public {
        uint256 bustPid = _open(alice, true, 100e18, 100, P0); // 10k long, bust ≈ 99,050
        uint256 openOid = _request(bob, false, 100e18, 10);
        _setPrice(98_000e18);
        assertTrue(ex.isLiquidatable(bustPid));
        _pause();

        _fund(carol, 100e18);
        vm.startPrank(carol);
        musd.approve(address(ex), 100e18);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ex.requestOpen(true, 100e18, 10, 0);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ex.executeOrder(openOid, NO_UPD);

        vm.prank(liquidator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ex.liquidate(bustPid, NO_UPD);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        ex.sweepExcess();

        // unpause (owner) → the same actions work again
        vm.prank(owner);
        ex.unpause();
        vm.prank(liquidator);
        ex.liquidate(bustPid, NO_UPD);
        vm.prank(keeper);
        ex.executeOrder(openOid, NO_UPD);
        assertEq(uint8(ex.getOrder(openOid).status), 2);
        _checkAccounting();
    }

    // ================================================================== pause: allowed list
    function test_pause_closeCanBeRequestedButNotFilled_expiredOrdersRefund() public {
        uint256 pid = _open(alice, true, 100e18, 10, P0);
        uint256 openOid = _request(bob, true, 50e18, 10);
        _pause();

        vm.prank(alice);
        uint256 closeOid = ex.requestClose(pid, 0); // allowed: queued for after the pause
        _setPrice(P0);
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ex.executeOrder(closeOid, NO_UPD);

        vm.warp(block.timestamp + 301);
        ex.cancelExpired(openOid); // refund still works
        assertEq(musd.balanceOf(bob), 50e18, "escrow refunded while paused");
        ex.cancelExpired(closeOid);
        assertTrue(ex.getPosition(pid).open, "expired close leaves the position open");
        ex.pushPrice(NO_UPD); // harmless while paused
        _checkAccounting();

        // after unpause a new close fills normally
        vm.prank(owner);
        ex.unpause();
        _close(alice, pid, P0);
        assertFalse(ex.getPosition(pid).open);
        _checkAccounting();
    }

    function test_pause_harvestStakingAndAdminStillWork() public {
        _stake(bob, 100e18); // bob stakes; house 100
        _seedHouse(1_000e18); // house 1,100 (−2% loss fee to stakers = 1,080)
        ex.rebalance(); // deposit into the (mock) SP
        uint256 dep = ex.spDeposit();
        assertGt(dep, 0);
        // a big winner with SP withdrawals blocked → part of the profit is queued
        sp.setBlocked(true);
        uint256 pid = _open(alice, true, 1_000e18, 10, P0);
        _close(alice, pid, 110_000e18);
        uint256 q = ex.queueTotal();
        assertGt(q, 0, "winner partly queued");

        _pause();
        sp.setBlocked(false);
        ex.harvest(10); // allowed: pays winners from SP withdrawals / cash
        assertEq(ex.queueTotal(), 0, "queue paid while paused");

        vm.startPrank(bob); // RebateStaking is not paused
        st.claim();
        uint256 bal = st.staked(bob);
        st.unstake(bal);
        rt.approve(address(st), bal);
        st.stake(bal);
        vm.stopPrank();

        vm.prank(owner); // admin still works (e.g. raise fees, disable SP)
        ex.setFees(300, 200, 200, 50, 5_000_000e18);
        assertEq(ex.winFeeBps(), 300);
        ex.forwardBtc();
        _checkAccounting();
    }

    function test_pause_rebalanceNeverDeposits_butStillWithdraws() public {
        _seedHouse(1_000e18);
        _pause();
        (uint8 a,) = ex.rebalanceAction();
        assertEq(a, 0, "no deposit while paused");
        ex.rebalance(); // no revert (keeper calls it every tick)
        assertEq(ex.spDeposit(), 0);

        vm.prank(owner);
        ex.unpause();
        ex.rebalance();
        assertEq(ex.spDeposit(), 500e18);

        _pause();
        vm.prank(owner);
        ex.setSpParams(false, 100e18, 5_000, 2_000); // stop SP → withdraw everything, even while paused
        (a,) = ex.rebalanceAction();
        assertEq(a, 2);
        ex.rebalance();
        assertEq(ex.spDeposit(), 0);
        assertEq(ex.houseCash(), 1_000e18);
        _checkAccounting();
    }

    // ================================================================== protocol fee: params
    function test_setTreasury_rejectsThisContract() public {
        vm.prank(owner);
        vm.expectRevert(HouseExchange.BadTreasury.selector);
        ex.setTreasury(address(ex));
        assertTrue(ex.treasury() != address(ex));
    }

    function test_constructor_rejectsOwnerEqualToThisContract() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(HouseExchange.BadTreasury.selector);
        new HouseExchange(address(musd), address(oracle), address(rt), predicted);
    }

    function test_fee_defaultsAndSetters() public {
        HouseExchange fresh = new HouseExchange(address(musd), address(oracle), address(rt), owner);
        assertEq(fresh.protocolFeeBps(), 100, "1% default");
        assertEq(fresh.treasury(), owner, "default treasury = initial owner");
        assertEq(fresh.guardian(), address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ex.setProtocolFee(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ex.setTreasury(alice);

        vm.startPrank(owner);
        vm.expectRevert(HouseExchange.FeeTooHigh.selector);
        ex.setProtocolFee(501);
        vm.expectEmit(address(ex));
        emit HouseExchange.ProtocolFeeSet(500);
        ex.setProtocolFee(500);
        vm.expectRevert(HouseExchange.BadTreasury.selector);
        ex.setTreasury(address(0));
        vm.expectEmit(address(ex));
        emit HouseExchange.TreasurySet(treasury, bob);
        ex.setTreasury(bob);
        vm.stopPrank();
        assertEq(ex.treasury(), bob);
    }

    // ================================================================== protocol fee: settlement
    /// Worked example (no stakers): 1,000 MUSD × 10x long at 100,000 closed at 101,000.
    /// raw = 100, impact-adjusted gain g ≈ 88; win fee 2% g stays with the house (no stakers);
    /// protocol fee 1% g → treasury; alice gets 1,000 + g − 3% g.
    function test_fee_workedExample_noStakers() public {
        vm.prank(owner);
        ex.setSpParams(false, 100e18, 5_000, 2_000);
        _seedHouse(1_000e18);
        uint256 pid = _open(alice, true, 1_000e18, 10, P0);
        uint256 g = _gain(10_000e18, P0, 101_000e18);
        uint256 winFee = g * 200 / 10_000;
        uint256 pFee = g * 100 / 10_000;
        (, uint256 preview) = ex.previewClose(pid, 101_000e18);
        assertEq(preview, 1_000e18 + g - winFee - pFee, "previewClose subtracts both fees");

        vm.prank(alice);
        uint256 oid = ex.requestClose(pid, 0);
        _setPrice(101_000e18);
        vm.expectEmit(address(ex));
        emit HouseExchange.ProtocolFee(pFee);
        vm.prank(keeper);
        ex.executeOrder(oid, NO_UPD);

        emit log_named_decimal_uint("gain g", g, 18);
        emit log_named_decimal_uint("win fee (stays: no stakers)", winFee, 18);
        emit log_named_decimal_uint("protocol fee -> treasury", pFee, 18);
        emit log_named_decimal_uint("alice receives", preview, 18);
        assertEq(musd.balanceOf(alice), preview);
        assertEq(musd.balanceOf(treasury), pFee);
        assertEq(ex.totalProtocolFees(), pFee);
        assertEq(ex.houseCash(), 1_000e18 - (g - winFee), "house out = payout + pFee = g - winFee");
        _checkAccounting();
    }

    function test_fee_withStakers_houseOutflowIsExactlyTheGain() public {
        vm.prank(owner);
        ex.setSpParams(false, 100e18, 5_000, 2_000);
        _stake(bob, 100e18);
        _seedHouse(1_000e18);
        uint256 cash0 = ex.houseCash();
        uint256 toStakers0 = ex.totalToStakers();
        uint256 pid = _open(alice, true, 1_000e18, 10, P0);
        uint256 g = _gain(10_000e18, P0, 101_000e18);
        _close(alice, pid, 101_000e18);
        assertEq(ex.totalToStakers() - toStakers0, g * 200 / 10_000, "2% win fee to stakers");
        assertEq(musd.balanceOf(treasury), g * 100 / 10_000, "1% to treasury");
        assertEq(cash0 - ex.houseCash(), g, "winner + both fees = gain (same as v3)");
        _checkAccounting();
    }

    function test_fee_queuedWinnerPaysNoFee_evenAfterHarvest() public {
        uint256 pa = _open(alice, true, 1_000e18, 50, P0);
        uint256 pb = _open(bob, false, 1_000e18, 50, P0);
        uint256 g = _gain(50_000e18, P0, 101_000e18);
        _close(alice, pa, 101_000e18); // house empty → whole payout queued
        uint256 owed = ex.queuedOf(alice);
        assertEq(owed, g, "queued winner is owed the whole gain (fee-free)");
        assertEq(musd.balanceOf(treasury), 0, "no fee on a queued payout");
        _close(bob, pb, 101_000e18); // bob's loss repays the queue
        assertEq(ex.queuedOf(alice), 0);
        ex.harvest(10);
        assertEq(musd.balanceOf(treasury), 0, "harvest never charges the fee");
        assertEq(ex.totalProtocolFees(), 0);
        _checkAccounting();
    }

    function test_fee_partialPayoutWaivesFee() public {
        vm.prank(owner);
        ex.setSpParams(false, 100e18, 5_000, 2_000);
        _seedHouse(50e18);
        uint256 pid = _open(alice, true, 1_000e18, 10, P0);
        uint256 g = _gainAt(pid, 101_000e18);
        _close(alice, pid, 101_000e18); // payout ≈ 85 > cash 50
        assertEq(musd.balanceOf(alice), 1_050e18, "margin + all cash");
        assertEq(ex.queueTotal(), g - 50e18, "rest of the WHOLE gain queued (no fee deducted)");
        assertEq(musd.balanceOf(treasury), 0, "fee waived on a partial payout");
        _checkAccounting();
    }

    /// Cash covers the net payout but not payout + protocol fee: no immediate full settlement → fee-free, the winner
    /// gets all cash now and the rest of the whole gain is queued (nothing is silently kept by the house).
    function test_fee_cashCoversPayoutButNotFee_feeFreeRestQueued() public {
        vm.prank(owner);
        ex.setSpParams(false, 100e18, 5_000, 2_000);
        uint256 pid = _open(alice, true, 1_000e18, 10, P0);
        uint256 g = _gainAt(pid, 101_000e18);
        uint256 payout = g - g * 200 / 10_000 - g * 100 / 10_000;
        uint256 cash = payout + (g * 100 / 10_000) / 2; // payout fits, payout + pFee does not
        _seedHouse(cash);
        assertEq(ex.houseCash(), cash);
        _close(alice, pid, 101_000e18);
        assertEq(musd.balanceOf(alice), 1_000e18 + cash, "margin + all cash");
        assertEq(ex.queuedOf(alice), g - cash, "rest of the whole gain queued");
        assertEq(musd.balanceOf(treasury), 0);
        assertEq(ex.houseCash(), 0);
        _checkAccounting();
    }

    /// v3.1 (operator decision 2026-11-07): when the payout needs a Stability Pool top-up, the top-up also covers
    /// both fees, so they are charged whenever the house (cash + SP) has the assets.
    function test_fee_spTopUpAlsoCoversBothFees() public {
        _stake(bob, 100e18); // stakers active → win fee is collected too
        _seedHouse(1_000e18);
        ex.rebalance(); // part of the cash goes into the SP
        assertGt(ex.spDeposit(), 0);
        uint256 assets0 = ex.houseCash() + ex.spDeposit();
        uint256 toStakers0 = ex.totalToStakers();
        uint256 pid = _open(alice, true, 1_000e18, 10, P0);
        uint256 g = _gain(10_000e18, P0, 108_000e18);
        (, uint256 receive_) = ex.previewClose(pid, 108_000e18);
        assertGt(receive_ - 1_000e18, ex.houseCash(), "needs the SP");
        _close(alice, pid, 108_000e18);
        assertEq(musd.balanceOf(alice), receive_, "paid in full");
        assertEq(musd.balanceOf(treasury), g * 100 / 10_000, "1% protocol fee despite the top-up");
        assertEq(ex.totalToStakers() - toStakers0, g * 200 / 10_000, "2% win fee despite the top-up");
        assertEq(assets0 - (ex.houseCash() + ex.spDeposit()), g, "house assets out = gain (as v3 + fees)");
        _checkAccounting();
    }

    /// Withdrawals blocked: no top-up possible → payout partly queued and both fees waived (never charged later).
    function test_fee_spBlockedPartialPayoutWaivesFees() public {
        _seedHouse(1_000e18);
        ex.rebalance();
        sp.setBlocked(true);
        uint256 pid = _open(alice, true, 1_000e18, 10, P0);
        _close(alice, pid, 108_000e18);
        assertGt(ex.queueTotal(), 0);
        assertEq(musd.balanceOf(treasury), 0);
        sp.setBlocked(false);
        ex.harvest(10);
        assertEq(ex.queueTotal(), 0);
        assertEq(musd.balanceOf(treasury), 0, "harvest never charges the fee");
        _checkAccounting();
    }

    /// Compared with protocolFeeBps = 0, the fee never makes the house pay out more (winner + treasury), never grows
    /// the queue, and the winner's total claim shrinks by at most the fee.
    /// With `useSp`, part of the house sits in the (mock) Stability Pool, so the top-up path is exercised too;
    /// "house out" counts cash + SP deposit.
    function testFuzz_fee_houseNeverPaysMoreThanWithoutFee(uint256 cashSeed, uint256 moveBps, uint256 margin, bool useSp)
        public
    {
        if (!useSp) {
            vm.prank(owner);
            ex.setSpParams(false, 100e18, 5_000, 2_000);
        }
        cashSeed = bound(cashSeed, 0, 2_000e18);
        moveBps = bound(moveBps, 1, 1_500);
        margin = bound(margin, 10e18, 1_000e18);
        if (cashSeed >= 10e18) _seedHouse(cashSeed);
        if (useSp) ex.rebalance();
        uint256 pid = _open(alice, true, margin, 10, P0);
        uint256 exit = P0 * (10_000 + moveBps) / 10_000;

        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        ex.setProtocolFee(0);
        (uint256 out0, uint256 q0, uint256 claim0) = _closeAndMeasure(pid, exit);
        vm.revertToState(snap);
        (uint256 out1, uint256 q1, uint256 claim1) = _closeAndMeasure(pid, exit);
        bool charged = musd.balanceOf(treasury) > 0;

        uint256 g = _gain(margin * 10, P0, exit);
        // same settlement threshold with or without the protocol fee (payout + pFee == payout without pFee)
        assertEq(out1, out0, "house assets out (winner + fees) identical");
        assertEq(q1, q0, "queue identical");
        assertEq(claim0 - claim1, charged ? g * 100 / 10_000 : 0, "claim drops by the fee only if it was charged");
        // the house never owes more than the gain from this close (paid now + queued + fees)
        assertLe(out1 + q1, g, "out + queued <= gain");
        if (!charged) assertEq(claim1, margin + g, "fee-free: winner owed margin + the whole gain");
        else assertEq(q1, 0, "fees only on an immediate full settlement");
        _checkAccounting();
    }

    function _closeAndMeasure(uint256 pid, uint256 exit) internal returns (uint256 out, uint256 q, uint256 claim) {
        uint256 assets0 = ex.houseCash() + ex.spDeposit();
        uint256 a0 = musd.balanceOf(alice);
        _close(alice, pid, exit);
        out = assets0 - (ex.houseCash() + ex.spDeposit());
        q = ex.queueTotal();
        claim = musd.balanceOf(alice) - a0 + ex.queuedOf(alice);
    }
}
