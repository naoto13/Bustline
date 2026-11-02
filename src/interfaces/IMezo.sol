// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interfaces of the Mezo MUSD protocol used by Bustline. Signatures checked against
///         mezo-org/musd at commit da7888a10949c8a5d3f884454cec8978cfa87e48 (solidity/contracts/*.sol).

/// @dev PriceFeed.sol: `fetchPrice() public view returns (uint256)` — BTC/USD, 18 decimals. Reverts with
///      "PriceFeed: Oracle is stale." if the underlying Skip aggregator was not updated within 60 s.
interface IMezoPriceFeed {
    function fetchPrice() external view returns (uint256);
}

/// @dev StabilityPool.sol. `provideToSP` / `withdrawFromSP` send the caller's accumulated BTC gain with
///      `call{value}` (re-entering the caller's `receive`). `withdrawFromSP(amount > 0)` reverts while the lowest
///      trove is under MCR (or PriceFeed reverts); `withdrawFromSP(0)` is not gated but needs a non-zero deposit.
interface IMezoStabilityPool {
    function provideToSP(uint256 _amount) external;
    function withdrawFromSP(uint256 _amount) external;
    function getCompoundedMUSDDeposit(address _depositor) external view returns (uint256);
    function getDepositorCollateralGain(address _depositor) external view returns (uint256);
}

/// @dev SortedTroves.sol: `getLast()` = trove with the smallest NICR (address(0) if the list is empty).
interface IMezoSortedTroves {
    function getLast() external view returns (address);
}

/// @dev TroveManager.sol: `getCurrentICR(borrower, price)` (1e18 = 100%; type(uint256).max for zero debt).
interface IMezoTroveManager {
    function getCurrentICR(address _borrower, uint256 _price) external view returns (uint256);
}
