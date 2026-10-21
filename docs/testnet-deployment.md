# Mezo testnet deployment (chainId 31611)

Deployed 2026-10-21 (JST) from the user's disposable testnet address `0x715211CAdb65Cc184c955B283933A1F7021d00b0`
(key supplied via the `MEZO_TESTNET_PRIVATE_KEY` env var only; never written to disk or argv). Unaudited demo.

## Main market — price = Skip Connect BTC/USD (`deployments/testnet.json`)

| Contract | Address |
|---|---|
| HouseExchange | `0x608757e82a847f04Ff6E8FeDCB18914c02e54a5c` |
| OracleAdapter (Skip `0x7b7c…0015`, 120 s staleness) | `0x53e834CDA15A7dDA36896f182B0feB4302DdF6f7` |
| RebateToken (HRP, non-transferable) | `0xBB96Fb1a7dC41427C286be13C36574DDa27f7cbe` |
| RebateStaking | `0x34C6316a83797C04e8c7003e293A03B65f596e8E` |
| MUSD | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` |

Pyth guard is configured (`0x2880…7B43`, BTC/USD feed) but only enforced when the Pyth update is < 60 s old; on
2026-10-21 the testnet Pyth BTC/USD price was ~85 days stale, so it is currently inactive.

## Crash-demo market — price = MockOracle owned by the deployer (`deployments/testnet-demo.json`)

Separate, clearly labelled market so liquidations and queue repayment can be shown on demand.

| Contract | Address |
|---|---|
| HouseExchange (DEMO) | `0xF5890Acbe962Eee3F9bB5FB18E535bcac7B0b1bE` |
| MockOracle | `0x68CF665f532345dDbD1002d2d66458A1D3fb29cD` |
| RebateToken (HRP-DEMO) | `0xD5a5D06EcFeF29959785D0f934FF17aD3aBC6e6e` |
| RebateStaking | `0x5890b192f8f1952E402D34A524b51044B13406a9` |

## MUSD source

Trove opened with 0.045 BTC collateral, 1,800 MUSD net debt (total ≈ 2,001.8 incl. 0.1% fee and 200 MUSD gas
compensation): tx `0x4a8dea67ba30961e7601d237cc9c14dc5b3d43debfe8c2f365e32664c82d9fb2`.

## On-chain demo events (2026-10-21)

Main market: long 300×50 and short 300×50 requested, filled by the keeper at a later Skip update; the winning long was
closed into an empty house → **Queued**; the losing short's close → **QueuePaid** + **RebateMinted**.
Demo market: long 200×20, short 100×100, short 100×10 → +0.5% close of the long → **Queued** → +1.5% → keeper
**Liquidated** the 100x short → **QueuePaid** → rebate staked → losing close with queue empty → 2% fee → **StakerRevenue** → claim.

### HouseExchange 0x608757e82a847f04Ff6E8FeDCB18914c02e54a5c
- PositionOpened — block 16276724 — tx `0x12f96d0dd932dba6dc8b5c2bfe692c5154b911a7793340f09d8ef0a7735a1cea`
- PositionOpened — block 16276725 — tx `0xb7e58a57e797d251b806048455d9af31e4622e9e38c486ee5926ad77ffd425b5`
- PositionClosed — block 16276780 — tx `0xdb820c0729cc0a9479c41b6a3e786d1ea227e78fcedeb5dfe99f401d39b05dc9`
- PositionClosed — block 16276781 — tx `0xb12bba2f6c5596bc8a68ac8c64557c5d9bc92490a652b202acb933b18e0b9193`
- Queued — block 16276780 — tx `0xdb820c0729cc0a9479c41b6a3e786d1ea227e78fcedeb5dfe99f401d39b05dc9`
- QueuePaid — block 16276781 — tx `0xb12bba2f6c5596bc8a68ac8c64557c5d9bc92490a652b202acb933b18e0b9193`
- RebateMinted — block 16276781 — tx `0xb12bba2f6c5596bc8a68ac8c64557c5d9bc92490a652b202acb933b18e0b9193`
### HouseExchange 0xF5890Acbe962Eee3F9bB5FB18E535bcac7B0b1bE
- PositionOpened — block 16276749 — tx `0xea4bd32e0518abb466b6ed4dda84cd26a07ed1f1d1ca257d3f1bdb85284c3682`
- PositionOpened — block 16276750 — tx `0xa1db756e246dd7154b32bd7aa5256780bb8e536f37447fce6c23e5ba6850140e`
- PositionOpened — block 16276751 — tx `0x18058c407e4b85a2238d1a43105dbbefddf602d7558a6d0d51349ac97cedda64`
- PositionClosed — block 16276756 — tx `0xcb9d7aad22f8d49d0ce524cc07fef175c64fc6130bb2396b028fb1c8388bfee9`
- PositionClosed — block 16276769 — tx `0x2aec6496e3e927506c43bf87de52f5a993028f4c40a7663de75b244524b77c10`
- Liquidated — block 16276760 — tx `0xd78fcc7a3446dcf14dcd277675edd7a35762f04be9e545ed9b1ebc6575567334`
- Queued — block 16276756 — tx `0xcb9d7aad22f8d49d0ce524cc07fef175c64fc6130bb2396b028fb1c8388bfee9`
- QueuePaid — block 16276760 — tx `0xd78fcc7a3446dcf14dcd277675edd7a35762f04be9e545ed9b1ebc6575567334`
- StakerRevenue — block 16276769 — tx `0x2aec6496e3e927506c43bf87de52f5a993028f4c40a7663de75b244524b77c10`
- RebateMinted — block 16276760 — tx `0xd78fcc7a3446dcf14dcd277675edd7a35762f04be9e545ed9b1ebc6575567334`
- RebateMinted — block 16276769 — tx `0x2aec6496e3e927506c43bf87de52f5a993028f4c40a7663de75b244524b77c10`
