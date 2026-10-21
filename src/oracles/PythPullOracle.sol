// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IPyth } from "../interfaces/IPyth.sol";
import { SkipBound } from "./SkipBound.sol";

/// @title PythPullOracle — primary price = Pyth BTC/USD (mainnet "stable" feed), pushed by the keeper.
/// @notice The keeper fetches a signed update from Pyth Hermes and passes it into the fill/liquidation tx; the Pyth
///         contract on Mezo verifies the Wormhole guardian signatures on-chain (trustless w.r.t. the keeper).
///         Verified 2026-10-21: Mezo testnet Pyth (0x2880…7B43, v1.4.6) uses the same guardian set + Pythnet data source
///         as Base mainnet and accepted a mainnet-signed BTC/USD update (eth_call + fork test).
contract PythPullOracle is IPriceOracle, SkipBound {
    IPyth public immutable pyth;
    bytes32 public immutable feedId;
    uint256 public maxAge; // seconds
    uint256 public maxConfBps = 100; // reject if conf > 1% of price

    error StalePrice(uint256 publishTime);
    error InvalidPrice();
    error WideConfidence();

    constructor(address pyth_, bytes32 feedId_, uint256 maxAge_, address owner_) Ownable(owner_) {
        pyth = IPyth(pyth_);
        feedId = feedId_;
        maxAge = maxAge_;
    }

    function setParams(uint256 maxAge_, uint256 maxConfBps_) external onlyOwner {
        (maxAge, maxConfBps) = (maxAge_, maxConfBps_);
    }

    function updateFee(bytes[] calldata data) external view returns (uint256) {
        return pyth.getUpdateFee(data);
    }

    /// @notice Permissionless: anyone may push a Pyth update (signatures are verified by Pyth).
    function update(bytes[] calldata data) external payable {
        pyth.updatePriceFeeds{ value: msg.value }(data);
    }

    function _read() internal view returns (uint256 p, uint256 t, uint256 conf) {
        IPyth.Price memory q = pyth.getPriceUnsafe(feedId);
        if (q.price <= 0) revert InvalidPrice();
        int256 e = int256(q.expo) + 18;
        uint256 v = uint256(uint64(q.price));
        if (e >= 0) {
            p = v * 10 ** uint256(e);
            conf = uint256(q.conf) * 10 ** uint256(e);
        } else {
            p = v / 10 ** uint256(-e);
            conf = uint256(q.conf) / 10 ** uint256(-e);
        }
        t = q.publishTime;
    }

    function latest() external view returns (uint256 p, uint256 t) {
        uint256 conf;
        (p, t, conf) = _read();
        if (t + maxAge < block.timestamp) revert StalePrice(t);
        if (conf * 10_000 > p * maxConfBps) revert WideConfidence();
        _checkSkip(p);
    }

    function peek() external view returns (uint256 p, uint256 t) {
        IPyth.Price memory q = pyth.getPriceUnsafe(feedId);
        if (q.price <= 0) return (0, q.publishTime);
        (p, t,) = _read();
    }
}
