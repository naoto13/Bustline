#!/usr/bin/env python3
"""List HouseExchange / oracle events on Mezo testnet (read-only) as markdown. Usage: list-events.py <deployment.json> [fromBlock]"""
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RPC = "https://rpc.test.mezo.org"


def rpc(m, p):
    r = urllib.request.Request(RPC, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(),
                               headers={"Content-Type": "application/json", "User-Agent": "bustline-events"})
    j = json.loads(urllib.request.urlopen(r, timeout=30).read())
    if "error" in j:
        raise RuntimeError(j["error"])
    return j["result"]


def topics(contract):
    from eth_utils import keccak
    abi = json.loads((ROOT / f"out/{contract}.sol/{contract}.json").read_text())["abi"]
    return {"0x" + keccak(text=f"{e['name']}({','.join(i['type'] for i in e['inputs'])})").hex(): e["name"]
            for e in abi if e["type"] == "event"}


dep = json.loads(Path(sys.argv[1]).read_text())
start = int(sys.argv[2]) if len(sys.argv) > 2 else 0
latest = int(rpc("eth_blockNumber", []), 16)
for name, contract in [("HouseExchange", "HouseExchange"), ("Oracle", "SignedPriceOracle")]:
    addr = dep.get(name)
    if not addr:
        continue
    t = topics(contract)
    print(f"### {name} {addr}")
    b = start
    while b <= latest:
        e = min(b + 9_999, latest)
        for lg in rpc("eth_getLogs", [{"address": addr, "fromBlock": hex(b), "toBlock": hex(e)}]):
            n = t.get(lg["topics"][0], lg["topics"][0][:10])
            if n in ("ParamsUpdated", "KeeperSet", "OwnershipTransferred", "SignerSet", "SkipBoundSet"):
                continue
            print(f"- {n} — block {int(lg['blockNumber'], 16)} — tx `{lg['transactionHash']}`")
        b = e + 1
