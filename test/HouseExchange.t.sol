// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base } from "./Base.t.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { RebateToken } from "../src/RebateToken.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { ImpactLib } from "../src/libraries/ImpactLib.sol";

contract HouseExchangeTest is Base {
    function setUp() public virtual {
        vm.warp(1_800_000_000);
        _deploy(address(new MockERC20("Mezo USD", "MUSD", 18)));
    }

    function _fund(address who, uint256 amt) internal virtual override {
        MockERC20(address(musd)).mint(who, amt);
    }

    // ---------------------------------------------------------------- 2-step execution
    function test_fillRequiresLaterOracleUpdate() public {
        uint256 oid = _request(alice, true, 100e18, 10);
        vm.prank(keeper);
        vm.expectRevert(HouseExchange.NotYetFillable.selector);
        ex.executeOrder(oid, NO_UPD);
        // same-second update is still not "later"
        vm.prank(owner);
        oracle.setPrice(P0 + 1e18);
        vm.prank(keeper);
        vm.expectRevert(HouseExchange.NotYetFillable.selector);
        ex.executeOrder(oid, NO_UPD);
        _setPrice(101_000e18);
        vm.prank(keeper);
        ex.executeOrder(oid, NO_UPD);
        assertEq(ex.getPosition(0).entryPrice, 101_000e18, "filled at the later price");
    }

    function test_onlyKeeperExecutes() public {
        uint256 oid = _request(alice, true, 100e18, 10);
        _setPrice(P0);
        vm.prank(alice);
        vm.expectRevert(HouseExchange.NotKeeper.selector);
        ex.executeOrder(oid, NO_UPD);
    }

    function test_leverageAndMarginLimits() public {
        _fund(alice, 1_000e18);
        vm.startPrank(alice);
        musd.approve(address(ex), type(uint256).max);
        vm.expectRevert(HouseExchange.BadLeverage.selector);
        ex.requestOpen(true, 100e18, 101, 0);
        vm.expectRevert(HouseExchange.BadLeverage.selector);
        ex.requestOpen(true, 100e18, 0, 0);
        vm.expectRevert(HouseExchange.MarginTooSmall.selector);
        ex.requestOpen(true, 9e18, 10, 0);
        ex.requestOpen(true, 100e18, 100, 0); // 100x ok
        vm.stopPrank();
    }

    function test_expiredOrderRefund() public {
        uint256 oid = _request(alice, true, 100e18, 10);
        vm.expectRevert(HouseExchange.NotExpired.selector);
        ex.cancelExpired(oid);
        vm.warp(block.timestamp + 301);
        ex.cancelExpired(oid);
        assertEq(musd.balanceOf(alice), 100e18);
        _checkAccounting();
    }

    function test_slippageCancelsAndRefunds() public {
        _fund(alice, 100e18);
        vm.startPrank(alice);
        musd.approve(address(ex), 100e18);
        uint256 oid = ex.requestOpen(true, 100e18, 10, 100_500e18);
        vm.stopPrank();
        _setPrice(101_000e18);
        vm.prank(keeper);
        ex.executeOrder(oid, NO_UPD);
        assertEq(uint8(ex.getOrder(oid).status), 3);
        assertEq(musd.balanceOf(alice), 100e18);
    }

    function test_oiCapCancels() public {
        vm.prank(owner);
        ex.setRisk(100, 10e18, 1_000_000e18, 1_500e18, 2_000, 300);
        _open(alice, true, 100e18, 10, P0); // 1000 notional
        uint256 oid = _request(bob, true, 100e18, 10);
        _setPrice(P0);
        vm.prank(keeper);
        ex.executeOrder(oid, NO_UPD);
        assertEq(uint8(ex.getOrder(oid).status), 3, "cancelled by OI cap");
        _open(bob, false, 100e18, 10, P0); // other side unaffected
        _checkAccounting();
    }

    // ---------------------------------------------------------------- open / close / queue
    function test_winnerQueuedWhenHouseEmpty_thenPaidByLoser() public {
        uint256 pa = _open(alice, true, 1_000e18, 50, P0); // 50k long
        uint256 pb = _open(bob, false, 1_000e18, 50, P0); // 50k short
        // +1%: alice wins ~500 raw, bob loses 500
        _close(alice, pa, 101_000e18);
        assertEq(musd.balanceOf(alice), 1_000e18, "margin returned immediately");
        uint256 owed = ex.queuedOf(alice);
        assertGt(owed, 0, "profit queued (house is empty)");
        assertLt(owed, 500e18, "haircut + win fee applied");
        assertEq(ex.queueTotal(), owed);
        assertLt(ex.houseEquity(), 0, "temporary insolvency");
        _checkAccounting();

        _close(bob, pb, 101_000e18);
        // bob's 500 loss (no loss fee: queue was active) repays alice FIFO
        assertEq(ex.queuedOf(alice), 0, "queue cleared");
        assertEq(musd.balanceOf(alice), 1_000e18 + owed);
        assertEq(musd.balanceOf(bob), 500e18);
        assertEq(ex.houseCash(), 500e18 - owed);
        assertEq(rt.balanceOf(bob), 500e18 * 100, "rebate minted on full loss (flat rate 100/MUSD)");
        _checkAccounting();
    }

    function test_fifoOrderAndPartialHarvest() public {
        uint256 p1 = _open(alice, true, 1_000e18, 10, P0);
        uint256 p2 = _open(bob, true, 1_000e18, 10, P0);
        uint256 p3 = _open(carol, false, 100e18, 10, P0);
        _close(alice, p1, 110_000e18);
        _close(bob, p2, 110_000e18);
        (address a0, uint256 q0) = ex.queueEntry(0);
        (address a1, uint256 q1) = ex.queueEntry(1);
        assertEq(a0, alice);
        assertEq(a1, bob);
        assertEq(q0, q1);
        // carol loses 100 → pays only (part of) alice, bob untouched
        _close(carol, p3, 110_000e18);
        (, uint256 q0b) = ex.queueEntry(0);
        (, uint256 q1b) = ex.queueEntry(1);
        assertEq(q0b, q0 - 100e18);
        assertEq(q1b, q1);
        assertEq(ex.queueHead(), 0);
        _checkAccounting();
    }

    function test_winnerPaidDirectWhenHouseSolvent() public {
        uint256 pb = _open(bob, false, 1_000e18, 10, P0);
        _close(bob, pb, 110_000e18); // bob loses full margin → house 1000 (no stakers: no loss fee)
        assertEq(ex.houseCash(), 1_000e18);
        uint256 pa = _open(alice, true, 100e18, 10, P0);
        _close(alice, pa, 101_000e18);
        assertEq(ex.queueTotal(), 0);
        assertGt(musd.balanceOf(alice), 100e18);
        _checkAccounting();
    }

    // ---------------------------------------------------------------- liquidation
    function test_liquidation_hardBust() public {
        uint256 pid = _open(alice, true, 100e18, 100, P0); // 10k long @100x
        uint256 bust = ex.bustPriceOf(pid);
        assertEq(bust, P0 - 1_000e18 + 50e18, "1% zero-equity + 5bps buffer");
        _setPrice(bust + 1);
        vm.expectRevert(HouseExchange.NotLiquidatable.selector);
        ex.liquidate(pid, NO_UPD);
        _setPrice(bust);
        vm.prank(liquidator);
        ex.liquidate(pid, NO_UPD);
        assertEq(musd.balanceOf(liquidator), 0.5e18, "0.5% keeper reward");
        assertEq(musd.balanceOf(alice), 0, "full margin forfeited");
        assertEq(rt.balanceOf(alice), 100e18 * 100, "mint on full margin");
        assertEq(ex.houseCash(), 99.5e18, "no stakers: fee stays with house");
        assertEq(ex.openPositionIds().length, 0);
        _checkAccounting();
    }

    function test_shortLiquidation() public {
        uint256 pid = _open(alice, false, 100e18, 20, P0);
        uint256 bust = ex.bustPriceOf(pid);
        assertEq(bust, P0 + 5_000e18 - 50e18);
        _setPrice(bust);
        assertTrue(ex.isLiquidatable(pid));
        ex.liquidate(pid, NO_UPD);
        _checkAccounting();
    }

    function test_closePastBustIsHardBust() public {
        uint256 pid = _open(alice, true, 100e18, 100, P0);
        _close(alice, pid, 98_000e18);
        assertEq(musd.balanceOf(alice), 0);
        assertFalse(ex.getPosition(pid).open);
        _checkAccounting();
    }

    // ---------------------------------------------------------------- rebate token + staking
    function test_rebateNonTransferable_stakeAndEarn() public {
        uint256 pid = _open(alice, true, 1_000e18, 10, P0);
        _close(alice, pid, 95_000e18); // lose 500
        uint256 bal = rt.balanceOf(alice);
        assertGt(bal, 0);
        vm.prank(alice);
        vm.expectRevert(RebateToken.NonTransferable.selector);
        rt.transfer(bob, 1);
        vm.startPrank(alice);
        rt.approve(address(st), bal);
        st.stake(bal);
        vm.stopPrank();
        // bob loses 1000 with queue empty → 2% loss fee to stakers
        uint256 pb = _open(bob, false, 1_000e18, 10, P0);
        _close(bob, pb, 110_000e18);
        assertApproxEqAbs(st.pending(alice), 20e18, 10);
        vm.prank(alice);
        st.claim();
        assertApproxEqAbs(musd.balanceOf(alice), 500e18 + 20e18, 10);
        vm.prank(alice);
        st.unstake(bal);
        assertEq(rt.balanceOf(alice), bal);
        vm.prank(owner);
        rt.setTransferable(true);
        vm.prank(alice);
        rt.transfer(bob, 1);
        _checkAccounting();
    }

    function test_sweepExcessToStakers() public {
        vm.prank(owner);
        ex.setFees(200, 200, 200, 50, 100e18);
        uint256 pid = _open(alice, true, 1_000e18, 10, P0);
        _close(alice, pid, 80_000e18); // full loss: house 1000 (no stakers → fee kept)
        vm.startPrank(alice);
        rt.approve(address(st), 1e18);
        st.stake(1e18);
        vm.stopPrank();
        uint256 swept = ex.sweepExcess();
        assertEq(swept, 900e18);
        assertApproxEqAbs(st.pending(alice), 900e18, 10); // accumulator rounding
        _checkAccounting();
    }

    function test_mintCurveDecaysAboveThreshold() public {
        vm.prank(owner);
        ex.setMintCurve(100e18, 500e18, 1_000e18);
        assertEq(ex.mintRate(), 100e18);
        uint256 pid = _open(alice, true, 1_000e18, 10, P0);
        _close(alice, pid, 80_000e18); // house 1000 > threshold 500 → HWM 500
        assertEq(ex.mintHwm(), 500e18);
        uint256 r = ex.mintRate(); // 100 * (1000/1500)^2 = 44.44
        assertApproxEqRel(r, 44.444e18, 1e15);
    }

    // ---------------------------------------------------------------- impact math
    function test_impactMatchesPublishedExamples() public view {
        // documented: on BTC (with deadband) a 1% move keeps ~88% of raw gain, 0.1% ~74%
        HouseExchange e = ex;
        (uint256 b, uint256 rm, uint256 pm, uint256 rn, uint256 dd) = e.impact();
        ImpactLib.Params memory p = ImpactLib.Params(b, rm, pm, rn, dd);
        uint256 g1 = ImpactLib.adjustedGain(p, true, 100_000e18, P0, 101_000e18);
        assertApproxEqRel(g1, 880e18, 0.01e18);
        uint256 g2 = ImpactLib.adjustedGain(p, true, 100_000e18, P0, 100_100e18);
        assertApproxEqRel(g2, 74e18, 0.02e18);
        assertEq(ImpactLib.adjustedGain(p, true, 100_000e18, P0, P0 + 1e18), 0, "inside deadband");
    }

    function testFuzz_impactScaleMonotonicAndCapped(uint256 m1, uint256 m2) public view {
        m1 = bound(m1, 1e12, 10e18);
        m2 = bound(m2, m1, 10e18);
        uint256 s1 = ex.impactScale(m1);
        uint256 s2 = ex.impactScale(m2);
        assertLe(s1, s2);
        assertLe(s2, 0.9e18);
    }

    function testFuzz_bustPriceBounds(uint256 margin, uint256 lev, bool isLong, uint256 entry) public pure {
        margin = bound(margin, 10e18, 1e24);
        lev = bound(lev, 1, 100);
        entry = bound(entry, 1_000e18, 1_000_000e18);
        uint256 size = margin * lev;
        uint256 b = ImpactLib.bustPrice(isLong, margin, size, entry, 2_000);
        // at the bust trigger, raw loss is within [margin - 5bps*size, margin]
        int256 pnl = ImpactLib.rawPnl(isLong, size, entry, b);
        if (lev == 1 && isLong) return; // zero price floor
        int256 tol = int256(size / 1e15) + 2;
        assertLe(-pnl, int256(margin) + tol);
        assertGe(-pnl + int256(size / 2_000) + tol, int256(margin));
    }

    // ---------------------------------------------------------------- randomized accounting
    function testFuzz_randomTradingKeepsAccounting(uint256 seed) public {
        address[3] memory who = [alice, bob, carol];
        uint256 price = P0;
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = seed % 4;
            address w = who[(seed >> 8) % 3];
            if (op <= 1) {
                _open(w, (seed >> 16) % 2 == 0, 10e18 + (seed >> 24) % 1_000e18, 1 + (seed >> 40) % 100, price);
            } else if (op == 2) {
                uint256[] memory ids = ex.openPositionIds();
                if (ids.length == 0) continue;
                uint256 pid = ids[(seed >> 48) % ids.length];
                _close(ex.getPosition(pid).owner, pid, price);
            } else {
                // random walk ±3%
                uint256 bps = (seed >> 56) % 600;
                price = bps >= 300 ? price * (10_000 + bps - 300) / 10_000 : price * (10_000 - bps) / 10_000;
                _setPrice(price);
                uint256[] memory ids = ex.openPositionIds();
                for (uint256 k; k < ids.length; ++k) {
                    if (ex.isLiquidatable(ids[k])) ex.liquidate(ids[k], NO_UPD);
                }
            }
            _checkAccounting();
        }
        ex.harvest(100);
        _checkAccounting();
        // house can never pay more than it received
        assertLe(ex.cumulativePaid(), ex.cumulativeLosses());
    }
}
