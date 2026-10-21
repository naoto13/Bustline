// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { SkipBound } from "./SkipBound.sol";

/// @title SignedPriceOracle — FALLBACK price source: reports signed by an authorized keeper key, verified on-chain.
/// @notice TRUST ASSUMPTION: the signer is trusted to report honest prices and to sign promptly. The contract bounds the
///         damage: ECDSA signature by `signer` only, report must be newer than the stored one, not in the future
///         (beyond `maxSkew`), not older than `maxAge`, and within `maxDeviationBps` of Skip Connect BTC/USD.
///         Report digest: EIP-191 personal_sign over keccak256(abi.encode(chainid, this, price, publishTime)).
contract SignedPriceOracle is IPriceOracle, SkipBound {
    address public signer;
    uint256 public maxAge;
    uint256 public maxSkew = 10;
    uint256 public price; // WAD
    uint256 public publishTime;

    error BadSignature();
    error FutureReport(uint256 publishTime);
    error StalePrice(uint256 publishTime);
    error InvalidPrice();

    event SignerSet(address signer);
    event PriceReported(uint256 price, uint256 publishTime);

    constructor(address signer_, uint256 maxAge_, address owner_) Ownable(owner_) {
        signer = signer_;
        maxAge = maxAge_;
        emit SignerSet(signer_);
    }

    function setSigner(address s) external onlyOwner {
        signer = s;
        emit SignerSet(s);
    }

    function setParams(uint256 maxAge_, uint256 maxSkew_) external onlyOwner {
        (maxAge, maxSkew) = (maxAge_, maxSkew_);
    }

    function digest(uint256 p, uint256 t) public view returns (bytes32) {
        return MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(block.chainid, address(this), p, t)));
    }

    function updateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    /// @param data each element = abi.encode(uint256 priceWad, uint256 publishTime, bytes signature)
    function update(bytes[] calldata data) external payable {
        for (uint256 i; i < data.length; ++i) {
            (uint256 p, uint256 t, bytes memory sig) = abi.decode(data[i], (uint256, uint256, bytes));
            if (p == 0) revert InvalidPrice();
            if (ECDSA.recover(digest(p, t), sig) != signer) revert BadSignature();
            if (t > block.timestamp + maxSkew) revert FutureReport(t);
            if (t <= publishTime) continue; // older/duplicate report: ignore (like Pyth)
            (price, publishTime) = (p, t);
            emit PriceReported(p, t);
        }
    }

    function latest() external view returns (uint256, uint256) {
        if (price == 0) revert InvalidPrice();
        if (publishTime + maxAge < block.timestamp) revert StalePrice(publishTime);
        _checkSkip(price);
        return (price, publishTime);
    }

    function peek() external view returns (uint256, uint256) {
        return (price, publishTime);
    }
}
