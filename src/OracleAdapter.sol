// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/// @title OracleAdapter — wraps Skip Connect BTC/USD (Chainlink-compatible) on Mezo
/// @dev Skip address (mainnet & testnet): 0x7b7c000000000000000000000000000000000015
contract OracleAdapter is IOracleAdapter {
    IAggregatorV3 public immutable feed;
    uint256 public maxStaleness;

    error StalePrice();
    error InvalidPrice();
    error IncompleteRound();

    constructor(address feed_, uint256 maxStaleness_) {
        feed = IAggregatorV3(feed_);
        maxStaleness = maxStaleness_;
    }

    function price() external view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answeredInRound < roundId) revert IncompleteRound();
        if (block.timestamp > updatedAt + maxStaleness) revert StalePrice();
        if (answer <= 0) revert InvalidPrice();

        uint8 feedDecimals = feed.decimals();
        uint256 raw = uint256(answer);
        if (feedDecimals == 18) return raw;
        if (feedDecimals < 18) return raw * (10 ** (18 - feedDecimals));
        return raw / (10 ** (feedDecimals - 18));
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
