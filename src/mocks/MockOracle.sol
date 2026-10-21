// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

/// @notice Admin-settable mock oracle for unit tests and crash demos.
contract MockOracle is IOracleAdapter {
    uint256 public priceValue; // 1e18 USD per BTC
    uint256 public updatedAt;
    uint256 public maxStaleness = 1 hours;
    address public owner;
    uint80 public roundId;

    error StalePrice();
    error InvalidPrice();
    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint256 initialPrice) {
        owner = msg.sender;
        priceValue = initialPrice;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidPrice();
        priceValue = newPrice;
        updatedAt = block.timestamp;
        unchecked {
            ++roundId;
        }
    }

    /// @notice Set price without refreshing timestamp (for staleness tests).
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

    function price() external view returns (uint256) {
        if (block.timestamp > updatedAt + maxStaleness) revert StalePrice();
        if (priceValue == 0) revert InvalidPrice();
        return priceValue;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256 answer, uint256, uint256, uint80)
    {
        return (roundId, int256(priceValue), updatedAt, updatedAt, roundId);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}
