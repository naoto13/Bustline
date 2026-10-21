// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { RebateToken } from "../src/RebateToken.sol";
import { RebateStaking } from "../src/RebateStaking.sol";
import { MockOracle } from "../src/mocks/MockOracle.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @notice Shared setup. `musd` is a MockERC20 in unit tests and the real testnet MUSD in fork tests.
abstract contract Base is Test {
    HouseExchange ex;
    RebateToken rt;
    RebateStaking st;
    MockOracle oracle;
    IERC20 musd;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address liquidator = makeAddr("liquidator");

    uint256 constant P0 = 100_000e18;
    bytes[] internal NO_UPD;

    function _deploy(address musd_) internal {
        musd = IERC20(musd_);
        vm.startPrank(owner);
        oracle = new MockOracle(P0);
        oracle.setMaxStaleness(365 days);
        rt = new RebateToken("Mezo Paper", "MPAPER", owner);
        ex = new HouseExchange(musd_, address(oracle), address(rt), owner);
        st = new RebateStaking(address(rt), musd_, address(ex));
        rt.setMinter(address(ex));
        rt.setStaking(address(st));
        ex.setStaking(address(st));
        ex.setKeeper(keeper, true);
        vm.stopPrank();
    }

    function _fund(address who, uint256 amt) internal virtual;

    function _setPrice(uint256 p) internal {
        vm.warp(block.timestamp + 3);
        vm.prank(owner);
        oracle.setPrice(p);
    }

    function _request(address who, bool isLong, uint256 margin, uint256 lev) internal returns (uint256 oid) {
        _fund(who, margin);
        vm.startPrank(who);
        musd.approve(address(ex), margin);
        oid = ex.requestOpen(isLong, margin, lev, 0);
        vm.stopPrank();
    }

    /// @dev request → later oracle update at `fillPrice` → keeper fill. Returns position id.
    function _open(address who, bool isLong, uint256 margin, uint256 lev, uint256 fillPrice)
        internal
        returns (uint256)
    {
        uint256 oid = _request(who, isLong, margin, lev);
        _setPrice(fillPrice);
        uint256 pid = ex.positionCount();
        vm.prank(keeper);
        ex.executeOrder(oid, NO_UPD);
        assertEq(uint8(ex.getOrder(oid).status), 2, "executed");
        return pid;
    }

    function _close(address who, uint256 pid, uint256 exitPrice) internal {
        vm.prank(who);
        uint256 oid = ex.requestClose(pid, 0);
        _setPrice(exitPrice);
        vm.prank(keeper);
        ex.executeOrder(oid, NO_UPD);
    }

    function _checkAccounting() internal view {
        assertEq(ex.accountingDelta(), 0, "MUSD held == houseCash + margin + escrow");
        uint256 sum;
        for (uint256 i = ex.queueHead(); i < ex.queueLength(); ++i) {
            (, uint256 a) = ex.queueEntry(i);
            sum += a;
        }
        assertEq(sum, ex.queueTotal(), "queueTotal == sum(entries)");
    }
}
