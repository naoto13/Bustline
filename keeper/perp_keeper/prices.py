"""Off-chain price sources that produce on-chain-verifiable updates for the oracle.

* HermesSource  — PRIMARY: latest Pyth BTC/USD (stable/mainnet) update from Hermes; verified on-chain by Pyth
                  (Wormhole guardian signatures). Hermes requires an API key since 2026-08 (env PYTH_API_KEY).
* SignedSource  — FALLBACK: median of public BTC/USD spot prices (Coinbase, Kraken, Bitstamp), signed by the keeper key
                  (EIP-191) and verified on-chain by SignedPriceOracle (authorized signer + staleness + Skip bound).
"""

from __future__ import annotations

import json
import os
import statistics
import time
import urllib.request
from dataclasses import dataclass
from typing import Callable, Optional

from .abi import call_bytes_array, report_hash, signed_report
from .rpc import JsonRpc, RpcError, words

W = 10**18
UA = {"User-Agent": "bustline-keeper/0.2"}
PYTH_BTC_USD = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43"
UPDATE_FEE_SEL = "0x7311cdcf"  # updateFee(bytes[]) — checked in tests against keccak


class PriceUnavailable(RuntimeError):
    pass


@dataclass
class PriceBundle:
    price: int  # WAD
    publish_time: int
    data: list[bytes]
    fee: int
    source: str


def _get_json(url: str, headers: Optional[dict] = None, timeout: float = 8.0):
    req = urllib.request.Request(url, headers={**UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (fixed public endpoints)
        return json.loads(r.read())


def _update_fee(rpc: JsonRpc, oracle: str, data: list[bytes]) -> int:
    return words(rpc.eth_call(oracle, call_bytes_array(UPDATE_FEE_SEL, data)))[0]


class HermesSource:
    def __init__(self, rpc: JsonRpc, oracle: str, feed_id: str = PYTH_BTC_USD, base_url: Optional[str] = None):
        self.rpc, self.oracle, self.feed = rpc, oracle, feed_id
        self.base = (base_url or os.getenv("PYTH_HERMES_URL", "https://hermes.pyth.network")).rstrip("/")

    def fetch(self) -> PriceBundle:
        key = os.environ.get("PYTH_API_KEY")
        hdr = {"Authorization": f"Bearer {key}"} if key else {}
        try:
            j = _get_json(f"{self.base}/v2/updates/price/latest?ids[]={self.feed}&encoding=hex&parsed=true", hdr)
        except Exception as e:  # noqa: BLE001
            hint = " (Hermes needs PYTH_API_KEY since 2026-08)" if "401" in str(e) else ""
            raise PriceUnavailable(f"hermes: {e}{hint}") from e
        data = [bytes.fromhex(h.removeprefix("0x")) for h in j["binary"]["data"]]
        p = j["parsed"][0]["price"]
        e = int(p["expo"])
        raw = int(p["price"])
        price = raw * 10 ** (18 + e) if 18 + e >= 0 else raw // 10 ** (-(18 + e))
        return PriceBundle(price, int(p["publish_time"]), data, _update_fee(self.rpc, self.oracle, data), "pyth-hermes")


def coinbase() -> float:
    return float(_get_json("https://api.coinbase.com/v2/prices/BTC-USD/spot")["data"]["amount"])


def kraken() -> float:
    r = _get_json("https://api.kraken.com/0/public/Ticker?pair=XBTUSD")["result"]
    return float(next(iter(r.values()))["c"][0])


def bitstamp() -> float:
    return float(_get_json("https://www.bitstamp.net/api/v2/ticker/btcusd/")["last"])


class SignedSource:
    def __init__(self, rpc: JsonRpc, oracle: str, sign_hash: Callable[[bytes], bytes], chain_id: int = 31611,
                 fetchers: Optional[list[Callable[[], float]]] = None, min_sources: int = 2, max_spread_bps: int = 50,
                 clock: Callable[[], float] = time.time):
        self.rpc, self.oracle, self.sign_hash, self.chain_id = rpc, oracle, sign_hash, chain_id
        self.fetchers = fetchers if fetchers is not None else [coinbase, kraken, bitstamp]
        self.min_sources, self.max_spread_bps, self.clock = min_sources, max_spread_bps, clock

    def spot(self) -> int:
        vals = []
        for f in self.fetchers:
            try:
                v = f()
                if v > 0:
                    vals.append(v)
            except Exception:  # noqa: BLE001 — one source down is fine
                continue
        if len(vals) < self.min_sources:
            raise PriceUnavailable(f"only {len(vals)} spot sources answered")
        med = statistics.median(vals)
        if (max(vals) - min(vals)) / med * 10_000 > self.max_spread_bps:
            raise PriceUnavailable(f"spot sources disagree: {vals}")
        return int(round(med * 1e8)) * 10**10  # 8-decimal precision, WAD

    def fetch(self) -> PriceBundle:
        price = self.spot()
        t = int(self.clock())
        sig = self.sign_hash(report_hash(self.chain_id, self.oracle, price, t))
        return PriceBundle(price, t, [signed_report(price, t, sig)], 0, "keeper-signed")


def make_source(kind: str, rpc: JsonRpc, dep: dict, sign_hash: Optional[Callable[[bytes], bytes]] = None):
    if kind == "none":
        return None
    oracle = dep.get("Oracle")
    if not oracle:
        raise RpcError("deployment has no 'Oracle' address")
    if kind == "hermes":
        return HermesSource(rpc, oracle, dep.get("PythFeedId", PYTH_BTC_USD))
    if kind == "signed":
        if sign_hash is None:
            raise RpcError("signed price source needs the testnet signer")
        return SignedSource(rpc, oracle, sign_hash, int(dep.get("chainId", 31611)))
    raise ValueError(kind)
