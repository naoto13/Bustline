// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {HouseExchange} from "../src/HouseExchange.sol";

/// @title KeeperOps — single keeper actions on Mezo TESTNET, signed with MEZO_TESTNET_PRIVATE_KEY (env only).
/// @dev Invoked by the Python keeper in --execute-testnet mode: `forge script script/KeeperOps.s.sol --sig "execute(address,uint256)" ...`
contract KeeperOps is Script {
    modifier guarded() {
        require(block.chainid == 31611, "testnet only (31611)");
        vm.startBroadcast(vm.envUint("MEZO_TESTNET_PRIVATE_KEY"));
        _;
        vm.stopBroadcast();
    }

    function execute(address ex, uint256 orderId) external guarded {
        HouseExchange(ex).executeOrder(orderId);
    }

    function liquidate(address ex, uint256 positionId) external guarded {
        HouseExchange(ex).liquidate(positionId);
    }

    function harvest(address ex, uint256 n) external guarded {
        HouseExchange(ex).harvest(n);
    }
}
