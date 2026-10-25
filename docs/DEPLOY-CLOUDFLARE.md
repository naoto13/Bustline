# Deploying the frontend to Cloudflare Pages

Live (Mezo testnet): https://bustline-c8p.pages.dev/  (Pages project `bustline`)

```bash
cd frontend
npm ci --legacy-peer-deps
STATIC_EXPORT=1 NEXT_PUBLIC_MODE=testnet NEXT_PUBLIC_RPC_URL=https://rpc.test.mezo.org npx next build
npx -p node@22 -p wrangler@latest -- wrangler pages deploy out --project-name bustline --branch main
```

The app is a single static page (no API routes), so `output: "export"` works. Wrangler needs Node >= 22.

# Keeper on Cloudflare Workers (`keeper-worker/`)

The testnet keeper runs as the Worker **`bustline-keeper`** (https://bustline-keeper.m9m1c3.workers.dev), so the
demo no longer depends on a Linux box. It is a TypeScript + viem port of one `perp_keeper` poll
(`monitor.Keeper.poll_once` with the keeper-signed price source), minus Telegram.

| | |
|---|---|
| Trigger | Cron `* * * * *`; each run ticks every 15 s for ~46 s (4 ticks) (`TICK_SECONDS`, `RUN_SECONDS`) |
| Price | median of Coinbase / Kraken / Bitstamp (≥ 2 sources, ≤ 50 bps spread), 8-dec WAD, signed EIP-191 over `keccak256(abi.encode(31611, oracle, price, publishTime))` exactly like `signer.py` / `abi.py`. One deliberate difference: publishTime = min(now, latest block time + 5 s), because testnet block time can lag wall clock by ~10 s and the oracle rejects reports > `maxSkew` (10 s) in the future |
| Per tick | fill pending orders (only at a price published after the request), liquidate positions past their bust price, push the price (at least once per run, so the on-chain price is ≤ ~60 s old), harvest the payout queue |
| Txs | sequential, one in flight, legacy EIP-155 tx, `pending` nonce (never reused within a run), gas = estimate × 1.3 + 20k, gasPrice = 2 × `eth_gasPrice` |
| Safety | refuses any RPC host other than `rpc.test.mezo.org` and any chainId other than 31611 |
| Health | `GET /health` → live on-chain price + age, open positions, pending orders, and the last run summary (tx hashes, per-tick results) from KV. No secrets |

Signature / calldata / raw-tx encoding is checked byte-for-byte against the Python keeper:
`node keeper-worker/test/sig.mjs` (public anvil key, never the keeper key) vs `perp_keeper.abi` + `eth_account`.

## Deploy

```bash
cd keeper-worker
npm install
W="npx -y -p node@22 -p wrangler@latest -- wrangler"   # wrangler needs Node >= 22
$W deploy
printenv MEZO_TESTNET_PRIVATE_KEY | $W secret put KEEPER_PRIVATE_KEY   # pipe only; never echo the key
$W tail --format pretty                                               # watch ticks
curl -s https://bustline-keeper.m9m1c3.workers.dev/health
```

Run only **one** keeper per key: stop the box Python keeper (`pkill -f perp_keeper`) once the Worker is pushing,
otherwise the two race for nonces. To fall back to the box, `wrangler triggers` / delete the cron (or
`$W delete`) and restart `python -m perp_keeper --execute-testnet ...`.

## Limits (Workers Free)

* **50 subrequests per invocation.** RPC reads are JSON-RPC batched (one HTTP call per snapshot); the loop stops
  early at ~44 subrequests. A busy minute (several fills + liquidations, each waiting for a receipt) may finish
  fewer ticks; the next cron minute picks up the rest.
* **CPU 10 ms per invocation.** Network waits do not count; secp256k1 signing is the main cost. Watch
  `cpuTime` in Workers Observability; if runs get killed for CPU, move the account to Workers Paid.
* **KV 1,000 writes/day**: the `/health` run summary is written on even minutes (or whenever a fill,
  liquidation, harvest or error happened), so it can be up to ~2 min old; the `live` block is always fresh.
* Cron trigger changes can take a few minutes to start firing after the first deploy.
