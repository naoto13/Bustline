// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IMezoPriceFeed } from "../interfaces/IMezo.sol";

/// @title MezoPriceBound — sanity bound: the primary price must stay within `boundBps` of MUSD's PriceFeed.
/// @notice Replaces SkipBound (wave 1). The reference is the price the MUSD protocol itself uses for troves
///         (`PriceFeed.fetchPrice()`, BTC/USD 18 dp, backed by Skip Connect).
///         If PriceFeed fails (stale > 60 s, any revert, zero) the bound is NOT applied: blocking price updates would
///         block liquidations, which is the bigger risk. `update()` paths emit `PriceBoundSkipped` in that case.
/// @dev Gas: the PriceFeed call gets a fixed `PRICE_FEED_GAS` stipend and the caller must have enough gas left that
///      the stipend is really available. Otherwise a caller could pick a gas limit that makes only the inner call run
///      out of gas, landing in `catch` and skipping the bound on purpose. The stipend also stops a broken/recursive
///      feed (e.g. the Skip precompile stub on a fork) from eating 63/64 of the transaction's gas.
abstract contract MezoPriceBound is Ownable {
    /// @dev PriceFeed answers in 18 decimals = Bustline's WAD prices, so no scaling is needed.
    uint256 public constant PRICE_FEED_GAS = 100_000;
    uint256 internal constant BOUND_GAS_OVERHEAD = 5_000;

    IMezoPriceFeed public priceFeed;
    uint256 public boundBps;

    error PriceDeviation(uint256 primary, uint256 refPrice);
    error InsufficientGasForBound();

    event PriceBoundSet(address priceFeed, uint256 boundBps);
    event PriceBoundSkipped(uint256 price);

    /// @param feed MUSD PriceFeed (address(0) disables the bound). @param bps max deviation (0 disables).
    function setPriceBound(address feed, uint256 bps) external onlyOwner {
        require(bps <= 10_000, "bps");
        (priceFeed, boundBps) = (IMezoPriceFeed(feed), bps);
        emit PriceBoundSet(feed, bps);
    }

    /// @notice Reference price from PriceFeed; ok = false if the bound is disabled or PriceFeed failed.
    function boundReference() public view returns (bool ok, uint256 ref) {
        if (address(priceFeed) == address(0) || boundBps == 0) return (false, 0);
        if (gasleft() < (PRICE_FEED_GAS * 64) / 63 + BOUND_GAS_OVERHEAD) revert InsufficientGasForBound();
        try priceFeed.fetchPrice{ gas: PRICE_FEED_GAS }() returns (uint256 r) {
            if (r == 0) return (false, 0);
            return (true, r);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Reverts with PriceDeviation if `p` is outside the bound. Returns false if the bound could not be applied.
    function _checkBound(uint256 p) internal view returns (bool applied) {
        (bool ok, uint256 ref) = boundReference();
        if (!ok) return false;
        uint256 diff = ref > p ? ref - p : p - ref;
        if (diff * 10_000 > ref * boundBps) revert PriceDeviation(p, ref);
        return true;
    }

    /// @dev Same as `_checkBound`, for state-changing update paths: logs when the bound was skipped.
    function _checkBoundLogged(uint256 p) internal {
        if (!_checkBound(p) && address(priceFeed) != address(0) && boundBps != 0) emit PriceBoundSkipped(p);
    }
}
