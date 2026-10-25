// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Verified Mezo testnet (chainId 31611) addresses — see docs/testnet-addresses.md
library MezoTestnet {
    uint256 internal constant CHAIN_ID = 31611;
    address internal constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address internal constant BTC = 0x7b7C000000000000000000000000000000000000;
    address internal constant SKIP_BTC_USD = 0x7b7c000000000000000000000000000000000015;
    address internal constant TIGRIS_ROUTER = 0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9;
    address internal constant TIGRIS_FACTORY = 0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A;
    address internal constant TIGRIS_MUSD_BTC = 0xd16A5Df82120ED8D626a1a15232bFcE2366d6AA9;
}

/// @notice Extra Mezo constants used by Bustline.
library MezoExtra {
    address internal constant PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    bytes32 internal constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
}
