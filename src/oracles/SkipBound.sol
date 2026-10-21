// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

interface IAggregatorV3Like {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @title SkipBound — optional sanity bound: primary price must stay within `maxDeviationBps` of Skip Connect BTC/USD.
/// @dev Skip on Mezo (0x7b7c…0015) is a chain precompile; forked EVMs cannot execute it, so tests set `skip = 0`
///      (disabled) or point it at a mock. Skip's own staleness is bounded by `skipMaxAge`; a stale Skip disables the bound
///      rather than freezing the market (the primary feed still has its own staleness check).
abstract contract SkipBound is Ownable {
    IAggregatorV3Like public skip;
    uint256 public maxDeviationBps;
    uint256 public skipMaxAge = 300;

    error PriceDeviation(uint256 primary, uint256 skipPrice);

    event SkipBoundSet(address skip, uint256 maxDeviationBps, uint256 skipMaxAge);

    function setSkipBound(address skip_, uint256 maxDevBps, uint256 maxAge) external onlyOwner {
        (skip, maxDeviationBps, skipMaxAge) = (IAggregatorV3Like(skip_), maxDevBps, maxAge);
        emit SkipBoundSet(skip_, maxDevBps, maxAge);
    }

    function _checkSkip(uint256 p) internal view {
        if (address(skip) == address(0) || maxDeviationBps == 0) return;
        (, int256 answer,, uint256 updatedAt,) = skip.latestRoundData();
        if (answer <= 0 || updatedAt + skipMaxAge < block.timestamp) return;
        uint8 d = skip.decimals();
        uint256 s = d <= 18 ? uint256(answer) * 10 ** (18 - d) : uint256(answer) / 10 ** (d - 18);
        uint256 diff = s > p ? s - p : p - s;
        if (diff * 10_000 > s * maxDeviationBps) revert PriceDeviation(p, s);
    }
}
