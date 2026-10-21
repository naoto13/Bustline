# Bustline — testnet deploy & operations (Mezo testnet only)

Rules: chainId 31611 / https://rpc.test.mezo.org only. The key comes ONLY from `MEZO_TESTNET_PRIVATE_KEY` in the
environment — never on argv, never in files, never printed. Every write needs an explicit confirm flag.

```bash
# 0. derive the address + check gas balance (prints the address only)
keeper/.venv/bin/python -m perp_keeper.testnet_ops status        # (never pass the key on argv, e.g. to cast)
# 1. deploy (forge: contract creation does not touch the Skip precompile, so local simulation works)
# ORACLE_MODE=pyth once PYTH_API_KEY exists (both oracles are deployed either way; switch later with setOracle)
CONFIRM_TESTNET_DEPLOY=1 ORACLE_MODE=signed forge script script/DeployTestnet.s.sol --rpc-url https://rpc.test.mezo.org --broadcast --slow
CONFIRM_TESTNET_DEPLOY=1 forge script script/DeployTestnetDemo.s.sol --rpc-url https://rpc.test.mezo.org --broadcast --slow  # optional crash-demo market
# 2. operator CLI (python signer; forge/cast can't be used for calls that read Skip: forge's local simulation hits
#    EvmError NotActivated on the precompile, and cast only takes keys on argv)
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
# 3. long-running keeper on testnet
.venv/bin/python -m perp_keeper --rpc https://rpc.test.mezo.org --deployment ../deployments/testnet.json --execute-testnet --heartbeat 120
# price source follows deployments/testnet.json "oracleMode": signed → keeper-signed spot median; pyth → Hermes (needs env PYTH_API_KEY)
```

Frontend in testnet mode: `cp deployments/testnet.json frontend/public/deployment.testnet.json` and
`NEXT_PUBLIC_MODE=testnet npm run build && npm start` (writes are signed by the Mezo Passport wallet).
