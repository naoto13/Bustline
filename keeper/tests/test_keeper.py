import os
import unittest
from unittest import mock

from perp_keeper.chain import (ExecutionRefused, LocalExecutor, Order, Snapshot, TestnetExecutor, dyn_uint_array,
                               enc_uint, load_selectors)
from perp_keeper.monitor import Keeper, KeeperConfig, describe
from perp_keeper.prices import PriceBundle, PriceUnavailable, SignedSource
from perp_keeper.notifier import TelegramNotifier
from perp_keeper.rpc import JsonRpc, RpcError

W = 10**18


def snap(**kw):
    base = dict(block_ts=1000, price=80_000 * W, price_updated_at=1000, price_error=None, house_cash=0, queue_total=0,
                house_equity=0, long_oi=0, short_oi=0, open_ids=[], order_count=0)
    base.update(kw)
    return Snapshot(**base)


class FakeReader:
    def __init__(self, s, orders=None, liq=()):
        self.s, self.orders, self.liq = s, orders or {}, set(liq)
        self.busts = {}

    def snapshot(self):
        return self.s

    def pending_orders(self, a, b):
        return [i for i, o in sorted(self.orders.items()) if a <= i < b and o.status == 1]

    def order(self, i):
        return self.orders[i]

    def is_liquidatable(self, pid):
        return pid in self.liq

    def bust_price(self, pid):
        return self.busts[pid][0]

    def position_is_long(self, pid):
        return self.busts[pid][1]


class FakeExec:
    def __init__(self, reader):
        self.r, self.calls = reader, []

    def execute(self, oid, update=(), fee=0):
        self.calls.append(("execute", oid, len(update), fee))
        self.r.orders[oid].status = 2

    def liquidate(self, pid, update=(), fee=0):
        self.calls.append(("liquidate", pid, len(update), fee))

    def push(self, update, fee=0):
        self.calls.append(("push", len(update), fee))

    def harvest(self, n):
        self.calls.append(("harvest", n))


def order(i, created):
    return Order(i, "0x" + "11" * 20, 0, 1, True, created, 100 * W, 1000 * W, 0)


def quiet():
    return TelegramNotifier(dry_run=True, printer=lambda *_: None)


class KeeperTests(unittest.TestCase):
    def test_waits_for_later_oracle_update(self):
        r = FakeReader(snap(order_count=1, price_updated_at=1000), {0: order(0, 1000)})
        ex = FakeExec(r)
        out = Keeper(r, quiet(), ex).poll_once()
        self.assertEqual(out["waiting"], [0])
        self.assertEqual(ex.calls, [])

    def test_fills_after_update_and_advances_cursor(self):
        r = FakeReader(snap(order_count=2, price_updated_at=1005), {0: order(0, 1000), 1: order(1, 1001)})
        ex = FakeExec(r)
        k = Keeper(r, quiet(), ex)
        out = k.poll_once()
        self.assertEqual(out["filled"], [0, 1])
        self.assertEqual(k.cursor, 2)

    def test_cursor_stays_on_waiting_order(self):
        r = FakeReader(snap(order_count=2, price_updated_at=1005), {0: order(0, 1000), 1: order(1, 1009)})
        k = Keeper(r, quiet(), FakeExec(r))
        k.poll_once()
        self.assertEqual(k.cursor, 1)

    def test_liquidates_and_harvests(self):
        r = FakeReader(snap(open_ids=[3, 4], queue_total=5 * W, house_cash=W), liq=[4])
        ex = FakeExec(r)
        out = Keeper(r, quiet(), ex).poll_once()
        self.assertEqual(out["liquidated"], [4])
        self.assertIn(("harvest", 32), ex.calls)

    def test_read_only_alerts_once(self):
        n = quiet()
        r = FakeReader(snap(open_ids=[7]), liq=[7])
        k = Keeper(r, n, None)
        k.poll_once()
        k.poll_once()
        self.assertEqual(len([m for m in n.sent if "#7" in m]), 1)

    def test_oracle_error_pauses(self):
        n = quiet()
        r = FakeReader(snap(price=None, price_error="StalePrice", order_count=1), {0: order(0, 1)})
        ex = FakeExec(r)
        Keeper(r, n, ex).poll_once()
        self.assertEqual(ex.calls, [])
        self.assertTrue(any("Oracle unavailable" in m for m in n.sent))

    def test_describe(self):
        self.assertIn("BTC/USD $80,000.00", describe(snap()))


class FakeSource:
    def __init__(self, price, t, fail=False):
        self.price, self.t, self.fail, self.n = price, t, fail, 0

    def fetch(self):
        self.n += 1
        if self.fail:
            raise PriceUnavailable("hermes: HTTP Error 401")
        return PriceBundle(self.price, self.t, [b"upd"], 10, "fake")


class PullOracleKeeperTests(unittest.TestCase):
    def test_fill_carries_update_once_then_reuses_stored_price(self):
        r = FakeReader(snap(price=None, price_error="StalePrice", order_count=2), {0: order(0, 1000), 1: order(1, 1001)})
        ex = FakeExec(r)
        out = Keeper(r, quiet(), ex, prices=FakeSource(81_000 * W, 1002)).poll_once(now=1003)
        self.assertEqual(out["filled"], [0, 1])
        self.assertEqual(ex.calls, [("execute", 0, 1, 10), ("execute", 1, 0, 0)])

    def test_waits_until_publish_time_after_order(self):
        r = FakeReader(snap(price=None, order_count=1), {0: order(0, 1002)})
        ex = FakeExec(r)
        out = Keeper(r, quiet(), ex, prices=FakeSource(81_000 * W, 1002)).poll_once(now=1003)
        self.assertEqual(out["waiting"], [0])
        self.assertEqual(ex.calls, [])

    def test_liquidation_decided_on_fresh_price(self):
        r = FakeReader(snap(price=None, open_ids=[1, 2]))
        r.busts = {1: (80_000 * W, True), 2: (90_000 * W, False)}  # long bust 80k, short bust 90k
        ex = FakeExec(r)
        out = Keeper(r, quiet(), ex, prices=FakeSource(79_999 * W, 1002)).poll_once(now=1003)
        self.assertEqual(out["liquidated"], [1])
        self.assertEqual(ex.calls[0], ("liquidate", 1, 1, 10))

    def test_idle_no_fetch_without_heartbeat_and_push_with_it(self):
        r = FakeReader(snap())
        src = FakeSource(81_000 * W, 1002)
        ex = FakeExec(r)
        Keeper(r, quiet(), ex, prices=src).poll_once(now=1003)
        self.assertEqual(src.n, 0)
        k = Keeper(r, quiet(), ex, KeeperConfig(heartbeat=30), prices=src)
        self.assertTrue(k.poll_once(now=1003)["pushed"])
        self.assertFalse(k.poll_once(now=1010)["pushed"])

    def test_source_down_falls_back_to_onchain_price(self):
        n = quiet()
        r = FakeReader(snap(order_count=1, price_updated_at=1005), {0: order(0, 1000)})
        ex = FakeExec(r)
        out = Keeper(r, n, ex, prices=FakeSource(0, 0, fail=True)).poll_once(now=1006)
        self.assertEqual(out["filled"], [0])
        self.assertEqual(ex.calls, [("execute", 0, 0, 0)])
        self.assertTrue(any("Price source unavailable" in m for m in n.sent))


class SignedSourceTests(unittest.TestCase):
    def test_median_and_spread_guard(self):
        src = SignedSource(None, "0x" + "22" * 20, lambda h: b"\x01" * 65, fetchers=[lambda: 100.0, lambda: 100.2, lambda: 100.1])
        self.assertEqual(src.spot(), 100_1 * W // 10)
        bad = SignedSource(None, "0x" + "22" * 20, lambda h: b"", fetchers=[lambda: 100.0, lambda: 102.0])
        with self.assertRaises(PriceUnavailable):
            bad.spot()
        one = SignedSource(None, "0x" + "22" * 20, lambda h: b"", fetchers=[lambda: 100.0, lambda: 1 / 0])
        with self.assertRaises(PriceUnavailable):
            one.spot()


class GuardTests(unittest.TestCase):
    def test_local_executor_refuses_remote(self):
        with self.assertRaises(ExecutionRefused):
            LocalExecutor(JsonRpc("https://rpc.test.mezo.org"), "0x" + "0" * 40, "0x" + "0" * 40, {}).check()

    def test_testnet_executor_refuses_other_hosts(self):
        with self.assertRaises(ExecutionRefused):
            TestnetExecutor(JsonRpc("https://mainnet.mezo.public.validationcloud.io"), "0x").check()

    def test_testnet_executor_requires_env_key(self):
        rpc = JsonRpc("https://rpc.test.mezo.org")
        with mock.patch.object(JsonRpc, "chain_id", return_value=31611), mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ExecutionRefused):
                TestnetExecutor(rpc, "0x").check()

    def test_testnet_executor_refuses_wrong_chain(self):
        rpc = JsonRpc("https://rpc.test.mezo.org")
        with mock.patch.object(JsonRpc, "chain_id", return_value=31612):
            with self.assertRaises(ExecutionRefused):
                TestnetExecutor(rpc, "0x").check()


class AbiTests(unittest.TestCase):
    def test_selectors_present(self):
        s = load_selectors()
        for sig in ["executeOrder(uint256,bytes[])", "liquidate(uint256,bytes[])", "pushPrice(bytes[])", "lastPrice()", "harvest(uint256)", "currentPrice()",
                    "getOrder(uint256)", "pendingOrderIds(uint256,uint256)", "openPositionIds()"]:
            self.assertTrue(s[sig].startswith("0x") and len(s[sig]) == 10, sig)

    def test_dyn_array_decode(self):
        raw = bytes.fromhex(enc_uint(32, 3, 5, 6, 9))
        self.assertEqual(dyn_uint_array(raw), [5, 6, 9])


if __name__ == "__main__":
    unittest.main()
