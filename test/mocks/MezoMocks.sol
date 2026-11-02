// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice MUSD PriceFeed stand-in: settable price (18 dp), can be made to revert like a stale Skip feed.
contract MockPriceFeed {
    uint256 public price;
    bool public reverting;
    bool public burnGas; // simulate the forked Skip stub: burn all the gas it is given

    constructor(uint256 p) {
        price = p;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    function setBurnGas(bool b) external {
        burnGas = b;
    }

    function fetchPrice() external view returns (uint256) {
        if (burnGas) {
            while (true) { } // runs out of gas
        }
        require(!reverting, "PriceFeed: Oracle is stale.");
        return price;
    }
}

contract MockSortedTroves {
    address public last;

    function setLast(address l) external {
        last = l;
    }

    function getLast() external view returns (address) {
        return last;
    }
}

contract MockTroveManager {
    uint256 public icr = 2e18;

    function setIcr(uint256 i) external {
        icr = i;
    }

    function getCurrentICR(address, uint256) external view returns (uint256) {
        return icr;
    }
}

/// @notice Simplified MUSD StabilityPool for unit tests. Tracks each depositor's compounded deposit directly.
///         `liquidate(depositor, burn, btc)` simulates an offset: burns `burn` MUSD of that deposit and credits `btc`
///         collateral gain (the mock must hold the BTC). Like the real pool, provide/withdraw send pending BTC gains
///         with `call{value}`, `withdrawFromSP(amount > 0)` reverts while `blocked`, and `withdrawFromSP(0)` needs a
///         non-zero initial deposit.
contract MockStabilityPool {
    IERC20 public immutable musd;
    bool public blocked;
    mapping(address => uint256) public deposits; // "initial" deposit (non-zero until fully withdrawn)
    mapping(address => uint256) public compounded;
    mapping(address => uint256) public gains;
    address constant DEAD = address(0xdead);

    constructor(address musd_) {
        musd = IERC20(musd_);
    }

    receive() external payable { }

    function setBlocked(bool b) external {
        blocked = b;
    }

    function liquidate(address depositor, uint256 burn, uint256 btc) external {
        if (burn > compounded[depositor]) burn = compounded[depositor];
        compounded[depositor] -= burn;
        if (burn > 0) musd.transfer(DEAD, burn);
        require(address(this).balance >= btc, "fund mock with BTC");
        gains[depositor] += btc;
    }

    function provideToSP(uint256 amount) external {
        require(amount > 0, "StabilityPool: Amount must be non-zero");
        compounded[msg.sender] += amount;
        deposits[msg.sender] = compounded[msg.sender];
        require(musd.transferFrom(msg.sender, address(this), amount), "MUSD was not transferred successfully.");
        _sendGain(msg.sender);
    }

    function withdrawFromSP(uint256 amount) external {
        if (amount != 0) require(!blocked, "StabilityPool: Cannot withdraw while there are troves with ICR < MCR");
        require(deposits[msg.sender] > 0, "StabilityPool: User must have a non-zero deposit");
        uint256 w = amount < compounded[msg.sender] ? amount : compounded[msg.sender];
        if (w > 0) musd.transfer(msg.sender, w);
        compounded[msg.sender] -= w;
        deposits[msg.sender] = compounded[msg.sender];
        _sendGain(msg.sender);
    }

    function _sendGain(address to) internal {
        uint256 g = gains[to];
        if (g == 0) return;
        gains[to] = 0;
        (bool ok,) = to.call{ value: g }("");
        require(ok, "Sending BTC failed");
    }

    function getCompoundedMUSDDeposit(address d) external view returns (uint256) {
        return compounded[d];
    }

    function getDepositorCollateralGain(address d) external view returns (uint256) {
        return gains[d];
    }
}
