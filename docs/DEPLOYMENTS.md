# Deployments — Mezo testnet (chainId 31611)

RPC `https://rpc.test.mezo.org` · Explorer `https://explorer.test.mezo.org` · Frontend https://bustline-c8p.pages.dev

All contracts were deployed from a dedicated testnet-only address, `0x715211CAdb65Cc184c955B283933A1F7021d00b0`, which
also runs the keeper, signs prices and opened the test positions below. Unaudited demo.

## Current market (v2) — `deployments/testnet.json`

Deployed 2026-10-21. Pyth-ready oracle design; the keeper-signed oracle is active.

| Contract | Address | Deploy tx |
|---|---|---|
| HouseExchange | `0x5e941EEA56DEE50924950E86f24624Be37f02050` | `0xbed9fb1030558f6cc13049ab0dd89c55d4162d515e57204a1426fc82861d4976` |
| SignedPriceOracle (**active**; maxAge 60 s, Skip ±1%) | `0x83401Fc1B16DbCa09531241Dad49700248C8c72c` | `0x177eb45bd3fda1d1d39080c51b0c0457fbdc5a45626438475f22315845c82741` |
| PythPullOracle (switch-ready; BTC/USD feed `0xe62d…5b43`, maxAge 60 s, Skip ±1%) | `0xA1E556D9e659fC879D3c37Bd2490D3274B6c20bB` | `0x59fec8279b3e069e21fd1231dad8cfe5a56a2fe225106fd75884b5bcf8ddbe25` |
| RebateToken — Mezo Paper (`MPAPER`), non-transferable | `0x07F9bd344916571321f494aE00eDD30ac1dE89Bd` | `0x7a24bb5d34ee07f3410c6327be51a6c18a992dd97984ab1204df87e61c07c5cf` |
| RebateStaking | `0x8c76076af61489D8fdc10F6DbA7a9aeC52879fD8` | `0x51095becb892713c48045a5c1aadc0ee4db3254f787ea6f0d0b04816fe8e06cc` |
| MUSD (Mezo) | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` | — |

### Why the signed oracle is active

Mezo testnet Pyth **accepts mainnet-signed (stable) BTC/USD updates**. This was verified with a real Base-mainnet update
(`parsePriceFeedUpdates` via `eth_call`, fee 10 wei) and in `test/fork/PythFork.t.sol` (accept, fill-in-same-tx and
liquidation-with-update on the real Mezo Pyth bytecode). Pyth Hermes, however, requires an API key since 2026-08.
Once `PYTH_API_KEY` is set, switching is one tx — `HouseExchange.setOracle(0xA1E5…20bB)` plus `"oracleMode": "pyth"` in
the deployment file — and the keeper uses Hermes automatically.

Trust model of the signed oracle: the keeper signs `(chainid, oracle, price, publishTime)` (EIP-191). The contract
rejects bad signatures, reports more than 10 s in the future, reports older than the stored one, prices older than 60 s
and prices more than 1% away from Skip Connect. Off-chain price = median of Coinbase / Kraken / Bitstamp spot.

### On-chain proof

Every fill and liquidation below carries its own signed price update in the same tx.

| Step | Tx |
|---|---|
| Long 100 MUSD × 10x requested | `0xa16d1eb08f355e1b11028794a9b3d1cc78bff65d8e738005e6ba026d8d84b965` |
| → filled by the keeper at a later price (PriceReported + PositionOpened) | `0x71e6e05faf30082580cc1ef84642f197cb19371b997f5d44ae818149a45a1704` |
| Close requested | `0x34770da66c81e2a4e280f8a8a4df3f5b0a8f332f41c922462749e6ffe3c81244` |
| → closed at a loss; 32.49 MPAPER minted (PositionClosed + RebateMinted) | `0x94b7aae9b7340b9ae4cbf3f31b23edb5d8f5bea89c6998e4292309022dff425e` |
| Long 10 MUSD × 100x and short 10 MUSD × 100x opened at ≈ $83,032 | `0xcfa564384134ca0317e5bee5153bde7df07f3d537cd59b7f8ff2b149136a5a75`, `0xfd15e12abfeca0016be9abd7b57dd1ed809a20edc1c48080215b8ca47dd6e47e` |
| **Live liquidation** of a test position opened by the deployer account — BTC fell to $80,638 on 2026-10-26 02:38 JST (within Coinbase's BTC-USD 1-minute candle for 17:37 UTC, $80,630–$80,648); the keeper liquidated the 100x long (position #1): 10 MUSD margin forfeited, 0.05 MUSD keeper reward, 1,000 MPAPER minted to the trader. The price came from the regular signed feed; nothing was pushed by hand | `0xfa67811e9766c14ee3971656b8387a9bf3f7c0964280789a921a3bc265b06a3c` |

The keeper has kept pushing signed prices since deployment (54 `PriceReported` events as of 2026-10-26). Regenerate the
full event list with:

```bash
forge build && python3 scripts/list-events.py deployments/testnet.json 16277100
```

## MUSD source

Testnet MUSD came from a real MUSD Trove: 0.045 BTC collateral, 1,800 MUSD net debt (≈ 2,001.8 total including the 0.1%
fee and 200 MUSD gas compensation) — tx `0x4a8dea67ba30961e7601d237cc9c14dc5b3d43debfe8c2f365e32664c82d9fb2`.

## Earlier markets (v1, legacy)

Deployed 2026-10-21 with the first ABI; the rebate token was still named HRP on-chain. Kept for the record.

**Skip market** (`deployments/testnet-v1-skip.json`) — price = Skip Connect BTC/USD, 120 s staleness.

| Contract | Address |
|---|---|
| HouseExchange | `0x608757e82a847f04Ff6E8FeDCB18914c02e54a5c` |
| OracleAdapter (Skip) | `0x53e834CDA15A7dDA36896f182B0feB4302DdF6f7` |
| RebateToken (HRP) | `0xBB96Fb1a7dC41427C286be13C36574DDa27f7cbe` |
| RebateStaking | `0x34C6316a83797C04e8c7003e293A03B65f596e8E` |

Long 300×50 and short 300×50 were filled at a later Skip update; the winning long closed into an empty house →
**Queued** (`0xdb820c0729cc0a9479c41b6a3e786d1ea227e78fcedeb5dfe99f401d39b05dc9`); the losing short's close →
**QueuePaid + RebateMinted** (`0xb12bba2f6c5596bc8a68ac8c64557c5d9bc92490a652b202acb933b18e0b9193`).

**Crash-demo market** (`deployments/testnet-demo.json`) — clearly labelled demo market whose price is a `MockOracle`
owned by the deployer, so liquidations and queue repayment can be shown on demand.

| Contract | Address |
|---|---|
| HouseExchange (DEMO) | `0xF5890Acbe962Eee3F9bB5FB18E535bcac7B0b1bE` |
| MockOracle | `0x68CF665f532345dDbD1002d2d66458A1D3fb29cD` |
| RebateToken (HRP-DEMO) | `0xD5a5D06EcFeF29959785D0f934FF17aD3aBC6e6e` |
| RebateStaking | `0x5890b192f8f1952E402D34A524b51044B13406a9` |

Sequence: long 200×20, short 100×100, short 100×10 → +0.5% close of the long → **Queued**
(`0xcb9d7aad22f8d49d0ce524cc07fef175c64fc6130bb2396b028fb1c8388bfee9`) → +1.5% → keeper **Liquidated** the 100x short,
**QueuePaid** (`0xd78fcc7a3446dcf14dcd277675edd7a35762f04be9e545ed9b1ebc6575567334`) → rebate staked → losing close with
the queue empty → 2% fee → **StakerRevenue** (`0x2aec6496e3e927506c43bf87de52f5a993028f4c40a7663de75b244524b77c10`).
