"""CLI: python -m perp_keeper [--status|--once] [--execute-local|--execute-testnet] ...

Default: READ-ONLY + Telegram dry-run unless TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID are set.
--execute-local    sends txs ONLY to a local anvil fork via an unlocked anvil account (no keys).
--execute-testnet  Mezo testnet (31611, rpc.test.mezo.org) only; signs via forge with MEZO_TESTNET_PRIVATE_KEY (env).
--price-source     none|hermes|signed (default: from deployment "oracleMode": pyth→hermes, signed→signed, else none).
                   hermes = Pyth stable update from Hermes (env PYTH_API_KEY), pushed in the fill/liquidation tx;
                   signed = keeper-signed spot median (fallback, needs --execute-testnet for the signer).
--heartbeat N      with a pull oracle, push a fresh price at least every N seconds even when idle.
--simulate-oracle  LOCAL ONLY: re-post the MockOracle price each poll (mimics Skip's per-block updates on anvil).
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

from .chain import ROOT, ExchangeReader, LocalExecutor, TestnetExecutor, enc_uint, load_selectors
from .monitor import Keeper, KeeperConfig, describe
from .prices import make_source
from .notifier import TelegramNotifier
from .rpc import JsonRpc

ANVIL_ACCOUNT_0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"


def tick_mock_oracle(rpc: JsonRpc, oracle: str, sender: str) -> None:
    """LOCAL ONLY: advance anvil time 1s and re-post the same MockOracle price (new update, same value)."""
    sel = load_selectors("MockOracle")
    ex = LocalExecutor(rpc, oracle, sender)
    ex.check()
    price = int(rpc.eth_call(oracle, sel["priceValue()"]).hex(), 16)
    rpc.call("evm_increaseTime", [1])
    ex.send(oracle, sel["setPrice(uint256)"] + enc_uint(price))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="perp_keeper")
    ap.add_argument("--rpc", default=os.getenv("PERP_RPC_URL", "http://127.0.0.1:8545"))
    ap.add_argument("--deployment", default=os.getenv("PERP_DEPLOYMENT", str(ROOT / "deployments/local.json")))
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--interval", type=float, default=float(os.getenv("PERP_POLL_SECONDS", "3")))
    ap.add_argument("--dry-run", action="store_true", help="never send Telegram even if token is set")
    ap.add_argument("--execute-local", action="store_true")
    ap.add_argument("--execute-testnet", action="store_true")
    ap.add_argument("--simulate-oracle", action="store_true")
    ap.add_argument("--sender", default=ANVIL_ACCOUNT_0)
    ap.add_argument("--state", default=None)
    ap.add_argument("--price-source", choices=["auto", "none", "hermes", "signed"], default="auto")
    ap.add_argument("--heartbeat", type=float, default=0)
    args = ap.parse_args(argv)

    dep = json.loads(Path(args.deployment).read_text())
    rpc = JsonRpc(args.rpc)
    reader = ExchangeReader(rpc, dep["HouseExchange"])
    if args.status:
        print(describe(reader.snapshot()))
        return 0
    notifier = TelegramNotifier.from_env(dry_run=args.dry_run)
    executor = None
    if args.execute_local and args.execute_testnet:
        ap.error("choose one executor")
    if args.execute_local:
        executor = LocalExecutor(rpc, dep["HouseExchange"], args.sender)
    elif args.execute_testnet:
        executor = TestnetExecutor(rpc, dep["HouseExchange"])
    if executor:
        executor.check()
    if args.simulate_oracle and not args.execute_local:
        ap.error("--simulate-oracle requires --execute-local")
    state = Path(args.state) if args.state else None
    kind = args.price_source
    if kind == "auto":
        kind = {"pyth": "hermes", "signed": "signed"}.get(dep.get("oracleMode", ""), "none")
    sign = None
    if kind == "signed":
        if not args.execute_testnet:
            ap.error("--price-source signed requires --execute-testnet (the report signer is the testnet key)")
        sign = executor.signer().sign_hash_eip191
    prices = make_source(kind, rpc, dep, sign)
    keeper = Keeper(reader, notifier, executor, KeeperConfig(state_path=state, heartbeat=args.heartbeat), prices)
    mode = "EXECUTE-LOCAL(anvil)" if args.execute_local else "EXECUTE-TESTNET" if args.execute_testnet else "READ-ONLY"
    print(f"[keeper] mode={mode} price-source={kind} telegram={'live' if notifier.live else 'dry-run'} rpc={args.rpc}")
    while True:
        if args.simulate_oracle:
            tick_mock_oracle(rpc, dep["MockOracle"], args.sender)
        res = keeper.poll_once()
        print(f"[keeper] {describe(reader.snapshot())} | {res}")
        if args.once:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
