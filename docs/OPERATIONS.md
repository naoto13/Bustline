# Operations — testnet deploy, keeper and frontend

Mezo testnet only (chainId `31611`, `https://rpc.test.mezo.org`). Addresses of the current deployment are in
[`DEPLOYMENTS.md`](DEPLOYMENTS.md).

**Current state (2026-11-06).** v3 (`deployments/testnet-v3.json`) is the live market and the keeper Worker runs on
it. v2 (`deployments/testnet.json`) is frozen: its single owner/keeper/signer key was lost, so the v2 commands below
are kept for reference only. The production frontend (https://bustline.planz.workers.dev) reads v3.

**Key roles (v3).** Three different keys, all stored outside git (never committed, never printed):

| Key | Address | Holds | Where it is used |
|---|---|---|---|
| Deployer = timelock proposer / canceller | `0xcDf4…8a21` | No direct ownership (the `TimelockController` owns HouseExchange, both oracles and the RebateToken) | `DeployTestnetV3` broadcast and timelock `schedule` / `cancel`. Read only from `MEZO_TESTNET_PRIVATE_KEY` |
| Keeper | `0x8560…2a42` | `isKeeper` on HouseExchange v3, BTC for gas | Worker secret `KEEPER_PRIVATE_KEY` |
| Price signer | `0x0BFf…2AEe` | `signer` of SignedPriceOracle v3; sends no txs | Worker secret `PRICE_SIGNER_PRIVATE_KEY` |

Keys are read only from environment variables or Worker secrets — never passed on argv, never written to tracked
files. Every write requires an explicit confirm flag. Owner actions on v3 (risk params, oracle switch, keeper list,
`setSpParams`, MPAPER transfers) are timelock operations: `schedule` from the proposer, wait 1 hour, `execute` from any
account. See [`DEPLOYMENTS.md`](DEPLOYMENTS.md#timelock-operations).

## 1. Deploy contracts

v3 (current): see the [runbook](DEPLOYMENTS.md#runbook-as-executed) — `script/DeployTestnetV3.s.sol` with
`CONFIRM_TESTNET_DEPLOY=1`, `KEEPER=<addr>` and `PRICE_SIGNER=<addr>`.

v2 (frozen, for reference; `testnet_ops` reads `deployments/testnet.json` by default):

```bash
# derive the address and check the gas balance (prints the address only)
keeper/.venv/bin/python -m perp_keeper.testnet_ops status

# ORACLE_MODE=pyth once PYTH_API_KEY exists (both oracles are deployed either way; switch later with setOracle)
CONFIRM_TESTNET_DEPLOY=1 ORACLE_MODE=signed forge script script/DeployTestnet.s.sol --rpc-url https://rpc.test.mezo.org --broadcast --slow
# optional mock-oracle crash-demo market
CONFIRM_TESTNET_DEPLOY=1 forge script script/DeployTestnetDemo.s.sol --rpc-url https://rpc.test.mezo.org --broadcast --slow
```

Contract creation doesn't touch the Skip precompile, so forge's local simulation works for deploys.

## 2. Operator CLI (v2 only)

`perp_keeper.testnet_ops` uses `keeper/abi` (no v3 functions) and defaults to `--deployment deployments/testnet.json`
(frozen v2). Calls that read Skip can't go through forge/cast (forge's local simulation hits `EvmError NotActivated` on the
precompile, and cast only takes keys on argv), so a small Python signer is used instead.

```bash
cd keeper && python3 -m venv .venv && .venv/bin/pip install eth-account==0.13.4
OPS=".venv/bin/python -m perp_keeper.testnet_ops"
$OPS status
$OPS --confirm open-trove --coll-wei 45000000000000000 --debt 1800     # MUSD source (min net debt 1,800)
$OPS --confirm open long 100 50                                          # approve + requestOpen
$OPS --confirm push-price                                                # signed report (or Hermes update) → oracle
$OPS --confirm keeper-once                                               # fill / liquidate / harvest (price update in the same tx)
$OPS --confirm close 0
$OPS --confirm stake-all && $OPS --confirm claim
$OPS --deployment ../deployments/testnet-demo.json --confirm set-price 84000   # demo market only
```

## 3. Keeper

### Cloudflare Worker (live)

The testnet keeper runs as the Worker **`bustline-keeper`** (`keeper-worker/`,
health: https://bustline-keeper.planz.workers.dev/health), so the demo doesn't depend on a server. It is a
TypeScript + viem port of one Python keeper poll (`monitor.Keeper.poll_once` with the keeper-signed price source),
without Telegram.

| | |
|---|---|
| Trigger | Cron `* * * * *`; each run ticks every 15 s for ~46 s (4 ticks) (`TICK_SECONDS`, `RUN_SECONDS`) |
| Price | Median of Coinbase / Kraken / Bitstamp (≥ 2 sources, ≤ 50 bps spread), 8-dec WAD, signed EIP-191 over `keccak256(abi.encode(31611, oracle, price, publishTime))` exactly like `signer.py` / `abi.py`. One deliberate difference: publishTime = min(now, latest block time + 5 s), because testnet block time can lag wall clock by ~10 s and the oracle rejects reports > `maxSkew` (10 s) in the future |
| Per tick | Fill pending orders (only at a price published after the request), liquidate positions past their bust price, push the price (at least once per run, so the on-chain price is ≤ ~60 s old), harvest the payout queue |
| Pause (v3.1) | Reads `paused()` in the same batch as the snapshot (no extra subrequest). While paused it skips fills and liquidations, holds the order-scan cursor (orders requested during the pause are filled after unpause), and keeps price pushes, harvest and `rebalance` / `forwardBtc`. It logs `exchange PAUSED` / `exchange unpaused` once per change (state in KV, shown as `paused` in `/health`), not an error every tick. On v3 `paused()` reverts and is read as not paused |
| Txs | Sequential, one in flight, legacy EIP-155 tx, `pending` nonce (never reused within a run), gas = estimate × 1.3 + 20k, gasPrice = 2 × `eth_gasPrice` |
| Safety | Refuses any RPC host other than `rpc.test.mezo.org` and any chainId other than 31611 |
| Health | `GET /health` → live on-chain price + age, open positions, pending orders, and the last run summary (tx hashes, per-tick results) from KV. No secrets |

Configuration (`keeper-worker/wrangler.toml` `[vars]`): `EXCHANGE_ADDRESS` = HouseExchange v3, `ORACLE_ADDRESS` =
SignedPriceOracle v3 (both from `deployments/testnet-v3.json`; required — there is no built-in fallback, and the Worker
refuses to run if either is missing), `SP_OPS = "1"` (also call `rebalance()` / `forwardBtc()`, at most once per
`SP_INTERVAL_SECONDS`). Secrets: `KEEPER_PRIVATE_KEY` sends the txs, `PRICE_SIGNER_PRIVATE_KEY` signs the price reports
(two different keys). Redeployed on v3 2026-11-06.

Signature / calldata / raw-tx encoding is checked byte-for-byte against the Python keeper:
`node keeper-worker/test/sig.mjs` (public anvil key, never the keeper key) vs `perp_keeper.abi` + `eth_account`.

```bash
cd keeper-worker
pnpm install --frozen-lockfile                          # pnpm 10.16+ (packageManager pins pnpm@10.33.2)
pnpm check                                              # tsc --noEmit
pnpm test                                               # pause handling (node --test)
W="pnpm dlx --package node@22 --package wrangler@latest wrangler"   # wrangler needs Node >= 22
$W deploy
printenv KEEPER_KEY | $W secret put KEEPER_PRIVATE_KEY               # pipe only; never echo the key
printenv PRICE_SIGNER_KEY | $W secret put PRICE_SIGNER_PRIVATE_KEY   # a different key from the keeper
$W tail --format pretty                                               # watch ticks
curl -s https://bustline-keeper.planz.workers.dev/health
```

Run only **one** keeper per key, otherwise two processes race for nonces.

Workers Free limits:

- **50 subrequests per invocation.** RPC reads are JSON-RPC batched (one HTTP call per snapshot); the loop stops early
  at ~44 subrequests. A busy minute (several fills + liquidations, each waiting for a receipt) may finish fewer ticks;
  the next cron minute picks up the rest.
- **CPU 10 ms per invocation.** Network waits don't count; secp256k1 signing is the main cost. Watch `cpuTime` in
  Workers Observability; if runs get killed for CPU, move to Workers Paid.
- **KV 1,000 writes/day.** State and the `/health` run summary share one key, written every 10 minutes or whenever
  the order cursor moved or a fill, liquidation, harvest or error happened (~144 writes/day baseline), so the summary
  can be up to ~10 min old; the `live` block is always fresh.
- Cron trigger changes can take a few minutes to start firing after the first deploy.

### Python keeper (v2 only, not a fallback for v3)

The Python keeper has no v3 functions (`rebalance`, `forwardBtc`, Stability Pool views) and defaults to the frozen v2
deployment, whose key was lost. It is kept for local forks and reference; it is **not** a working fallback for the v3
market.

```bash
cd keeper
.venv/bin/python -m perp_keeper --rpc https://rpc.test.mezo.org --deployment ../deployments/testnet.json --execute-testnet --heartbeat 120
```

The price source follows `"oracleMode"` in the deployment file: `signed` → keeper-signed spot median, `pyth` → Hermes
(needs `PYTH_API_KEY`). Optional Telegram alerts read `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` from the environment.

## 4. Frontend

The frontend reads the gitignored `frontend/public/deployment.testnet.json` at runtime. The production site uses
a copy of `deployments/testnet-v3.json`.

Local, against a testnet deployment:

```bash
cp deployments/testnet-v3.json frontend/public/deployment.testnet.json
cd frontend && pnpm install --frozen-lockfile && NEXT_PUBLIC_MODE=testnet pnpm build && pnpm start   # writes are signed by Mezo Passport
```

Static build on Cloudflare Workers static assets (live at https://bustline.planz.workers.dev; the app is a single static page with no API
routes, so `output: "export"` works; Wrangler needs Node ≥ 22; `frontend/wrangler.jsonc` pins the Cloudflare account,
because wrangler otherwise reuses the account cached in `node_modules/.cache/wrangler`):

```bash
cd frontend
pnpm install --frozen-lockfile
cp ../deployments/testnet-v3.json public/deployment.testnet.json
STATIC_EXPORT=1 NEXT_PUBLIC_MODE=testnet NEXT_PUBLIC_RPC_URL=https://rpc.test.mezo.org pnpm exec next build
pnpm dlx --package node@22 --package wrangler@latest wrangler deploy
```

Package manager: both `frontend/` and `keeper-worker/` use **pnpm** (`packageManager` in each `package.json`; settings
in each `pnpm-workspace.yaml`):

- `minimumReleaseAge: 10080` — newly resolved versions must be at least 7 days old (supply-chain guard).
- frontend only: `autoInstallPeers: false` + `strictPeerDependencies: false` replace the old `npm ci --legacy-peer-deps`
  (otherwise pnpm pulls react-native and other unused peers of `@mezo-org/passport` into the tree); the wagmi pins that
  were npm `overrides` are now pnpm `overrides`; dependency build scripts stay blocked (`ignoredBuiltDependencies`,
  all have pure-JS fallbacks or are unused).

Read-only preview: `?viewAs=0x…` shows any address's trove, balances and the deposit routes without a wallet (every
write is refused). Used for screenshots of the "has a trove" / "no trove" states.

## 5. Emergency pause (v3.1)

HouseExchange v3.1 has an emergency stop. `pause()` can be called by the `guardian` or the owner and takes effect in
the same block. `unpause()` is owner-only, and the owner is the `TimelockController`, so resuming always goes through
schedule → 1-hour delay → execute. A guardian key alone can never undo a pause.

| While paused | |
|---|---|
| Reverts with `EnforcedPause` | `requestOpen`, `executeOrder` (all fills, including queued closes), `liquidate`, `sweepExcess` |
| Skipped | Stability Pool deposits (`rebalance` only withdraws or does nothing) |
| Still works | `requestClose` (filled after unpause), `cancelExpired` (refunds), `harvest`, pool withdrawals, `forwardBtc`, `pushPrice`, views, owner admin calls, RebateStaking `stake` / `unstake` / `claim` |

The frontend shows a "TRADING PAUSED" banner and disables opening; the keeper Worker stops filling and liquidating
on its own (section 3). Nothing else has to be changed to pause.

### Pause (guardian, immediate)

The guardian key is set at deploy (`GUARDIAN`, default = the deployer; never the keeper key). Keep keys off argv: use a
Foundry keystore (`cast wallet import`), which prompts for its password.

```bash
EX=<HouseExchange v3.1>   # deployments/testnet-v3.1.json
cast call $EX "paused()(bool)" --rpc-url https://rpc.test.mezo.org          # false
cast send $EX "pause()" --account <guardian-keystore> --rpc-url https://rpc.test.mezo.org
cast call $EX "paused()(bool)" --rpc-url https://rpc.test.mezo.org          # true
```

Then check the keeper: `curl -s https://bustline-keeper.planz.workers.dev/health` shows `"paused": true`.

### Resume (timelock: schedule → wait → execute)

`unpause()` has selector `0x3f4ba83a` (`cast sig "unpause()"`) and no arguments, so the payload is just the selector.
Use a **fresh salt** every time: a timelock operation id is `hash(target, value, data, predecessor, salt)`, so reusing the
salt of an earlier unpause would give an id that is already done and `schedule` would revert.

```bash
TL=<TimelockController>   # deployments/testnet-v3.1.json "Timelock"
SALT=$(cast keccak "bustline-v3.1-unpause-$(date -u +%Y%m%dT%H%M%S)")
cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $EX 0 0x3f4ba83a 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT 3600 \
  --account <proposer-keystore> --rpc-url https://rpc.test.mezo.org
# operation id (keep it with the salt):
cast call $TL "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
  $EX 0 0x3f4ba83a 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT --rpc-url https://rpc.test.mezo.org

# after the delay (isOperationReady(id) == true), from any account:
cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" \
  $EX 0 0x3f4ba83a 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT \
  --account <any-keystore> --rpc-url https://rpc.test.mezo.org
cast call $EX "paused()(bool)" --rpc-url https://rpc.test.mezo.org          # false
```

After unpause the keeper logs `exchange unpaused` and fills the orders that were requested during the pause (a close
that expired meanwhile is refundable with `cancelExpired`; its position stays open). Record the schedule / execute
txs in [`DEPLOYMENTS.md`](DEPLOYMENTS.md#timelock-operations).
