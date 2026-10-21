// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ImpactLib — PnL math for the synthetic perp (independent implementation).
/// @notice Winning closes: (1) deadband — exit measured `entry/deadbandDiv` less favourably, (2) asymmetric impact
///         scale = (1 - base) / (1 + 1/(move*rateMult) + refNotional/(1e6*move*posMult)), (3) win fee.
///         Mechanism inspired by public docs of Papertrade ("Asymmetric impact PnL") and Rollbit's market-impact model.
///         All values WAD (1e18) unless noted.
library ImpactLib {
    uint256 internal constant WAD = 1e18;

    struct Params {
        uint256 baseRate; // WAD, e.g. 0.10e18
        uint256 rateMult; // plain integer, e.g. 15_000
        uint256 posMult; // WAD, e.g. 814.598e18
        uint256 refNotional; // WAD USD, e.g. 100_000e18
        uint256 deadbandDiv; // e.g. 50_000 (= 0.2 bps); 0 disables
    }

    /// @notice Raw signed PnL of a position of notional `size` (USD) opened at `entry`, marked at `price`.
    function rawPnl(bool isLong, uint256 size, uint256 entry, uint256 price) internal pure returns (int256) {
        if (isLong) {
            return price >= entry
                ? int256(Math.mulDiv(size, price - entry, entry))
                : -int256(Math.mulDiv(size, entry - price, entry));
        }
        return price <= entry
            ? int256(Math.mulDiv(size, entry - price, entry))
            : -int256(Math.mulDiv(size, price - entry, entry));
    }

    /// @notice Exit price after applying the deadband against the trader (only meaningful for winners).
    function deadbandExit(bool isLong, uint256 entry, uint256 exit, uint256 deadbandDiv) internal pure returns (uint256) {
        if (deadbandDiv == 0) return exit;
        uint256 db = entry / deadbandDiv;
        if (isLong) return exit > db ? exit - db : 0;
        return exit + db;
    }

    /// @notice Impact scale factor (WAD) for a relative move `move` (WAD). 0 when move == 0.
    function scale(Params memory p, uint256 move) internal pure returns (uint256) {
        if (move == 0 || p.rateMult == 0 || p.posMult == 0) return 0;
        uint256 term1 = Math.mulDiv(WAD, WAD, move * p.rateMult);
        uint256 term2 = Math.mulDiv(p.refNotional, 1e30, Math.mulDiv(move, p.posMult, 1)); // R*1e30/(m*p)
        return Math.mulDiv(WAD - p.baseRate, WAD, WAD + term1 + term2);
    }

    /// @notice Gain kept by a winner before the win fee (0 if the deadband eats it). Caller ensures raw pnl > 0.
    function adjustedGain(Params memory p, bool isLong, uint256 size, uint256 entry, uint256 exit)
        internal
        pure
        returns (uint256)
    {
        uint256 e = deadbandExit(isLong, entry, exit, p.deadbandDiv);
        int256 g = rawPnl(isLong, size, entry, e);
        if (g <= 0) return 0;
        uint256 move = Math.mulDiv(e > entry ? e - entry : entry - e, WAD, entry);
        return Math.mulDiv(uint256(g), scale(p, move), WAD);
    }

    /// @notice Hard-bust trigger: zero-equity price moved `bufferDiv`-th of entry closer to entry.
    /// @dev long: entry*(1 - margin/size) + entry/bufferDiv ; short: entry*(1 + margin/size) - entry/bufferDiv
    function bustPrice(bool isLong, uint256 margin, uint256 size, uint256 entry, uint256 bufferDiv)
        internal
        pure
        returns (uint256)
    {
        uint256 dist = Math.mulDiv(entry, margin, size);
        uint256 buf = bufferDiv == 0 ? 0 : entry / bufferDiv;
        if (isLong) {
            uint256 zero = entry > dist ? entry - dist : 0;
            return zero + buf;
        }
        uint256 z = entry + dist;
        return z > buf ? z - buf : 0;
    }
}
