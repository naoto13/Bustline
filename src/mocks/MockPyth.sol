// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPyth } from "../interfaces/IPyth.sol";

/// @notice Unit-test Pyth: update data = abi.encode(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime).
contract MockPyth is IPyth {
    mapping(bytes32 => Price) internal _p;
    uint256 public fee = 1;

    function set(bytes32 id, int64 price, int32 expo, uint256 publishTime) external {
        _p[id] = Price(price, 0, expo, publishTime);
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory) {
        return _p[id];
    }

    function getUpdateFee(bytes[] calldata d) external view returns (uint256) {
        return fee * d.length;
    }

    function updatePriceFeeds(bytes[] calldata d) external payable {
        require(msg.value >= fee * d.length, "fee");
        for (uint256 i; i < d.length; ++i) {
            (bytes32 id, int64 pr, uint64 conf, int32 expo, uint256 t) =
                abi.decode(d[i], (bytes32, int64, uint64, int32, uint256));
            if (t > _p[id].publishTime) _p[id] = Price(pr, conf, expo, t);
        }
    }
}
