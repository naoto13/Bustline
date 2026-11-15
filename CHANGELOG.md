# Changelog

All notable changes to Bustline, grouped by hackathon wave. Dates are JST. Tags mark the state of the repository at
each milestone; contract addresses are in [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md).

## [Unreleased]

### Added

- First v3.1 trades (2026-11-07) from two scripted test wallets funded by the deployer: all three funding routes
  ("Start with BTC", "From my trove", "Deposit MUSD"), a loss that funded the house, an MPAPER stake, and two wins paid
  in full with the 1% protocol fee to the treasury and the 2% win fee to the staker. Txs in
  [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md#v31-test-wallet-trades-2026-11-07).
- First Stability Pool deposit (2026-11-10): the floor was lowered to 0.25 MUSD through the timelock (testnet only,
  op C in [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md#v31-timelock-operations)), and the keeper deposited 0.2785 MUSD.

- Proof page at `/proof`: all 48 v3.1 transactions (deploy broadcast, timelock operations, every test-wallet
  transaction, all order fills, the first Stability Pool deposit), each labelled by the wallet that sent it, plus a
  Limits box (testnet only, no external audit, 0 outside users) and live house figures.
- UI runs (2026-11-10): all three funding routes clicked through the live app with team test wallets connected as an
  injected EVM wallet (connect → fund → open → fill → close); wallet C was funded from the Mezo testnet faucet. Mezo
  Passport's BTC accounts are not tested yet.
- "First trade" guide on the trade screen (Wave 1 build goal): six steps for newcomers to MUSD (connect, testnet BTC,
  MUSD margin, a 20 MUSD × 5x preset with the bust price in words, the keeper fill, the close), each ticked off from
  live reads of the address; dismissible, reopened with "Start here" in the header. Docs section "Your first trade".
- Trove funding panel shows where the trove sits in Mezo's redemption order (lowest ICR is redeemed first); Docs
  section "Redemptions & recovery mode".
- Keeper Worker: Pyth pull support. Every tick it reads the exchange's on-chain `oracle()` and picks the price source:
  the SignedPriceOracle → keeper-signed report (unchanged), the PythPullOracle → a BTC/USD update from Pyth Hermes
  (API key `PYTH_API_KEY`, response validated as untrusted, update fee read from `updateFee` and capped at 10,000 wei),
  anything else → no price-carrying transaction and an error. Switching or rolling back the oracle on-chain needs no
  Worker redeploy. `/health` shows the live and last-run oracle and mode.
- Tests: 34 keeper Worker tests (22 unit + 12 offline integration tests that run the scheduled handler and `/health`
  with stubbed `fetch` and decode the transactions it would send), and the fork suite `test/fork/OracleSwitchFork.t.sol`
  (10 tests, 5 of them need a live Hermes update in `PYTH_UPDATE_HEX`) that runs the exact timelock calldata against
  the deployed v3.1 contracts, then a push, a fill and a liquidation with a Pyth update.
- Settlement oracle switched from the keeper-signed oracle to the Pyth pull oracle on 2026-11-15 (timelock op D,
  `HouseExchange v3.1.setOracle(PythPullOracle v3.1)`, executed 19:57 JST, tx `0x7edaae6d9d512356dd1e6d11a633b92d11d671831513316ed41ebb51545da732`;
  details in [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md#v31-timelock-operations)). Trades before the switch were
  settled on the keeper-signed oracle, which stays deployed as the rollback target. `deployments/testnet-v3.1.json`
  now has `"Oracle"` = PythPullOracle and `"oracleMode": "pyth"`.
- First Pyth-settled trades (2026-11-15): 10 round trips from test wallet A (positions #6–#15, long and short,
  2x to 100x), each opened and closed by the keeper with a Pyth Hermes BTC/USD update. Four wins paid at once with both
  fees, one win with nothing left after the impact haircut, five losses that minted MPAPER; nothing queued, no
  liquidation. Txs in [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md#v31-pyth-settled-round-trips-2026-11-15) and on `/proof`.
- Layout regression test `pnpm e2e:layout` (`frontend/e2e/layout.cjs`, headless Chrome via playwright-core against a
  running app): widths 1440, 1280, 1046, 1000 and 430 plus three window resizes, checking for overlaps and clipped
  header stats.

### Fixed

- Keeper Worker KV writes (2026-11-15): a run with only errors used to write state every minute, so a lasting error
  (unknown oracle, missing `PYTH_API_KEY`, Hermes outage) could reach 1,440 writes/day, above the Workers Free 1,000/day,
  and a failed `put` then lost the cursor. Now fills, liquidations, harvest, Stability Pool operations, cursor moves and
  pause changes still write every time; error-only runs write only when the kind of error changed and the last write is
  at least 300 s old, and a failed `put` is logged without failing the run. Measured over a simulated day: 145
  writes/day with a lasting error, 289 in the worst case. Keeper Worker tests: 50 (31 unit incl. 9 for the write
  rule, 19 integration incl. 7 multi-run). Totals: 103 unit/fuzz, 56 fork, 50 keeper Worker, 23 Python keeper.
- Trade screen layout: at window widths of 901–1090px the bottom tabs (Positions / Pending / Activity / Status)
  overlapped the chart's time axis and the Open Positions bar, because the fixed-height chart SVG stretched the grid
  row past the trading area; the row height now follows the trading area. The header stats now wrap, so ORACLE,
  PUBLISHED and LIVE/STALE stay visible below ~1260px (on phones the stats move to a full-width row under the price).

Still to do before the Wave 2 deadline (2026-11-15):

- Trades by outside users, and a run of the funding routes through the UI with a Passport BTC wallet.
- Demo video recorded on v3.1.

## [v3.1-wave2] — 2026-11-07 — Emergency pause, protocol revenue, review fixes

v3.1 deployed on Mezo testnet on 2026-11-07 (`deployments/testnet-v3.1.json`, addresses in
[`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md#v31-wave-2-current--deploymentstestnet-v31json)). Everything below is
on-chain in v3.1 and live on the keeper Worker and https://bustline.planz.workers.dev.

### Added

- **Emergency pause** (`HouseExchange` v3.1): a `guardian` (or the owner) can `pause()` at once; only the owner (the
  timelock) can `unpause()`, so resuming always waits the 1-hour delay. While paused, opens, fills, liquidations,
  sweeps and Stability Pool deposits stop; close requests, refunds, queue harvest, pool withdrawals, price pushes and
  staking keep working.
- **Protocol fee**: 1% of a winner's impact-adjusted gain (`protocolFeeBps` = 100, capped at 5%) goes to a `treasury`
  that funds the keeper's gas and price updates, on top of the 2% win fee to stakers. Taken only when the winner is paid
  in full on the spot.
- Frontend: house assets & fees panel (Stability Pool deposit, protocol fees), BTC rewards in the MPAPER tab, a
  "TRADING PAUSED" banner that disables opening, and Docs sections on fees and governance (guardian, timelock).
- Keeper Worker: reads `paused()` with each snapshot and, while paused, skips fills and liquidations but keeps price
  pushes, harvest and `rebalance` / `forwardBtc` (6 tests, `pnpm test`).
- In-app Docs page at `/docs` (how trades, funding routes, the house queue, MPAPER, oracles and governance work, plus
  live contract addresses); the header "Docs" link now opens it instead of GitHub. Header badge shows only TESTNET.
- Tests: 103 unit/fuzz (incl. `test/PauseAndProtocolFee.t.sol`), 46 fork (incl. the v3.1 deploy script and the fee on
  real MUSD), 6 keeper Worker, 23 Python keeper.

### Fixed (deployed in v3.1)

- From an independent review of the Wave 2 contracts on 2026-11-06:
  - `RebateStaking.claim()` no longer reverts when the staker cannot receive native BTC: MUSD is always paid, the BTC
    stays owed (`BtcClaimFailed`), and the new `claimBtcTo(address)` sends it to another address.
  - `HouseExchange.sweepExcess()` no longer sweeps on-hand MUSD below `spMinLiquid` while the house has a Stability
    Pool deposit, so winners can still be paid if Stability Pool withdrawals are blocked.
- From the 2026-11-07 review: a winner who cannot be paid in full on the spot is no longer charged any fee. The whole
  gain is owed; what the house can pay now is paid and the rest is queued (before, only the after-fee amount was queued
  and the difference silently stayed in the house; the v3 win fee had the same issue).
- Also from the 2026-11-07 review: the treasury can no longer be the exchange itself, and the v3.1 deploy script
  refuses a timelock delay below 1 hour.

### Changed

- v3.1 deployed on Mezo testnet (2026-11-07) as a fresh set with a new TimelockController and a new RebateToken; all
  six contracts verified on the explorer. Guardian and treasury are the deployer address.
- Stability Pool enabled on v3.1 through the timelock (`setSpParams`, executed 2026-11-07, tx
  `0x50eb35942b1941733ee03537563fa49bc62a642875a9e2784822205d4df604cd`).
- Keeper Worker and production frontend switched from v3 to v3.1. v3 (2026-11-06) is retired; no trade ever happened on
  it.

## [v3-wave2] — 2026-11-06 — Wave 2: Mezo-native integration on testnet

### Added

- **MUSD PriceFeed price bound** (`src/oracles/MezoPriceBound.sol`): Pyth and keeper-signed prices are checked against
  Mezo's own MUSD PriceFeed before fills and liquidations.
- **Stability Pool for idle house MUSD** (`HouseExchange` v3): the house deposits MUSD above a liquid floor into Mezo's
  Stability Pool and keeps enough liquid MUSD for payouts.
- **BTC rewards to MPAPER stakers** (`RebateStaking` v3): BTC collateral gains from the Stability Pool are forwarded to
  stakers.
- **TimelockController** (1 h delay) as owner of HouseExchange, both oracles and RebateToken (RebateStaking has no owner); separate
  owner / keeper / price-signer keys.
- **Trove funding routes** in the frontend (`components/Funding.tsx`, `lib/mezo.ts`): "Start with BTC" (open a trove,
  borrow MUSD, open a position in one flow), "From my trove", and "Deposit MUSD"; hints via HintHelpers/SortedTroves;
  ICR, two liquidation lines, minimum debt, gas compensation, fees.
- Fork tests against Mezo testnet primitives (`test/fork/MezoPrimitivesFork.t.sol`, `WaveTwoFork.t.sol`) and timelock
  tests. Totals: 80 unit/fuzz, 44 fork, 23 keeper.

### Changed

- v3 deployed on Mezo testnet with a new RebateToken; all contracts verified on the Mezo explorer.
- Stability Pool enabled through a timelock operation (schedule → execute after 1 h).
- Keeper Cloudflare Worker and the frontend moved to `https://bustline.planz.workers.dev` (Workers static assets).
- The keeper Worker now refuses to run when contract addresses are missing instead of falling back to v2.
- Package manager migrated to pnpm.

### Deprecated

- v2 contracts are frozen: the v2 deployer key was lost, so v2 MPAPER balances and open v2 positions were not
  migrated.

## [v2-wave1] — 2026-10-26 — Wave 1 submission

### Added

- Core exchange: 2-step fills, hard-bust liquidation at 100x, FIFO payout queue, impact haircut.
- Mezo Paper (MPAPER) rebate token and staking.
- Oracles: Pyth pull (primary), keeper-signed fallback, Skip deviation bound.
- Python keeper and its Cloudflare Worker port (cron every minute, 15 s ticks).
- Next.js + Mezo Passport frontend: trade screen with bust lines, positions, house and payout queue, MPAPER staking.
- Testnet deployment (v1 Skip market, v2 signed-oracle market, crash-demo market) and a live liquidation.
- Unit/fuzz and fork tests against real Mezo testnet MUSD.

[Unreleased]: https://github.com/naoto13/Bustline/compare/v3.1-wave2...HEAD
[v3.1-wave2]: https://github.com/naoto13/Bustline/compare/v3-wave2...v3.1-wave2
[v3-wave2]: https://github.com/naoto13/Bustline/compare/v2-wave1...v3-wave2
[v2-wave1]: https://github.com/naoto13/Bustline/releases/tag/v2-wave1
