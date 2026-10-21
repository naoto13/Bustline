// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { HouseExchange } from "../../src/HouseExchange.sol";
import { RebateToken } from "../../src/RebateToken.sol";
import { RebateStaking } from "../../src/RebateStaking.sol";
import { PythPullOracle } from "../../src/oracles/PythPullOracle.sol";
import { IPyth } from "../../src/interfaces/IPyth.sol";

/// @notice Fork test against the REAL Mezo testnet Pyth contract (0x2880…7B43) and REAL MUSD, using a REAL
///         mainnet-signed (Pyth stable) BTC/USD update (test/fixtures). Proves: (1) Mezo testnet Pyth verifies
///         stable Hermes data, (2) fill + liquidation work end-to-end through PythPullOracle with publishTime-based
///         2-step rule. Skip bound disabled (Skip is a precompile forks cannot execute). Run with MEZO_FORK_URL.
contract PythForkTest is Test {
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    bytes32 constant FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    uint256 constant T_UPD = 1792544395; // fixture publishTime
    uint256 constant P_UPD = 82_943.63411393e18; // fixture price

    HouseExchange ex;
    PythPullOracle po;
    bytes[] upd;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address liquidator = makeAddr("liquidator");

    function setUp() public {
        string memory url = vm.envOr("MEZO_FORK_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
        require(block.chainid == 31611, "not a Mezo testnet fork");
        upd.push(
            vm.parseBytes(string.concat("0x", vm.readFile("test/fixtures/pyth_btcusd_base_mainnet_1792544395.hex")))
        );

        vm.startPrank(owner);
        po = new PythPullOracle(PYTH, FEED, 60, owner);
        RebateToken rt = new RebateToken("Mezo Paper", "MPAPER", owner);
        ex = new HouseExchange(MUSD, address(po), address(rt), owner);
        RebateStaking st = new RebateStaking(address(rt), MUSD, address(ex));
        rt.setMinter(address(ex));
        rt.setStaking(address(st));
        ex.setStaking(address(st));
        ex.setKeeper(keeper, true);
        vm.stopPrank();

        bytes32 slot = keccak256(abi.encode(alice, uint256(0)));
        vm.store(MUSD, slot, bytes32(uint256(uint256(vm.load(MUSD, slot)) + 10_000e18)));
        vm.prank(alice);
        IERC20(MUSD).approve(address(ex), type(uint256).max);
        vm.deal(keeper, 1 ether);
        vm.deal(liquidator, 1 ether);
    }

    function test_fork_pyth_acceptsMainnetSignedUpdate() public {
        vm.warp(T_UPD + 5);
        uint256 fee = po.updateFee(upd);
        assertGt(fee, 0);
        po.update{ value: fee }(upd);
        IPyth.Price memory q = IPyth(PYTH).getPriceUnsafe(FEED);
        assertEq(q.publishTime, T_UPD);
        (uint256 p, uint256 t) = po.latest();
        assertEq(p, P_UPD);
        assertEq(t, T_UPD);
    }

    function test_fork_pyth_fillInSameTx() public {
        vm.warp(T_UPD - 10);
        vm.prank(alice);
        uint256 oid = ex.requestOpen(true, 100e18, 100, 0);
        vm.warp(T_UPD + 5);
        uint256 fee = po.updateFee(upd);
        vm.prank(keeper);
        ex.executeOrder{ value: fee }(oid, upd);
        HouseExchange.Position memory pos = ex.getPosition(0);
        assertTrue(pos.open);
        assertEq(pos.entryPrice, P_UPD);
    }

    function test_fork_pyth_orderAfterPublishNotFillable() public {
        vm.warp(T_UPD + 1); // order placed AFTER the price was published
        vm.prank(alice);
        uint256 oid = ex.requestOpen(true, 100e18, 100, 0);
        vm.warp(T_UPD + 5);
        uint256 fee = po.updateFee(upd);
        vm.prank(keeper);
        vm.expectRevert(HouseExchange.NotYetFillable.selector);
        ex.executeOrder{ value: fee }(oid, upd);
    }

    /// @dev Fill at the Pyth price already stored on Mezo testnet, then liquidate with the newer mainnet-signed update.
    function test_fork_pyth_liquidationWithUpdate() public {
        IPyth.Price memory q = IPyth(PYTH).getPriceUnsafe(FEED);
        require(q.publishTime < T_UPD, "stored price already newer than fixture");
        vm.warp(q.publishTime - 10);
        vm.prank(alice);
        uint256 oid = ex.requestOpen(false, 100e18, 100, 0); // 100x short
        vm.warp(q.publishTime + 5);
        vm.prank(keeper);
        ex.executeOrder(oid, new bytes[](0));
        HouseExchange.Position memory pos = ex.getPosition(0);
        assertTrue(pos.open);

        vm.warp(T_UPD + 5);
        uint256 fee = po.updateFee(upd);
        uint256 bal = IERC20(MUSD).balanceOf(liquidator);
        vm.prank(liquidator);
        ex.liquidate{ value: fee }(0, upd);
        assertFalse(ex.getPosition(0).open);
        assertEq(IERC20(MUSD).balanceOf(liquidator) - bal, 0.5e18, "0.5% keeper reward");
    }
}
