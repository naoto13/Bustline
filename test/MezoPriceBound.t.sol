// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { RebateToken } from "../src/RebateToken.sol";
import { RebateStaking } from "../src/RebateStaking.sol";
import { PythPullOracle } from "../src/oracles/PythPullOracle.sol";
import { SignedPriceOracle } from "../src/oracles/SignedPriceOracle.sol";
import { MezoPriceBound } from "../src/oracles/MezoPriceBound.sol";
import { MockPyth } from "../src/mocks/MockPyth.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockPriceFeed } from "./mocks/MezoMocks.sol";

/// @notice spec 5.1 (C): PriceFeed-based price bound.
contract MezoPriceBoundTest is Test {
    bytes32 constant ID = keccak256("BTC/USD");
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    uint256 signerPk = 0xA11CE;

    MockPyth py;
    PythPullOracle po;
    SignedPriceOracle so;
    MockPriceFeed feed;

    function setUp() public {
        vm.warp(1_800_000_000);
        py = new MockPyth();
        po = new PythPullOracle(address(py), ID, 60, owner);
        so = new SignedPriceOracle(vm.addr(signerPk), 60, owner);
        feed = new MockPriceFeed(100_000e18);
        vm.startPrank(owner);
        po.setPriceBound(address(feed), 100); // ±1%
        so.setPriceBound(address(feed), 100);
        vm.stopPrank();
    }

    function _signed(uint256 p, uint256 t) internal view returns (bytes[] memory u) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, so.digest(p, t));
        u = new bytes[](1);
        u[0] = abi.encode(p, t, abi.encodePacked(r, s, v));
    }

    function _pyUpd(int64 p, uint256 t) internal pure returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = abi.encode(ID, p, uint64(0), int32(-8), t);
    }

    // ------------------------------------------------------------------ the three unit cases (signed oracle)
    function test_bound_insideUpdates() public {
        so.update(_signed(100_999e18, block.timestamp)); // +0.999%
        (uint256 p,) = so.latest();
        assertEq(p, 100_999e18);
        vm.warp(block.timestamp + 1);
        so.update(_signed(99_001e18, block.timestamp)); // -0.999%
        (p,) = so.latest();
        assertEq(p, 99_001e18);
    }

    function test_bound_outsideReverts() public {
        bytes[] memory u = _signed(101_001e18, block.timestamp); // +1.001%
        vm.expectRevert(abi.encodeWithSelector(MezoPriceBound.PriceDeviation.selector, 101_001e18, 100_000e18));
        so.update(u);
        u = _signed(98_999e18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(MezoPriceBound.PriceDeviation.selector, 98_999e18, 100_000e18));
        so.update(u);
    }

    function test_bound_priceFeedRevert_updatesWithoutBoundAndEmits() public {
        feed.setReverting(true);
        vm.expectEmit(address(so));
        emit MezoPriceBound.PriceBoundSkipped(150_000e18);
        so.update(_signed(150_000e18, block.timestamp)); // +50%: would be out of bound
        (uint256 p,) = so.latest();
        assertEq(p, 150_000e18);
        (bool ok,) = so.boundReference();
        assertFalse(ok);
    }

    function test_bound_priceFeedZeroIsTreatedAsFailure() public {
        feed.setPrice(0);
        so.update(_signed(150_000e18, block.timestamp));
        (uint256 p,) = so.latest();
        assertEq(p, 150_000e18);
    }

    /// The Skip stub on a fork recurses until it runs out of gas. The fixed stipend keeps that from starving the tx.
    function test_bound_gasBurningFeedIsSkippedWithinStipend() public {
        feed.setBurnGas(true);
        uint256 g0 = gasleft();
        so.update(_signed(150_000e18, block.timestamp));
        assertLt(g0 - gasleft(), 250_000, "only the stipend was burnt");
        (uint256 p,) = so.latest();
        assertEq(p, 150_000e18);
    }

    /// A caller must not be able to force the catch branch by under-gassing the transaction.
    function test_bound_underGassedCallRevertsInsteadOfSkipping() public {
        bytes[] memory u = _signed(150_000e18, block.timestamp);
        (bool ok, bytes memory ret) = address(so).call{ gas: 90_000 }(abi.encodeCall(so.update, (u)));
        assertFalse(ok);
        assertEq(bytes4(ret), MezoPriceBound.InsufficientGasForBound.selector);
        assertEq(so.price(), 0, "nothing stored");
    }

    function test_bound_disabled() public {
        vm.prank(owner);
        so.setPriceBound(address(0), 100);
        so.update(_signed(150_000e18, block.timestamp));
        vm.prank(owner);
        so.setPriceBound(address(feed), 0);
        (uint256 p,) = so.latest();
        assertEq(p, 150_000e18);
    }

    function test_bound_onlyOwner() public {
        vm.expectRevert();
        so.setPriceBound(address(feed), 100);
    }

    function test_bound_pyth_sameThreeCases() public {
        po.update{ value: 1 }(_pyUpd(10_099_000_000_000, block.timestamp)); // +0.99%
        po.latest();
        vm.warp(block.timestamp + 1);
        bytes[] memory bad = _pyUpd(10_200_000_000_000, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(MezoPriceBound.PriceDeviation.selector, 102_000e18, 100_000e18));
        po.update{ value: 1 }(bad);
        feed.setReverting(true);
        vm.expectEmit(address(po));
        emit MezoPriceBound.PriceBoundSkipped(102_000e18);
        po.update{ value: 1 }(bad);
        (uint256 p,) = po.latest();
        assertEq(p, 102_000e18);
    }

    // ------------------------------------------------------------------ exchange keeps working while PriceFeed reverts
    function _exchange(address oracle_) internal returns (HouseExchange ex) {
        MockERC20 musd = new MockERC20("MUSD", "MUSD", 18);
        vm.startPrank(owner);
        RebateToken rt = new RebateToken("Mezo Paper", "MPAPER", owner);
        ex = new HouseExchange(address(musd), oracle_, address(rt), owner);
        RebateStaking st = new RebateStaking(address(rt), address(musd), address(ex));
        rt.setMinter(address(ex));
        rt.setStaking(address(st));
        ex.setStaking(address(st));
        ex.setKeeper(keeper, true);
        vm.stopPrank();
        musd.mint(alice, 1_000e18);
        vm.prank(alice);
        musd.approve(address(ex), type(uint256).max);
    }

    function test_priceFeedReverting_executeOrderAndLiquidateSucceed_signed() public {
        HouseExchange ex = _exchange(address(so));
        so.update(_signed(100_000e18, block.timestamp));
        feed.setReverting(true); // PriceFeed down (stale Skip) from here on
        vm.prank(alice);
        uint256 oid = ex.requestOpen(true, 100e18, 100, 0);
        vm.warp(block.timestamp + 1);
        bytes[] memory u = _signed(100_000e18, block.timestamp);
        vm.prank(keeper);
        vm.expectEmit(address(so));
        emit MezoPriceBound.PriceBoundSkipped(100_000e18);
        ex.executeOrder(oid, u);
        assertTrue(ex.getPosition(0).open, "filled");
        vm.warp(block.timestamp + 1);
        u = _signed(98_900e18, block.timestamp);
        ex.liquidate(0, u); // -1.1% → bust at 100x (and > 1% away from nothing: PriceFeed is down)
        assertFalse(ex.getPosition(0).open, "liquidated");
        assertEq(ex.accountingDelta(), 0);
    }

    function test_priceFeedReverting_executeOrderAndLiquidateSucceed_pyth() public {
        HouseExchange ex = _exchange(address(po));
        vm.deal(keeper, 1 ether);
        vm.deal(address(this), 1 ether);
        po.update{ value: 1 }(_pyUpd(10_000_000_000_000, block.timestamp));
        feed.setBurnGas(true); // the nastier failure mode (forked Skip stub)
        vm.prank(alice);
        uint256 oid = ex.requestOpen(false, 100e18, 100, 0);
        vm.warp(block.timestamp + 1);
        vm.prank(keeper);
        ex.executeOrder{ value: 1 }(oid, _pyUpd(10_000_000_000_000, block.timestamp));
        assertTrue(ex.getPosition(0).open);
        vm.warp(block.timestamp + 1);
        ex.liquidate{ value: 1 }(0, _pyUpd(10_110_000_000_000, block.timestamp));
        assertFalse(ex.getPosition(0).open);
    }

    /// Control: with a healthy PriceFeed, the same out-of-bound liquidation price is rejected.
    function test_priceFeedHealthy_outOfBoundLiquidationRejected() public {
        HouseExchange ex = _exchange(address(so));
        so.update(_signed(100_000e18, block.timestamp));
        vm.prank(alice);
        uint256 oid = ex.requestOpen(true, 100e18, 100, 0);
        vm.warp(block.timestamp + 1);
        bytes[] memory u = _signed(100_000e18, block.timestamp);
        vm.prank(keeper);
        ex.executeOrder(oid, u);
        vm.warp(block.timestamp + 1);
        u = _signed(97_000e18, block.timestamp); // -3% vs PriceFeed 100k
        vm.expectRevert(abi.encodeWithSelector(MezoPriceBound.PriceDeviation.selector, 97_000e18, 100_000e18));
        ex.liquidate(0, u);
    }
}
