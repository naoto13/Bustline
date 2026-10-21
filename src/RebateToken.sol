// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RebateToken — loss-rebate point minted to traders in proportion to realised losses.
/// @notice Name/symbol are deployment parameters (placeholder by default). Non-transferable by default:
///         only mint, burn and moves to/from the staking contract are allowed until the owner flips `transferable`.
contract RebateToken is ERC20, Ownable {
    address public minter; // HouseExchange
    address public staking; // RebateStaking (allowed counterparty while non-transferable)
    bool public transferable;

    error NotMinter();
    error NonTransferable();

    event MinterSet(address minter);
    event StakingSet(address staking);
    event TransferableSet(bool transferable);

    constructor(string memory name_, string memory symbol_, address owner_) ERC20(name_, symbol_) Ownable(owner_) {}

    function setMinter(address m) external onlyOwner {
        minter = m;
        emit MinterSet(m);
    }

    function setStaking(address s) external onlyOwner {
        staking = s;
        emit StakingSet(s);
    }

    function setTransferable(bool t) external onlyOwner {
        transferable = t;
        emit TransferableSet(t);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!transferable && from != address(0) && to != address(0)) {
            if (staking == address(0) || (from != staking && to != staking)) revert NonTransferable();
        }
        super._update(from, to, value);
    }
}
