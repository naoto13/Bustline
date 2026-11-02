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
    // MUSD protocol (spec 3.2, mezo-org/musd testnet deployment)
    address internal constant BORROWER_OPERATIONS = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address internal constant STABILITY_POOL = 0x1CCA7E410eE41739792eA0A24e00349Dd247680e;
    address internal constant PRICE_FEED = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;
    address internal constant TROVE_MANAGER = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address internal constant HINT_HELPERS = 0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6;
    address internal constant SORTED_TROVES = 0x722E4D24FD6Ff8b0AC679450F3D91294607268fA;
}

/// @notice Extra Mezo constants used by Bustline.
library MezoExtra {
    address internal constant PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    bytes32 internal constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
}
