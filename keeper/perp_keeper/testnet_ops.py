"""Mezo TESTNET operator CLI (keeper/.venv/bin/python -m perp_keeper.testnet_ops ...).

Every write requires --confirm, signs in-process with MEZO_TESTNET_PRIVATE_KEY (env only) and refuses any RPC other
than https://rpc.test.mezo.org / chainId 31611. The key is never printed, logged, written or passed on argv.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .chain import ROOT, ExchangeReader
from .monitor import describe
from .rpc import JsonRpc, words
from .signer import EnvSigner, calldata, selector

RPC = "https://rpc.test.mezo.org"
MUSD = "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503"
BORROWER_OPS = "0xCdF7028ceAB81fA0C6971208e83fa7872994beE5"
TROVE_MANAGER = "0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0"
ZERO = "0x" + "0" * 40
W = 10**18


def u(rpc: JsonRpc, to: str, sig: str, types=(), args=()) -> int:
    return words(rpc.eth_call(to, calldata(sig, list(types), list(args))))[0]


def _source(rpc, dep, te):
    from .prices import make_source

    kind = {"pyth": "hermes", "signed": "signed"}.get(dep.get("oracleMode", ""), "none")
    return make_source(kind, rpc, dep, te.signer().sign_hash_eip191 if kind == "signed" else None)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="testnet_ops")
    ap.add_argument("--deployment", default=str(ROOT / "deployments/testnet.json"))
    ap.add_argument("--confirm", action="store_true", help="required for any transaction")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    t = sub.add_parser("open-trove")
    t.add_argument("--coll-wei", type=int, default=45 * 10**15)
    t.add_argument("--debt", type=float, default=1800)
    o = sub.add_parser("open")
    o.add_argument("side", choices=["long", "short"])
    o.add_argument("margin", type=float)
    o.add_argument("leverage", type=int)
    c = sub.add_parser("close")
    c.add_argument("position_id", type=int)
    sub.add_parser("keeper-once")
    sub.add_parser("push-price", help="push a fresh price to a pull oracle (signed/hermes per deployment)")
    sub.add_parser("stake-all")
    sub.add_parser("claim")
    s = sub.add_parser("set-price", help="demo market only (MockOracle owned by this key)")
    s.add_argument("price", type=float)
    a = ap.parse_args(argv)

    rpc = JsonRpc(RPC)
    dep = json.loads(Path(a.deployment).read_text())
    ex = dep["HouseExchange"]
    signer = EnvSigner(rpc)
    me = signer.address

    def send(to, data, value=0):
        if not a.confirm:
            raise SystemExit("refusing: add --confirm to send a testnet transaction")
        rc = signer.send(to, data, value)
        print(f"  tx {rc['transactionHash']} status={int(rc['status'], 16)} gasUsed={int(rc['gasUsed'], 16)}")
        return rc

    if a.cmd == "status":
        print(f"address {me}")
        print(f"  BTC {int(rpc.call('eth_getBalance', [me, 'latest']), 16) / W:.6f} | MUSD {u(rpc, MUSD, 'balanceOf(address)', ['address'], [me]) / W:,.2f}"
              f" | trove status {u(rpc, TROVE_MANAGER, 'getTroveStatus(address)', ['address'], [me])}")
        print(f"  oracle mode {dep.get('oracleMode', 'n/a')} ({dep.get('Oracle', dep.get('MockOracle', '?'))})")
        print("  " + describe(ExchangeReader(rpc, ex).snapshot()))
        print(f"  rebate {u(rpc, dep['RebateToken'], 'balanceOf(address)', ['address'], [me]) / W:,.2f}"
              f" | staked {u(rpc, dep['RebateStaking'], 'staked(address)', ['address'], [me]) / W:,.2f}"
              f" | claimable {u(rpc, dep['RebateStaking'], 'pending(address)', ['address'], [me]) / W:,.6f} MUSD"
              f" | queued {u(rpc, ex, 'queuedOf(address)', ['address'], [me]) / W:,.4f} MUSD")
    elif a.cmd == "open-trove":
        send(BORROWER_OPS, calldata("openTrove(uint256,address,address)", ["uint256", "address", "address"], [int(a.debt * W), ZERO, ZERO]), a.coll_wei)
    elif a.cmd == "open":
        m = int(a.margin * W)
        if u(rpc, MUSD, "allowance(address,address)", ["address", "address"], [me, ex]) < m:
            send(MUSD, calldata("approve(address,uint256)", ["address", "uint256"], [ex, 2**256 - 1]))
        rc = send(ex, calldata("requestOpen(bool,uint256,uint256,uint256)", ["bool", "uint256", "uint256", "uint256"], [a.side == "long", m, a.leverage, 0]))
        print(f"  order id {u(rpc, ex, 'orderCount()') - 1} (block {int(rc['blockNumber'], 16)})")
    elif a.cmd == "close":
        send(ex, calldata("requestClose(uint256,uint256)", ["uint256", "uint256"], [a.position_id, 0]))
    elif a.cmd == "keeper-once":
        from .chain import TestnetExecutor
        from .monitor import Keeper
        from .notifier import TelegramNotifier

        if not a.confirm:
            raise SystemExit("refusing: add --confirm")
        te = TestnetExecutor(rpc, ex)
        k = Keeper(ExchangeReader(rpc, ex), TelegramNotifier.from_env(dry_run=True), te, prices=_source(rpc, dep, te))
        print(f"  {k.poll_once()}")
    elif a.cmd == "push-price":
        from .chain import TestnetExecutor

        if not a.confirm:
            raise SystemExit("refusing: add --confirm")
        te = TestnetExecutor(rpc, ex)
        b = _source(rpc, dep, te).fetch()
        print(f"  {b.source}: ${b.price / W:,.2f} publishTime {b.publish_time} fee {b.fee} wei")
        print(f"  tx {te.push(b.data, b.fee)}")
    elif a.cmd == "stake-all":
        bal = u(rpc, dep["RebateToken"], "balanceOf(address)", ["address"], [me])
        send(dep["RebateToken"], calldata("approve(address,uint256)", ["address", "uint256"], [dep["RebateStaking"], bal]))
        send(dep["RebateStaking"], calldata("stake(uint256)", ["uint256"], [bal]))
    elif a.cmd == "claim":
        send(dep["RebateStaking"], selector("claim()"))
    elif a.cmd == "set-price":
        if "MockOracle" not in dep:
            raise SystemExit("refusing: set-price is only for the labelled demo market (deployment has a MockOracle)")
        send(dep["MockOracle"], calldata("setPrice(uint256)", ["uint256"], [int(a.price * W)]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
