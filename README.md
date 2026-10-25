# Bustline

**A 100x BTC/USD perpetual on Mezo, margined in MUSD, where the house is funded only by trader losses.**

> **Testnet demo, unaudited.** Runs on Mezo testnet (chainId `31611`) only. Up to 100x leverage — losses can be total.

- **Live app:** https://bustline-c8p.pages.dev (Mezo testnet, connect with Mezo Passport)
- **Contracts & on-chain proof:** [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md)
- **Demo video:** _TBD_

![Bustline trade screen on Mezo testnet](docs/demo/frontend-testnet.png)

## What it is

Bustline is a single-market **BTC/USD synthetic perpetual**. There are no LP deposits: the counterparty is a **house that
starts at 0 MUSD** and grows only from trader losses.

- **Winners** are paid from the house. When the house can't pay, the remainder waits in a **FIFO payout queue** that
  later losses repay. Margin is always returned immediately; only profit can be queued.
- **Losers** receive a **non-transferable rebate token, Mezo Paper (`MPAPER`)**, that can be **staked for MUSD revenue
  share** (fees + house cash above a cap).
- **No funding, no spread.** Winning closes pay an asymmetric impact haircut + 2% win fee. Positions that cross their
  bust price are liquidated in full.

The result is a perp that can launch with zero liquidity and never pays out more than it holds: profit beyond house cash
is queued, so house equity (`houseCash − queueTotal`) may go negative while the contract stays fully backed — the invariant
`MUSD held == houseCash + open margin + escrow` is checked after every step in the fuzz/fork tests and the demo.

## Built for Mezo

| | |
|---|---|
| **MUSD everywhere** | Margin, house cash, queue payouts and staker revenue are all MUSD. Testnet MUSD was minted by opening a real MUSD Trove. |
| **Mezo Passport** | The frontend signs every write through Mezo Passport (BTC wallets such as Unisat / OKX / Xverse, plus EVM wallets). |
| **Pyth on Mezo, verified** | Mezo testnet's Pyth contract accepts **mainnet-signed BTC/USD updates** — proven with a real Base-mainnet update in `test/fork/PythFork.t.sol`. `PythPullOracle` is deployed and switch-ready. |
| **Skip Connect as a guard rail** | Every price must be within **±1% of Skip Connect BTC/USD**, Mezo's native oracle. |
| **Oracle-timing safety** | Mezo's Velar PerpDEX was drained via oracle-update timing ([post-mortem](https://mezo.org/blog/velars-perpdex-exploited-on-mezo/)). Bustline makes every open/close **2-step**, so no one can trade against a price they have already seen (below). |

## How a trade works

```text
trader                       HouseExchange                      keeper
  │ requestOpen / requestClose ─▶ escrow margin, record block time
  │                                                     fetch a price published AFTER the request
  │                              executeOrder(id, priceUpdate) ◀─┘  (price update rides in the same tx)
  │                              ├─ verify signature / Pyth proof, staleness ≤ 60 s, within ±1% of Skip
  │                              ├─ publishTime > request time, else revert NotYetFillable
  │ ◀── position opened / closed (profit paid or queued, loss → house + MPAPER minted)
```

- Orders not filled within 5 minutes become refundable. Slippage or OI-cap failures cancel and refund.
- `liquidate(id, priceUpdate)` is permissionless; the keeper calls it with a fresh price in the same tx.

## Mechanics

| | |
|---|---|
| Market | BTC/USD, isolated margin, `size = margin × leverage`, 1–100x, min margin 10 MUSD, max size + per-side OI caps |
| Wins | Deadband (exit measured `entry/50,000` worse) → `scale = (1−base)/(1 + 1/(move·rateMult) + refNotional/(1e6·move·posMult))` (BTC: base 10%, rateMult 15,000, refNotional $100k, posMult 814.598) → 2% win fee. ≈88% of raw gain kept at a 1% move, ≈74% at 0.1% |
| Losses | Lose up to the margin. 2% loss fee goes to stakers **only when the queue is empty and someone is staking**; otherwise 100% to the house |
| Liquidation | Hard bust: trigger = zero-equity price moved 5 bps toward entry; full margin forfeited; 0.5% of margin to the liquidator, 2% to stakers (queue empty). A close that lands past the trigger is treated as a bust |
| Payout queue | `harvest(n)` (anyone; auto-called on each loss) pays FIFO. New winners never jump the queue |
| MPAPER | Minted on realised loss (liquidations: full margin): 100 / MUSD while house equity < threshold, then `flat·(S/(S+H))²` with a ratcheting high-water-mark H. Non-transferable (the owner can enable transfers) |
| Staking | `stake / unstake / claim` MUSD (accumulator). Revenue: loss/win/liquidation fees + house cash above `houseCap` (`sweepExcess`) |

## Oracle

Settlement is keeper-driven, so the oracle is **pull-based**: the keeper submits a fresh price update inside the same tx
as `executeOrder` / `liquidate` (`msg.value` pays the update fee). `HouseExchange` only talks to `IPriceOracle`, and the
owner can switch sources with one `setOracle` tx.

| Source | Trust | Status |
|---|---|---|
| **Pyth pull** (`oracles/PythPullOracle`) — Mezo Pyth `updatePriceFeeds`, maxAge 60 s, conf ≤ 1%, Skip ±1% | Wormhole guardians; trustless w.r.t. the keeper | Deployed and verified on Mezo testnet. Going live only needs a Pyth Hermes API key (`PYTH_API_KEY`) and one `setOracle` call |
| **Keeper-signed** (`oracles/SignedPriceOracle`) — EIP-191 report `(chainid, oracle, price, publishTime)`; newer than stored, ≤ 10 s in the future, maxAge 60 s, within 1% of Skip | Trusts the signer inside the ±1% Skip band, and for liveness | **Active on testnet.** Price = median of Coinbase / Kraken / Bitstamp spot (≥ 2 sources, ≤ 0.5% spread) |

If Skip itself is stale (> 300 s) the ±1% bound is skipped, so a Skip outage can't freeze the market; the primary
oracle's own staleness check still applies.

## Repository layout

| Path | What |
|---|---|
| `src/` | `HouseExchange`, `RebateToken` (MPAPER), `RebateStaking`, `libraries/ImpactLib`, `oracles/` (Pyth pull, signed, Skip bound), mocks |
| `test/` | Unit + fuzz (`HouseExchange.t.sol`, `Oracles.t.sol`); fork suites against real testnet MUSD and real Mezo Pyth with a mainnet-signed update (`test/fork/`) |
| `script/` | `DeployLocal` (anvil), `DeployTestnet` (`ORACLE_MODE=signed\|pyth`), `DeployTestnetDemo` (mock-oracle crash-demo market) |
| `scripts/` | `dev-fork.sh` (anvil fork + deploy), `demo.sh` (crash/volatility demo), `export-abi.sh`, `list-events.py` |
| `keeper/` | Python keeper (fills, liquidations, queue harvest, optional Telegram alerts) + testnet operator CLI |
| `frontend/` | Next.js 14 + Mezo Passport: trade screen with bust lines, positions, house & payout queue, MPAPER staking |
| `docs/` | [`DEPLOYMENTS.md`](docs/DEPLOYMENTS.md) (addresses + on-chain events), [`OPERATIONS.md`](docs/OPERATIONS.md) (deploy & run), `demo/` (recorded outputs) |

## Run it

Requires [Foundry](https://book.getfoundry.sh/), Python 3 and Node 18+.

```bash
git clone --recurse-submodules https://github.com/naoto13/mezo-paperperp.git && cd mezo-paperperp

forge test                                                  # unit + fuzz (fork suites auto-skip)
MEZO_FORK_URL=https://rpc.test.mezo.org forge test --match-path 'test/fork/*'   # against real Mezo testnet state (read-only)

./scripts/dev-fork.sh                                       # anvil fork of Mezo testnet + deploy (unlocked anvil accounts, no keys)
./scripts/demo.sh                                           # crash/volatility demo → docs/demo/crash-demo-output.txt
(cd keeper && python3 -m unittest discover -s tests)        # keeper tests
(cd keeper && python3 -m perp_keeper --execute-local --simulate-oracle)   # keeper loop on the local fork
(cd frontend && npm ci --legacy-peer-deps && npm run build && npm start)  # http://localhost:3100
```

The crash demo walks through the whole lifecycle — empty house → winner queued → 100x and 20x longs busted by a −6% move
→ their margin repays the queue → MPAPER staked and transfer rejected. Output:
[`docs/demo/crash-demo-output.txt`](docs/demo/crash-demo-output.txt).

Testnet deployment and keeper operation: [`docs/OPERATIONS.md`](docs/OPERATIONS.md).

## Security & limitations

- **Unaudited hackathon build.** Single market, isolated margin, no partial closes, no session keys or relayer.
- **Admin powers.** The owner can switch the oracle, whitelist keepers, change risk/fee/impact/mint-curve parameters,
  rotate the price signer and enable MPAPER transfers. On testnet the owner is a single EOA; production would need a
  multisig + timelock.
- The live testnet market uses the keeper-signed oracle until a Pyth Hermes API key is configured; the Pyth path is
  deployed and tested.
- The keeper set is permissioned (owner whitelist) so traders can't time their own fills; expired orders are refundable.
- Skip on Mezo testnet returns `answeredInRound = 0`, so the Skip adapter relies on `updatedAt` freshness only.
- Anvil can't execute Mezo's Skip precompile, so local/fork runs use `MockOracle`; MUSD is the real bytecode.
- Impact-haircut and mint-curve parameters start from published defaults of the reference designs below and are not
  yet tuned for Mezo.

## Credits

Bustline is an independent implementation built on [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
and [forge-std](https://github.com/foundry-rs/forge-std). The mechanism design draws on public documentation:
[Papertrade](https://docs.papertrade.xyz/) (asymmetric impact PnL, solvency & payout queue, mint curve — the name
"Mezo Paper" is a nod to it), Rollbit's market-impact PnL model, and Mezo's Velar PerpDEX post-mortem.
Not affiliated with any of them.

## License

[MIT](LICENSE). Testnet demo — use at your own risk.
