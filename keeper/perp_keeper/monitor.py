"""Keeper loop: fill pending orders (only at a later oracle update), liquidate bust positions, harvest the queue."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Protocol

from .chain import ExchangeReader, Snapshot
from .notifier import TelegramNotifier
from .prices import PriceBundle, PriceUnavailable
from .rpc import RpcError, fmt_wad


class Executor(Protocol):
    def execute(self, oid: int, update: list[bytes] = (), fee: int = 0) -> str: ...
    def liquidate(self, pid: int, update: list[bytes] = (), fee: int = 0) -> str: ...
    def push(self, update: list[bytes], fee: int = 0) -> str: ...
    def harvest(self, n: int) -> str: ...


class PriceSource(Protocol):
    def fetch(self) -> PriceBundle: ...


def describe(s: Snapshot) -> str:
    if s.price is not None:
        price = f"${fmt_wad(s.price)} (age {max(0, s.block_ts - s.price_updated_at)}s)"
    elif s.last_price:
        price = f"last ${fmt_wad(s.last_price)} (age {max(0, s.block_ts - s.last_time)}s, not settle-able)"
    else:
        price = f"ERROR ({(s.price_error or '')[:60]})"
    return (
        f"BTC/USD {price} | house cash {fmt_wad(s.house_cash)} MUSD"
        f" | queued {fmt_wad(s.queue_total)} | equity {s.house_equity / 1e18:,.2f}"
        f" | OI L {fmt_wad(s.long_oi)} / S {fmt_wad(s.short_oi)} | open {len(s.open_ids)} | orders {s.order_count}"
    )


@dataclass
class KeeperConfig:
    state_path: Optional[Path] = None
    harvest_batch: int = 32
    scan_window: int = 500
    heartbeat: float = 0  # >0: push a fresh price at least this often (s) even with nothing to do (pull oracles)


@dataclass
class Keeper:
    reader: ExchangeReader
    notifier: TelegramNotifier
    executor: Optional[Executor] = None
    cfg: KeeperConfig = field(default_factory=KeeperConfig)
    prices: Optional[PriceSource] = None  # pull oracle (Pyth/Hermes or signed); None = oracle updates itself
    cursor: int = 0  # all orders below this id are final
    alerted: set = field(default_factory=set)
    last_push: float = 0

    def __post_init__(self) -> None:
        if self.cfg.state_path and self.cfg.state_path.exists():
            st = json.loads(self.cfg.state_path.read_text())
            self.cursor = st.get("cursor", 0)
            self.alerted = set(st.get("alerted", []))

    def _save(self) -> None:
        if self.cfg.state_path:
            self.cfg.state_path.write_text(json.dumps({"cursor": self.cursor, "alerted": sorted(self.alerted)}))

    def _alert_once(self, key: str, level: str, title: str, body: str = "") -> None:
        if key in self.alerted:
            return
        self.alerted.add(key)
        self.notifier.notify(level, title, body)

    def poll_once(self, now: Optional[float] = None) -> dict:
        import time as _t

        now = _t.time() if now is None else now
        s = self.reader.snapshot()
        out = {"filled": [], "waiting": [], "liquidated": [], "harvested": False, "at_risk": [], "pushed": False, "source": None}
        bundle: Optional[PriceBundle] = None
        end = min(s.order_count, self.cursor + self.cfg.scan_window)
        pending = self.reader.pending_orders(self.cursor, end)
        if self.prices is not None and (pending or s.open_ids or (self.cfg.heartbeat and now - self.last_push >= self.cfg.heartbeat)):
            try:
                bundle = self.prices.fetch()
                out["source"] = bundle.source
            except PriceUnavailable as e:
                self._alert_once(f"src:{int(now) // 300}", "warning", "Price source unavailable — using on-chain price", str(e)[:200])
        if bundle is not None:
            price, ts = bundle.price, bundle.publish_time
        elif s.price is not None:
            price, ts = s.price, s.price_updated_at
        else:
            self._alert_once(f"oracle:{s.price_updated_at}", "critical", "Oracle unavailable — fills/liquidations paused", s.price_error or "")
            self._save()
            return out
        upd: list[bytes] = list(bundle.data) if bundle else []
        fee = bundle.fee if bundle else 0

        def consume() -> tuple[list[bytes], int]:
            nonlocal upd, fee
            u, f = upd, fee
            upd, fee = [], 0  # once pushed on-chain, later txs in this poll reuse the stored price
            return u, f

        # 1) pending orders → fill only at a price PUBLISHED strictly after the request
        for oid in pending:
            o = self.reader.order(oid)
            if ts <= o.created_at:
                out["waiting"].append(oid)
                continue
            if self.executor:
                u, f = consume()
                try:
                    self.executor.execute(oid, u, f)
                    out["filled"].append(oid)
                except RpcError as e:
                    upd, fee = u, f
                    self._alert_once(f"fillerr:{oid}", "warning", f"fill #{oid} failed", str(e)[:200])
        remaining = self.reader.pending_orders(self.cursor, end)
        self.cursor = min(remaining) if remaining else end

        # 2) liquidations (pull mode: decided off-chain against the fresh price, enforced on-chain)
        for pid in s.open_ids:
            try:
                if bundle is not None:
                    bust = self.reader.bust_price(pid)
                    liq = price <= bust if self.reader.position_is_long(pid) else price >= bust
                else:
                    liq = self.reader.is_liquidatable(pid)
            except RpcError:
                continue
            if not liq:
                continue
            out["at_risk"].append(pid)
            if self.executor:
                u, f = consume()
                try:
                    self.executor.liquidate(pid, u, f)
                    out["liquidated"].append(pid)
                    self.notifier.notify("warning", f"Liquidated position #{pid}", f"price ${fmt_wad(price)}")
                except RpcError as e:
                    upd, fee = u, f
                    self._alert_once(f"liqerr:{pid}", "warning", f"liquidation #{pid} failed", str(e)[:200])
            else:
                self._alert_once(f"liq:{pid}", "warning", f"Position #{pid} is liquidatable (read-only mode)")

        # heartbeat: keep the on-chain price fresh for UIs even when idle
        if bundle is not None and self.executor:
            if not upd:
                self.last_push = now
            elif self.cfg.heartbeat and now - self.last_push >= self.cfg.heartbeat:
                try:
                    self.executor.push(upd, fee)
                    self.last_push, out["pushed"] = now, True
                except RpcError as e:
                    self._alert_once(f"pusherr:{int(now) // 300}", "warning", "price push failed", str(e)[:200])

        # 3) queue harvest (normally automatic on every loss; this catches leftovers)
        s2 = self.reader.snapshot()
        if s2.queue_total > 0:
            self._alert_once(f"queue:{s2.queue_total}", "info", "Payout queue active",
                             f"queued {fmt_wad(s2.queue_total)} MUSD, house cash {fmt_wad(s2.house_cash)}")
            if s2.house_cash > 0 and self.executor:
                try:
                    self.executor.harvest(self.cfg.harvest_batch)
                    out["harvested"] = True
                except RpcError as e:
                    self._alert_once(f"harverr:{s2.queue_total}", "warning", "harvest failed", str(e)[:200])
        self._save()
        return out
