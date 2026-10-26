# Operations — testnet deploy, keeper and frontend

Mezo testnet only (chainId `31611`, `https://rpc.test.mezo.org`). Addresses of the current deployment are in
[`DEPLOYMENTS.md`](DEPLOYMENTS.md).

**Key handling.** The deployer/keeper key is read only from the `MEZO_TESTNET_PRIVATE_KEY` environment variable — never
passed on argv, never written to files, never printed. Every write requires an explicit confirm flag.

## 1. Deploy contracts

```bash
# derive the address and check the gas balance (prints the address only)
keeper/.venv/bin/python -m perp_keeper.testnet_ops status

# ORACLE_MODE=pyth once PYTH_API_KEY exists (both oracles are deployed either way; switch later with setOracle)
CONFIRM_TESTNET_DEPLOY=1 ORACLE_MODE=signed forge script script/DeployTestnet.s.sol --rpc-url https://rpc.test.mezo.org --broadcast --slow
# optional mock-oracle crash-demo market
CONFIRM_TESTNET_DEPLOY=1 forge script script/DeployTestnetDemo.s.sol --rpc-url https://rpc.test.mezo.org --broadcast --slow
```

Contract creation doesn't touch the Skip precompile, so forge's local simulation works for deploys.

## 2. Operator CLI

Calls that read Skip can't go through forge/cast (forge's local simulation hits `EvmError NotActivated` on the
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
health: https://bustline-keeper.m9m1c3.workers.dev/health), so the demo doesn't depend on a server. It is a
TypeScript + viem port of one Python keeper poll (`monitor.Keeper.poll_once` with the keeper-signed price source),
without Telegram.

| | |
|---|---|
| Trigger | Cron `* * * * *`; each run ticks every 15 s for ~46 s (4 ticks) (`TICK_SECONDS`, `RUN_SECONDS`) |
| Price | Median of Coinbase / Kraken / Bitstamp (≥ 2 sources, ≤ 50 bps spread), 8-dec WAD, signed EIP-191 over `keccak256(abi.encode(31611, oracle, price, publishTime))` exactly like `signer.py` / `abi.py`. One deliberate difference: publishTime = min(now, latest block time + 5 s), because testnet block time can lag wall clock by ~10 s and the oracle rejects reports > `maxSkew` (10 s) in the future |
| Per tick | Fill pending orders (only at a price published after the request), liquidate positions past their bust price, push the price (at least once per run, so the on-chain price is ≤ ~60 s old), harvest the payout queue |
| Txs | Sequential, one in flight, legacy EIP-155 tx, `pending` nonce (never reused within a run), gas = estimate × 1.3 + 20k, gasPrice = 2 × `eth_gasPrice` |
| Safety | Refuses any RPC host other than `rpc.test.mezo.org` and any chainId other than 31611 |
| Health | `GET /health` → live on-chain price + age, open positions, pending orders, and the last run summary (tx hashes, per-tick results) from KV. No secrets |

Signature / calldata / raw-tx encoding is checked byte-for-byte against the Python keeper:
`node keeper-worker/test/sig.mjs` (public anvil key, never the keeper key) vs `perp_keeper.abi` + `eth_account`.

```bash
cd keeper-worker
npm install
W="npx -y -p node@22 -p wrangler@latest -- wrangler"   # wrangler needs Node >= 22
$W deploy
printenv MEZO_TESTNET_PRIVATE_KEY | $W secret put KEEPER_PRIVATE_KEY   # pipe only; never echo the key
$W tail --format pretty                                               # watch ticks
curl -s https://bustline-keeper.m9m1c3.workers.dev/health
```

Run only **one** keeper per key: stop the Python keeper (`pkill -f perp_keeper`) once the Worker is pushing,
otherwise the two race for nonces. To fall back to Python, remove the cron (`wrangler triggers`) or `$W delete`, then
start the Python keeper below.

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

### Python keeper (fallback)

```bash
cd keeper
.venv/bin/python -m perp_keeper --rpc https://rpc.test.mezo.org --deployment ../deployments/testnet.json --execute-testnet --heartbeat 120
```

The price source follows `"oracleMode"` in the deployment file: `signed` → keeper-signed spot median, `pyth` → Hermes
(needs `PYTH_API_KEY`). Optional Telegram alerts read `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` from the environment.

## 4. Frontend

Local, against a testnet deployment:

```bash
cp deployments/testnet.json frontend/public/deployment.testnet.json
cd frontend && NEXT_PUBLIC_MODE=testnet npm run build && npm start   # writes are signed by Mezo Passport
```

Static build for Cloudflare Pages (live at https://bustline-c8p.pages.dev; the app is a single static page with no API
routes, so `output: "export"` works; Wrangler needs Node ≥ 22):

```bash
cd frontend
npm ci --legacy-peer-deps
STATIC_EXPORT=1 NEXT_PUBLIC_MODE=testnet NEXT_PUBLIC_RPC_URL=https://rpc.test.mezo.org npx next build
npx -p node@22 -p wrangler@latest -- wrangler pages deploy out --project-name bustline --branch main
```
