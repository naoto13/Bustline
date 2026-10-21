// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { HouseExchange } from "../src/HouseExchange.sol";
import { RebateToken } from "../src/RebateToken.sol";
import { RebateStaking } from "../src/RebateStaking.sol";
import { MockOracle } from "../src/mocks/MockOracle.sol";
import { MezoTestnet } from "./MezoTestnet.sol";

/// @title DeployLocal — dev deployment on a LOCAL anvil fork of Mezo testnet (scripts/dev-fork.sh, unlocked anvil #0).
/// @dev Skip BTC/USD is a precompile the forked EVM cannot run → MockOracle seeded with INITIAL_PRICE (Skip value read
///      by dev-fork.sh with a read-only eth_call against the real testnet).
contract DeployLocal is Script {
    function run() external {
        require(block.chainid == MezoTestnet.CHAIN_ID, "fork must keep chainId 31611");
        require(vm.envOr("PERP_LOCAL_FORK", uint256(0)) == 1, "set PERP_LOCAL_FORK=1 (scripts/dev-fork.sh)");
        uint256 p0 = vm.envOr("INITIAL_PRICE", uint256(83_000e18));
        address keeper = vm.envOr("KEEPER", address(0));

        vm.startBroadcast();
        address owner = msg.sender;
        MockOracle oracle = new MockOracle(p0);
        oracle.setMaxStaleness(365 days); // idle anvil: no staleness
        RebateToken rt = new RebateToken(
            vm.envOr("REBATE_NAME", string("Mezo Paper")), vm.envOr("REBATE_SYMBOL", string("MPAPER")), owner
        );
        HouseExchange ex = new HouseExchange(MezoTestnet.MUSD, address(oracle), address(rt), owner);
        RebateStaking st = new RebateStaking(address(rt), MezoTestnet.MUSD, address(ex));
        rt.setMinter(address(ex));
        rt.setStaking(address(st));
        ex.setStaking(address(st));
        ex.setKeeper(owner, true);
        if (keeper != address(0)) ex.setKeeper(keeper, true);
        ex.setRisk(100, 10e18, 1_000_000e18, 10_000_000e18, 2_000, 3_600); // demo: 1h exec window on idle anvil
        vm.stopBroadcast();

        string memory k = "local";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "owner", owner);
        vm.serializeAddress(k, "MUSD", MezoTestnet.MUSD);
        vm.serializeAddress(k, "MockOracle", address(oracle));
        vm.serializeAddress(k, "RebateToken", address(rt));
        vm.serializeAddress(k, "RebateStaking", address(st));
        string memory json = vm.serializeAddress(k, "HouseExchange", address(ex));
        vm.writeJson(json, "./deployments/local.json");
        console2.log("HouseExchange", address(ex));
    }
}
