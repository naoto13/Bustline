# Changelog

All notable changes to Bustline, grouped by hackathon wave. Dates are JST. Tags mark the state of the repository at
each milestone; contract addresses are in [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md).

## [Unreleased]

### Added

- First v3.1 trades (2026-11-07) from two scripted test wallets funded by the deployer: all three funding routes
  ("Start with BTC", "From my trove", "Deposit MUSD"), a loss that funded the house, an MPAPER stake, and two wins paid
  in full with the 1% protocol fee to the treasury and the 2% win fee to the staker. Txs in
  [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md#v31-test-wallet-trades-2026-11-07).

Still to do before the Wave 2 deadline (2026-11-15):

- Trades by outside users, and a run of the funding routes through the UI with a Passport BTC wallet.
- First Stability Pool deposit (needs house cash above 50 MUSD).
- Switch the active oracle to the Pyth pull oracle (needs a Pyth Hermes API key and one timelock operation).
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
