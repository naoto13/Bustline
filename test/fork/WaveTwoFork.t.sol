// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base } from "../Base.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { HouseExchange } from "../../src/HouseExchange.sol";
import { RebateToken } from "../../src/RebateToken.sol";
import { SignedPriceOracle } from "../../src/oracles/SignedPriceOracle.sol";
import { MezoPriceBound } from "../../src/oracles/MezoPriceBound.sol";
import { IMezoStabilityPool, IMezoPriceFeed } from "../../src/interfaces/IMezo.sol";
import { DeployTestnetV3 } from "../../script/DeployTestnetV3.s.sol";

/// @notice Skip stand-in for `vm.etch` onto 0x7b7c…0015 (see MezoPrimitivesFork.t.sol). slot 0 = price,
///         slot 1 = stale flag (updatedAt = 0 → MUSD PriceFeed reverts "Oracle is stale.").
contract EtchableSkip {
    int256 public answer;
    bool public stale;

    function setPrice(int256 a) external {
        answer = a;
    }

    function setStale(bool s) external {
        stale = s;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 t = stale ? 0 : block.timestamp;
        return (1, answer, t, t, 1);
    }
}

interface ITroveManagerFork {
    function getCurrentICR(address, uint256) external view returns (uint256);
}

interface ISortedTrovesFork {
    function getLast() external view returns (address);
}

/// @notice Wave 2 fork tests against the REAL Mezo testnet MUSD protocol (PriceFeed, StabilityPool) and the v3
///         deploy script. Run with MEZO_FORK_URL. Nothing is broadcast.
contract WaveTwoForkTest is Base {
    address constant SKIP = 0x7b7c000000000000000000000000000000000015;
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant STABILITY_POOL = 0x1CCA7E410eE41739792eA0A24e00349Dd247680e;
    address constant PRICE_FEED = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;
    address constant TROVE_MANAGER = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address constant SORTED_TROVES = 0x722E4D24FD6Ff8b0AC679450F3D91294607268fA;
    address constant V2_OWNER = 0x715211CAdb65Cc184c955B283933A1F7021d00b0;
    uint256 constant HIGH = 160_000e18; // keeps the live testnet's lowest trove (≈109% at ~78k) above MCR
    uint256 constant SIGNER_PK = 0xA11CE;

    IMezoStabilityPool sp = IMezoStabilityPool(STABILITY_POOL);

    function setUp() public {
        string memory url = vm.envOr("MEZO_FORK_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
        require(block.chainid == 31611, "not a Mezo testnet fork");
        vm.warp(block.timestamp + 1);
        _deploy(MUSD);
    }

    function _fund(address who, uint256 amt) internal override {
        bytes32 slot = keccak256(abi.encode(who, uint256(0)));
        vm.store(MUSD, slot, bytes32(uint256(vm.load(MUSD, slot)) + amt));
    }

    function _etchSkip(uint256 price) internal {
        vm.etch(SKIP, address(new EtchableSkip()).code);
        EtchableSkip(SKIP).setPrice(int256(price));
    }

    function _seedHouse(uint256 amt) internal {
        uint256 pid = _open(carol, false, amt, 10, P0);
        _close(carol, pid, P0 * 12 / 10);
        _setPrice(P0);
    }

    function _signed(SignedPriceOracle so, uint256 p, uint256 t) internal view returns (bytes[] memory u) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, so.digest(p, t));
        u = new bytes[](1);
        u[0] = abi.encode(p, t, abi.encodePacked(r, s, v));
    }

    // ------------------------------------------------------------------ C: bound against the real PriceFeed
    function test_fork_bound_realPriceFeed() public {
        SignedPriceOracle so = new SignedPriceOracle(vm.addr(SIGNER_PK), 60, owner);
        vm.prank(owner);
        so.setPriceBound(PRICE_FEED, 100);
        _etchSkip(80_000e18);
        assertEq(IMezoPriceFeed(PRICE_FEED).fetchPrice(), 80_000e18);
        so.update(_signed(so, 80_700e18, block.timestamp)); // +0.875%
        (uint256 p,) = so.latest();
        assertEq(p, 80_700e18);
        vm.warp(block.timestamp + 1);
        bytes[] memory bad = _signed(so, 81_000e18, block.timestamp); // +1.25%
        vm.expectRevert(abi.encodeWithSelector(MezoPriceBound.PriceDeviation.selector, 81_000e18, 80_000e18));
        so.update(bad);
        // stale Skip → PriceFeed reverts → bound skipped, event emitted
        EtchableSkip(SKIP).setStale(true);
        vm.expectRevert(bytes("PriceFeed: Oracle is stale."));
        IMezoPriceFeed(PRICE_FEED).fetchPrice();
        vm.expectEmit(address(so));
        emit MezoPriceBound.PriceBoundSkipped(81_000e18);
        so.update(bad);
        (p,) = so.latest();
        assertEq(p, 81_000e18);
    }

    /// Without the etch, the forked Skip stub recurses until it runs out of gas — the worst case for try/catch.
    /// The stipend keeps executeOrder and liquidate working.
    function test_fork_bound_unetchedStub_executeAndLiquidateStillWork() public {
        SignedPriceOracle so = new SignedPriceOracle(vm.addr(SIGNER_PK), 60, owner);
        vm.startPrank(owner);
        so.setPriceBound(PRICE_FEED, 100);
        ex.setOracle(address(so));
        vm.stopPrank();
        (bool ok,) = so.boundReference();
        assertFalse(ok, "PriceFeed unusable on the un-etched fork");
        so.update(_signed(so, 100_000e18, block.timestamp));
        uint256 oid = _request(alice, true, 100e18, 100);
        vm.warp(block.timestamp + 1);
        bytes[] memory u = _signed(so, 100_000e18, block.timestamp);
        vm.prank(keeper);
        ex.executeOrder(oid, u);
        assertTrue(ex.getPosition(0).open);
        vm.warp(block.timestamp + 1);
        u = _signed(so, 98_900e18, block.timestamp);
        ex.liquidate(0, u);
        assertFalse(ex.getPosition(0).open);
        _checkAccounting();
    }

    // ------------------------------------------------------------------ B: the real Stability Pool
    function _wireRealSp() internal {
        vm.startPrank(owner);
        ex.setStabilityPool(STABILITY_POOL, PRICE_FEED, SORTED_TROVES, TROVE_MANAGER);
        ex.setSpParams(true, 100e18, 5_000, 2_000);
        vm.stopPrank();
    }

    function test_fork_sp_depositAndWithdrawRealPool() public {
        _etchSkip(HIGH);
        _wireRealSp();
        _seedHouse(1_000e18);
        assertTrue(ex.spWithdrawable());
        uint256 g0 = gasleft();
        ex.rebalance();
        emit log_named_uint("gas rebalance (provideToSP)", g0 - gasleft());
        assertEq(sp.getCompoundedMUSDDeposit(address(ex)), 500e18, "real SP holds our deposit");
        assertEq(ex.spDeposit(), 500e18);
        assertEq(ex.houseCash(), 500e18);
        _checkAccounting();

        vm.prank(owner);
        ex.setSpParams(true, 700e18, 5_000, 2_000);
        g0 = gasleft();
        ex.rebalance();
        emit log_named_uint("gas rebalance (withdrawFromSP)", g0 - gasleft());
        assertEq(ex.houseCash(), 700e18);
        assertEq(sp.getCompoundedMUSDDeposit(address(ex)), 300e18);
        _checkAccounting();

        // forwardBtc: withdrawFromSP(0) works on the real pool (no gain yet → nothing to forward)
        assertEq(ex.forwardBtc(), 0);
        _checkAccounting();
    }

    function test_fork_sp_realGate_noDepositAndBlockedWithdrawAndQueuedWinner() public {
        _etchSkip(HIGH);
        _wireRealSp();
        _seedHouse(1_000e18);
        ex.rebalance(); // 500 in the real SP
        // drop the price so the lowest real trove is under MCR (ICR is linear in price)
        address lowest = ISortedTrovesFork(SORTED_TROVES).getLast();
        uint256 icr = ITroveManagerFork(TROVE_MANAGER).getCurrentICR(lowest, HIGH);
        uint256 low = HIGH * 1.05e18 / icr;
        EtchableSkip(SKIP).setPrice(int256(low));
        assertFalse(ex.spWithdrawable(), "real gate: lowest trove < MCR");
        _seedHouse(1_000e18);
        (uint8 a,) = ex.rebalanceAction();
        assertEq(a, 0, "no deposit while withdrawals are blocked");

        // winner larger than the cash on hand: settles, rest queued (real SP withdraw reverts → caught)
        uint256 pid = _open(alice, true, 3_000e18, 10, P0);
        (, uint256 receive_) = ex.previewClose(pid, 108_000e18);
        uint256 payout = receive_ - 3_000e18;
        assertGt(payout, ex.houseCash());
        vm.prank(alice);
        uint256 oid = ex.requestClose(pid, 0);
        _setPrice(108_000e18);
        vm.prank(keeper);
        vm.expectEmit(address(ex));
        emit HouseExchange.SpWithdrawBlocked(500e18); // min(shortfall, deposit)
        ex.executeOrder(oid, NO_UPD);
        assertFalse(ex.getPosition(pid).open);
        assertGt(ex.queueTotal(), 0);
        _checkAccounting();

        // price back up → harvest pulls from the real SP and pays the queue
        EtchableSkip(SKIP).setPrice(int256(HIGH));
        uint256 q = ex.queueTotal();
        ex.harvest(10);
        assertEq(ex.queueTotal(), q - 500e18, "the whole real-SP deposit went to the queue");
        assertEq(sp.getCompoundedMUSDDeposit(address(ex)), 0);
        assertEq(IERC20(MUSD).balanceOf(alice), receive_ - ex.queueTotal());
        _checkAccounting();
    }

    // ------------------------------------------------------------------ T: the deploy script on a fork
    function test_fork_deployScriptV3_ownersAndTimelockFlow() public {
        vm.setEnv("CONFIRM_TESTNET_DEPLOY", "1");
        vm.setEnv("MEZO_TESTNET_PRIVATE_KEY", "0");
        vm.setEnv("DEPLOYER", vm.toString(V2_OWNER)); // real RebateToken owner → ownership moves to the timelock
        address k = makeAddr("keeperKey");
        address s = makeAddr("signerKey");
        DeployTestnetV3 script = new DeployTestnetV3();
        // (env is process-global, so the shared-key rejection lives in this one test)
        vm.setEnv("KEEPER", vm.toString(V2_OWNER));
        vm.setEnv("PRICE_SIGNER", vm.toString(s));
        vm.expectRevert(bytes("deployer, KEEPER, PRICE_SIGNER must be 3 different addresses"));
        script.run();
        vm.setEnv("KEEPER", vm.toString(k));
        DeployTestnetV3.Deployed memory d = script.run();

        address tl = address(d.timelock);
        assertEq(d.exchange.owner(), tl);
        assertEq(d.pythOracle.owner(), tl);
        assertEq(d.signedOracle.owner(), tl);
        assertEq(d.rebateToken.owner(), tl);
        assertTrue(d.rebateTokenToTimelock);
        assertEq(d.timelock.getMinDelay(), 3600);
        assertTrue(d.exchange.isKeeper(k));
        assertFalse(d.exchange.isKeeper(V2_OWNER));
        assertEq(d.signedOracle.signer(), s);
        assertFalse(d.exchange.spEnabled());
        assertEq(address(d.exchange.stabilityPool()), STABILITY_POOL);
        assertEq(address(d.signedOracle.priceFeed()), PRICE_FEED);

        // deployer can no longer act as owner
        vm.prank(V2_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, V2_OWNER));
        d.rebateToken.setMinter(address(d.exchange));
        vm.prank(V2_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, V2_OWNER));
        d.exchange.setOracle(address(1));

        // op A through the timelock: schedule → (too early) → warp → execute
        (address[] memory t, uint256[] memory v, bytes[] memory p) = script.rebateSwitchBatch(d);
        bytes32 salt = script.REBATE_SWITCH_SALT();
        vm.prank(V2_OWNER);
        d.timelock.scheduleBatch(t, v, p, bytes32(0), salt, 3600);
        vm.expectRevert();
        d.timelock.executeBatch(t, v, p, bytes32(0), salt);
        vm.warp(block.timestamp + 3600);
        d.timelock.executeBatch(t, v, p, bytes32(0), salt);
        assertEq(d.rebateToken.minter(), address(d.exchange));
        assertEq(d.rebateToken.staking(), address(d.staking));

        // op B: enable SP
        (address spT, bytes memory spP) = script.spEnableCall(d);
        bytes32 spSalt = script.SP_ENABLE_SALT();
        vm.prank(V2_OWNER);
        d.timelock.schedule(spT, 0, spP, bytes32(0), spSalt, 3600);
        vm.warp(block.timestamp + 3600);
        d.timelock.execute(spT, 0, spP, bytes32(0), spSalt);
        assertTrue(d.exchange.spEnabled());
        assertEq(d.exchange.spMinLiquid(), 50e18);
    }
}
