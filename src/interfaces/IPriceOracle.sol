// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceOracle — BTC/USD price source for HouseExchange (prices WAD = 1e18 USD per BTC).
/// @notice Pull-style: callers (keepers) may push a fresh update right before reading it.
interface IPriceOracle {
    /// @notice Native-token fee required by `update` for `data`.
    function updateFee(bytes[] calldata data) external view returns (uint256);

    /// @notice Verify and store price update(s). Must revert on invalid data.
    function update(bytes[] calldata data) external payable;

    /// @notice Latest verified price + its publish time. Reverts if stale / invalid / outside the sanity bound.
    function latest() external view returns (uint256 price, uint256 publishTime);

    /// @notice Last stored price without freshness/sanity checks (UI only).
    function peek() external view returns (uint256 price, uint256 publishTime);
}
