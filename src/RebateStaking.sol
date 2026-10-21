// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RebateStaking — stake the loss-rebate token, earn MUSD revenue share from the house.
/// @dev Classic accumulator (accRewardPerShare). Rewards arrive via `notifyReward` after the funder transferred MUSD.
contract RebateStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant ACC = 1e36;

    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken; // MUSD
    address public immutable funder; // HouseExchange

    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint256 public totalDistributed;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public owed; // settled-but-unclaimed

    error NotFunder();
    error ZeroAmount();
    error NoStakers();

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount);

    constructor(address stakeToken_, address rewardToken_, address funder_) {
        stakeToken = IERC20(stakeToken_);
        rewardToken = IERC20(rewardToken_);
        funder = funder_;
    }

    function _settle(address u) internal {
        uint256 accrued = (staked[u] * accRewardPerShare) / ACC;
        owed[u] += accrued - rewardDebt[u];
    }

    function _sync(address u) internal {
        rewardDebt[u] = (staked[u] * accRewardPerShare) / ACC;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _settle(msg.sender);
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        staked[msg.sender] += amount;
        totalStaked += amount;
        _sync(msg.sender);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _settle(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        _sync(msg.sender);
        stakeToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        _sync(msg.sender);
        amount = owed[msg.sender];
        owed[msg.sender] = 0;
        if (amount > 0) rewardToken.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function pending(address u) external view returns (uint256) {
        return owed[u] + (staked[u] * accRewardPerShare) / ACC - rewardDebt[u];
    }

    /// @notice Called by the house after transferring `amount` MUSD here. Reverts with no stakers (house keeps it).
    function notifyReward(uint256 amount) external {
        if (msg.sender != funder) revert NotFunder();
        if (totalStaked == 0) revert NoStakers();
        accRewardPerShare += (amount * ACC) / totalStaked;
        totalDistributed += amount;
        emit RewardNotified(amount);
    }
}
