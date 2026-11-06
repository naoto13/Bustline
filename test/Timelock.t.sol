// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { RebateToken } from "../src/RebateToken.sol";
import { RebateStaking } from "../src/RebateStaking.sol";
import { SignedPriceOracle } from "../src/oracles/SignedPriceOracle.sol";
import { PythPullOracle } from "../src/oracles/PythPullOracle.sol";
import { MockPyth } from "../src/mocks/MockPyth.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @notice spec 5.4 (T): every owner power sits behind the timelock (same wiring as script/DeployTestnetV3.s.sol).
contract TimelockTest is Test {
    uint256 constant DELAY = 1 hours;
    address deployer = makeAddr("deployer");
    address keeper = makeAddr("keeper");
    address anyone = makeAddr("anyone");

    TimelockController tl;
    HouseExchange ex;
    RebateToken rt;
    RebateStaking st;
    SignedPriceOracle so;
    PythPullOracle po;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.startPrank(deployer);
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        tl = new TimelockController(DELAY, proposers, executors, address(0));
        MockERC20 musd = new MockERC20("MUSD", "MUSD", 18);
        so = new SignedPriceOracle(makeAddr("signer"), 60, deployer);
        po = new PythPullOracle(address(new MockPyth()), bytes32(0), 60, deployer);
        rt = new RebateToken("Mezo Paper", "MPAPER", deployer);
        ex = new HouseExchange(address(musd), address(so), address(rt), deployer);
        st = new RebateStaking(address(rt), address(musd), address(ex));
        ex.setStaking(address(st));
        rt.setMinter(address(ex)); // v3 deploys its own RebateToken and wires it before the handover
        rt.setStaking(address(st));
        ex.setKeeper(keeper, true);
        ex.transferOwnership(address(tl));
        so.transferOwnership(address(tl));
        po.transferOwnership(address(tl));
        rt.transferOwnership(address(tl));
        vm.stopPrank();
    }

    function _schedule(address target, bytes memory data, bytes32 salt) internal {
        vm.prank(deployer);
        tl.schedule(target, 0, data, bytes32(0), salt, DELAY);
    }

    function test_ownerIsTimelock() public view {
        assertEq(ex.owner(), address(tl));
        assertEq(so.owner(), address(tl));
        assertEq(po.owner(), address(tl));
        assertEq(rt.owner(), address(tl));
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), deployer));
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), deployer));
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "open executor");
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), deployer), "no admin backdoor");
        assertEq(tl.getMinDelay(), DELAY);
    }

    function test_deployerDirectCallsRevert() public {
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        ex.setOracle(address(1));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        ex.setSpParams(true, 0, 10_000, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        rt.setMinter(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        so.setSigner(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        po.setPriceBound(address(1), 100);
        vm.stopPrank();
        // the keeper key cannot use owner powers either
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        ex.setOracle(address(1));
    }

    function test_scheduleWaitExecute() public {
        bytes memory data = abi.encodeCall(HouseExchange.setOracle, (address(0xBEEF)));
        _schedule(address(ex), data, bytes32("a"));
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(anyone);
        vm.expectRevert(); // TimelockUnexpectedOperationState: not ready yet
        tl.execute(address(ex), 0, data, bytes32(0), bytes32("a"));
        vm.warp(block.timestamp + 1);
        vm.prank(anyone); // executor = anyone
        tl.execute(address(ex), 0, data, bytes32(0), bytes32("a"));
        assertEq(address(ex.oracle()), address(0xBEEF));
    }

    function test_rebateTokenWiredThenOwnerPowersViaTimelock() public {
        assertEq(rt.owner(), address(tl));
        assertEq(rt.minter(), address(ex));
        assertEq(rt.staking(), address(st));
        assertFalse(rt.transferable());
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        rt.setMinter(anyone);
        // later changes (e.g. a future exchange) still go schedule → wait → execute
        address[] memory t = new address[](2);
        t[0] = address(rt);
        t[1] = address(rt);
        uint256[] memory v = new uint256[](2);
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encodeCall(RebateToken.setMinter, (anyone));
        p[1] = abi.encodeCall(RebateToken.setStaking, (anyone));
        vm.prank(deployer);
        tl.scheduleBatch(t, v, p, bytes32(0), bytes32("s"), DELAY);
        vm.warp(block.timestamp + DELAY);
        tl.executeBatch(t, v, p, bytes32(0), bytes32("s"));
        assertEq(rt.minter(), anyone);
        assertEq(rt.staking(), anyone);
    }

    function test_onlyProposerSchedules_proposerCancels() public {
        bytes memory data = abi.encodeCall(HouseExchange.setKeeper, (anyone, true));
        vm.prank(keeper);
        vm.expectRevert();
        tl.schedule(address(ex), 0, data, bytes32(0), bytes32("k"), DELAY);
        vm.prank(deployer);
        vm.expectRevert(); // delay below the minimum
        tl.schedule(address(ex), 0, data, bytes32(0), bytes32("k"), DELAY - 1);
        _schedule(address(ex), data, bytes32("k"));
        bytes32 id = tl.hashOperation(address(ex), 0, data, bytes32(0), bytes32("k"));
        vm.prank(deployer);
        tl.cancel(id);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert();
        tl.execute(address(ex), 0, data, bytes32(0), bytes32("k"));
        assertFalse(ex.isKeeper(anyone));
    }

    function test_delayChangeAlsoNeedsTimelock() public {
        vm.prank(deployer);
        vm.expectRevert();
        tl.updateDelay(0);
    }
}
