// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { RebateToken } from "../src/RebateToken.sol";
import { RebateStaking } from "../src/RebateStaking.sol";
import { PythPullOracle } from "../src/oracles/PythPullOracle.sol";
import { SignedPriceOracle } from "../src/oracles/SignedPriceOracle.sol";
import { SkipBound } from "../src/oracles/SkipBound.sol";
import { MockPyth } from "../src/mocks/MockPyth.sol";
import { MockOracle } from "../src/mocks/MockOracle.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

contract OraclesTest is Test {
    bytes32 constant ID = keccak256("BTC/USD");
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    uint256 signerPk = 0xA11CE;
    address signerAddr;

    MockPyth py;
    PythPullOracle po;
    SignedPriceOracle so;
    MockOracle skipFeed;

    function setUp() public {
        vm.warp(1_800_000_000);
        signerAddr = vm.addr(signerPk);
        py = new MockPyth();
        po = new PythPullOracle(address(py), ID, 60, owner);
        so = new SignedPriceOracle(signerAddr, 60, owner);
        skipFeed = new MockOracle(100_000e18);
        skipFeed.setMaxStaleness(365 days);
    }

    function _pyUpd(int64 p, uint256 t) internal pure returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = abi.encode(ID, p, uint64(0), int32(-8), t);
    }

    function _signed(uint256 p, uint256 t) internal view returns (bytes[] memory u) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, so.digest(p, t));
        u = new bytes[](1);
        u[0] = abi.encode(p, t, abi.encodePacked(r, s, v));
    }

    // ------------------------------------------------------------------ Pyth pull
    function test_pyth_updateThenLatest() public {
        bytes[] memory u = _pyUpd(10_000_012_345_678, block.timestamp); // 100,000.12345678
        po.update{ value: po.updateFee(u) }(u);
        (uint256 p, uint256 t) = po.latest();
        assertEq(p, 100_000.12345678e18);
        assertEq(t, block.timestamp);
    }

    function test_pyth_feeRequired() public {
        bytes[] memory u = _pyUpd(10_000_000_000_000, block.timestamp);
        vm.expectRevert(bytes("fee"));
        po.update(u);
    }

    function test_pyth_staleReverts() public {
        bytes[] memory u = _pyUpd(10_000_000_000_000, block.timestamp - 61);
        po.update{ value: 1 }(u);
        vm.expectRevert(abi.encodeWithSelector(PythPullOracle.StalePrice.selector, block.timestamp - 61));
        po.latest();
        (uint256 p,) = po.peek(); // UI read never reverts
        assertEq(p, 100_000e18);
    }

    function test_pyth_wideConfidenceReverts() public {
        bytes[] memory u = new bytes[](1);
        u[0] = abi.encode(ID, int64(10_000_000_000_000), uint64(200_000_000_000), int32(-8), block.timestamp); // conf 2%
        po.update{ value: 1 }(u);
        vm.expectRevert(PythPullOracle.WideConfidence.selector);
        po.latest();
    }

    function test_pyth_skipDeviationBound() public {
        vm.prank(owner);
        po.setSkipBound(address(skipFeed), 100, 300); // 1%
        bytes[] memory u = _pyUpd(10_050_000_000_000, block.timestamp); // +0.5%
        po.update{ value: 1 }(u);
        po.latest();
        u = _pyUpd(10_200_000_000_000, block.timestamp + 1); // +2%
        vm.warp(block.timestamp + 1);
        po.update{ value: 1 }(u);
        vm.expectRevert(abi.encodeWithSelector(SkipBound.PriceDeviation.selector, 102_000e18, 100_000e18));
        po.latest();
        // stale Skip disables the bound instead of freezing the market
        skipFeed.setPriceRaw(100_000e18, block.timestamp - 301);
        po.latest();
    }

    // ------------------------------------------------------------------ signed fallback
    function test_signed_validReport() public {
        so.update(_signed(101_000e18, block.timestamp));
        (uint256 p, uint256 t) = so.latest();
        assertEq(p, 101_000e18);
        assertEq(t, block.timestamp);
    }

    function test_signed_wrongSignerReverts() public {
        bytes32 d = so.digest(101_000e18, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, d);
        bytes[] memory u = new bytes[](1);
        u[0] = abi.encode(uint256(101_000e18), block.timestamp, abi.encodePacked(r, s, v));
        vm.expectRevert(SignedPriceOracle.BadSignature.selector);
        so.update(u);
    }

    function test_signed_tamperedPriceReverts() public {
        bytes[] memory u = _signed(101_000e18, block.timestamp);
        (, uint256 t, bytes memory sig) = abi.decode(u[0], (uint256, uint256, bytes));
        u[0] = abi.encode(uint256(90_000e18), t, sig);
        vm.expectRevert(SignedPriceOracle.BadSignature.selector);
        so.update(u);
    }

    function test_signed_futureAndStaleAndReplay() public {
        bytes[] memory fut = _signed(100_000e18, block.timestamp + 11);
        vm.expectRevert(abi.encodeWithSelector(SignedPriceOracle.FutureReport.selector, block.timestamp + 11));
        so.update(fut);

        so.update(_signed(100_000e18, block.timestamp));
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 5);
        so.update(_signed(99_000e18, t0 - 1)); // older report ignored (no rollback)
        (uint256 p,) = so.latest();
        assertEq(p, 100_000e18);

        vm.warp(t0 + 61);
        vm.expectRevert(abi.encodeWithSelector(SignedPriceOracle.StalePrice.selector, t0));
        so.latest();
    }

    function test_signed_reportBoundToChainAndContract() public {
        SignedPriceOracle other = new SignedPriceOracle(signerAddr, 60, owner);
        bytes[] memory u = _signed(100_000e18, block.timestamp); // signed for `so`
        vm.expectRevert(SignedPriceOracle.BadSignature.selector);
        other.update(u);
    }

    function test_signed_skipBound() public {
        vm.prank(owner);
        so.setSkipBound(address(skipFeed), 100, 300);
        so.update(_signed(102_000e18, block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(SkipBound.PriceDeviation.selector, 102_000e18, 100_000e18));
        so.latest();
    }

    // ------------------------------------------------------------------ exchange integration (2-step on publishTime)
    function _exchange(address oracle_) internal returns (HouseExchange ex, MockERC20 musd) {
        musd = new MockERC20("MUSD", "MUSD", 18);
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

    function test_exchange_pythFillAndLiquidateWithUpdate() public {
        (HouseExchange ex,) = _exchange(address(po));
        vm.deal(keeper, 1 ether);
        po.update{ value: 1 }(_pyUpd(10_000_000_000_000, block.timestamp));
        vm.prank(alice);
        uint256 oid = ex.requestOpen(true, 100e18, 100, 0);

        // a price published at/before the order cannot fill it, even if pushed in the same tx
        vm.warp(block.timestamp + 2);
        bytes[] memory old = _pyUpd(10_000_000_000_000, block.timestamp - 2);
        vm.prank(keeper);
        vm.expectRevert(HouseExchange.NotYetFillable.selector);
        ex.executeOrder{ value: 1 }(oid, old);

        bytes[] memory u = _pyUpd(10_001_000_000_000, block.timestamp); // 100,010
        vm.prank(keeper);
        ex.executeOrder{ value: 1 }(oid, u);
        (,,,, uint256 entry) = _pos(ex, 0);
        assertEq(entry, 100_010e18);

        vm.warp(block.timestamp + 3);
        vm.expectRevert(HouseExchange.NotLiquidatable.selector);
        ex.liquidate{ value: 1 }(0, _pyUpd(10_000_000_000_000, block.timestamp));
        vm.warp(block.timestamp + 1);
        vm.prank(makeAddr("anyone"));
        vm.deal(makeAddr("anyone"), 1);
        ex.liquidate{ value: 1 }(0, _pyUpd(9_900_000_000_000, block.timestamp)); // -1% => bust at 100x
        (bool open,,,,) = _pos(ex, 0);
        assertFalse(open);
    }

    function test_exchange_signedFillAndLiquidate() public {
        (HouseExchange ex,) = _exchange(address(so));
        so.update(_signed(100_000e18, block.timestamp));
        vm.prank(alice);
        uint256 oid = ex.requestOpen(false, 100e18, 100, 0);
        vm.warp(block.timestamp + 1);
        bytes[] memory u = _signed(100_000e18, block.timestamp);
        vm.prank(keeper);
        ex.executeOrder(oid, u);
        vm.warp(block.timestamp + 1);
        ex.liquidate(0, _signed(101_000e18, block.timestamp));
        (bool open,,,,) = _pos(ex, 0);
        assertFalse(open);
    }

    function test_exchange_valueWithoutUpdateReverts() public {
        (HouseExchange ex,) = _exchange(address(so));
        vm.deal(address(this), 1);
        vm.expectRevert(HouseExchange.UnexpectedValue.selector);
        ex.pushPrice{ value: 1 }(new bytes[](0));
    }

    function _pos(HouseExchange ex, uint256 id) internal view returns (bool, bool, uint256, uint256, uint256) {
        HouseExchange.Position memory p = ex.getPosition(id);
        return (p.open, p.isLong, p.margin, p.size, p.entryPrice);
    }
}
