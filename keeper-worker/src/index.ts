/**
 * Bustline testnet keeper as a Cloudflare Worker.
 *
 * Port of keeper/perp_keeper (monitor.Keeper.poll_once + SignedSource + TestnetExecutor/EnvSigner), Telegram skipped.
 * Cron fires every minute; each invocation runs ticks every ~15s for ~45s and pushes a fresh signed price at least
 * once per run. Mezo TESTNET only (chainId 31611, rpc.test.mezo.org). Key = secret KEEPER_PRIVATE_KEY (never logged).
 */
import { encodeAbiParameters, keccak256, type Hex } from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

export interface Env {
  KEEPER_PRIVATE_KEY: string;
  KEEPER_STATE?: KVNamespace;
  RPC_URL?: string;
  TICK_SECONDS?: string;
  RUN_SECONDS?: string;
  HEARTBEAT_SECONDS?: string;
}

const TESTNET_HOST = "rpc.test.mezo.org";
const CHAIN_ID = 31611;
const EXCHANGE = "0x5e941EEA56DEE50924950E86f24624Be37f02050" as const; // deployments/testnet.json HouseExchange
const ORACLE = "0x83401Fc1B16DbCa09531241Dad49700248C8c72c" as const; // SignedPriceOracle
const HARVEST_BATCH = 32n;
const SCAN_WINDOW = 500;
const MAX_SPREAD_BPS = 50;
const MIN_SOURCES = 2;
const PUBLISH_SKEW_MARGIN = 5; // < SignedPriceOracle.maxSkew (10 s)
const SUBREQUEST_BUDGET = 44; // Workers Free: 50 subrequests / invocation; keep headroom for the KV write
const UA = { "User-Agent": "mezo-perp-keeper/0.2" };

// keeper/abi/HouseExchange.selectors.json
const SEL = {
  currentPrice: "0x9d1b464a",
  lastPrice: "0x053f14da",
  houseCash: "0xba1d61cf",
  queueTotal: "0x498991d9",
  orderCount: "0x2453ffa8",
  openPositionIds: "0x96cf4e7c",
  pendingOrderIds: "0x8915ce0a",
  getOrder: "0xd09ef241",
  bustPriceOf: "0x8a8c6842",
  isLiquidatable: "0x211a4443",
  getPosition: "0xeb02c301",
  executeOrder: "0x33e7dddb",
  liquidate: "0xf6614170",
  pushPrice: "0x066f2eb6",
  harvest: "0xddc63262",
} as const;

class RpcError extends Error {}

// ------------------------------------------------------------------ JSON-RPC (batched to save subrequests)
type Call = { method: string; params: unknown[] };
type Res = { result?: any; error?: { message?: string; data?: unknown } };

class Rpc {
  count = 0;
  private id = 0;
  constructor(readonly url: string) {
    if (new URL(url).hostname !== TESTNET_HOST) throw new RpcError(`refusing: '${url}' is not the Mezo testnet RPC`);
  }
  async batch(calls: Call[]): Promise<Res[]> {
    if (calls.length === 0) return [];
    this.count++;
    const body = calls.map((c) => ({ jsonrpc: "2.0", id: ++this.id, method: c.method, params: c.params }));
    const r = await fetch(this.url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...UA },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    if (!r.ok) throw new RpcError(`rpc http ${r.status}`);
    const out = (await r.json()) as any;
    const arr: any[] = Array.isArray(out) ? out : [out];
    const byId = new Map(arr.map((x) => [x.id, x]));
    return body.map((b) => byId.get(b.id) ?? { error: { message: "missing batch response" } });
  }
  async call(method: string, params: unknown[] = []): Promise<any> {
    const [r] = await this.batch([{ method, params }]);
    return ok(r);
  }
}

function ok(r: Res): any {
  if (r.error) throw new RpcError(r.error.message ?? JSON.stringify(r.error));
  return r.result;
}
const ethCall = (data: string): Call => ({ method: "eth_call", params: [{ to: EXCHANGE, data }, "latest"] });
const u256 = (...v: (bigint | number)[]) => v.map((x) => BigInt(x).toString(16).padStart(64, "0")).join("");
function words(hex: string): bigint[] {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  const w: bigint[] = [];
  for (let i = 0; i + 64 <= h.length; i += 64) w.push(BigInt("0x" + h.slice(i, i + 64)));
  return w;
}
function dynUintArray(hex: string): bigint[] {
  const w = words(hex);
  const off = Number(w[0] / 32n);
  const n = Number(w[off]);
  return w.slice(off + 1, off + 1 + n);
}

// ------------------------------------------------------------------ chain reads (chain.ExchangeReader)
interface Snapshot {
  blockTs: number;
  price: bigint | null;
  priceUpdatedAt: number;
  priceError: string | null;
  lastPrice: bigint | null;
  lastTime: number;
  houseCash: bigint;
  queueTotal: bigint;
  orderCount: number;
  openIds: bigint[];
  pending: bigint[];
  chainId: number;
}

async function snapshot(rpc: Rpc, cursor: number): Promise<Snapshot> {
  const r = await rpc.batch([
    ethCall(SEL.currentPrice),
    ethCall(SEL.lastPrice),
    { method: "eth_getBlockByNumber", params: ["latest", false] },
    ethCall(SEL.houseCash),
    ethCall(SEL.queueTotal),
    ethCall(SEL.orderCount),
    ethCall(SEL.openPositionIds),
    ethCall(SEL.pendingOrderIds + u256(cursor, cursor + SCAN_WINDOW)), // contract clamps `to` to orderCount
    { method: "eth_chainId", params: [] },
  ]);
  let price: bigint | null = null, upd = 0, err: string | null = null;
  if (r[0].error) err = r[0].error.message ?? "currentPrice reverted";
  else [price, upd] = ((w) => [w[0], Number(w[1])] as [bigint, number])(words(r[0].result));
  let lp: bigint | null = null, lt = 0;
  if (!r[1].error) { const w = words(r[1].result); lp = w[0]; lt = Number(w[1]); }
  return {
    blockTs: Number(BigInt(ok(r[2]).timestamp)),
    price, priceUpdatedAt: upd, priceError: err, lastPrice: lp, lastTime: lt,
    houseCash: words(ok(r[3]))[0],
    queueTotal: words(ok(r[4]))[0],
    orderCount: Number(words(ok(r[5]))[0]),
    openIds: dynUintArray(ok(r[6])),
    pending: dynUintArray(ok(r[7])),
    chainId: Number(BigInt(ok(r[8]))),
  };
}

// ------------------------------------------------------------------ prices (prices.SignedSource)
async function getJson(url: string): Promise<any> {
  const r = await fetch(url, { headers: UA, signal: AbortSignal.timeout(8_000) });
  if (!r.ok) throw new Error(`${url} http ${r.status}`);
  return r.json();
}
const FETCHERS: [string, () => Promise<number>][] = [
  ["coinbase", async () => parseFloat((await getJson("https://api.coinbase.com/v2/prices/BTC-USD/spot")).data.amount)],
  ["kraken", async () => { const r = (await getJson("https://api.kraken.com/0/public/Ticker?pair=XBTUSD")).result; return parseFloat((Object.values(r)[0] as any).c[0]); }],
  ["bitstamp", async () => parseFloat((await getJson("https://www.bitstamp.net/api/v2/ticker/btcusd/")).last)],
];

/** Python round(): half-to-even. */
function roundHalfEven(x: number): number {
  const f = Math.floor(x), d = x - f;
  if (d > 0.5) return f + 1;
  if (d < 0.5) return f;
  return f % 2 === 0 ? f : f + 1;
}
function median(v: number[]): number {
  const s = [...v].sort((a, b) => a - b), m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

class PriceUnavailable extends Error {}
interface PriceBundle { price: bigint; publishTime: number; data: Hex[]; fee: bigint; source: string; spots: Record<string, number> }

async function spot(rpc: Rpc): Promise<{ price: bigint; spots: Record<string, number> }> {
  rpc.count += FETCHERS.length;
  const res = await Promise.allSettled(FETCHERS.map(([, f]) => f()));
  const spots: Record<string, number> = {};
  const vals: number[] = [];
  res.forEach((r, i) => { if (r.status === "fulfilled" && r.value > 0) { vals.push(r.value); spots[FETCHERS[i][0]] = r.value; } });
  if (vals.length < MIN_SOURCES) throw new PriceUnavailable(`only ${vals.length} spot sources answered`);
  const med = median(vals);
  if (((Math.max(...vals) - Math.min(...vals)) / med) * 10_000 > MAX_SPREAD_BPS) throw new PriceUnavailable(`spot sources disagree: ${vals}`);
  return { price: BigInt(roundHalfEven(med * 1e8)) * 10n ** 10n, spots }; // 8-decimal precision, WAD
}

/** keccak256(abi.encode(chainid, oracle, price, publishTime)) — abi.report_hash / SignedPriceOracle.digest pre-EIP-191. */
export function reportHash(chainId: number, oracle: Hex, price: bigint, t: number): Hex {
  return keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }], [BigInt(chainId), BigInt(oracle), price, BigInt(t)]));
}
/** abi.encode(uint256 price, uint256 publishTime, bytes signature) — abi.signed_report. */
export function signedReport(price: bigint, t: number, sig: Hex): Hex {
  return encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "bytes" }], [price, BigInt(t), sig]);
}
/** EIP-191 personal_sign over the 32-byte hash, r||s||v (v = 27/28) — signer.sign_hash_eip191. */
export async function signReport(acct: PrivateKeyAccount, price: bigint, t: number): Promise<Hex> {
  const sig = await acct.signMessage({ message: { raw: reportHash(CHAIN_ID, ORACLE, price, t) } });
  return signedReport(price, t, sig);
}

async function fetchBundle(rpc: Rpc, acct: PrivateKeyAccount, blockTs: number): Promise<PriceBundle> {
  const { price, spots } = await spot(rpc);
  // Python uses time.time(). Mezo testnet block timestamps can lag wall clock by ~10 s and the oracle rejects
  // t > block.timestamp + maxSkew (10 s) with FutureReport, so clamp to the latest block time + a 5 s margin.
  const t = Math.min(Math.floor(Date.now() / 1000), blockTs + PUBLISH_SKEW_MARGIN);
  return { price, publishTime: t, data: [await signReport(acct, price, t)], fee: 0n, source: "keeper-signed", spots };
}

// ------------------------------------------------------------------ executor (chain.TestnetExecutor + signer.EnvSigner)
const bytesArr = [{ type: "bytes[]" }] as const;
const uintBytesArr = [{ type: "uint256" }, { type: "bytes[]" }] as const;
const cdExecute = (oid: bigint, upd: Hex[]) => (SEL.executeOrder + encodeAbiParameters(uintBytesArr, [oid, upd]).slice(2)) as Hex;
const cdLiquidate = (pid: bigint, upd: Hex[]) => (SEL.liquidate + encodeAbiParameters(uintBytesArr, [pid, upd]).slice(2)) as Hex;
const cdPush = (upd: Hex[]) => (SEL.pushPrice + encodeAbiParameters(bytesArr, [upd]).slice(2)) as Hex;
const cdHarvest = (n: bigint) => (SEL.harvest + u256(n)) as Hex;

class Executor {
  private lastNonce = -1;
  txs: { kind: string; hash: string; status: string }[] = [];
  constructor(readonly rpc: Rpc, readonly acct: PrivateKeyAccount, readonly deadline: number) {}

  /** Sequential: estimate → pending nonce → sign legacy EIP-155 tx → send → wait for receipt. One tx in flight at a time. */
  async send(kind: string, data: Hex, value = 0n): Promise<string> {
    const from = this.acct.address;
    const tx = { from, to: EXCHANGE, data, value: "0x" + value.toString(16) };
    const [est, nonceR, gp] = await this.rpc.batch([
      { method: "eth_estimateGas", params: [tx] },
      { method: "eth_getTransactionCount", params: [from, "pending"] },
      { method: "eth_gasPrice", params: [] },
    ]);
    const gas = (BigInt(ok(est)) * 13n) / 10n + 20_000n;
    let nonce = Number(BigInt(ok(nonceR)));
    if (nonce <= this.lastNonce) nonce = this.lastNonce + 1; // RPC lagging behind our own previous tx
    const g = BigInt(ok(gp)) * 2n;
    const gasPrice = g > 1000n ? g : 1000n;
    const raw = await this.acct.signTransaction({ type: "legacy", chainId: CHAIN_ID, to: EXCHANGE, data, value, gas, gasPrice, nonce });
    const hash = (await this.rpc.call("eth_sendRawTransaction", [raw])) as string;
    this.lastNonce = nonce;
    const rec = { kind, hash, status: "pending" };
    this.txs.push(rec);
    const until = Math.max(this.deadline, Date.now() + 20_000);
    while (Date.now() < until) {
      await sleep(1500);
      let rc: any = null;
      try { rc = await this.rpc.call("eth_getTransactionReceipt", [hash]); } catch { rc = null; } // flaky RPC: keep polling
      if (rc) {
        if (Number(BigInt(rc.status)) !== 1) { rec.status = "reverted"; throw new RpcError(`tx reverted: ${hash}`); }
        rec.status = "ok";
        return hash;
      }
    }
    throw new RpcError(`no receipt yet: ${hash}`);
  }
  execute = (oid: bigint, u: Hex[], fee: bigint) => this.send(`fill#${oid}`, cdExecute(oid, u), fee);
  liquidate = (pid: bigint, u: Hex[], fee: bigint) => this.send(`liquidate#${pid}`, cdLiquidate(pid, u), fee);
  push = (u: Hex[], fee: bigint) => this.send("push", cdPush(u), fee);
  harvest = (n: bigint) => this.send("harvest", cdHarvest(n));
}

// ------------------------------------------------------------------ one tick (monitor.Keeper.poll_once)
interface RunState { cursor: number; lastPush: number; pushedThisRun: boolean; heartbeat: number }
interface TickOut {
  at: string; filled: string[]; waiting: string[]; liquidated: string[]; harvested: boolean; at_risk: string[];
  pushed: boolean; source: string | null; price: string | null; errors: string[]; snapshot?: Record<string, unknown>;
}
const fmt = (w: bigint | null) => (w === null ? null : (Number(w) / 1e18).toFixed(2));

async function tick(rpc: Rpc, ex: Executor, acct: PrivateKeyAccount, st: RunState): Promise<TickOut> {
  const now = Date.now() / 1000;
  const out: TickOut = { at: new Date().toISOString(), filled: [], waiting: [], liquidated: [], harvested: false, at_risk: [], pushed: false, source: null, price: null, errors: [] };
  const s = await snapshot(rpc, st.cursor);
  if (s.chainId !== CHAIN_ID) throw new RpcError(`refusing: chainId ${s.chainId} != ${CHAIN_ID}`);
  out.snapshot = {
    block_ts: s.blockTs, onchain_price: fmt(s.price ?? s.lastPrice), price_age_s: Math.max(0, s.blockTs - (s.price !== null ? s.priceUpdatedAt : s.lastTime)),
    settleable: s.price !== null, house_cash: fmt(s.houseCash), queued: fmt(s.queueTotal), open: s.openIds.map(String), orders: s.orderCount,
  };
  const end = Math.min(s.orderCount, st.cursor + SCAN_WINDOW);
  const pending = s.pending;
  const hbDue = !st.pushedThisRun || (st.heartbeat > 0 && now - st.lastPush >= st.heartbeat);

  let bundle: PriceBundle | null = null;
  if (pending.length || s.openIds.length || hbDue) {
    try { bundle = await fetchBundle(rpc, acct, s.blockTs); out.source = bundle.source; }
    catch (e) { out.errors.push(`price source unavailable — using on-chain price: ${String(e).slice(0, 200)}`); }
  }
  let price: bigint, ts: number;
  if (bundle) [price, ts] = [bundle.price, bundle.publishTime];
  else if (s.price !== null) [price, ts] = [s.price, s.priceUpdatedAt];
  else { out.errors.push(`oracle unavailable — fills/liquidations paused: ${s.priceError ?? ""}`.slice(0, 240)); return out; }
  out.price = fmt(price);
  let upd: Hex[] = bundle ? [...bundle.data] : [];
  let fee = bundle ? bundle.fee : 0n;
  const consume = (): [Hex[], bigint] => { const r: [Hex[], bigint] = [upd, fee]; upd = []; fee = 0n; return r; };

  // 1) pending orders → fill only at a price PUBLISHED strictly after the request
  if (pending.length) {
    const orders = await rpc.batch(pending.map((oid) => ethCall(SEL.getOrder + u256(oid))));
    for (let i = 0; i < pending.length; i++) {
      const oid = pending[i];
      const createdAt = Number(words(ok(orders[i]))[4]);
      if (ts <= createdAt) { out.waiting.push(String(oid)); continue; }
      const [u, f] = consume();
      try { await ex.execute(oid, u, f); out.filled.push(String(oid)); }
      catch (e) { [upd, fee] = [u, f]; out.errors.push(`fill #${oid} failed: ${String(e).slice(0, 200)}`); }
    }
    const rem = dynUintArray(await rpc.call("eth_call", [{ to: EXCHANGE, data: SEL.pendingOrderIds + u256(st.cursor, end) }, "latest"]));
    st.cursor = rem.length ? Number(rem.reduce((a, b) => (b < a ? b : a))) : end;
  } else {
    st.cursor = end;
  }

  // 2) liquidations (decided off-chain against the fresh price, enforced on-chain)
  if (s.openIds.length && rpc.count < SUBREQUEST_BUDGET) {
    const calls: Call[] = [];
    // with a fresh bundle: compare against bustPriceOf; otherwise ask isLiquidatable (same as monitor.py)
    for (const pid of s.openIds)
      calls.push(bundle ? ethCall(SEL.bustPriceOf + u256(pid)) : ethCall(SEL.isLiquidatable + u256(pid)), ethCall(SEL.getPosition + u256(pid)));
    const r = await rpc.batch(calls);
    for (let i = 0; i < s.openIds.length; i++) {
      const pid = s.openIds[i];
      const b = r[2 * i], p = r[2 * i + 1];
      if (b.error || p.error) continue;
      let liq: boolean;
      if (bundle) {
        const bust = words(b.result)[0];
        const isLong = words(p.result)[1] !== 0n;
        liq = isLong ? price <= bust : price >= bust;
      } else liq = words(b.result)[0] !== 0n;
      if (!liq) continue;
      out.at_risk.push(String(pid));
      const [u, f] = consume();
      try { await ex.liquidate(pid, u, f); out.liquidated.push(String(pid)); }
      catch (e) { [upd, fee] = [u, f]; out.errors.push(`liquidation #${pid} failed: ${String(e).slice(0, 200)}`); }
    }
  }

  // heartbeat: keep the on-chain price fresh for UIs (at least one push per cron run)
  if (bundle) {
    if (!upd.length) { st.lastPush = now; st.pushedThisRun = true; }
    else if (hbDue) {
      try { await ex.push(upd, fee); st.lastPush = now; st.pushedThisRun = true; out.pushed = true; }
      catch (e) { out.errors.push(`price push failed: ${String(e).slice(0, 200)}`); }
    }
  }

  // 3) queue harvest (catches leftovers)
  if (rpc.count < SUBREQUEST_BUDGET) {
    const [q, c] = await rpc.batch([ethCall(SEL.queueTotal), ethCall(SEL.houseCash)]);
    const queued = words(ok(q))[0], cash = words(ok(c))[0];
    if (queued > 0n && cash > 0n) {
      try { await ex.harvest(HARVEST_BATCH); out.harvested = true; }
      catch (e) { out.errors.push(`harvest failed: ${String(e).slice(0, 200)}`); }
    }
  }
  return out;
}

// ------------------------------------------------------------------ run loop + handlers
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function run(env: Env, scheduledTime: number): Promise<Record<string, unknown>> {
  const tickMs = Number(env.TICK_SECONDS ?? 15) * 1000;
  const runMs = Number(env.RUN_SECONDS ?? 46) * 1000;
  const start = Date.now();
  const stopAt = Math.min(start, scheduledTime || start) + runMs; // never start a tick after this (next cron at +60s)
  const rpc = new Rpc(env.RPC_URL ?? `https://${TESTNET_HOST}`);
  const acct = privateKeyToAccount(env.KEEPER_PRIVATE_KEY.trim() as Hex);
  const ex = new Executor(rpc, acct, stopAt + 10_000);
  const prev = env.KEEPER_STATE ? ((await env.KEEPER_STATE.get("state", "json")) as any) : null;
  const st: RunState = { cursor: prev?.cursor ?? 0, lastPush: prev?.lastPush ?? 0, pushedThisRun: false, heartbeat: Number(env.HEARTBEAT_SECONDS ?? 300) };
  const ticks: TickOut[] = [];
  for (let i = 0; ; i++) {
    const slot = start + i * tickMs;
    if (slot >= stopAt) break;
    if (Date.now() < slot) await sleep(slot - Date.now());
    if (Date.now() >= stopAt || rpc.count >= SUBREQUEST_BUDGET - 6) break;
    let t: TickOut;
    try { t = await tick(rpc, ex, acct, st); }
    catch (e) { t = { at: new Date().toISOString(), filled: [], waiting: [], liquidated: [], harvested: false, at_risk: [], pushed: false, source: null, price: null, errors: [`tick failed: ${String(e).slice(0, 240)}`] }; }
    ticks.push(t);
    const { snapshot: snap, ...rest } = t;
    console.log(`[keeper] tick ${i} ${JSON.stringify(snap ?? {})} | ${JSON.stringify(rest)}`);
  }
  const summary = {
    keeper: acct.address, scheduled: new Date(scheduledTime || start).toISOString(), ran_ms: Date.now() - start,
    subrequests: rpc.count, cursor: st.cursor, last_push: st.lastPush ? new Date(st.lastPush * 1000).toISOString() : null,
    txs: ex.txs, ticks,
  };
  console.log(`[keeper] run done ${JSON.stringify({ ticks: ticks.length, subrequests: rpc.count, txs: ex.txs })}`);
  if (env.KEEPER_STATE) {
    // Workers KV free tier = 1000 writes/day: write on even minutes, or whenever something other than a push happened.
    const eventful = ticks.some((t) => t.filled.length || t.liquidated.length || t.harvested || t.errors.length);
    if (eventful || new Date(scheduledTime || start).getUTCMinutes() % 2 === 0) {
      await env.KEEPER_STATE.put("state", JSON.stringify({ cursor: st.cursor, lastPush: st.lastPush }));
      await env.KEEPER_STATE.put("last", JSON.stringify(summary));
    }
  }
  return summary;
}

async function health(env: Env): Promise<Response> {
  const rpc = new Rpc(env.RPC_URL ?? `https://${TESTNET_HOST}`);
  const live: Record<string, unknown> = {};
  try {
    const s = await snapshot(rpc, 0);
    const t = s.price !== null ? s.priceUpdatedAt : s.lastTime;
    live.chain_id = s.chainId;
    live.block_ts = s.blockTs;
    live.onchain_price = fmt(s.price ?? s.lastPrice);
    live.price_publish_time = t;
    live.price_age_s = Math.max(0, s.blockTs - t);
    live.settleable = s.price !== null;
    live.price_error = s.priceError;
    live.open_positions = s.openIds.map(String);
    live.order_count = s.orderCount;
    live.pending_orders = s.pending.map(String);
  } catch (e) { live.error = String(e).slice(0, 200); }
  const last = env.KEEPER_STATE ? await env.KEEPER_STATE.get("last", "json") : null;
  return Response.json({ worker: "bustline-keeper", network: "mezo-testnet", live, last_run: last }, { headers: { "Cache-Control": "no-store" } });
}

export default {
  async scheduled(ev: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(run(env, ev.scheduledTime));
  },
  async fetch(req: Request, env: Env): Promise<Response> {
    const u = new URL(req.url);
    if (u.pathname === "/health" || u.pathname === "/") return health(env);
    return new Response("not found", { status: 404 });
  },
};
