// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";

/// @notice Admin-settable price for unit tests, anvil demos and the labelled crash-demo market.
///         Also exposes Chainlink-style `latestRoundData` so it can stand in for Skip in SkipBound tests.
contract MockOracle is IPriceOracle {
    uint256 public priceValue; // WAD
    uint256 public updatedAt;
    uint256 public maxStaleness = 1 hours;
    address public owner;
    uint80 public roundId;

    error StalePrice();
    error InvalidPrice();
    error NotOwner();

    constructor(uint256 initialPrice) {
        owner = msg.sender;
        priceValue = initialPrice;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidPrice();
        priceValue = newPrice;
        updatedAt = block.timestamp;
        unchecked {
            ++roundId;
        }
    }

    function setPriceRaw(uint256 newPrice, uint256 timestamp) external onlyOwner {
        priceValue = newPrice;
        updatedAt = timestamp;
        unchecked {
            ++roundId;
        }
    }

    function setMaxStaleness(uint256 secs) external onlyOwner {
        maxStaleness = secs;
    }

    function updateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    function update(bytes[] calldata) external payable { }

    function latest() external view returns (uint256, uint256) {
        if (block.timestamp > updatedAt + maxStaleness) revert StalePrice();
        if (priceValue == 0) revert InvalidPrice();
        return (priceValue, updatedAt);
    }

    function peek() external view returns (uint256, uint256) {
        return (priceValue, updatedAt);
    }

    function price() external view returns (uint256) {
        return priceValue;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, int256(priceValue), updatedAt, updatedAt, roundId);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}
