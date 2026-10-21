// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IOracleAdapter — Chainlink-compatible BTC/USD price feed (Skip Connect on Mezo)
/// @notice Prices are normalized to 1e18 (USD per 1 BTC).
interface IOracleAdapter {
    /// @notice Returns BTC/USD price normalized to 1e18.
    /// @dev Reverts if the feed is stale or the answer is non-positive.
    function price() external view returns (uint256);

    /// @notice Raw Chainlink-style round data (answer may use feed decimals).
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Feed decimals (Skip on Mezo uses 18).
    function decimals() external view returns (uint8);

    /// @notice Max age (seconds) before a reading is considered stale.
    function maxStaleness() external view returns (uint256);
}
