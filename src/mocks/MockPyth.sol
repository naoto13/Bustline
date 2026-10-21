// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPyth} from "../interfaces/IPyth.sol";

contract MockPyth is IPyth {
    mapping(bytes32 => Price) internal _p;

    function set(bytes32 id, int64 price, int32 expo, uint256 publishTime) external {
        _p[id] = Price(price, 0, expo, publishTime);
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory) {
        return _p[id];
    }
}
