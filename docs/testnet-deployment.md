# Bustline — Mezo testnet deployment (chainId 31611)

## v2 market (current, 2026-10-21 17:13 JST) — Pyth-primary oracle design, keeper-signed fallback live (`deployments/testnet.json`)

| Contract | Address | Deploy tx |
|---|---|---|
| HouseExchange | `0x5e941EEA56DEE50924950E86f24624Be37f02050` | `0xbed9fb1030558f6cc13049ab0dd89c55d4162d515e57204a1426fc82861d4976` |
| SignedPriceOracle (**active**; signer `0x7152…00b0`, maxAge 60 s, Skip ±1%) | `0x83401Fc1B16DbCa09531241Dad49700248C8c72c` | `0x177eb45bd3fda1d1d39080c51b0c0457fbdc5a45626438475f22315845c82741` |
| PythPullOracle (deployed, switch-ready; Pyth `0x2880…7B43`, BTC/USD `0xe62d…5b43`, maxAge 60 s, Skip ±1%) | `0xA1E556D9e659fC879D3c37Bd2490D3274B6c20bB` | `0x59fec8279b3e069e21fd1231dad8cfe5a56a2fe225106fd75884b5bcf8ddbe25` |
| RebateToken — **Mezo Paper (MPAPER)**, non-transferable | `0x07F9bd344916571321f494aE00eDD30ac1dE89Bd` | `0x7a24bb5d34ee07f3410c6327be51a6c18a992dd97984ab1204df87e61c07c5cf` |
| RebateStaking | `0x8c76076af61489D8fdc10F6DbA7a9aeC52879fD8` | `0x51095becb892713c48045a5c1aadc0ee4db3254f787ea6f0d0b04816fe8e06cc` |

Why the signed fallback is active: Mezo testnet Pyth **does accept** Pyth stable (mainnet-signed) updates — verified with
a real Base-mainnet BTC/USD update (eth_call `parsePriceFeedUpdates`, fee 10 wei, and `test/fork/PythFork.t.sol`:
accept + fill-in-same-tx + liquidation-with-update on real Mezo Pyth bytecode). But Pyth Hermes (`hermes.pyth.network`,
`pyth.dourolabs.app/hermes`, Benchmarks) returns **401 without an API key** (required since 2026-08). With
`PYTH_API_KEY` set: `HouseExchange.setOracle(0xA1E5…20bB)` + `oracleMode: "pyth"` → keeper uses Hermes automatically.

Trust assumption of the fallback: the keeper key signs `(chainid, oracle, price, publishTime)` (EIP-191); the contract
rejects bad signatures, reports > 10 s in the future, older-than-stored reports, prices older than 60 s and prices more
than 1% away from Skip. Within that band the signer is trusted. Off-chain price = median of Coinbase/Kraken/Bitstamp.

### Live demo on v2 (every fill/liquidation carries its own signed price update in the same tx)
- Price push (signed report): tx `0x93216aeb5f34d423410591f8717d633d9d544df29986b762b21e342a4fa9bcc9`
- Long 100 MUSD × 10x: request `0xa16d1eb0…4b965` → keeper fill **with signed update in the same tx** `0x71e6e05f…1a5a1704`
  (PriceReported + PositionOpened); close request `0x34770da6…1244` → fill `0x94b7aae9…f425e` (PositionClosed + RebateMinted, 32.49 MPAPER).
- Liquidation path: long 10 × 100x (bust ≈ $82,243) and short 10 × 100x (bust ≈ $83,821) opened at ≈ $83,032
  (fills `0xcfa56438…5a75`, `0xfd15e12a…e47e`). The keeper (`--execute-testnet --heartbeat 120`) keeps pushing signed
  prices and will liquidate whichever side BTC crosses (≈ ±0.95%). No price was forced: as of 17:52 JST BTC ranged
  $83,032–$83,278, so the live liquidation had not triggered yet. The liquidation path with the new oracle is proven on
  real Mezo Pyth bytecode in `test/fork/PythFork.t.sol::test_fork_pyth_liquidationWithUpdate` and with the signed oracle in
  `test/Oracles.t.sol::test_exchange_signedFillAndLiquidate`.

Raw event list (`scripts/list-events.py deployments/testnet.json 16277100`):

### HouseExchange 0x5e941EEA56DEE50924950E86f24624Be37f02050
- OrderRequested — block 16277152 — tx `0xa16d1eb08f355e1b11028794a9b3d1cc78bff65d8e738005e6ba026d8d84b965`
- PositionOpened — block 16277155 — tx `0x71e6e05faf30082580cc1ef84642f197cb19371b997f5d44ae818149a45a1704`
- OrderRequested — block 16277158 — tx `0x34770da66c81e2a4e280f8a8a4df3f5b0a8f332f41c922462749e6ffe3c81244`
- RebateMinted — block 16277160 — tx `0x94b7aae9b7340b9ae4cbf3f31b23edb5d8f5bea89c6998e4292309022dff425e`
- PositionClosed — block 16277160 — tx `0x94b7aae9b7340b9ae4cbf3f31b23edb5d8f5bea89c6998e4292309022dff425e`
- OrderRequested — block 16277164 — tx `0xa6a723844cd25478cabfc4e43511412d2cd4b95f359f1f9da246748b623ab451`
- OrderRequested — block 16277165 — tx `0xe2ad8d6d9830ad00e577a4a403bcb3efb5bccfe8dfc8ffe247e8622c774d1e12`
- PositionOpened — block 16277166 — tx `0xcfa564384134ca0317e5bee5153bde7df07f3d537cd59b7f8ff2b149136a5a75`
- PositionOpened — block 16277167 — tx `0xfd15e12abfeca0016be9abd7b57dd1ed809a20edc1c48080215b8ca47dd6e47e`
### Oracle 0x83401Fc1B16DbCa09531241Dad49700248C8c72c
- PriceReported — block 16277148 — tx `0x93216aeb5f34d423410591f8717d633d9d544df29986b762b21e342a4fa9bcc9`
- PriceReported — block 16277155 — tx `0x71e6e05faf30082580cc1ef84642f197cb19371b997f5d44ae818149a45a1704`
- PriceReported — block 16277160 — tx `0x94b7aae9b7340b9ae4cbf3f31b23edb5d8f5bea89c6998e4292309022dff425e`
- PriceReported — block 16277166 — tx `0xcfa564384134ca0317e5bee5153bde7df07f3d537cd59b7f8ff2b149136a5a75`
- PriceReported — block 16277192 — tx `0xd7f0ca4130d1bb562ffdcc3e5b8651cd082018839b4b91e05a23b95c7ae4f74a`
- PriceReported — block 16277221 — tx `0x2141fe454fc1658667f2ed3828d6f7912cb702ef0aba1aa580411bf9c41063b2`
- PriceReported — block 16277235 — tx `0x5867e2d4751e124ddc1f8c391390de6e9780fb10f5a7a30ac3283929024b1098`
- PriceReported — block 16277260 — tx `0x4a94e7dcfe253c1cf40887a6df4d007b69674e1bb4eec2a607442c687da84f80`
- PriceReported — block 16277285 — tx `0x64ba505ee2cd247e04c0fd05461811d21597718b26a49ddade2eaf8b18cec9dd`
- PriceReported — block 16277314 — tx `0x9b087bd4a7bd6f36e5262fbd836113c8fe1119f5af5ee8296288b73685d29015`
- PriceReported — block 16277343 — tx `0xe7047cf37d1061a77df0280739607fd6490253d922de27f2710aa2731a8a1e48`
- PriceReported — block 16277372 — tx `0x7bd844d3c15725e4a94851fb8b2a71440d8d922e4779d6e73a6a9a83d5f2f972`
- PriceReported — block 16277397 — tx `0xc91a1ea5fb23c02abdb9428e2367032c283aa86d288a024f6216392364748657`
- PriceReported — block 16277426 — tx `0x227e73890adda99ba23f08549d69a827356ded7042bebb00374aecaf6b230eb7`
- PriceReported — block 16277455 — tx `0x22e0defbd1f884084527a68b002b23fae01225e788b44a8b8c39b524763fac8c`
- PriceReported — block 16277540 — tx `0xc6d93c89be7d209474dd5a8d0251f86937898d0be9a77fa3364724fa0952faa5`

The v1 markets below are legacy (old ABI, token still named HRP on-chain).

Deployed 2026-10-21 (JST) from the user's disposable testnet address `0x715211CAdb65Cc184c955B283933A1F7021d00b0`
(key supplied via the `MEZO_TESTNET_PRIVATE_KEY` env var only; never written to disk or argv). Unaudited demo.

## v1 main market (legacy) — price = Skip Connect BTC/USD (`deployments/testnet-v1-skip.json`)

| Contract | Address |
|---|---|
| HouseExchange | `0x608757e82a847f04Ff6E8FeDCB18914c02e54a5c` |
| OracleAdapter (Skip `0x7b7c…0015`, 120 s staleness) | `0x53e834CDA15A7dDA36896f182B0feB4302DdF6f7` |
| RebateToken (HRP, non-transferable) | `0xBB96Fb1a7dC41427C286be13C36574DDa27f7cbe` |
| RebateStaking | `0x34C6316a83797C04e8c7003e293A03B65f596e8E` |
| MUSD | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` |

Pyth guard is configured (`0x2880…7B43`, BTC/USD feed) but only enforced when the Pyth update is < 60 s old; on
2026-10-21 the testnet Pyth BTC/USD price was ~85 days stale, so it is currently inactive.

## v1 crash-demo market (legacy) — price = MockOracle owned by the deployer (`deployments/testnet-demo.json`)

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
