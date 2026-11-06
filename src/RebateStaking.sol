// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RebateStaking — stake the loss-rebate token, earn MUSD revenue share and native BTC from the house.
/// @dev Classic accumulator (acc*PerShare), one per reward asset. MUSD arrives via `notifyReward` after the funder
///      transferred it; BTC (the house's Stability Pool collateral gains) arrives with `notifyRewardBtc{value}`.
///      Rounding: per-share increments are floored, so the contract can only ever owe less than it received; the dust
///      stays here.
contract RebateStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant ACC = 1e36;

    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken; // MUSD
    address public immutable funder; // HouseExchange

    uint256 public totalStaked;
    uint256 public accRewardPerShare; // MUSD
    uint256 public accBtcPerShare; // native BTC
    uint256 public totalDistributed; // MUSD
    uint256 public totalBtcDistributed;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public owed; // settled-but-unclaimed MUSD
    mapping(address => uint256) public btcDebt;
    mapping(address => uint256) public owedBtc; // settled-but-unclaimed BTC

    error NotFunder();
    error ZeroAmount();
    error NoStakers();
    error BtcTransferFailed();

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event ClaimedBtc(address indexed user, uint256 amount);
    event ClaimedBtcTo(address indexed user, address indexed to, uint256 amount);
    event BtcClaimFailed(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount);
    event RewardBtcNotified(uint256 amount);

    constructor(address stakeToken_, address rewardToken_, address funder_) {
        stakeToken = IERC20(stakeToken_);
        rewardToken = IERC20(rewardToken_);
        funder = funder_;
    }

    function _settle(address u) internal {
        uint256 s = staked[u];
        owed[u] += (s * accRewardPerShare) / ACC - rewardDebt[u];
        owedBtc[u] += (s * accBtcPerShare) / ACC - btcDebt[u];
    }

    function _sync(address u) internal {
        uint256 s = staked[u];
        rewardDebt[u] = (s * accRewardPerShare) / ACC;
        btcDebt[u] = (s * accBtcPerShare) / ACC;
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

    /// @notice Pays both rewards: MUSD (`amount`) always, native BTC (`btcAmount`) to `msg.sender` if it accepts it.
    /// @dev Never reverts because of the BTC leg: if the native send fails (e.g. a contract without `receive`), the BTC
    ///      stays owed (`owedBtc`), `BtcClaimFailed` is emitted and `btcAmount` is 0 (the amount actually paid). Such a
    ///      staker can route its BTC elsewhere with `claimBtcTo`. CEI: state is zeroed before any external call.
    function claim() external nonReentrant returns (uint256 amount, uint256 btcAmount) {
        _settle(msg.sender);
        _sync(msg.sender);
        amount = owed[msg.sender];
        uint256 btcOwed = owedBtc[msg.sender];
        owed[msg.sender] = 0;
        owedBtc[msg.sender] = 0;
        if (amount > 0) rewardToken.safeTransfer(msg.sender, amount);
        if (btcOwed > 0) {
            (bool ok,) = msg.sender.call{ value: btcOwed }("");
            if (ok) {
                btcAmount = btcOwed;
            } else {
                owedBtc[msg.sender] = btcOwed; // keep it owed; claimable later or via claimBtcTo
                emit BtcClaimFailed(msg.sender, btcOwed);
            }
        }
        emit Claimed(msg.sender, amount);
        emit ClaimedBtc(msg.sender, btcAmount);
    }

    /// @notice Pays only the caller's BTC reward, to `to` (for stakers that cannot receive native BTC themselves).
    ///         Reverts with `BtcTransferFailed` if the send to `to` fails (nothing changes). MUSD is untouched.
    function claimBtcTo(address payable to) external nonReentrant returns (uint256 btcAmount) {
        _settle(msg.sender);
        _sync(msg.sender);
        btcAmount = owedBtc[msg.sender];
        owedBtc[msg.sender] = 0;
        if (btcAmount > 0) {
            (bool ok,) = to.call{ value: btcAmount }("");
            if (!ok) revert BtcTransferFailed();
        }
        emit ClaimedBtcTo(msg.sender, to, btcAmount);
    }

    function pending(address u) external view returns (uint256) {
        return owed[u] + (staked[u] * accRewardPerShare) / ACC - rewardDebt[u];
    }

    function pendingBtc(address u) external view returns (uint256) {
        return owedBtc[u] + (staked[u] * accBtcPerShare) / ACC - btcDebt[u];
    }

    /// @notice Called by the house after transferring `amount` MUSD here. Reverts with no stakers (house keeps it).
    function notifyReward(uint256 amount) external {
        if (msg.sender != funder) revert NotFunder();
        if (totalStaked == 0) revert NoStakers();
        accRewardPerShare += (amount * ACC) / totalStaked;
        totalDistributed += amount;
        emit RewardNotified(amount);
    }

    /// @notice Called by the house with the BTC attached. Reverts with no stakers (house keeps it for later).
    function notifyRewardBtc() external payable {
        if (msg.sender != funder) revert NotFunder();
        if (totalStaked == 0) revert NoStakers();
        accBtcPerShare += (msg.value * ACC) / totalStaked;
        totalBtcDistributed += msg.value;
        emit RewardBtcNotified(msg.value);
    }
}
