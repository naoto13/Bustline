// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { HouseExchange } from "../../src/HouseExchange.sol";
import { PythPullOracle } from "../../src/oracles/PythPullOracle.sol";
import { MezoPriceBound } from "../../src/oracles/MezoPriceBound.sol";
import { IPyth } from "../../src/interfaces/IPyth.sol";
import { EtchableSkip } from "./WaveTwoFork.t.sol";

/// @notice Rehearsal of the v3.1 oracle switch (SignedPriceOracle → PythPullOracle) on the REAL deployed HouseExchange,
///         TimelockController and PythPullOracle on Mezo testnet. One timelock op: `ex.setOracle(PYTH_ORACLE)`.
///         Run with MEZO_FORK_URL; the price tests also need PYTH_UPDATE_HEX (one Hermes `binary.data[0]`, hex
///         without 0x). Price and publishTime are read back from the contracts, never hard-coded. Nothing is broadcast.
///         Stays green as the REAL switch progresses (see `SwitchState`): (a) not scheduled → full rehearsal,
///         (b) scheduled, not executed → only wait + execute, (c) executed → tests run on the real post-switch state.
contract OracleSwitchForkTest is Test {
    address constant EX = 0x3c58314cd5710893519E5d962F553633ECC60cF7;
    address constant SIGNED = 0x75a3071482883d9616bf0473B7eE25B4222b181F;
    address constant PYTH_ORACLE = 0xf05B4108B93A83a1a87Ba1E392a81226aAC63619;
    address constant TIMELOCK = 0x115ba5242fc96c72cb2971D1B0f25439Def8f1C4;
    address constant DEPLOYER = 0xcDf407c01d38553eA44F250028D19b1d80898a21;
    address constant KEEPER = 0x85601C5Fc9A735a2710ba78024115039a7a32a42;
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    address constant PRICE_FEED = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;
    address constant SKIP = 0x7b7c000000000000000000000000000000000015;
    bytes32 constant FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant SALT = keccak256("bustline-v3.1-oracle-pyth");
    uint256 constant DELAY = 3600;

    HouseExchange ex = HouseExchange(payable(EX));
    PythPullOracle po = PythPullOracle(PYTH_ORACLE);
    TimelockController tl = TimelockController(payable(TIMELOCK));
    uint256 t0;
    address trader = makeAddr("trader");
    address liquidator = makeAddr("liquidator");

    function setUp() public {
        string memory url = vm.envOr("MEZO_FORK_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
        require(block.chainid == 31611, "not a Mezo testnet fork");
        t0 = block.timestamp;
        vm.deal(KEEPER, 1 ether);
        vm.deal(liquidator, 1 ether);
    }

    // ------------------------------------------------------------------ helpers
    enum SwitchState {
        Unscheduled, // (a) oracle = SIGNED, operation unknown to the timelock
        Scheduled, // (b) oracle = SIGNED, operation pending (scheduled on chain, not executed yet)
        Executed // (c) oracle = PYTH_ORACLE
    }

    function _payload() internal pure returns (bytes memory) {
        return abi.encodeCall(HouseExchange.setOracle, (PYTH_ORACLE));
    }

    function _id() internal view returns (bytes32) {
        return tl.hashOperation(EX, 0, _payload(), bytes32(0), SALT);
    }

    /// Classifies the (real or fork-modified) chain state; anything else fails loudly instead of being guessed at.
    function _state() internal view returns (SwitchState) {
        address o = address(ex.oracle());
        if (o == PYTH_ORACLE) return SwitchState.Executed;
        require(o == SIGNED, "unexpected oracle: neither SignedPriceOracle nor PythPullOracle");
        bytes32 id = _id();
        if (!tl.isOperation(id)) return SwitchState.Unscheduled;
        require(!tl.isOperationDone(id), "switch op done but oracle is not PythPullOracle");
        return SwitchState.Scheduled;
    }

    /// External wrapper so `vm.expectRevert` can observe `_state()` failing.
    function stateOf() external view returns (SwitchState) {
        return _state();
    }

    /// Brings the fork to the switched state from wherever the real chain is: (a) deployer schedules, wait, anyone
    /// executes; (b) wait until the on-chain ready time, anyone executes; (c) nothing — no schedule/execute is sent.
    function _switch() internal {
        SwitchState st = _state();
        if (st == SwitchState.Executed) return;
        if (st == SwitchState.Unscheduled) {
            vm.prank(DEPLOYER);
            tl.schedule(EX, 0, _payload(), bytes32(0), SALT, DELAY);
        }
        uint256 ready = tl.getTimestamp(_id());
        if (block.timestamp < ready) vm.warp(ready);
        vm.prank(makeAddr("anyone"));
        tl.execute(EX, 0, _payload(), bytes32(0), SALT);
        require(address(ex.oracle()) == PYTH_ORACLE, "switch failed");
    }

    /// Runs an arbitrary op through the real timelock (deployer schedules, wait, execute). For the branch tests only.
    function _tlRun(bytes memory data, bytes32 salt) internal {
        vm.prank(DEPLOYER);
        tl.schedule(EX, 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        tl.execute(EX, 0, data, bytes32(0), salt);
    }

    function _countEvents(Vm.Log[] memory logs, address emitter, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    /// Skips the calling test (before any fork work) when no live update is supplied.
    function _upd() internal returns (bytes[] memory u) {
        string memory h = vm.envOr("PYTH_UPDATE_HEX", string(""));
        if (bytes(h).length == 0) {
            vm.skip(true);
            return u;
        }
        u = new bytes[](1);
        u[0] = vm.parseBytes(string.concat("0x", h));
    }

    /// Price/publishTime carried by `u` (18 dp), learned by pushing it in a throw-away state.
    function _probe(bytes[] memory u) internal returns (uint256 p, uint256 t) {
        uint256 snap = vm.snapshotState();
        uint256 fee = po.updateFee(u);
        po.update{ value: fee }(u);
        (p, t) = po.peek();
        vm.revertToState(snap);
    }

    function _etchSkip(uint256 price) internal {
        vm.etch(SKIP, address(new EtchableSkip()).code);
        EtchableSkip(SKIP).setPrice(int256(price));
    }

    function _countSkipped(Vm.Log[] memory logs) internal pure returns (uint256) {
        return _countEvents(logs, PYTH_ORACLE, MezoPriceBound.PriceBoundSkipped.selector);
    }

    function _pushAndCheck(bytes[] memory u, bool etched) internal returns (uint256 p, uint256 t) {
        uint256 fee = po.updateFee(u);
        assertGt(fee, 0);
        assertLe(fee, 10_000, "Pyth update fee should be tiny");
        vm.recordLogs();
        vm.prank(KEEPER);
        uint256 g = gasleft();
        ex.pushPrice{ value: fee }(u);
        g -= gasleft();
        uint256 skipped = _countSkipped(vm.getRecordedLogs());
        if (etched) assertEq(skipped, 0, "bound applied (no PriceBoundSkipped)");
        else assertEq(skipped, 1, "bound skipped on the un-etched fork");
        console2.log(
            etched
                ? "gas pushPrice (Skip etched, bound applied; representative)"
                : "gas pushPrice (un-etched; includes Skip stub burning the stipend)",
            g
        );
        console2.log("update fee (wei)", fee);
        console2.log("update bytes length", u[0].length);

        (p, t) = ex.currentPrice();
        IPyth.Price memory q = IPyth(PYTH).getPriceUnsafe(FEED);
        assertEq(t, q.publishTime);
        (uint256 pp, uint256 pt) = po.peek();
        assertEq(p, pp);
        assertEq(t, pt);
        console2.log("Pyth price (18dp)", p);
        console2.log("Pyth publishTime", t);
    }

    // ------------------------------------------------------------------ 1: the timelock operation itself
    function test_fork_switch_timelockScheduleWaitExecute() public {
        // (c) The real switch has been executed: there is no timelock flow left to rehearse, and recreating the
        //     pre-switch state would need vm.store on the exchange/timelock (not allowed here). The price tests below
        //     still run against the real post-switch state.
        if (_state() == SwitchState.Executed) vm.skip(true);
        _timelockRehearsal();
    }

    /// (a) full schedule → wait → execute; (b) the op is already scheduled on chain: check it, wait, execute.
    function _timelockRehearsal() internal {
        SwitchState st = _state();
        require(st != SwitchState.Executed, "rehearsal needs a pre-switch state");
        // real-chain preconditions
        assertEq(address(ex.oracle()), SIGNED, "current oracle");
        assertEq(ex.owner(), TIMELOCK);
        assertEq(po.owner(), TIMELOCK);
        assertEq(Ownable(SIGNED).owner(), TIMELOCK);
        assertEq(tl.getMinDelay(), DELAY);
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), DEPLOYER), "deployer proposes");
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "open executor");
        assertFalse(ex.paused());
        assertEq(ex.openPositionIds().length, 0, "no open positions before the switch");
        assertEq(ex.pendingOrderIds(0, ex.orderCount()).length, 0, "no pending orders before the switch");
        assertEq(address(po.pyth()), PYTH);
        assertEq(po.feedId(), FEED);
        assertEq(address(po.priceFeed()), PRICE_FEED);

        bytes memory data = _payload();
        bytes32 id = _id();
        bytes memory scheduleCall = abi.encodeCall(TimelockController.schedule, (EX, 0, data, bytes32(0), SALT, DELAY));
        bytes memory executeCall = abi.encodeCall(TimelockController.execute, (EX, 0, data, bytes32(0), SALT));
        console2.log(st == SwitchState.Unscheduled ? "state (a): not scheduled" : "state (b): scheduled, not executed");
        console2.log("target (HouseExchange)", EX);
        console2.log("payload setOracle(PythPullOracle):");
        console2.logBytes(data);
        console2.log("salt:");
        console2.logBytes32(SALT);
        console2.log("operation id:");
        console2.logBytes32(id);
        console2.log("timelock.schedule calldata (from deployer):");
        console2.logBytes(scheduleCall);
        console2.log("timelock.execute calldata (anyone, >= 3600 s later):");
        console2.logBytes(executeCall);

        // the owner path is the only one: deployer / keeper cannot set the oracle directly
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
        ex.setOracle(PYTH_ORACLE);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, KEEPER));
        ex.setOracle(PYTH_ORACLE);

        // a non-proposer cannot schedule (fresh salt, so the revert is the role check, not "already scheduled")
        vm.prank(KEEPER);
        vm.expectRevert();
        tl.schedule(EX, 0, data, bytes32(0), keccak256("not-a-proposer"), DELAY);

        bool ok;
        if (st == SwitchState.Unscheduled) {
            assertFalse(tl.isOperation(id), "salt unused on chain");
            // deployer schedules (raw calldata, exactly what will be sent)
            vm.prank(DEPLOYER);
            (ok,) = TIMELOCK.call(scheduleCall);
            assertTrue(ok, "schedule");
            assertEq(tl.getTimestamp(id), block.timestamp + DELAY);
        } else {
            // (b) the real schedule is on chain: same id (= same target/payload/salt/predecessor), nothing re-sent
            assertTrue(tl.isOperation(id), "scheduled on chain");
            console2.log("on-chain ready timestamp", tl.getTimestamp(id));
        }
        assertTrue(tl.isOperationPending(id));
        assertFalse(tl.isOperationDone(id));
        uint256 ready = tl.getTimestamp(id);

        // too early
        if (block.timestamp < ready) {
            vm.warp(ready - 1);
            vm.expectRevert();
            tl.execute(EX, 0, data, bytes32(0), SALT);
            assertEq(address(ex.oracle()), SIGNED);
        }

        // after the delay anyone executes (raw calldata)
        if (block.timestamp < ready) vm.warp(ready);
        vm.prank(makeAddr("anyone"));
        (ok,) = TIMELOCK.call(executeCall);
        assertTrue(ok, "execute");
        assertEq(address(ex.oracle()), PYTH_ORACLE);
        assertTrue(tl.isOperationDone(id));
        assertTrue(_state() == SwitchState.Executed);

        // right after the switch nothing settles until the keeper pushes Pyth data (stored price is old)
        IPyth.Price memory q = IPyth(PYTH).getPriceUnsafe(FEED);
        console2.log("stored Pyth publishTime on chain", q.publishTime);
        console2.log("fork head timestamp t0", t0);
        if (q.publishTime + po.maxAge() < block.timestamp) {
            vm.expectRevert(abi.encodeWithSelector(PythPullOracle.StalePrice.selector, q.publishTime));
            ex.currentPrice();
        }
    }

    // ------------------------------------------------------------------ branches (b)/(c)/unknown, built on the fork
    /// (b) Make the fork look like "deployer already sent schedule": the shared paths must not schedule again.
    function test_fork_switch_branchScheduled() public {
        SwitchState st = _state();
        // From (c) state (b) cannot be rebuilt without vm.store on the exchange/timelock.
        if (st == SwitchState.Executed) vm.skip(true);
        if (st == SwitchState.Unscheduled) {
            vm.prank(DEPLOYER);
            tl.schedule(EX, 0, _payload(), bytes32(0), SALT, DELAY);
        }
        assertTrue(_state() == SwitchState.Scheduled, "fork is in state (b)");

        // shared switch helper: waits for the on-chain ready time, executes once, never schedules
        uint256 snap = vm.snapshotState();
        uint256 ready = tl.getTimestamp(_id());
        vm.recordLogs();
        _switch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countEvents(logs, TIMELOCK, TimelockController.CallScheduled.selector), 0, "no schedule in (b)");
        assertEq(_countEvents(logs, TIMELOCK, TimelockController.CallExecuted.selector), 1, "one execute in (b)");
        assertGe(block.timestamp, ready);
        assertTrue(_state() == SwitchState.Executed);
        vm.revertToState(snap);

        // the timelock rehearsal's (b) branch
        _timelockRehearsal();
    }

    /// (c) After a full switch, the shared helper sends nothing and leaves the oracle alone.
    function test_fork_switch_branchExecuted() public {
        _switch();
        assertTrue(_state() == SwitchState.Executed, "fork is in state (c)");
        uint256 ts = block.timestamp;
        vm.recordLogs();
        _switch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countEvents(logs, TIMELOCK, TimelockController.CallScheduled.selector), 0, "no schedule in (c)");
        assertEq(_countEvents(logs, TIMELOCK, TimelockController.CallExecuted.selector), 0, "no execute in (c)");
        assertEq(logs.length, 0, "nothing emitted at all");
        assertEq(block.timestamp, ts, "no warp in (c)");
        assertEq(address(ex.oracle()), PYTH_ORACLE);
    }

    /// Any other state must fail explicitly (built through the real timelock, no vm.store).
    function test_fork_switch_unknownStateFails() public {
        uint256 snap = vm.snapshotState();
        // oracle is neither SIGNED nor PYTH
        _tlRun(abi.encodeCall(HouseExchange.setOracle, (address(0xBEEF))), keccak256("test-unknown-oracle"));
        vm.expectRevert(bytes("unexpected oracle: neither SignedPriceOracle nor PythPullOracle"));
        this.stateOf();
        vm.revertToState(snap);

        // switch op done, then the oracle was set back to SIGNED
        _switch();
        _tlRun(abi.encodeCall(HouseExchange.setOracle, (SIGNED)), keccak256("test-back-to-signed"));
        vm.expectRevert(bytes("switch op done but oracle is not PythPullOracle"));
        this.stateOf();
    }

    // ------------------------------------------------------------------ 2: keeper pushes Pyth after the switch
    function test_fork_switch_pushPriceAfterSwitch_boundSkipped() public {
        bytes[] memory u = _upd();
        _switch();
        (, uint256 tu) = _probe(u);
        vm.warp(tu + 5);
        (bool ok,) = po.boundReference();
        assertFalse(ok, "PriceFeed unusable on the un-etched fork");
        _pushAndCheck(u, false);
    }

    function test_fork_switch_pushPriceAfterSwitch_boundApplied() public {
        bytes[] memory u = _upd();
        _switch();
        (uint256 pu, uint256 tu) = _probe(u);
        vm.warp(tu + 5);
        _etchSkip(pu);
        (bool ok, uint256 ref) = po.boundReference();
        assertTrue(ok, "PriceFeed answers with the etched Skip");
        assertEq(ref, pu);
        (uint256 p, uint256 t) = _pushAndCheck(u, true);
        assertEq(p, pu);
        assertEq(t, tu);
    }

    // ------------------------------------------------------------------ 3: ±1% bound against the real PriceFeed
    function test_fork_switch_boundRejectsDeviation() public {
        bytes[] memory u = _upd();
        _switch();
        (uint256 pu, uint256 tu) = _probe(u);
        vm.warp(tu + 5);
        uint256 ref = pu * 102 / 100;
        _etchSkip(ref);
        uint256 fee = po.updateFee(u);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MezoPriceBound.PriceDeviation.selector, pu, ref));
        ex.pushPrice{ value: fee }(u);
    }

    // ------------------------------------------------------------------ 4: fill + liquidation on the real exchange
    function _fundTrader(uint256 amt) internal {
        bytes32 slot = keccak256(abi.encode(trader, uint256(0)));
        vm.store(MUSD, slot, bytes32(uint256(vm.load(MUSD, slot)) + amt));
        assertGe(IERC20(MUSD).balanceOf(trader), amt);
        vm.prank(trader);
        IERC20(MUSD).approve(EX, type(uint256).max);
    }

    /// Fill in the same tx as the Pyth update (keeper path) at the Pyth price. A close needs a price published after
    /// the close request, i.e. a 2nd update, so the settlement leg is covered by the liquidation test below.
    function test_fork_switch_fillWithUpdate() public {
        bytes[] memory u = _upd();
        _switch();
        (uint256 pu, uint256 tu) = _probe(u);
        _fundTrader(100e18);
        uint256 margin = ex.minMargin();
        uint256 pid = ex.positionCount();

        vm.warp(tu - 10);
        vm.prank(trader);
        uint256 oid = ex.requestOpen(true, margin, 10, 0);
        vm.warp(tu + 5);
        uint256 fee = po.updateFee(u);
        vm.prank(KEEPER);
        uint256 g = gasleft();
        ex.executeOrder{ value: fee }(oid, u);
        g -= gasleft();
        console2.log("gas executeOrder+Pyth update (un-etched)", g);
        HouseExchange.Position memory pos = ex.getPosition(pid);
        assertTrue(pos.open);
        assertEq(pos.owner, trader);
        assertEq(pos.entryPrice, pu);
        assertEq(pos.margin, margin);
    }

    /// Single update: fill at the Pyth price already stored on chain (no update), then liquidate with the live update.
    /// Needs a backward warp to the stored publishTime; direction picked so the move crosses the bust price.
    function test_fork_switch_fillStoredThenLiquidateWithUpdate() public {
        bytes[] memory u = _upd();
        _switch();
        (uint256 pu, uint256 tu) = _probe(u);
        (uint256 ps, uint256 ts) = po.peek();
        if (ts >= tu || ps == 0) {
            console2.log("SKIP liquidation: stored Pyth price is not older than the update");
            vm.skip(true);
            return;
        }
        bool isLong = pu < ps; // long loses if the price falls, short if it rises
        _fundTrader(100e18);
        uint256 margin = ex.minMargin();
        uint256 pid = ex.positionCount();

        vm.warp(ts - 10);
        vm.prank(trader);
        uint256 oid = ex.requestOpen(isLong, margin, 100, 0);
        vm.warp(ts + 5);
        vm.prank(KEEPER);
        ex.executeOrder(oid, new bytes[](0));
        assertTrue(ex.getPosition(pid).open);
        assertEq(ex.getPosition(pid).entryPrice, ps);
        uint256 bust = ex.bustPriceOf(pid);
        console2.log("stored price / update price / bust", ps, pu, bust);
        if (isLong ? pu > bust : pu < bust) {
            console2.log("SKIP liquidation: the update does not cross the bust price");
            vm.skip(true);
            return;
        }

        vm.warp(tu + 5);
        _liquidateWithUpdate(pid, u, margin);
    }

    function _liquidateWithUpdate(uint256 pid, bytes[] memory u, uint256 margin) internal {
        uint256 fee = po.updateFee(u);
        uint256 bal = IERC20(MUSD).balanceOf(liquidator);
        uint256 nOpen = ex.openPositionIds().length; // (c): real positions may exist
        vm.prank(liquidator);
        uint256 g = gasleft();
        ex.liquidate{ value: fee }(pid, u);
        g -= gasleft();
        console2.log("gas liquidate+Pyth update (un-etched)", g);
        assertFalse(ex.getPosition(pid).open);
        assertEq(IERC20(MUSD).balanceOf(liquidator) - bal, margin * ex.liqKeeperBps() / 10_000, "keeper reward");
        assertEq(ex.openPositionIds().length, nOpen - 1, "removed from the open set");
    }

    // ------------------------------------------------------------------ 5: signed reports no longer work
    function test_fork_switch_signedReportRejectedAfterSwitch() public {
        _switch();
        vm.deal(KEEPER, 1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(HouseExchange.UnexpectedValue.selector);
        ex.pushPrice{ value: 1 }(new bytes[](0));

        bytes[] memory s = new bytes[](1);
        s[0] = abi.encode(uint256(66_000e18), block.timestamp, new bytes(65)); // SignedPriceOracle report shape
        vm.prank(KEEPER);
        vm.expectRevert();
        ex.pushPrice{ value: 1 }(s);
        assertEq(address(ex.oracle()), PYTH_ORACLE);
    }
}
