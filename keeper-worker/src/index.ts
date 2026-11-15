/**
 * Bustline testnet keeper as a Cloudflare Worker.
 *
 * Port of keeper/perp_keeper (monitor.Keeper.poll_once + SignedSource + TestnetExecutor/EnvSigner), Telegram skipped.
 * Cron fires every minute; each invocation runs ticks every ~15s for ~45s and pushes a fresh price at least once per
 * run. The price source follows the exchange's on-chain `oracle()` every tick: SignedPriceOracle (ORACLE_ADDRESS) →
 * keeper-signed report; PythPullOracle (PYTH_ORACLE_ADDRESS) → Pyth Hermes update (hermes.ts); anything else → no price
 * push. So switching / rolling back the oracle on-chain needs no redeploy. Mezo TESTNET only (chainId 31611,
 * rpc.test.mezo.org). Keys = secrets KEEPER_PRIVATE_KEY / PRICE_SIGNER_PRIVATE_KEY / PYTH_API_KEY (never logged).
 */
import { encodeAbiParameters, keccak256, type Hex } from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { PAUSED_SELECTOR, parsePaused, pauseGate } from "./pause.ts";
import { errorSignature, shouldWriteState } from "./kvgate.ts";
import { MAX_UPDATE_FEE_WEI, ORACLE_SELECTOR, PYTH_BTC_USD, UPDATE_FEE_SELECTOR, hermesUrl, parseHermes, pickSource, wordToAddress } from "./hermes.ts";

export interface Env {
  KEEPER_PRIVATE_KEY: string;
  /** v3 splits the keys: price reports are signed by SignedPriceOracle.signer, txs are sent by the keeper.
   *  Secret, optional: unset = sign with KEEPER_PRIVATE_KEY (v2, where both are the same EOA). */
  PRICE_SIGNER_PRIVATE_KEY?: string;
  KEEPER_STATE?: KVNamespace;
  RPC_URL?: string;
  TICK_SECONDS?: string;
  RUN_SECONDS?: string;
  HEARTBEAT_SECONDS?: string;
  /** HouseExchange address (required; wrangler.toml [vars], currently v3.1 = deployments/testnet-v3.1.json). */
  EXCHANGE_ADDRESS?: string;
  /** SignedPriceOracle address (required) — part of the signed-report digest. Used while the exchange's on-chain
   *  `oracle()` equals it; the active oracle is read on-chain every tick. */
  ORACLE_ADDRESS?: string;
  /** PythPullOracle address (wrangler.toml [vars], optional): used while the exchange's `oracle()` equals it. Unset = no Pyth mode. */
  PYTH_ORACLE_ADDRESS?: string;
  /** Pyth Hermes API key (secret, sent as a Bearer token, never logged). Required only in Pyth mode. */
  PYTH_API_KEY?: string;
  /** "1" = HouseExchange v3: also call rebalance() / forwardBtc() (v2 has neither: leave unset for v2). */
  SP_OPS?: string;
  /** Minimum seconds between Stability Pool checks (default = HEARTBEAT_SECONDS). */
  SP_INTERVAL_SECONDS?: string;
}

const TESTNET_HOST = "rpc.test.mezo.org";
const CHAIN_ID = 31611;
// Contract addresses come ONLY from wrangler.toml [vars] (currently v3.1 = deployments/testnet-v3.1.json). There is no fallback: a
// missing var must stop the Worker, not silently point it at the frozen v2 market (fail closed).
// Set from env at the start of every invocation (configure). env is fixed per deployment, so module scope is safe.
let EXCHANGE: Hex = "0x0000000000000000000000000000000000000000";
let ORACLE: Hex = "0x0000000000000000000000000000000000000000";
let PYTH_ORACLE: Hex | undefined;
function addr(v: string | undefined, name: string): Hex {
  const a = (v ?? "").trim();
  if (!a) throw new Error(`${name} is not set (wrangler.toml [vars]); refusing to run`);
  if (!/^0x[0-9a-fA-F]{40}$/.test(a)) throw new Error(`${name} is not an address: '${a}'`);
  if (/^0x0{40}$/.test(a)) throw new Error(`${name} is the zero address`);
  return a as Hex;
}
function configure(env: Env): void {
  EXCHANGE = addr(env.EXCHANGE_ADDRESS, "EXCHANGE_ADDRESS");
  ORACLE = addr(env.ORACLE_ADDRESS, "ORACLE_ADDRESS");
  PYTH_ORACLE = env.PYTH_ORACLE_ADDRESS?.trim() ? addr(env.PYTH_ORACLE_ADDRESS, "PYTH_ORACLE_ADDRESS") : undefined; // unset = no Pyth mode
}
const HARVEST_BATCH = 32n;
const SCAN_WINDOW = 500;
const MAX_SPREAD_BPS = 50;
const MIN_SOURCES = 2;
const PUBLISH_SKEW_MARGIN = 5; // < SignedPriceOracle.maxSkew (10 s)
const SUBREQUEST_BUDGET = 44; // Workers Free: 50 subrequests / invocation; keep headroom for the KV write
const UA = { "User-Agent": "bustline-keeper/0.2" };

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
  // v3 (Stability Pool)
  rebalance: "0x7d7c2a1c",
  rebalanceAction: "0xe249f67d",
  forwardBtc: "0x9eca6d72",
  forwardableBtc: "0x52594520",
  spDeposit: "0xfaefef87",
  spWithdrawable: "0xaf5deacf",
  // v3.1 (emergency pause) — v3 has no paused(): the call reverts and is read as "not paused" (pause.ts)
  paused: PAUSED_SELECTOR,
  oracle: ORACLE_SELECTOR,
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
  /** v3.1 `paused()`; false on v3 (no such function) */
  paused: boolean;
  /** exchange's current `oracle()` (lowercase); zero address if the read failed */
  oracle: string;
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
    ethCall(SEL.paused), // same batch = no extra subrequest; never passed through ok() (reverts on v3)
    ethCall(SEL.oracle), // same batch; not through ok(): a failed read becomes the zero address = unknown oracle
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
    paused: parsePaused(r[9]),
    oracle: r[10]?.error ? wordToAddress(null) : wordToAddress(r[10]?.result),
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

// ------------------------------------------------------------------ prices (prices.HermesSource, for PythPullOracle)
async function fetchHermes(rpc: Rpc, apiKey: string | undefined): Promise<PriceBundle> {
  const key = apiKey?.trim();
  if (!key) throw new PriceUnavailable("PYTH_API_KEY is not set (Pyth mode)");
  if (!PYTH_ORACLE) throw new PriceUnavailable("PYTH_ORACLE_ADDRESS is not set (Pyth mode)");
  rpc.count += 1;
  const r = await fetch(hermesUrl(PYTH_BTC_USD), { headers: { ...UA, Authorization: "Bearer " + key }, redirect: "manual", signal: AbortSignal.timeout(8_000) });
  if (!r.ok) throw new PriceUnavailable(`hermes HTTP ${r.status}`); // never the body / headers (key)
  let json: unknown;
  try { json = await r.json(); } catch { throw new PriceUnavailable("hermes: invalid JSON"); }
  const h = parseHermes(json, PYTH_BTC_USD, Math.floor(Date.now() / 1000));
  const cd = UPDATE_FEE_SELECTOR + encodeAbiParameters(bytesArr, [h.data]).slice(2);
  const w = words(await rpc.call("eth_call", [{ to: PYTH_ORACLE, data: cd }, "latest"]));
  if (!w.length) throw new PriceUnavailable("updateFee returned nothing");
  const fee = w[0];
  if (fee > MAX_UPDATE_FEE_WEI) throw new PriceUnavailable(`updateFee ${fee} wei > cap ${MAX_UPDATE_FEE_WEI}`);
  // publishTime = Hermes publish_time (no block-time clamp: that is only for SignedPriceOracle.maxSkew)
  return { price: h.price, publishTime: h.publishTime, data: h.data, fee, source: "pyth-hermes", spots: {} };
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
  rebalance = () => this.send("rebalance", SEL.rebalance as Hex);
  forwardBtc = () => this.send("forwardBtc", SEL.forwardBtc as Hex);
}

// ------------------------------------------------------------------ one tick (monitor.Keeper.poll_once)
interface RunState {
  cursor: number; lastPush: number; pushedThisRun: boolean; heartbeat: number;
  spOps: boolean; spInterval: number; lastSp: number;
  /** last `paused()` state seen (persisted in KV so a long pause is logged once, on the transition) */
  paused: boolean;
}
interface TickOut {
  at: string; filled: string[]; waiting: string[]; liquidated: string[]; harvested: boolean; at_risk: string[];
  sp?: string[];
  /** v3.1: exchange paused this tick (fills / liquidations skipped). Not an error: it must not trigger KV writes. */
  paused?: boolean;
  /** price source picked from the exchange's on-chain oracle(); null = unknown oracle (no price push) */
  oracle_mode?: "signed" | "pyth" | null;
  pushed: boolean; source: string | null; price: string | null; errors: string[]; snapshot?: Record<string, unknown>;
}
const fmt = (w: bigint | null) => (w === null ? null : (Number(w) / 1e18).toFixed(2));

/** `signer` signs price reports (SignedPriceOracle.signer); transactions are sent by `ex` (the keeper account). */
async function tick(rpc: Rpc, ex: Executor, signer: PrivateKeyAccount, st: RunState, pythKey: string | undefined): Promise<TickOut> {
  const now = Date.now() / 1000;
  const out: TickOut = { at: new Date().toISOString(), filled: [], waiting: [], liquidated: [], harvested: false, at_risk: [], pushed: false, source: null, price: null, errors: [] };
  const s = await snapshot(rpc, st.cursor);
  if (s.chainId !== CHAIN_ID) throw new RpcError(`refusing: chainId ${s.chainId} != ${CHAIN_ID}`);
  out.snapshot = {
    block_ts: s.blockTs, onchain_price: fmt(s.price ?? s.lastPrice), price_age_s: Math.max(0, s.blockTs - (s.price !== null ? s.priceUpdatedAt : s.lastTime)),
    settleable: s.price !== null, house_cash: fmt(s.houseCash), queued: fmt(s.queueTotal), open: s.openIds.map(String), orders: s.orderCount,
    paused: s.paused, oracle: s.oracle,
  };
  // v3.1 pause: skip fills + liquidations (they revert EnforcedPause), hold the scan cursor, log only on a change
  const gate = pauseGate(s.paused, st.paused);
  st.paused = gate.paused;
  if (gate.log) console.log(`[keeper] ${gate.log}`);
  if (s.paused) out.paused = true;
  const end = Math.min(s.orderCount, st.cursor + SCAN_WINDOW);
  const pending = s.pending;
  const hbDue = !st.pushedThisRun || (st.heartbeat > 0 && now - st.lastPush >= st.heartbeat);

  let bundle: PriceBundle | null = null;
  const mode = pickSource(s.oracle, ORACLE, PYTH_ORACLE);
  out.oracle_mode = mode;
  // unknown oracle: no bundle (no fetch, no heartbeat push); fills / liquidations fall back to the on-chain price with
  // empty update data, exactly as when the price source is down
  if (mode === null) out.errors.push(`unknown oracle ${s.oracle} — not pushing prices`);
  else if ((!gate.skipTrading && (pending.length || s.openIds.length)) || hbDue) {
    try { bundle = mode === "signed" ? await fetchBundle(rpc, signer, s.blockTs) : await fetchHermes(rpc, pythKey); out.source = bundle.source; }
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
  if (!gate.moveCursor) {
    // paused: leave st.cursor alone so orders requested during the pause (requestClose) are scanned after unpause
  } else if (pending.length) {
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
  if (!gate.skipTrading && s.openIds.length && rpc.count < SUBREQUEST_BUDGET) {
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

  // 3) queue harvest (catches leftovers). v3: harvest also tops up from the Stability Pool, so a deposit counts.
  if (rpc.count < SUBREQUEST_BUDGET) {
    // a deposit only helps while SP withdrawals are open; otherwise harvest would pay 0 every tick
    const calls = [ethCall(SEL.queueTotal), ethCall(SEL.houseCash)];
    if (st.spOps) calls.push(ethCall(SEL.spDeposit), ethCall(SEL.spWithdrawable));
    const [q, c, d, w] = await rpc.batch(calls);
    const queued = words(ok(q))[0], cash = words(ok(c))[0];
    const spOpen = !!w && !w.error && words(w.result)[0] !== 0n;
    const dep = spOpen && d && !d.error ? words(d.result)[0] : 0n;
    if (queued > 0n && (cash > 0n || dep > 0n)) {
      try { await ex.harvest(HARVEST_BATCH); out.harvested = true; }
      catch (e) { out.errors.push(`harvest failed: ${String(e).slice(0, 200)}`); }
    }
  }

  // 4) v3 Stability Pool upkeep: at most once per SP_INTERVAL_SECONDS (default: heartbeat), and a tx only when the
  //    on-chain previews say there is work. Each tx costs ~3 + receipt polls subrequests, so keep a margin of 12.
  if (st.spOps && now - st.lastSp >= st.spInterval && rpc.count < SUBREQUEST_BUDGET - 12) {
    st.lastSp = now;
    out.sp = [];
    const [ra, fb, wd] = await rpc.batch([ethCall(SEL.rebalanceAction), ethCall(SEL.forwardableBtc), ethCall(SEL.spWithdrawable)]);
    let action = ra.error ? 0n : words(ra.result)[0];
    // a withdrawal (2) while SP withdrawals are blocked would only emit SpWithdrawBlocked: skip the tx
    if (action === 2n && (wd.error || words(wd.result)[0] === 0n)) action = 0n;
    const btc = fb.error ? 0n : words(fb.result)[0];
    if (ra.error || fb.error) out.errors.push(`sp preview failed: ${String(ra.error?.message ?? fb.error?.message).slice(0, 200)}`);
    if (action !== 0n) {
      try { await ex.rebalance(); out.sp.push(action === 1n ? "deposit" : "withdraw"); }
      catch (e) { out.errors.push(`rebalance failed: ${String(e).slice(0, 200)}`); }
    }
    if (btc > 0n && rpc.count < SUBREQUEST_BUDGET - 8) {
      try { await ex.forwardBtc(); out.sp.push(`forwardBtc ${btc}`); }
      catch (e) { out.errors.push(`forwardBtc failed: ${String(e).slice(0, 200)}`); }
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
  configure(env);
  // never start a tick after this; hard cap 55 s after the scheduled minute (next cron at +60 s). A late retry of an old
  // schedule therefore does nothing.
  const stopAt = Math.min(start + runMs, (scheduledTime || start) + 55_000);
  const rpc = new Rpc(env.RPC_URL ?? `https://${TESTNET_HOST}`);
  const acct = privateKeyToAccount(env.KEEPER_PRIVATE_KEY.trim() as Hex);
  const ex = new Executor(rpc, acct, stopAt + 10_000);
  const signerKey = env.PRICE_SIGNER_PRIVATE_KEY?.trim();
  const signer = signerKey ? privateKeyToAccount(signerKey as Hex) : acct;
  const prev = env.KEEPER_STATE ? ((await env.KEEPER_STATE.get("state", "json")) as any) : null;
  const heartbeat = Number(env.HEARTBEAT_SECONDS ?? 300);
  const st: RunState = {
    cursor: prev?.cursor ?? 0, lastPush: prev?.lastPush ?? 0, pushedThisRun: false, heartbeat,
    spOps: env.SP_OPS === "1", spInterval: Number(env.SP_INTERVAL_SECONDS ?? heartbeat), lastSp: prev?.lastSp ?? 0,
    paused: prev?.paused === true,
  };
  const ticks: TickOut[] = [];
  for (let i = 0; ; i++) {
    const slot = start + i * tickMs;
    if (slot >= stopAt) break;
    if (Date.now() < slot) await sleep(slot - Date.now());
    if (Date.now() >= stopAt || rpc.count >= SUBREQUEST_BUDGET - 6) break;
    let t: TickOut;
    try { t = await tick(rpc, ex, signer, st, env.PYTH_API_KEY); }
    catch (e) { t = { at: new Date().toISOString(), filled: [], waiting: [], liquidated: [], harvested: false, at_risk: [], pushed: false, source: null, price: null, errors: [`tick failed: ${String(e).slice(0, 240)}`] }; }
    ticks.push(t);
    const { snapshot: snap, ...rest } = t;
    console.log(`[keeper] tick ${i} ${JSON.stringify(snap ?? {})} | ${JSON.stringify(rest)}`);
  }
  const lastSnap = [...ticks].reverse().find((t) => t.snapshot);
  const summary = {
    keeper: acct.address, price_signer: signer.address, exchange: EXCHANGE, signed_oracle: ORACLE, pyth_oracle: PYTH_ORACLE ?? null,
    // the oracle the exchange actually used (last tick's on-chain oracle()) and the price source picked for it
    oracle: lastSnap?.snapshot?.oracle ?? null, oracle_mode: lastSnap ? lastSnap.oracle_mode : null, sp_ops: st.spOps, paused: st.paused, scheduled: new Date(scheduledTime || start).toISOString(), ran_ms: Date.now() - start,
    subrequests: rpc.count, cursor: st.cursor, last_push: st.lastPush ? new Date(st.lastPush * 1000).toISOString() : null,
    txs: ex.txs, ticks,
  };
  console.log(`[keeper] run done ${JSON.stringify({ ticks: ticks.length, subrequests: rpc.count, txs: ex.txs })}`);
  if (env.KEEPER_STATE) {
    // Workers KV free tier = 1000 writes/day. One key per write; write only when the cursor moved, something other than
    // a push happened, or every 10 minutes so /health stays reasonably fresh (~144 writes/day baseline). Errors alone
    // write only when their kind changes (incl. appearing / clearing), at most once per 300 s (kvgate.ts): a steady
    // error state (unknown oracle, Hermes down, ...) is left to the periodic write instead of writing every minute.
    const activity = ticks.some((t) => t.filled.length || t.liquidated.length || t.harvested || t.sp?.length);
    // A pause is not "eventful" by itself (that would write every minute); only the transition is persisted.
    const pauseChanged = st.paused !== (prev?.paused === true);
    const errSig = errorSignature(ticks);
    const nowSec = Math.floor(Date.now() / 1000);
    const gate = shouldWriteState({
      activity, pauseChanged, cursorMoved: st.cursor !== (prev?.cursor ?? 0),
      periodic: new Date(scheduledTime || start).getUTCMinutes() % 10 === 0,
      errSig, prevErrSig: typeof prev?.errSig === "string" ? prev.errSig : undefined,
      prevWroteAt: typeof prev?.wroteAt === "number" ? prev.wroteAt : undefined, nowSec,
    });
    if (gate.write) {
      // a failed put (e.g. daily write limit) must not fail the run: txs are already sent; the next write catches up
      try { await env.KEEPER_STATE.put("state", JSON.stringify({ cursor: st.cursor, lastPush: st.lastPush, lastSp: st.lastSp, paused: st.paused, errSig, wroteAt: nowSec, last: summary })); }
      catch (e) { console.log(`[keeper] KV state write failed (${gate.reason}): ${String(e).slice(0, 160)}`); }
    }
  }
  return summary;
}

async function health(env: Env): Promise<Response> {
  configure(env);
  const rpc = new Rpc(env.RPC_URL ?? `https://${TESTNET_HOST}`);
  const live: Record<string, unknown> = {};
  try {
    const s = await snapshot(rpc, 0);
    const t = s.price !== null ? s.priceUpdatedAt : s.lastTime;
    live.exchange = EXCHANGE;
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
    live.paused = s.paused;
    live.oracle = s.oracle;
    live.oracle_mode = pickSource(s.oracle, ORACLE, PYTH_ORACLE);
  } catch (e) { live.error = String(e).slice(0, 200); }
  const last = env.KEEPER_STATE ? ((await env.KEEPER_STATE.get("state", "json")) as any)?.last ?? null : null;
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
