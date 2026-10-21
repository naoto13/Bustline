// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { RebateToken } from "../src/RebateToken.sol";
import { RebateStaking } from "../src/RebateStaking.sol";
import { PythPullOracle } from "../src/oracles/PythPullOracle.sol";
import { SignedPriceOracle } from "../src/oracles/SignedPriceOracle.sol";
import { MezoTestnet, MezoExtra } from "./MezoTestnet.sol";

/// @title DeployTestnet — Mezo TESTNET (chainId 31611) deployment. See docs/TESTNET-DEPLOY.md.
/// @notice Guards: chainId must be 31611, CONFIRM_TESTNET_DEPLOY=1 must be set, and the key is read ONLY from the
///         MEZO_TESTNET_PRIVATE_KEY env var (never pass it on the command line, never write it to disk).
///         Without `--broadcast` forge only simulates.
contract DeployTestnet is Script {
    function run() external {
        require(block.chainid == MezoTestnet.CHAIN_ID, "testnet only (31611)");
        require(vm.envOr("CONFIRM_TESTNET_DEPLOY", uint256(0)) == 1, "set CONFIRM_TESTNET_DEPLOY=1");
        uint256 pk = vm.envUint("MEZO_TESTNET_PRIVATE_KEY");
        address owner = vm.addr(pk);
        address keeper = vm.envOr("KEEPER", owner);
        address reporter = vm.envOr("PRICE_SIGNER", keeper);
        // ORACLE_MODE: "pyth" = PythPullOracle primary (needs Hermes updates), "signed" = keeper-signed fallback
        bool pythPrimary = keccak256(bytes(vm.envOr("ORACLE_MODE", string("signed")))) == keccak256("pyth");

        vm.startBroadcast(pk);
        // Both oracles are deployed; the exchange owner can switch with setOracle() (one tx) once Hermes access exists.
        PythPullOracle pythOracle = new PythPullOracle(MezoExtra.PYTH, MezoExtra.PYTH_BTC_USD, 60, owner);
        pythOracle.setSkipBound(MezoTestnet.SKIP_BTC_USD, 100, 300); // Pyth must stay within 1% of Skip
        SignedPriceOracle signedOracle = new SignedPriceOracle(reporter, 60, owner);
        signedOracle.setSkipBound(MezoTestnet.SKIP_BTC_USD, 100, 300);
        address oracle = pythPrimary ? address(pythOracle) : address(signedOracle);
        RebateToken rt = new RebateToken(
            vm.envOr("REBATE_NAME", string("Mezo Paper")), vm.envOr("REBATE_SYMBOL", string("MPAPER")), owner
        );
        HouseExchange ex = new HouseExchange(MezoTestnet.MUSD, oracle, address(rt), owner);
        RebateStaking st = new RebateStaking(address(rt), MezoTestnet.MUSD, address(ex));
        rt.setMinter(address(ex));
        rt.setStaking(address(st));
        ex.setStaking(address(st));
        ex.setKeeper(keeper, true);
        // testnet demo caps: 100x, min margin 10 MUSD, 100k max notional, 1M OI per side, 5bps bust buffer, 5 min window
        ex.setRisk(100, 10e18, 100_000e18, 1_000_000e18, 2_000, 300);
        vm.stopBroadcast();

        string memory k = "testnet";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "owner", owner);
        vm.serializeAddress(k, "MUSD", MezoTestnet.MUSD);
        vm.serializeString(k, "oracleMode", pythPrimary ? "pyth" : "signed");
        vm.serializeAddress(k, "Oracle", oracle);
        vm.serializeAddress(k, "PythPullOracle", address(pythOracle));
        vm.serializeAddress(k, "SignedPriceOracle", address(signedOracle));
        vm.serializeAddress(k, "PriceSigner", reporter);
        vm.serializeAddress(k, "Pyth", MezoExtra.PYTH);
        vm.serializeBytes32(k, "PythFeedId", MezoExtra.PYTH_BTC_USD);
        vm.serializeAddress(k, "RebateToken", address(rt));
        vm.serializeAddress(k, "RebateStaking", address(st));
        string memory json = vm.serializeAddress(k, "HouseExchange", address(ex));
        vm.writeJson(json, "./deployments/testnet.json");
        console2.log("HouseExchange", address(ex));
    }
}
