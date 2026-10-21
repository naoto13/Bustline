# BTC House Perp on Mezo (`mezo-perp`) — Buildathon MVP

> **TESTNET DEMO / UNAUDITED.** Mezo testnet (chainId `31611`) only. Up to 100x leverage — losses can be total.
> Private repo until publication is approved.

A single-market **BTC/USD synthetic perpetual** margined in **MUSD**. The counterparty is a **house that starts at 0 MUSD
and is funded only by trader losses** (no external LP deposits). Winners are paid from the house; when it can't pay,
the remainder waits in a **FIFO payout queue** that later losses repay. Every realised loss mints a **non-transferable
rebate token** that can be **staked for MUSD revenue share**. No funding, no spread; winning closes pay an asymmetric
impact haircut + 2% win fee.

Plan / progress: [bot_list#684](https://github.com/naoto13/bot_list/issues/684) (fallback: levBTC, #601).

## Why it fits Mezo
- **MUSD everywhere**: margin, house cash, queue payouts and staker revenue are all MUSD (demo MUSD was minted by opening a
  real MUSD Trove on testnet).
- **Skip Connect BTC/USD** price (Mezo's native oracle), optional **Pyth** deviation guard.
- **Oracle-timing safety first** — Mezo's Velar perp was drained via oracle-update timing (see Mezo's post-mortem). Here
  every open/close is **2-step**: the request escrows margin, and a keeper fills it only at an oracle update **strictly
  later** than the request block, within a 5-minute window (otherwise refundable). Keepers can't pick a stale price and
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
| Rebate token | minted on realised loss (liquidations: full margin): 100 tokens / MUSD while house equity < threshold, then `flat·(S/(S+H))²` with a ratcheting high-water-mark H. Non-transferable flag (owner can enable). Placeholder name "House Rebate Point" (HRP), set at deploy |
| Staking | `stake / unstake / claim` MUSD (accumulator). Revenue: loss/win/liq fees + house cash above `houseCap` (`sweepExcess`) |

Invariant (checked after every step in fuzz/fork tests and demo): `MUSD held == houseCash + open margin + escrow`.

## Repo layout
| Path | What |
|---|---|
| `src/` | `HouseExchange`, `RebateToken`, `RebateStaking`, `libraries/ImpactLib`, `OracleAdapter` (Skip), mocks |
| `test/` | unit + fuzz (`HouseExchange.t.sol`), fork suite on real testnet MUSD (`test/fork/`) |
| `script/` | `DeployLocal` (anvil), `DeployTestnet` (Skip market), `DeployTestnetDemo` (MockOracle crash-demo market) |
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
