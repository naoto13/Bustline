// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { RebateToken } from "../src/RebateToken.sol";
import { RebateStaking } from "../src/RebateStaking.sol";
import { PythPullOracle } from "../src/oracles/PythPullOracle.sol";
import { SignedPriceOracle } from "../src/oracles/SignedPriceOracle.sol";
import { MezoTestnet, MezoExtra } from "./MezoTestnet.sol";

/// @title DeployTestnetV3 — Wave 2 (v3) deployment on Mezo TESTNET (chainId 31611). See spec 5.4 / 6.
/// @notice What it does (all as the deployer, in one broadcast):
///   1. TimelockController: delay TIMELOCK_DELAY (default 3600 s), proposer + canceller = deployer, executor = anyone,
///      no admin (the timelock administers itself).
///   2. PythPullOracle + SignedPriceOracle with the MUSD PriceFeed bound (±1%), HouseExchange v3, RebateStaking v3.
///      The existing RebateToken (MPAPER, REBATE_TOKEN, default = deployments/testnet.json) is reused.
///   3. Configures everything (keeper, risk caps, Stability Pool wiring, SP params with spEnabled = false), THEN hands
///      ownership of HouseExchange v3, both oracles and — if the deployer still owns it — the RebateToken to the
///      timelock. From here on every owner action goes through schedule → wait → execute.
///   4. Prints the timelock operations the user runs later (NOT scheduled here — see the order in the output):
///      RebateToken.setMinter(v3) + setStaking(v3 staking) as one batch, and HouseExchange.setSpParams(true, …).
/// Keys: deployer (= timelock proposer), KEEPER and PRICE_SIGNER must be three DIFFERENT addresses (env, required).
/// Guards: chainId 31611, CONFIRM_TESTNET_DEPLOY=1. The deployer key is read ONLY from MEZO_TESTNET_PRIVATE_KEY
/// (never on the command line). Without it, DEPLOYER=<address> runs an unsigned simulation (dry-run).
/// deployments/testnet-v3.json is written only when broadcasting; deployments/testnet.json (v2) is never touched.
contract DeployTestnetV3 is Script {
    bytes32 public constant REBATE_SWITCH_SALT = keccak256("bustline-v3-rebate-switch");
    bytes32 public constant SP_ENABLE_SALT = keccak256("bustline-v3-sp-enable");
    address internal constant RT_V2 = 0x07F9bd344916571321f494aE00eDD30ac1dE89Bd; // deployments/testnet.json

    // SP initial parameters (todo 0): v2 accumulated ~110 MUSD of house cash over Wave 1 → testnet-scale values.
    uint256 public constant SP_MIN_LIQUID = 50e18;
    uint256 public constant SP_MAX_SHARE_BPS = 5_000;
    uint256 public constant SP_BAND_BPS = 2_000;

    struct Deployed {
        address deployer;
        address keeper;
        address priceSigner;
        TimelockController timelock;
        PythPullOracle pythOracle;
        SignedPriceOracle signedOracle;
        address oracle;
        HouseExchange exchange;
        RebateStaking staking;
        RebateToken rebateToken;
        bool rebateTokenToTimelock;
    }

    function run() external returns (Deployed memory d) {
        require(block.chainid == MezoTestnet.CHAIN_ID, "testnet only (31611)");
        require(vm.envOr("CONFIRM_TESTNET_DEPLOY", uint256(0)) == 1, "set CONFIRM_TESTNET_DEPLOY=1");
        uint256 pk = vm.envOr("MEZO_TESTNET_PRIVATE_KEY", uint256(0));
        d.deployer = pk != 0 ? vm.addr(pk) : vm.envAddress("DEPLOYER");
        d.keeper = vm.envAddress("KEEPER");
        d.priceSigner = vm.envAddress("PRICE_SIGNER");
        require(
            d.keeper != d.deployer && d.priceSigner != d.deployer && d.keeper != d.priceSigner,
            "deployer, KEEPER, PRICE_SIGNER must be 3 different addresses"
        );
        require(d.keeper != address(0) && d.priceSigner != address(0), "zero address");
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(3600));
        bool pythPrimary = keccak256(bytes(vm.envOr("ORACLE_MODE", string("signed")))) == keccak256("pyth");
        d.rebateToken = RebateToken(vm.envOr("REBATE_TOKEN", RT_V2));
        require(address(d.rebateToken).code.length > 0, "REBATE_TOKEN has no code");

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast(d.deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = d.deployer; // OZ 5: proposers also get CANCELLER_ROLE
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone may execute a ready operation
        d.timelock = new TimelockController(delay, proposers, executors, address(0));

        d.pythOracle = new PythPullOracle(MezoExtra.PYTH, MezoExtra.PYTH_BTC_USD, 60, d.deployer);
        d.pythOracle.setPriceBound(MezoTestnet.PRICE_FEED, 100); // within 1% of MUSD PriceFeed
        d.signedOracle = new SignedPriceOracle(d.priceSigner, 60, d.deployer);
        d.signedOracle.setPriceBound(MezoTestnet.PRICE_FEED, 100);
        d.oracle = pythPrimary ? address(d.pythOracle) : address(d.signedOracle);

        d.exchange = new HouseExchange(MezoTestnet.MUSD, d.oracle, address(d.rebateToken), d.deployer);
        d.staking = new RebateStaking(address(d.rebateToken), MezoTestnet.MUSD, address(d.exchange));
        d.exchange.setStaking(address(d.staking));
        d.exchange.setKeeper(d.keeper, true);
        // testnet demo caps (same as v2): 100x, min margin 10 MUSD, 100k max notional, 1M OI/side, 5bps buffer, 5 min
        d.exchange.setRisk(100, 10e18, 100_000e18, 1_000_000e18, 2_000, 300);
        d.exchange
            .setStabilityPool(
                MezoTestnet.STABILITY_POOL, MezoTestnet.PRICE_FEED, MezoTestnet.SORTED_TROVES, MezoTestnet.TROVE_MANAGER
            );
        d.exchange.setSpParams(false, SP_MIN_LIQUID, SP_MAX_SHARE_BPS, SP_BAND_BPS); // enabled later via timelock

        d.exchange.transferOwnership(address(d.timelock));
        d.pythOracle.transferOwnership(address(d.timelock));
        d.signedOracle.transferOwnership(address(d.timelock));
        if (d.rebateToken.owner() == d.deployer) {
            d.rebateToken.transferOwnership(address(d.timelock));
            d.rebateTokenToTimelock = true;
        }
        vm.stopBroadcast();

        _report(d, delay, pythPrimary);
    }

    // ------------------------------------------------------------------ timelock operations (for the user)
    function rebateSwitchBatch(Deployed memory d)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = address(d.rebateToken);
        targets[1] = address(d.rebateToken);
        payloads[0] = abi.encodeCall(RebateToken.setMinter, (address(d.exchange)));
        payloads[1] = abi.encodeCall(RebateToken.setStaking, (address(d.staking)));
    }

    function spEnableCall(Deployed memory d) public pure returns (address target, bytes memory payload) {
        target = address(d.exchange);
        payload = abi.encodeCall(HouseExchange.setSpParams, (true, SP_MIN_LIQUID, SP_MAX_SHARE_BPS, SP_BAND_BPS));
    }

    function _report(Deployed memory d, uint256 delay, bool pythPrimary) internal {
        string memory k = "testnet-v3";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeString(k, "version", "v3");
        vm.serializeAddress(k, "Deployer", d.deployer);
        vm.serializeAddress(k, "Timelock", address(d.timelock));
        vm.serializeUint(k, "TimelockDelay", delay);
        vm.serializeAddress(k, "owner", address(d.timelock));
        vm.serializeAddress(k, "Keeper", d.keeper);
        vm.serializeAddress(k, "PriceSigner", d.priceSigner);
        vm.serializeAddress(k, "MUSD", MezoTestnet.MUSD);
        vm.serializeString(k, "oracleMode", pythPrimary ? "pyth" : "signed");
        vm.serializeAddress(k, "Oracle", d.oracle);
        vm.serializeAddress(k, "PythPullOracle", address(d.pythOracle));
        vm.serializeAddress(k, "SignedPriceOracle", address(d.signedOracle));
        vm.serializeAddress(k, "Pyth", MezoExtra.PYTH);
        vm.serializeBytes32(k, "PythFeedId", MezoExtra.PYTH_BTC_USD);
        vm.serializeAddress(k, "PriceFeed", MezoTestnet.PRICE_FEED);
        vm.serializeAddress(k, "StabilityPool", MezoTestnet.STABILITY_POOL);
        vm.serializeAddress(k, "BorrowerOperations", MezoTestnet.BORROWER_OPERATIONS);
        vm.serializeAddress(k, "TroveManager", MezoTestnet.TROVE_MANAGER);
        vm.serializeAddress(k, "HintHelpers", MezoTestnet.HINT_HELPERS);
        vm.serializeAddress(k, "SortedTroves", MezoTestnet.SORTED_TROVES);
        vm.serializeAddress(k, "RebateToken", address(d.rebateToken));
        vm.serializeAddress(k, "RebateStaking", address(d.staking));
        string memory json = vm.serializeAddress(k, "HouseExchange", address(d.exchange));
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            vm.writeJson(json, "./deployments/testnet-v3.json");
            console2.log("wrote deployments/testnet-v3.json");
        } else {
            console2.log("dry-run: deployments JSON NOT written. Would be:");
            console2.log(json);
        }

        address tl = address(d.timelock);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = rebateSwitchBatch(d);
        bytes32 switchId = d.timelock.hashOperationBatch(t, v, p, bytes32(0), REBATE_SWITCH_SALT);
        (address spT, bytes memory spP) = spEnableCall(d);
        bytes32 spId = d.timelock.hashOperation(spT, 0, spP, bytes32(0), SP_ENABLE_SALT);

        console2.log("==== v3 deployed. Owner of HouseExchange v3 / oracles = Timelock", tl);
        if (!d.rebateTokenToTimelock) {
            console2.log("!! RebateToken owner is not the deployer; transfer it to the Timelock separately:", tl);
        }
        console2.log("---- Timelock op A (RebateToken -> v3). Run ONLY after v2 has no open position / pending order");
        console2.log("     and v2 RebateStaking.totalStaked() == 0 (otherwise v2 losses + unstakes would revert).");
        console2.log("     id:");
        console2.logBytes32(switchId);
        console2.log("     salt:");
        console2.logBytes32(REBATE_SWITCH_SALT);
        console2.log("     target (both calls): RebateToken", address(d.rebateToken));
        console2.log("     payload[0] setMinter(HouseExchange v3):");
        console2.logBytes(p[0]);
        console2.log("     payload[1] setStaking(RebateStaking v3):");
        console2.logBytes(p[1]);
        console2.log("     schedule (proposer=deployer): scheduleBatch(targets,[0,0],payloads,0x0,salt,delay)");
        console2.log("     execute (anyone, after delay): executeBatch(targets,[0,0],payloads,0x0,salt)");
        console2.log("---- Timelock op B (enable Stability Pool). After op A and the keeper points at v3.");
        console2.log("     id:");
        console2.logBytes32(spId);
        console2.log("     target HouseExchange v3", spT);
        console2.log("     payload setSpParams(true, 50e18, 5000, 2000):");
        console2.logBytes(spP);
        console2.log("     salt:");
        console2.logBytes32(SP_ENABLE_SALT);
    }
}
