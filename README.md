# Bustline — BTC/USD perp on Mezo (repo `mezo-perp`) — Buildathon MVP

> **TESTNET DEMO / UNAUDITED.** Mezo testnet (chainId `31611`) only. Up to 100x leverage — losses can be total.
> Private repo until publication is approved.

**Bustline** is a single-market **BTC/USD synthetic perpetual** margined in **MUSD**. The counterparty is a **house that starts at 0 MUSD
and is funded only by trader losses** (no external LP deposits). Winners are paid from the house; when it can't pay,
the remainder waits in a **FIFO payout queue** that later losses repay. Every realised loss mints a **non-transferable
rebate token** that can be **staked for MUSD revenue share**. No funding, no spread; winning closes pay an asymmetric
impact haircut + 2% win fee.

Plan / progress: [bot_list#684](https://github.com/naoto13/bot_list/issues/684) (fallback: levBTC, #601).

## Why it fits Mezo
- **MUSD everywhere**: margin, house cash, queue payouts and staker revenue are all MUSD (demo MUSD was minted by opening a
  real MUSD Trove on testnet).
- **Pyth BTC/USD (mainnet "stable" feed) as the primary price**, pulled by the keeper and verified on-chain by Mezo's
  Pyth contract; **Skip Connect BTC/USD** (Mezo's native oracle) as a ±1% sanity bound. See [Oracle](#oracle).
- **Oracle-timing safety first** — Mezo's Velar perp was drained via oracle-update timing (see Mezo's post-mortem). Here
  every open/close is **2-step**: the request escrows margin, and a keeper fills it only at a price **published strictly
  later** than the request block (Pyth `publishTime` / signed-report time), within a 5-minute window (otherwise refundable). Keepers can't pick a stale price and
  traders can't trade against a price they already saw.

## Mechanics
| | |
|---|---|
| Market | BTC/USD, isolated margin, `size = margin × leverage`, 1–100x (param), min margin 10 MUSD, max size + per-side OI caps |
| Fills | `requestOpen / requestClose` → keeper `executeOrder` at a later oracle update; slippage / OI-cap failures cancel + refund |
| Wins | deadband (exit measured `entry/50,000` worse) → `scale = (1−base)/(1 + 1/(move·rateMult) + refNotional/(1e6·move·posMult))` (BTC: base 10%, rateMult 15,000, refNotional $100k, posMult 814.598) → 2% win fee. ≈88% of raw gain kept at a 1% move, ≈74% at 0.1% |
| Losses | lose up to the margin; 2% loss fee to stakers **only when the queue is empty and someone is staking** (otherwise 100% to the house) |
| Liquidation | hard bust: trigger = zero-equity price moved 5 bps toward entry; full margin forfeited; 0.5% of margin to the liquidator, 2% to stakers (queue empty) — permissionless `liquidate()`; a close that lands past the trigger is treated as a bust |
| House & queue | `houseEquity = houseCash − queueTotal` (may go negative by design). Margin is always returned immediately; only profit can be queued. `harvest(n)` (anyone; auto-called on each loss) pays FIFO. New winners never jump the queue |
| Rebate token | minted on realised loss (liquidations: full margin): 100 tokens / MUSD while house equity < threshold, then `flat·(S/(S+H))²` with a ratcheting high-water-mark H. Non-transferable flag (owner can enable). Name **Mezo Paper** (`MPAPER`) — a nod to Papertrade, whose public docs inspired the mechanism |
| Staking | `stake / unstake / claim` MUSD (accumulator). Revenue: loss/win/liq fees + house cash above `houseCap` (`sweepExcess`) |

Invariant (checked after every step in fuzz/fork tests and demo): `MUSD held == houseCash + open margin + escrow`.

## Oracle
Settlement (fills + liquidations) is driven by the keeper, so the oracle is **pull-based**: the keeper fetches a fresh
price update and submits it **inside the same tx** as `executeOrder(id, priceUpdate)` / `liquidate(id, priceUpdate)`
(`msg.value` pays the update fee). `HouseExchange` only talks to `IPriceOracle` (`update / latest / peek / updateFee`),
and the owner can switch sources with one `setOracle` tx.

| Source | Contract | Trust | Status (2026-10-21) |
|---|---|---|---|
| **Pyth pull (primary)** | `oracles/PythPullOracle` → Mezo Pyth `0x2880…7B43` `updatePriceFeeds` + read, maxAge 60 s, conf ≤ 1%, Skip ±1% | Wormhole guardians (trustless w.r.t. keeper) | Verified: Mezo **testnet** Pyth uses the same guardian set + Pythnet emitter as Base mainnet and **accepts mainnet-signed (stable) BTC/USD updates** (eth_call + `test/fork/PythFork.t.sol` with a real update). Live use needs a Hermes API key (Hermes requires `Authorization: Bearer` since 2026-08) → set `PYTH_API_KEY`, deploy with `ORACLE_MODE=pyth` or `setOracle(PythPullOracle)` |
| **Keeper-signed (fallback, live)** | `oracles/SignedPriceOracle`: ECDSA (EIP-191) report `(chainid, oracle, price, publishTime)` from an authorized signer; newer-than-stored, ≤ 10 s in the future, maxAge 60 s, **within 1% of Skip** | **Trusts the signer** for prices inside the ±1% Skip band and for liveness | Live on testnet; price = median of Coinbase / Kraken / Bitstamp spot (≥ 2 sources, ≤ 0.5% spread) |
| Skip only | `OracleAdapter` (no `answeredInRound` check — Skip returns 0) | Mezo validators | legacy v1 market |

2-step rule: `executeOrder` reverts `NotYetFillable` unless the oracle's `publishTime > order.createdAt`, so neither the
trader nor the keeper can fill at a price that was already public when the order was placed. The Skip bound is skipped
if Skip itself is stale (> 300 s), so a Skip outage can't freeze the market; the primary's own staleness check still applies.

## Repo layout
| Path | What |
|---|---|
| `src/` | `HouseExchange`, `RebateToken`, `RebateStaking`, `libraries/ImpactLib`, `oracles/` (Pyth pull, signed fallback, Skip bound), `OracleAdapter` (Skip), mocks |
| `test/` | unit + fuzz (`HouseExchange.t.sol`, `Oracles.t.sol`), fork suites on real testnet MUSD + real Mezo Pyth with a real mainnet-signed update (`test/fork/`, fixture in `test/fixtures/`) |
| `script/` | `DeployLocal` (anvil), `DeployTestnet` (Pyth + signed oracles, `ORACLE_MODE=signed|pyth`), `DeployTestnetDemo` (MockOracle crash-demo market) |
| `scripts/` | `dev-fork.sh` (anvil fork + deploy), `demo.sh` (crash/volatility demo), `export-abi.sh` |
| `keeper/` | Python keeper (fills, liquidations, harvest; Telegram dry-run) + testnet operator CLI |
| `frontend/` | Next.js 14 + Mezo Passport: trade panel, positions + liquidation price, rebate stake/claim, queue position |
| `docs/` | `testnet-deployment.md` (addresses + on-chain events), `TESTNET-DEPLOY.md`, demo recordings |

## Quick start (local, no keys)
```bash
forge test                                                   # unit + fuzz (fork suite auto-skips)
MEZO_FORK_URL=https://rpc.test.mezo.org forge test --match-path 'test/fork/*'   # same suite on real MUSD (read-only fork)
./scripts/dev-fork.sh                                        # anvil fork of rpc.test.mezo.org + deploy (unlocked anvil accounts)
./scripts/demo.sh                                            # crash demo → docs/demo/crash-demo-output.txt
(cd keeper && python3 -m unittest discover -s tests && python3 -m perp_keeper --status)
(cd keeper && python3 -m perp_keeper --execute-local --simulate-oracle)   # keeper loop on anvil
(cd frontend && npm i --legacy-peer-deps && npm run build && npm start)  # http://localhost:3100
```
Testnet: see [`docs/TESTNET-DEPLOY.md`](docs/TESTNET-DEPLOY.md) and [`docs/testnet-deployment.md`](docs/testnet-deployment.md).

## Known limitations
- Unaudited, written in days. Single market, isolated margin, no partial closes, no session keys / relayer.
- Keeper set is permissioned (owner-whitelisted) so traders can't time their own fills; expired orders are refundable.
- Live testnet market runs on the keeper-signed fallback until a Hermes API key is configured (see [Oracle](#oracle)).
- Skip on Mezo testnet returns `answeredInRound = 0`, so the adapter relies on `updatedAt` freshness only.
- The anvil fork can't execute Mezo's precompiles (Skip), so local/fork runs use `MockOracle`; MUSD is the real bytecode.
- Mint curve & haircut parameters are copied from public docs as a starting point, not tuned for Mezo.

## Credits / inspiration
Independent implementation — no third-party code. Mechanism ideas from public documentation:
Papertrade docs (asymmetric impact PnL, solvency & payout queue, mint curve, liquidations — https://docs.papertrade.xyz/),
Rollbit's market-impact PnL model, and Mezo's Velar PerpDEX exploit post-mortem
(https://mezo.org/blog/velars-perpdex-exploited-on-mezo/). Not affiliated with any of them.

## License
MIT (hackathon demo). Use at your own risk.
