// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { RebateToken } from "../src/RebateToken.sol";
import { RebateStaking } from "../src/RebateStaking.sol";
import { MockOracle } from "../src/mocks/MockOracle.sol";
import { MezoTestnet } from "./MezoTestnet.sol";

/// @title DeployTestnetDemo — a SEPARATE, clearly-labelled "crash demo" market on Mezo TESTNET whose price comes from a
///        MockOracle owned by the deployer (to demonstrate liquidations / queue on demand). The real market
///        (DeployTestnet) uses Skip BTC/USD. Same guards: chainId 31611, CONFIRM_TESTNET_DEPLOY=1, key from env only.
contract DeployTestnetDemo is Script {
    function run() external {
        require(block.chainid == MezoTestnet.CHAIN_ID, "testnet only (31611)");
        require(vm.envOr("CONFIRM_TESTNET_DEPLOY", uint256(0)) == 1, "set CONFIRM_TESTNET_DEPLOY=1");
        uint256 pk = vm.envUint("MEZO_TESTNET_PRIVATE_KEY");
        address owner = vm.addr(pk);
        uint256 p0 = vm.envOr("INITIAL_PRICE", uint256(83_000e18));
        vm.startBroadcast(pk);
        MockOracle oracle = new MockOracle(p0);
        oracle.setMaxStaleness(7 days);
        RebateToken rt = new RebateToken("Mezo Paper (DEMO market)", "MPAPER-DEMO", owner);
        HouseExchange ex = new HouseExchange(MezoTestnet.MUSD, address(oracle), address(rt), owner);
        RebateStaking st = new RebateStaking(address(rt), MezoTestnet.MUSD, address(ex));
        rt.setMinter(address(ex));
        rt.setStaking(address(st));
        ex.setStaking(address(st));
        ex.setKeeper(owner, true);
        ex.setRisk(100, 10e18, 100_000e18, 1_000_000e18, 2_000, 3_600);
        vm.stopBroadcast();
        string memory k = "demo";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "owner", owner);
        vm.serializeAddress(k, "MUSD", MezoTestnet.MUSD);
        vm.serializeAddress(k, "MockOracle", address(oracle));
        vm.serializeAddress(k, "RebateToken", address(rt));
        vm.serializeAddress(k, "RebateStaking", address(st));
        string memory json = vm.serializeAddress(k, "HouseExchange", address(ex));
        vm.writeJson(json, "./deployments/testnet-demo.json");
        console2.log("HouseExchange (demo)", address(ex));
    }
}
