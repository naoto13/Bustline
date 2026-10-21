// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPriceOracle } from "./interfaces/IPriceOracle.sol";

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/// @title OracleAdapter — Skip Connect BTC/USD (Chainlink-compatible) as an IPriceOracle (legacy / last-resort source;
///        the primary price is Pyth via PythPullOracle, see README "Oracle").
/// @dev Skip address (mainnet & testnet): 0x7b7c000000000000000000000000000000000015
contract OracleAdapter is IPriceOracle {
    IAggregatorV3 public immutable feed;
    uint256 public maxStaleness;

    error StalePrice();
    error InvalidPrice();

    constructor(address feed_, uint256 maxStaleness_) {
        feed = IAggregatorV3(feed_);
        maxStaleness = maxStaleness_;
    }

    function updateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    /// @dev Skip is pushed by Mezo validators; nothing to update.
    function update(bytes[] calldata) external payable { }

    function latest() external view returns (uint256, uint256) {
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        return (price(), updatedAt);
    }

    function peek() external view returns (uint256, uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        return (answer > 0 ? _scale(uint256(answer)) : 0, updatedAt);
    }

    function _scale(uint256 raw) internal view returns (uint256) {
        uint8 d = feed.decimals();
        return d <= 18 ? raw * 10 ** (18 - d) : raw / 10 ** (d - 18);
    }

    function price() public view returns (uint256) {
        // NOTE: Skip on Mezo testnet returns answeredInRound = 0 (verified 2026-10-21 via eth_call), so the usual
        // Chainlink `answeredInRound >= roundId` check would always revert; we rely on updatedAt freshness instead.
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (block.timestamp > updatedAt + maxStaleness) revert StalePrice();
        if (answer <= 0) revert InvalidPrice();
        return _scale(uint256(answer));
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return feed.latestRoundData();
    }

    function decimals() external view returns (uint8) {
        return feed.decimals();
    }
}
