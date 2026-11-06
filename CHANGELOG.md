# Changelog

All notable changes to Bustline, grouped by hackathon wave. Dates are JST. Tags mark the state of the repository at
each milestone; contract addresses are in [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md).

## [Unreleased]

Planned before the Wave 2 deadline (2026-11-15):

- Real-wallet runs of all three funding routes (Passport BTC wallet and an EVM wallet), from a non-deployer wallet.
- Redeploy of the contract fixes below (they are not on-chain yet; v3 on testnet still runs the 2026-11-06 code).
- Demo video recorded on v3.

### Fixed (in the repo, after an independent review of the Wave 2 contracts on 2026-11-06)

- `RebateStaking.claim()` no longer reverts when the staker cannot receive native BTC: MUSD is always paid, the BTC
  stays owed (`BtcClaimFailed`), and the new `claimBtcTo(address)` sends it to another address.
- `HouseExchange.sweepExcess()` no longer sweeps on-hand MUSD below `spMinLiquid` while the house has a Stability Pool
  deposit, so winners can still be paid if Stability Pool withdrawals are blocked.
- 5 regression tests added (85 unit/fuzz tests in total).

## [v3-wave2] — 2026-11-06 — Wave 2: Mezo-native integration on testnet

### Added

- **MUSD PriceFeed price bound** (`src/oracles/MezoPriceBound.sol`): Pyth and keeper-signed prices are checked against
  Mezo's own MUSD PriceFeed before fills and liquidations.
- **Stability Pool for idle house MUSD** (`HouseExchange` v3): the house deposits MUSD above a liquid floor into Mezo's
  Stability Pool and keeps enough liquid MUSD for payouts.
- **BTC rewards to MPAPER stakers** (`RebateStaking` v3): BTC collateral gains from the Stability Pool are forwarded to
  stakers.
- **TimelockController** (1 h delay) as owner of HouseExchange, both oracles, RebateToken and RebateStaking; separate
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

[Unreleased]: https://github.com/naoto13/Bustline/compare/v3-wave2...HEAD
[v3-wave2]: https://github.com/naoto13/Bustline/compare/v2-wave1...v3-wave2
[v2-wave1]: https://github.com/naoto13/Bustline/releases/tag/v2-wave1
