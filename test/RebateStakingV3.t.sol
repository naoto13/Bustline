// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { RebateToken } from "../src/RebateToken.sol";
import { RebateStaking } from "../src/RebateStaking.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockOracle } from "../src/mocks/MockOracle.sol";

contract RejectsBtc {
    function go(RebateStaking st, RebateToken rt, uint256 amt) external {
        rt.approve(address(st), amt);
        st.stake(amt);
    }

    function claim(RebateStaking st) external {
        st.claim();
    }
}

/// @notice spec 5.2 RebateStaking v3 (MUSD + BTC rewards) and spec 6 / todo 0 (RebateToken switch-over effects).
contract RebateStakingV3Test is Test {
    RebateToken rt;
    RebateStaking st;
    MockERC20 musd;
    address funder = makeAddr("funder");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        musd = new MockERC20("MUSD", "MUSD", 18);
        rt = new RebateToken("Mezo Paper", "MPAPER", address(this));
        st = new RebateStaking(address(rt), address(musd), funder);
        rt.setMinter(address(this));
        rt.setStaking(address(st));
        rt.mint(alice, 1e18);
        rt.mint(bob, 3e18);
        vm.deal(funder, 100 ether);
        _stake(alice, 1e18);
        _stake(bob, 3e18);
    }

    function _stake(address who, uint256 amt) internal {
        vm.startPrank(who);
        rt.approve(address(st), amt);
        st.stake(amt);
        vm.stopPrank();
    }

    function _rewardMusd(uint256 amt) internal {
        musd.mint(address(st), amt);
        vm.prank(funder);
        st.notifyReward(amt);
    }

    function _rewardBtc(uint256 amt) internal {
        vm.prank(funder);
        st.notifyRewardBtc{ value: amt }();
    }

    function test_v3_bothRewardsProRata() public {
        _rewardMusd(400e18);
        _rewardBtc(4 ether);
        assertEq(st.pending(alice), 100e18);
        assertEq(st.pending(bob), 300e18);
        assertEq(st.pendingBtc(alice), 1 ether);
        assertEq(st.pendingBtc(bob), 3 ether);
        vm.prank(alice);
        (uint256 m, uint256 b) = st.claim();
        assertEq(m, 100e18);
        assertEq(b, 1 ether);
        assertEq(musd.balanceOf(alice), 100e18);
        assertEq(alice.balance, 1 ether);
        // claimed once only
        vm.prank(alice);
        (m, b) = st.claim();
        assertEq(m + b, 0);
    }

    function test_v3_stakeChangeSettlesBoth() public {
        _rewardBtc(4 ether);
        vm.prank(bob);
        st.unstake(3e18); // bob leaves after earning 3
        _rewardBtc(1 ether); // all to alice
        _rewardMusd(1e18);
        assertEq(st.pendingBtc(alice), 2 ether);
        assertEq(st.pendingBtc(bob), 3 ether);
        assertEq(st.pending(alice), 1e18);
        assertEq(st.pending(bob), 0);
        vm.prank(bob);
        st.claim();
        assertEq(bob.balance, 3 ether);
        assertEq(address(st).balance, 2 ether);
    }

    function test_v3_onlyFunderNotifies() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(RebateStaking.NotFunder.selector);
        st.notifyRewardBtc{ value: 1 ether }();
        vm.prank(alice);
        vm.expectRevert(RebateStaking.NotFunder.selector);
        st.notifyReward(1);
    }

    function test_v3_noStakersReverts() public {
        RebateStaking empty = new RebateStaking(address(rt), address(musd), funder);
        vm.prank(funder);
        vm.expectRevert(RebateStaking.NoStakers.selector);
        empty.notifyRewardBtc{ value: 1 }();
    }

    function test_v3_claimRevertsIfBtcCannotBeDelivered() public {
        RejectsBtc c = new RejectsBtc();
        rt.mint(address(c), 1e18);
        c.go(st, rt, 1e18);
        _rewardBtc(5 ether);
        vm.expectRevert(RebateStaking.BtcTransferFailed.selector);
        c.claim(st);
        assertGt(st.pendingBtc(address(c)), 0, "still owed");
    }

    function testFuzz_v3_neverOwesMoreThanReceived(uint96 a, uint96 b, uint96 r1, uint96 r2) public {
        vm.assume(a > 0 && b > 0);
        rt.mint(alice, a);
        rt.mint(bob, b);
        _stake(alice, a);
        _rewardBtc(uint256(r1) % 50 ether);
        _stake(bob, b);
        _rewardBtc(uint256(r2) % 40 ether);
        assertLe(st.pendingBtc(alice) + st.pendingBtc(bob), address(st).balance);
        vm.prank(alice);
        st.claim();
        vm.prank(bob);
        st.claim();
    }

    // ------------------------------------------------------------------ todo 0: switching RebateToken to v3
    /// After `setStaking(v3)`, unstaking from the v2 staking contract REVERTS: the token only allows transfers
    /// from/to the *current* staking address. → v2 stakers must unstake before the switch (v2 totalStaked was 0 on
    /// 2026-11-02, re-check right before executing the timelock operation).
    function test_migration_setStakingBlocksOldUnstake() public {
        RebateStaking v3 = new RebateStaking(address(rt), address(musd), funder);
        rt.setStaking(address(v3));
        vm.prank(alice);
        vm.expectRevert(RebateToken.NonTransferable.selector);
        st.unstake(1e18);
        // switching back (or making the token transferable) is the only way out
        rt.setStaking(address(st));
        vm.prank(alice);
        st.unstake(1e18);
        assertEq(rt.balanceOf(alice), 1e18);
    }

    /// After `setMinter(v3)`, the v2 exchange can no longer settle a LOSS or liquidate (minting the rebate reverts).
    /// → v2's open positions must be closed before the switch.
    function test_migration_setMinterBlocksOldLossSettlement() public {
        address keeper = makeAddr("keeper");
        MockOracle o = new MockOracle(100_000e18);
        o.setMaxStaleness(365 days);
        HouseExchange v2 = new HouseExchange(address(musd), address(o), address(rt), address(this));
        v2.setKeeper(keeper, true);
        rt.setMinter(address(v2));
        musd.mint(alice, 100e18);
        vm.startPrank(alice);
        musd.approve(address(v2), 100e18);
        uint256 oid = v2.requestOpen(true, 100e18, 100, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 2);
        o.setPrice(100_000e18);
        vm.prank(keeper);
        v2.executeOrder(oid, new bytes[](0));
        rt.setMinter(makeAddr("v3")); // the switch
        vm.warp(block.timestamp + 2);
        o.setPrice(98_000e18);
        vm.expectRevert(RebateToken.NotMinter.selector);
        v2.liquidate(0, new bytes[](0));
    }
}
