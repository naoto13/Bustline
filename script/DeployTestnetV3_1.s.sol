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

/// @title DeployTestnetV3_1 — v3.1 (emergency pause + protocol fee) on Mezo TESTNET (chainId 31611). See spec 5.5.
/// @notice Same flow as DeployTestnetV3 (a fresh, independent set — v3 is left untouched):
///   1. TimelockController: delay TIMELOCK_DELAY (default and minimum 3600 s), proposer + canceller = deployer, executor = anyone,
///      no admin.
///   2. PythPullOracle + SignedPriceOracle (MUSD PriceFeed bound ±1%), a NEW RebateToken ("Mezo Paper"/"MPAPER",
///      non-transferable; minter/staking are wired at deploy, so v3's token cannot be reused), HouseExchange v3.1 and
///      RebateStaking.
///   3. Configures everything as v3 (keeper, risk caps, Stability Pool wiring, SP params with spEnabled = false) plus
///      v3.1: guardian = GUARDIAN (default deployer), treasury = TREASURY (default deployer), protocolFeeBps = 100.
///      THEN hands ownership of HouseExchange, both oracles and the RebateToken to the timelock.
///   4. Prints the timelock operations the user runs later (NOT scheduled here): op B setSpParams(true, …) to enable
///      the Stability Pool, and the `unpause()` payload for after an emergency pause.
/// Keys: deployer (= timelock proposer), KEEPER and PRICE_SIGNER must be three DIFFERENT addresses (env, required).
/// Guards: chainId 31611, CONFIRM_TESTNET_DEPLOY=1. The deployer key is read ONLY from MEZO_TESTNET_PRIVATE_KEY
/// (never on the command line). Without it, DEPLOYER=<address> runs an unsigned simulation (dry-run).
/// deployments/testnet-v3.1.json is written only when broadcasting; testnet-v3.json / testnet.json are never touched.
contract DeployTestnetV3_1 is Script {
    bytes32 public constant SP_ENABLE_SALT = keccak256("bustline-v3.1-sp-enable");
    bytes32 public constant UNPAUSE_SALT = keccak256("bustline-v3.1-unpause");
    string public constant REBATE_NAME = "Mezo Paper";
    string public constant REBATE_SYMBOL = "MPAPER";

    uint256 public constant SP_MIN_LIQUID = 50e18;
    uint256 public constant SP_MAX_SHARE_BPS = 5_000;
    uint256 public constant SP_BAND_BPS = 2_000;
    uint256 public constant MIN_TIMELOCK_DELAY = 3600; // a shorter (e.g. 0) delay would make the timelock moot
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1% of the (impact-adjusted) winning profit → treasury

    struct Config {
        uint256 pk; // 0 = unsigned simulation as `deployer`
        address deployer;
        address keeper;
        address priceSigner;
        address guardian;
        address treasury;
        uint256 delay;
        bool pythPrimary;
    }

    struct Deployed {
        address deployer;
        address keeper;
        address priceSigner;
        address guardian;
        address treasury;
        TimelockController timelock;
        PythPullOracle pythOracle;
        SignedPriceOracle signedOracle;
        address oracle;
        HouseExchange exchange;
        RebateStaking staking;
        RebateToken rebateToken;
    }

    function run() external returns (Deployed memory) {
        return deploy(configFromEnv());
    }

    /// @notice Reads the env (same variables as v3, plus optional GUARDIAN / TREASURY).
    function configFromEnv() public view returns (Config memory c) {
        require(vm.envOr("CONFIRM_TESTNET_DEPLOY", uint256(0)) == 1, "set CONFIRM_TESTNET_DEPLOY=1");
        c.pk = vm.envOr("MEZO_TESTNET_PRIVATE_KEY", uint256(0));
        c.deployer = c.pk != 0 ? vm.addr(c.pk) : vm.envAddress("DEPLOYER");
        c.keeper = vm.envAddress("KEEPER");
        c.priceSigner = vm.envAddress("PRICE_SIGNER");
        c.guardian = vm.envOr("GUARDIAN", c.deployer);
        c.treasury = vm.envOr("TREASURY", c.deployer);
        c.delay = vm.envOr("TIMELOCK_DELAY", uint256(3600));
        c.pythPrimary = keccak256(bytes(vm.envOr("ORACLE_MODE", string("signed")))) == keccak256("pyth");
    }

    /// @notice The deployment itself; tests call it with an explicit Config (no process-global env races).
    function deploy(Config memory c) public returns (Deployed memory d) {
        require(block.chainid == MezoTestnet.CHAIN_ID, "testnet only (31611)");
        (d.deployer, d.keeper, d.priceSigner, d.guardian, d.treasury) =
            (c.deployer, c.keeper, c.priceSigner, c.guardian, c.treasury);
        require(
            d.keeper != d.deployer && d.priceSigner != d.deployer && d.keeper != d.priceSigner,
            "deployer, KEEPER, PRICE_SIGNER must be 3 different addresses"
        );
        require(d.keeper != address(0) && d.priceSigner != address(0), "zero address");
        require(d.treasury != address(0), "zero treasury");
        require(c.delay >= MIN_TIMELOCK_DELAY, "TIMELOCK_DELAY < 3600");
        require(d.guardian != d.keeper, "guardian must not be the keeper key");

        if (c.pk != 0) vm.startBroadcast(c.pk);
        else vm.startBroadcast(d.deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = d.deployer; // OZ 5: proposers also get CANCELLER_ROLE
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone may execute a ready operation
        d.timelock = new TimelockController(c.delay, proposers, executors, address(0));

        d.pythOracle = new PythPullOracle(MezoExtra.PYTH, MezoExtra.PYTH_BTC_USD, 60, d.deployer);
        d.pythOracle.setPriceBound(MezoTestnet.PRICE_FEED, 100); // within 1% of MUSD PriceFeed
        d.signedOracle = new SignedPriceOracle(d.priceSigner, 60, d.deployer);
        d.signedOracle.setPriceBound(MezoTestnet.PRICE_FEED, 100);
        d.oracle = c.pythPrimary ? address(d.pythOracle) : address(d.signedOracle);

        d.rebateToken = new RebateToken(REBATE_NAME, REBATE_SYMBOL, d.deployer); // transferable stays false
        d.exchange = new HouseExchange(MezoTestnet.MUSD, d.oracle, address(d.rebateToken), d.deployer);
        d.staking = new RebateStaking(address(d.rebateToken), MezoTestnet.MUSD, address(d.exchange));
        d.exchange.setStaking(address(d.staking));
        d.rebateToken.setMinter(address(d.exchange));
        d.rebateToken.setStaking(address(d.staking));
        d.exchange.setKeeper(d.keeper, true);
        // testnet demo caps (same as v3): 100x, min margin 10 MUSD, 100k max notional, 1M OI/side, 5bps buffer, 5 min
        d.exchange.setRisk(100, 10e18, 100_000e18, 1_000_000e18, 2_000, 300);
        d.exchange
            .setStabilityPool(
                MezoTestnet.STABILITY_POOL, MezoTestnet.PRICE_FEED, MezoTestnet.SORTED_TROVES, MezoTestnet.TROVE_MANAGER
            );
        d.exchange.setSpParams(false, SP_MIN_LIQUID, SP_MAX_SHARE_BPS, SP_BAND_BPS); // enabled later via timelock
        // v3.1
        d.exchange.setGuardian(d.guardian);
        d.exchange.setTreasury(d.treasury);
        d.exchange.setProtocolFee(PROTOCOL_FEE_BPS);

        d.exchange.transferOwnership(address(d.timelock));
        d.pythOracle.transferOwnership(address(d.timelock));
        d.signedOracle.transferOwnership(address(d.timelock));
        d.rebateToken.transferOwnership(address(d.timelock));
        vm.stopBroadcast();

        _report(d, c.delay, c.pythPrimary);
    }

    // ------------------------------------------------------------------ timelock operations (for the user)
    function spEnableCall(Deployed memory d) public pure returns (address target, bytes memory payload) {
        target = address(d.exchange);
        payload = abi.encodeCall(HouseExchange.setSpParams, (true, SP_MIN_LIQUID, SP_MAX_SHARE_BPS, SP_BAND_BPS));
    }

    function unpauseCall(Deployed memory d) public pure returns (address target, bytes memory payload) {
        target = address(d.exchange);
        payload = abi.encodeCall(HouseExchange.unpause, ());
    }

    function _report(Deployed memory d, uint256 delay, bool pythPrimary) internal {
        string memory k = "testnet-v3.1";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeString(k, "version", "v3.1");
        vm.serializeAddress(k, "Deployer", d.deployer);
        vm.serializeAddress(k, "Timelock", address(d.timelock));
        vm.serializeUint(k, "TimelockDelay", delay);
        vm.serializeAddress(k, "owner", address(d.timelock));
        vm.serializeAddress(k, "Keeper", d.keeper);
        vm.serializeAddress(k, "PriceSigner", d.priceSigner);
        vm.serializeAddress(k, "Guardian", d.guardian);
        vm.serializeAddress(k, "Treasury", d.treasury);
        vm.serializeUint(k, "ProtocolFeeBps", PROTOCOL_FEE_BPS);
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
            vm.writeJson(json, "./deployments/testnet-v3.1.json");
            console2.log("wrote deployments/testnet-v3.1.json");
        } else {
            console2.log("dry-run: deployments JSON NOT written. Would be:");
            console2.log(json);
        }

        address tl = address(d.timelock);
        (address spT, bytes memory spP) = spEnableCall(d);
        bytes32 spId = d.timelock.hashOperation(spT, 0, spP, bytes32(0), SP_ENABLE_SALT);
        (, bytes memory upP) = unpauseCall(d);

        console2.log("==== v3.1 deployed. Owner of HouseExchange v3.1 / oracles / RebateToken = Timelock", tl);
        console2.log("     guardian (pause only)", d.guardian);
        console2.log("     treasury (protocol fee)", d.treasury);
        console2.log("---- Timelock op B (enable Stability Pool). After the keeper Worker points at v3.1.");
        console2.log("     id:");
        console2.logBytes32(spId);
        console2.log("     target HouseExchange v3.1", spT);
        console2.log("     payload setSpParams(true, 50e18, 5000, 2000):");
        console2.logBytes(spP);
        console2.log("     salt:");
        console2.logBytes32(SP_ENABLE_SALT);
        console2.log("---- After an emergency pause: unpause() only via the timelock (schedule -> delay -> execute).");
        console2.log("     payload unpause():");
        console2.logBytes(upP);
        console2.log("     salt (suggested; use a fresh one per pause):");
        console2.logBytes32(UNPAUSE_SALT);
    }
}
