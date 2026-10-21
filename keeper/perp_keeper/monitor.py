"""Keeper loop: fill pending orders (only at a later oracle update), liquidate bust positions, harvest the queue."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Protocol

from .chain import ExchangeReader, Snapshot
from .notifier import TelegramNotifier
from .rpc import RpcError, fmt_wad


class Executor(Protocol):
    def execute(self, oid: int) -> str: ...
    def liquidate(self, pid: int) -> str: ...
    def harvest(self, n: int) -> str: ...


def describe(s: Snapshot) -> str:
    price = f"${fmt_wad(s.price)}" if s.price is not None else f"ERROR ({s.price_error})"
    return (
        f"BTC/USD {price} (age {max(0, s.block_ts - s.price_updated_at)}s) | house cash {fmt_wad(s.house_cash)} MUSD"
        f" | queued {fmt_wad(s.queue_total)} | equity {s.house_equity / 1e18:,.2f}"
        f" | OI L {fmt_wad(s.long_oi)} / S {fmt_wad(s.short_oi)} | open {len(s.open_ids)} | orders {s.order_count}"
    )


@dataclass
class KeeperConfig:
    state_path: Optional[Path] = None
    harvest_batch: int = 32
    scan_window: int = 500


@dataclass
class Keeper:
    reader: ExchangeReader
    notifier: TelegramNotifier
    executor: Optional[Executor] = None
    cfg: KeeperConfig = field(default_factory=KeeperConfig)
    cursor: int = 0  # all orders below this id are final
    alerted: set = field(default_factory=set)

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

    def poll_once(self) -> dict:
        s = self.reader.snapshot()
        out = {"filled": [], "waiting": [], "liquidated": [], "harvested": False, "at_risk": []}
        if s.price is None:
            self._alert_once(f"oracle:{s.price_updated_at}", "critical", "Oracle unavailable — fills/liquidations paused", s.price_error or "")
            self._save()
            return out

        # 1) pending orders → fill only at an oracle update strictly after the request
        pending = self.reader.pending_orders(self.cursor, min(s.order_count, self.cursor + self.cfg.scan_window))
        for oid in pending:
            o = self.reader.order(oid)
            if s.price_updated_at <= o.created_at:
                out["waiting"].append(oid)
                continue
            if self.executor:
                try:
                    self.executor.execute(oid)
                    out["filled"].append(oid)
                except RpcError as e:
                    self._alert_once(f"fillerr:{oid}", "warning", f"fill #{oid} failed", str(e)[:200])
        end = min(s.order_count, self.cursor + self.cfg.scan_window)
        remaining = self.reader.pending_orders(self.cursor, end)
        self.cursor = min(remaining) if remaining else end

        # 2) liquidations
        for pid in s.open_ids:
            try:
                liq = self.reader.is_liquidatable(pid)
            except RpcError:
                continue
            if not liq:
                continue
            out["at_risk"].append(pid)
            if self.executor:
                try:
                    self.executor.liquidate(pid)
                    out["liquidated"].append(pid)
                    self.notifier.notify("warning", f"Liquidated position #{pid}", f"price ${fmt_wad(s.price)}")
                except RpcError as e:
                    self._alert_once(f"liqerr:{pid}", "warning", f"liquidation #{pid} failed", str(e)[:200])
            else:
                self._alert_once(f"liq:{pid}", "warning", f"Position #{pid} is liquidatable (read-only mode)")

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
