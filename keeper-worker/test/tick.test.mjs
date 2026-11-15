// Offline integration test: runs the real Worker handlers (src/index.ts default export) with fetch stubbed.
// No network: JSON-RPC, Hermes and the spot APIs are answered by the stub; any other request fails the test.
// Keys are PUBLIC anvil test keys (same policy as test/sig.mjs), never the keeper key. Run: pnpm test
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodeAbiParameters, encodeAbiParameters, keccak256, parseTransaction, recoverMessageAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import worker from "../src/index.ts";

const FIX = JSON.parse(readFileSync(new URL("./fixtures/hermes-btcusd-latest.json", import.meta.url), "utf8"));
const T = 1794733931; // fixture publish_time
const FIX_DATA = ["0x" + FIX.binary.data[0]];
const KEEPER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a84112f6c79f4f8f9d4"; // throwaway test key, same as test/sig.mjs (never a real wallet)
const SIGNER_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"; // anvil #2 (public)
const API_KEY = "test-pyth-key-NOT-REAL-7f3a9c";
const EXCHANGE = "0x3c58314cd5710893519E5d962F553633ECC60cF7";
const SIGNED = "0x75a3071482883d9616bf0473B7eE25B4222b181F";
const PYTH = "0xf05B4108B93A83a1a87Ba1E392a81226aAC63619";
const E18 = 10n ** 18n;

const SEL = {
  currentPrice: "0x9d1b464a", lastPrice: "0x053f14da", houseCash: "0xba1d61cf", queueTotal: "0x498991d9",
  orderCount: "0x2453ffa8", openPositionIds: "0x96cf4e7c", pendingOrderIds: "0x8915ce0a", getOrder: "0xd09ef241",
  bustPriceOf: "0x8a8c6842", isLiquidatable: "0x211a4443", getPosition: "0xeb02c301", paused: "0x5c975abb",
  oracle: "0x7dc0d1d0", updateFee: "0x7311cdcf",
  executeOrder: "0x33e7dddb", liquidate: "0xf6614170", pushPrice: "0x066f2eb6",
};
const w = (...v) => "0x" + v.map((x) => BigInt(x).toString(16).padStart(64, "0")).join("");
const dyn = (a) => w(32, a.length, ...a);
const addrWord = (a) => "0x" + a.slice(2).toLowerCase().padStart(64, "0");

// ------------------------------------------------------------------ fake clock (no real waiting)
const real = { now: Date.now, setTimeout: globalThis.setTimeout, log: console.log };
let clock = 0;
function useClock(ms) {
  clock = ms;
  Date.now = () => clock;
  globalThis.setTimeout = (fn, d = 0, ...a) => { clock += Number(d) || 0; return setImmediate(fn, ...a); };
}
afterEach(() => {
  Date.now = real.now; globalThis.setTimeout = real.setTimeout; console.log = real.log; globalThis.fetch = realFetch;
});
const realFetch = globalThis.fetch;

// ------------------------------------------------------------------ fetch stub
function stub(sc) {
  const rec = { raw: [], hermes: [], spot: [], calls: [], unexpected: [], pendingReads: 0 };
  const ex = EXCHANGE.toLowerCase(), py = PYTH.toLowerCase();
  const json = (x, status = 200) => new Response(JSON.stringify(x), { status, headers: { "Content-Type": "application/json" } });
  function ethCall({ to, data }) {
    to = to.toLowerCase();
    const sel = data.slice(0, 10);
    rec.calls.push({ to, sel, data });
    if (to === py && sel === SEL.updateFee) {
      if (sc.feeError) return { error: { message: "execution reverted" } };
      return { result: w(sc.fee ?? 1n) };
    }
    if (to !== ex) { rec.unexpected.push(`eth_call to ${to}`); return { error: { message: "unexpected" } }; }
    const pending = sc.pending ?? [], open = sc.open ?? [];
    switch (sel) {
      case SEL.currentPrice: return { result: w(66000n * E18, T - 30) };
      case SEL.lastPrice: return { result: w(66000n * E18, T - 30) };
      case SEL.houseCash: case SEL.queueTotal: return { result: w(0) };
      case SEL.orderCount: return { result: w(pending.length) };
      case SEL.openPositionIds: return { result: dyn(open.map((p) => p.pid)) };
      case SEL.pendingOrderIds: return { result: dyn(rec.pendingReads++ === 0 ? pending.map((o) => o.oid) : []) };
      case SEL.paused: return { result: w(0) };
      case SEL.oracle: return sc.oracleError ? { error: { message: "rpc hiccup" } } : { result: addrWord(sc.oracle) };
      case SEL.getOrder: {
        const oid = BigInt("0x" + data.slice(10));
        const o = pending.find((x) => BigInt(x.oid) === oid);
        return { result: w(1, 0, 0, 0, o.createdAt, 0) };
      }
      case SEL.bustPriceOf: { const p = open.find((x) => BigInt(x.pid) === BigInt("0x" + data.slice(10))); return { result: w(p.bust) }; }
      case SEL.getPosition: { const p = open.find((x) => BigInt(x.pid) === BigInt("0x" + data.slice(10))); return { result: w(1, p.long ? 1 : 0, 0, 0) }; }
      case SEL.isLiquidatable: return { result: w(0) };
    }
    rec.unexpected.push(`exchange selector ${sel}`);
    return { error: { message: "unexpected" } };
  }
  function rpc(m) {
    switch (m.method) {
      case "eth_call": return ethCall(m.params[0]);
      case "eth_getBlockByNumber": return { result: { timestamp: "0x" + T.toString(16) } };
      case "eth_chainId": return { result: "0x7b7b" };
      case "eth_estimateGas": return { result: "0x30000" };
      case "eth_getTransactionCount": return { result: "0x" + (5 + rec.raw.length).toString(16) };
      case "eth_gasPrice": return { result: "0x3e8" };
      case "eth_sendRawTransaction": rec.raw.push(m.params[0]); return { result: "0x" + String(rec.raw.length).padStart(64, "a") };
      case "eth_getTransactionReceipt": return { result: { status: "0x1" } };
    }
    rec.unexpected.push(`rpc ${m.method}`);
    return { error: { message: "unexpected" } };
  }
  globalThis.fetch = async (url, init = {}) => {
    const u = new URL(String(url));
    if (u.hostname === "rpc.test.mezo.org" && init.method === "POST") {
      const body = JSON.parse(init.body);
      return json(body.map((m) => ({ jsonrpc: "2.0", id: m.id, ...rpc(m) })));
    }
    if (u.hostname === "hermes.pyth.network") {
      rec.hermes.push({ url: String(url), headers: { ...init.headers }, redirect: init.redirect });
      const h = sc.hermes ?? {};
      if (h.status === 302) return new Response(null, { status: 302, headers: { Location: "https://evil.example/" } });
      if (h.status) return new Response("internal error " + API_KEY, { status: h.status });
      if (h.raw !== undefined) return new Response(h.raw, { status: 200 });
      return json(h.body ?? FIX);
    }
    if (u.hostname === "api.coinbase.com") { rec.spot.push(u.hostname); return json({ data: { amount: "66000.00" } }); }
    if (u.hostname === "api.kraken.com") { rec.spot.push(u.hostname); return json({ result: { XXBTZUSD: { c: ["66001.0", "1"] } } }); }
    if (u.hostname === "www.bitstamp.net") { rec.spot.push(u.hostname); return json({ last: "66002.0" }); }
    rec.unexpected.push(`host ${u.hostname}`);
    throw new Error(`unexpected request to ${u.hostname}`);
  };
  return rec;
}

// ------------------------------------------------------------------ run the real handlers
const baseEnv = () => ({
  KEEPER_PRIVATE_KEY: KEEPER_KEY, PRICE_SIGNER_PRIVATE_KEY: SIGNER_KEY, PYTH_API_KEY: API_KEY,
  RPC_URL: "https://rpc.test.mezo.org", TICK_SECONDS: "15", RUN_SECONDS: "1", HEARTBEAT_SECONDS: "300",
  EXCHANGE_ADDRESS: EXCHANGE, ORACLE_ADDRESS: SIGNED, PYTH_ORACLE_ADDRESS: PYTH,
});
function kv() {
  const m = new Map();
  return { store: m, get: async (k, t) => (m.has(k) ? (t === "json" ? JSON.parse(m.get(k)) : m.get(k)) : null), put: async (k, v) => { m.set(k, v); } };
}

async function runOnce(sc, envPatch = {}, clockSec = T + 2) {
  useClock(clockSec * 1000);
  const logs = [];
  console.log = (...a) => logs.push(a.join(" "));
  const env = { ...baseEnv(), ...envPatch };
  const store = kv();
  env.KEEPER_STATE = store;
  const rec = stub(sc);
  let p;
  await worker.scheduled({ scheduledTime: clock }, env, { waitUntil: (x) => { p = x; } });
  const summary = await p;
  // /health on the same scenario (fresh stub so read counters start over)
  const hrec = stub(sc);
  const health = await (await worker.fetch(new Request("https://keeper.example/health"), env)).text();
  console.log = real.log;
  const txs = rec.raw.map((r) => { const t = parseTransaction(r); return { ...t, value: t.value ?? 0n }; }); // viem omits value 0
  const leak = [JSON.stringify(summary), [...store.store.values()].join(""), health, logs.join("\n")].join("\n");
  assert.ok(!leak.includes(API_KEY), "API key leaked into summary / KV / health / logs");
  assert.deepEqual([...rec.unexpected, ...hrec.unexpected], [], "unexpected requests");
  return { summary, tick: summary.ticks[0], rec, txs, health: JSON.parse(health), logs };
}
const decodeUpd = (data, withId) =>
  decodeAbiParameters(withId ? [{ type: "uint256" }, { type: "bytes[]" }] : [{ type: "bytes[]" }], "0x" + data.slice(10));
const priceTxs = (txs) => txs.filter((t) => [SEL.executeOrder, SEL.liquidate, SEL.pushPrice].includes(t.data.slice(0, 10)));
const carriesPrice = (t) => { const s = t.data.slice(0, 10); const d = decodeUpd(t.data, s !== SEL.pushPrice); return d[d.length - 1].length > 0; };

// ------------------------------------------------------------------ cases
test("pyth mode, heartbeat only: one pushPrice with the Hermes update and the fee as value", async () => {
  const r = await runOnce({ oracle: PYTH, fee: 1n });
  assert.equal(r.tick.oracle_mode, "pyth");
  assert.equal(r.tick.source, "pyth-hermes");
  assert.equal(r.tick.pushed, true);
  assert.deepEqual(r.tick.errors, []);
  assert.equal(r.txs.length, 1);
  const tx = r.txs[0];
  assert.equal(tx.to.toLowerCase(), EXCHANGE.toLowerCase());
  assert.equal(tx.chainId, 31611);
  assert.equal(tx.value, 1n);
  assert.equal(tx.data, SEL.pushPrice + encodeAbiParameters([{ type: "bytes[]" }], [FIX_DATA]).slice(2));
  assert.equal(r.rec.hermes.length, 1);
  const h = r.rec.hermes[0];
  assert.equal(new URL(h.url).hostname, "hermes.pyth.network");
  assert.equal(h.headers.Authorization, `Bearer ${API_KEY}`);
  assert.equal(h.redirect, "manual");
  assert.deepEqual(r.rec.spot, []); // no exchange spot APIs in pyth mode
  const fees = r.rec.calls.filter((c) => c.sel === SEL.updateFee);
  assert.equal(fees.length, 1);
  assert.equal(fees[0].to, PYTH.toLowerCase());
  assert.equal(fees[0].data, SEL.updateFee + encodeAbiParameters([{ type: "bytes[]" }], [FIX_DATA]).slice(2));
  assert.equal(r.summary.oracle, PYTH.toLowerCase());
  assert.equal(r.summary.oracle_mode, "pyth");
  assert.equal(r.health.live.oracle_mode, "pyth");
  assert.equal(r.health.live.oracle, PYTH.toLowerCase());
});

test("pyth mode with a pending order and a liquidation: update + fee only on the first tx", async () => {
  const r = await runOnce({ oracle: PYTH, fee: 1n, pending: [{ oid: 7, createdAt: T - 100 }], open: [{ pid: 3, bust: 70000n * E18, long: true }] });
  assert.deepEqual(r.tick.filled, ["7"]);
  assert.deepEqual(r.tick.liquidated, ["3"]);
  assert.equal(r.txs.length, 2); // no extra heartbeat: the update was consumed by the fill
  const [a, b] = r.txs;
  assert.equal(a.data.slice(0, 10), SEL.executeOrder);
  const [oid, upd] = decodeUpd(a.data, true);
  assert.equal(oid, 7n);
  assert.deepEqual(upd, FIX_DATA);
  assert.equal(a.value, 1n);
  assert.equal(b.data.slice(0, 10), SEL.liquidate);
  const [pid, upd2] = decodeUpd(b.data, true);
  assert.equal(pid, 3n);
  assert.deepEqual(upd2, []);
  assert.equal(b.value, 0n);
});

test("updateFee above the cap: nothing price-carrying is sent; exactly the cap is sent", async () => {
  const over = await runOnce({ oracle: PYTH, fee: 10_001n });
  assert.equal(priceTxs(over.txs).length, 0);
  assert.match(over.tick.errors.join(" "), /updateFee 10001 wei > cap 10000/);
  const at = await runOnce({ oracle: PYTH, fee: 10_000n });
  assert.equal(at.txs.length, 1);
  assert.equal(at.txs[0].value, 10_000n);
});

for (const [name, sc, clockSec, re] of [
  ["HTTP 500", { hermes: { status: 500 } }, T + 2, /hermes HTTP 500/],
  ["302 redirect (not followed)", { hermes: { status: 302 } }, T + 2, /hermes HTTP 302/],
  ["invalid JSON", { hermes: { raw: "{not json " + API_KEY } }, T + 2, /hermes: invalid JSON/],
  ["stale publish_time", {}, T + 56, /stale/],
]) {
  test(`Hermes ${name}: no price-carrying tx, error recorded without the key`, async () => {
    const r = await runOnce({ oracle: PYTH, fee: 1n, ...sc }, {}, clockSec);
    assert.equal(r.txs.length, 0);
    assert.equal(r.rec.hermes.length, 1);
    assert.equal(r.rec.hermes[0].redirect, "manual");
    assert.match(r.tick.errors.join(" "), re);
    assert.ok(!r.tick.errors.join(" ").includes(API_KEY));
  });
}

test("PYTH_API_KEY unset in pyth mode: no tx, no crash, no Hermes request", async () => {
  const r = await runOnce({ oracle: PYTH }, { PYTH_API_KEY: undefined });
  assert.equal(r.txs.length, 0);
  assert.equal(r.rec.hermes.length, 0);
  assert.match(r.tick.errors.join(" "), /PYTH_API_KEY is not set/);
});

test("PYTH_ORACLE_ADDRESS unset while the exchange uses Pyth: treated as unknown oracle", async () => {
  const r = await runOnce({ oracle: PYTH }, { PYTH_ORACLE_ADDRESS: undefined });
  assert.equal(r.txs.length, 0);
  assert.equal(r.tick.oracle_mode, null);
  assert.equal(r.rec.hermes.length, 0);
  assert.match(r.tick.errors.join(" "), /unknown oracle/);
});

for (const [name, sc] of [
  ["unknown oracle", { oracle: "0x" + "12".repeat(20) }],
  ["oracle() read failed", { oracleError: true }],
]) {
  test(`${name}: no Hermes, no spot APIs, no price-carrying tx`, async () => {
    const r = await runOnce({ ...sc, pending: [{ oid: 7, createdAt: T - 100 }] });
    assert.equal(r.tick.oracle_mode, null);
    assert.equal(r.rec.hermes.length, 0);
    assert.deepEqual(r.rec.spot, []);
    assert.equal(r.txs.filter(carriesPrice).length, 0);
    assert.equal(r.txs.filter((t) => t.data.slice(0, 10) === SEL.pushPrice).length, 0);
    assert.match(r.tick.errors.join(" "), /unknown oracle 0x/);
    assert.equal(r.health.live.oracle_mode, null);
  });
}

test("signed mode is unchanged: one pushPrice, value 0, a report signed by PRICE_SIGNER, no Hermes", async () => {
  const r = await runOnce({ oracle: SIGNED, fee: 1n });
  assert.equal(r.tick.oracle_mode, "signed");
  assert.equal(r.tick.source, "keeper-signed");
  assert.equal(r.rec.hermes.length, 0);
  assert.equal(r.rec.calls.filter((c) => c.sel === SEL.updateFee).length, 0);
  assert.equal(r.rec.spot.length, 3);
  assert.equal(r.txs.length, 1);
  const tx = r.txs[0];
  assert.equal(tx.value, 0n);
  assert.equal(tx.chainId, 31611);
  assert.equal(tx.data.slice(0, 10), SEL.pushPrice);
  const [upd] = decodeUpd(tx.data, false);
  assert.equal(upd.length, 1);
  const [price, t, sig] = decodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "bytes" }], upd[0]);
  assert.equal(price, 6600100000000n * 10n ** 10n); // median(66000, 66001, 66002)
  assert.equal(t, BigInt(T + 2)); // min(now, block.timestamp + 5)
  const digest = keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }], [31611n, BigInt(SIGNED), price, t]));
  assert.equal(await recoverMessageAddress({ message: { raw: digest }, signature: sig }), privateKeyToAccount(SIGNER_KEY).address);
  assert.equal(r.txs.length && (await recoverTxSender(r.rec.raw[0])), privateKeyToAccount(KEEPER_KEY).address);
  assert.equal(r.summary.oracle_mode, "signed");
  assert.equal(r.summary.signed_oracle, SIGNED);
});

async function recoverTxSender(raw) {
  const { recoverTransactionAddress } = await import("viem");
  return recoverTransactionAddress({ serializedTransaction: raw });
}
