"use client";
import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { formatUnits, maxUint256, parseUnits, type Abi, type Address, type Hex } from "viem";
import { HouseExchangeAbi, MockERC20Abi } from "@/abi";
import { BTC_FAUCET_URL, EXPLORER_URL, mezoProtocol, type Deployment } from "@/lib/config";
import { publicClient } from "@/lib/chain";
import {
  BorrowerOperationsAbi, CCR, ICR_RECOMMENDED, ICR_WARN, MCR, GAS_COMPENSATION,
  collForIcr, computeHints, openTroveQuote, readProtocol, readTrove, repayQuote, withdrawQuote,
  type Protocol, type Trove,
} from "@/lib/mezo";
import { num, usd } from "@/lib/format";
import type { Guide } from "./PriceChart";

const EX = HouseExchangeAbi as Abi;
const E20 = MockERC20Abi as Abi;

export type WriteOpts = { value?: bigint; from?: Address; onHash?: (h: Hex) => void };
export type WriteFn = (address: Address, abi: Abi, functionName: string, args: readonly unknown[], opts?: WriteOpts) => Promise<Hex>;

export type Route = "btc" | "trove" | "musd";
type StepKey = "openTrove" | "withdrawMUSD" | "approve" | "requestOpen";
type StepStatus = "todo" | "running" | "done" | "skipped" | "failed";
type Step = { key: StepKey; status: StepStatus; hash?: Hex; error?: string; note?: string };
/** One deposit-and-trade run. Amounts are decimal strings (wei) so the flow survives a reload via localStorage. */
type Flow = { route: Route; who: Address; coll: string; borrow: string; margin: string; isLong: boolean; lev: number; steps: Step[] };

const ROUTE_LABEL: Record<Route, string> = { btc: "Start with BTC", trove: "From my trove", musd: "Deposit MUSD" };
const STEPS: Record<Route, StepKey[]> = {
  btc: ["openTrove", "approve", "requestOpen"],
  trove: ["withdrawMUSD", "approve", "requestOpen"],
  musd: ["approve", "requestOpen"],
};
const flowKey = (who: Address) => `bustline.flow.${who.toLowerCase()}`;
const loadFlow = (who: Address): Flow | null => {
  try { const s = window.localStorage.getItem(flowKey(who)); return s ? (JSON.parse(s) as Flow) : null; } catch { return null; }
};
const saveFlow = (f: Flow | null, who: Address) => {
  try { if (f) window.localStorage.setItem(flowKey(who), JSON.stringify(f)); else window.localStorage.removeItem(flowKey(who)); } catch { /* storage unavailable */ }
};
const isFinished = (f: Flow) => f.steps.every((s) => s.status === "done" || s.status === "skipped");

const wei = (s: string, d = 18) => { try { const v = parseUnits((s || "0").trim(), d); return v > 0n ? v : 0n; } catch { return 0n; } };
const btc = (v?: bigint, d = 4) => (v === undefined ? "–" : Number(formatUnits(v, 18)).toLocaleString("en-US", { maximumFractionDigits: d, minimumFractionDigits: d }));
const pct = (r?: bigint) => (r === undefined || r === 0n ? "–" : `${(Number(formatUnits(r, 16))).toFixed(1)}%`);
const shortH = (h: string) => `${h.slice(0, 6)}…${h.slice(-4)}`;
const errMsg = (e: unknown) => (e as { shortMessage?: string }).shortMessage ?? (e as Error).message ?? String(e);

function Row({ k, v, cls }: { k: React.ReactNode; v: React.ReactNode; cls?: string }) {
  return <div className="kv"><span className="k">{k}</span><span className={`v ${cls ?? ""}`}>{v}</span></div>;
}

/** ICR verdict for a planned trove. `block` stops submission. */
function icrCheck(r: bigint | undefined, p?: Protocol): { level: "ok" | "info" | "warn" | "block"; text?: string } {
  if (r === undefined) return { level: "ok" };
  if (r < MCR) return { level: "block", text: "ICR below 110% — the protocol rejects it (instantly liquidatable)." };
  if (p?.recovery && r < CCR) return { level: "block", text: "Recovery mode: new and adjusted troves need ICR ≥ 150%." };
  if (r < ICR_WARN) return { level: "warn", text: "ICR is close to 110%. A small BTC drop liquidates the trove — add BTC or borrow less." };
  if (r < ICR_RECOMMENDED) return { level: "info", text: "Below the recommended 150%. If the system enters recovery mode, this trove can be liquidated below 150%." };
  return { level: "ok" };
}

export default function Funding(props: {
  d: Deployment; who?: Address; readOnly: boolean; busy: boolean;
  side: "long" | "short"; lev: number; marginW: bigint; musd?: bigint; mark?: bigint; bust?: bigint;
  write: WriteFn; run: (label: string, fn: () => Promise<unknown>) => Promise<void>;
  connect?: () => void; needConnect: boolean; onLines: (g: Guide[]) => void;
}) {
  const { d, who, readOnly, busy, side, lev, marginW, write, run } = props;
  const mz = useMemo(() => mezoProtocol(d), [d]);
  const proto = useQuery({ queryKey: ["mezo-proto", mz.BorrowerOperations], queryFn: () => readProtocol(mz), refetchInterval: 15000, retry: 1 });
  const trove = useQuery({ queryKey: ["mezo-trove", mz.TroveManager, who], queryFn: () => readTrove(mz, who!), enabled: !!who, refetchInterval: 6000, retry: 1 });
  const btcBal = useQuery({ queryKey: ["btc-bal", who], queryFn: () => publicClient.getBalance({ address: who! }), enabled: !!who, refetchInterval: 10000 });
  const p = proto.data;
  const t: Trove | undefined = trove.data;
  const hasTrove = t?.status === "active";
  const troveRoutes = !!p?.price; // PriceFeed readable (testnet); false on the local fork or when the feed is stale

  const [route, setRoute] = useState<Route>("btc");
  const [flow, setFlowState] = useState<Flow | null>(null);
  const [collIn, setCollIn] = useState("");
  const [collTouched, setCollTouched] = useState(false);
  const [borrowIn, setBorrowIn] = useState("1800");
  const [moreIn, setMoreIn] = useState("");
  const [repayIn, setRepayIn] = useState("");

  const setFlow = (f: Flow | null) => { setFlowState(f); if (who) saveFlow(f, who); };
  useEffect(() => { setFlowState(who ? loadFlow(who) : null); }, [who]);
  const flowActive = !!flow && !isFinished(flow);

  // Route auto-selection. An unfinished flow locks its route: after openTrove succeeds the trove exists, and switching to
  // "From my trove" here would hide the remaining steps (and invite a second borrow).
  useEffect(() => {
    if (flow && flowActive) { setRoute(flow.route); return; }
    if (proto.isFetched && !troveRoutes) { setRoute("musd"); return; }
    if (!t) return;
    setRoute((r) => (hasTrove && r === "btc" ? "trove" : !hasTrove && r === "trove" ? "btc" : r));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hasTrove, !!t, flowActive, troveRoutes, proto.isFetched]);

  const borrow = wei(borrowIn);
  // default collateral: ICR 160% for the default borrow, until the user types a value
  useEffect(() => {
    if (collTouched || !p?.price) return;
    const q = openTroveQuote(p, borrow, 0n);
    setCollIn(formatUnits(collForIcr(q.debt, p.price, 1_600_000_000_000_000_000n), 18));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [p?.price, borrow, collTouched]);
  useEffect(() => { if (!moreIn && marginW > 0n) setMoreIn(formatUnits(marginW, 18)); }, [marginW, moreIn]);

  const coll = wei(collIn);
  const more = wei(moreIn);
  const repay = wei(repayIn);
  const oq = p ? openTroveQuote(p, borrow, coll) : undefined;
  const wq = p && t && hasTrove ? withdrawQuote(p, t, more) : undefined;
  const rq = p && t && hasTrove ? repayQuote(p, t, repay) : undefined;
  const curIcr = p?.price && t && hasTrove ? (t.coll * p.price) / t.debt : undefined;
  const curLiq = t && hasTrove && t.coll > 0n ? (MCR * t.debt) / t.coll : undefined;

  // Client-side hint preview for the planned trove (recomputed again right before sending).
  const hintArgs = route === "btc" && oq && coll > 0n ? { coll, principal: oq.principal } : route === "trove" && wq && t && more > 0n ? { coll: t.coll, principal: wq.principal } : undefined;
  const hints = useQuery({
    queryKey: ["mezo-hints", String(hintArgs?.coll), String(hintArgs?.principal)],
    queryFn: () => computeHints(mz, hintArgs!.coll, hintArgs!.principal),
    enabled: !!hintArgs && troveRoutes, staleTime: 30000, retry: 0,
  });

  // Lines for the shared chart: trove liquidation (ICR 110%) next to the position's bust line.
  const planLiq = route === "btc" && oq && coll > 0n ? oq.liq : route === "trove" && wq && more > 0n ? wq.liq : curLiq;
  const lineLabel = route === "btc" ? "TROVE LIQ 110% (planned)" : route === "trove" && more > 0n ? "TROVE LIQ 110% (after borrow)" : "TROVE LIQ 110%";
  useEffect(() => {
    const show = planLiq && planLiq > 0n && (route !== "musd" || hasTrove);
    props.onLines(show ? [{ price: Number(formatUnits(planLiq, 18)), label: route === "musd" ? "TROVE LIQ 110%" : lineLabel, color: "#2F5D7C" }] : []);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [planLiq, route, hasTrove, lineLabel]);

  // ---- validation of the planned run --------------------------------------------------------------------------------
  const musd = props.musd ?? 0n;
  const problems: string[] = [];
  let icrV: ReturnType<typeof icrCheck> = { level: "ok" };
  if (marginW === 0n) problems.push("Enter a margin.");
  if (route === "btc") {
    if (!oq || !p) problems.push("Reading the MUSD protocol…");
    else {
      if (oq.netDebt < p.minNetDebt) problems.push(`Net debt must be at least ${num(p.minNetDebt, 0)} MUSD (borrow + 0.1% fee).`);
      if (coll === 0n) problems.push("Enter the BTC to deposit.");
      if (btcBal.data !== undefined && coll > btcBal.data) problems.push("Not enough BTC in the wallet — use the faucet.");
      if (marginW > borrow + musd) problems.push("Margin is larger than the MUSD you borrow plus your wallet balance.");
      icrV = icrCheck(oq.icr, p);
      if (icrV.level === "block") problems.push(icrV.text!);
    }
  } else if (route === "trove") {
    if (!wq || !p) problems.push("Reading your trove…");
    else {
      if (p.recovery) problems.push("Recovery mode: borrowing more from a trove is not allowed (it would lower ICR).");
      if (more === 0n) problems.push("Enter the MUSD to borrow.");
      if (more > wq.maxAmount) problems.push(`Above this trove's borrowing capacity (max ${num(wq.maxAmount)} MUSD).`);
      if (marginW > more + musd) problems.push("Margin is larger than the MUSD you borrow plus your wallet balance.");
      icrV = icrCheck(wq.icr, p);
      if (icrV.level === "block") problems.push(icrV.text!);
    }
  } else if (props.musd !== undefined && marginW > musd) problems.push("Not enough MUSD in the wallet.");

  // ---- step runner ---------------------------------------------------------------------------------------------------
  const stepLabel = (k: StepKey, f: Flow) => {
    const s = f.isLong ? "long" : "short";
    if (k === "openTrove") return `Open trove — deposit ${btc(BigInt(f.coll))} BTC, borrow ${num(BigInt(f.borrow))} MUSD`;
    if (k === "withdrawMUSD") return `Borrow ${num(BigInt(f.borrow))} MUSD from your trove`;
    if (k === "approve") return "Approve MUSD for Bustline (first time only)";
    return `Request ${s} — ${num(BigInt(f.margin))} MUSD × ${f.lev}x`;
  };

  async function execStep(f: Flow, i: number, onHash: (h: Hex) => void): Promise<Partial<Step>> {
    const s = f.steps[i];
    // A tx from an earlier attempt: settle it first instead of sending a second one.
    if (s.hash) {
      const rc = await publicClient.waitForTransactionReceipt({ hash: s.hash, timeout: 90_000 }).catch(() => null);
      if (rc?.status === "success") return { status: "done" };
      if (!rc) throw new Error(`earlier tx ${shortH(s.hash)} is not confirmed yet — wait, then resume`);
    }
    const coll0 = BigInt(f.coll), borrow0 = BigInt(f.borrow), margin0 = BigInt(f.margin);
    if (s.key === "openTrove") {
      const tr = await readTrove(mz, f.who);
      if (tr.status === "active") return { status: "done", note: "trove is open" };
      const pr = await readProtocol(mz);
      const q = openTroveQuote(pr, borrow0, coll0);
      if (pr.recovery && (q.icr ?? 0n) < CCR) throw new Error("recovery mode: ICR must be ≥ 150%");
      const h = await computeHints(mz, coll0, q.principal);
      return { status: "done", hash: await write(mz.BorrowerOperations, BorrowerOperationsAbi as Abi, "openTrove", [borrow0, h.upper, h.lower], { value: coll0, onHash }) };
    }
    if (s.key === "withdrawMUSD") {
      const [pr, tr] = await Promise.all([readProtocol(mz), readTrove(mz, f.who)]);
      if (tr.status !== "active") throw new Error("no active trove");
      const q = withdrawQuote(pr, tr, borrow0);
      const h = await computeHints(mz, tr.coll, q.principal);
      return { status: "done", hash: await write(mz.BorrowerOperations, BorrowerOperationsAbi as Abi, "withdrawMUSD", [borrow0, h.upper, h.lower], { onHash }) };
    }
    if (s.key === "approve") {
      const allowance = (await publicClient.readContract({ address: d.MUSD, abi: E20, functionName: "allowance", args: [f.who, d.HouseExchange] })) as bigint;
      if (allowance >= margin0) return { status: "skipped", note: "already approved" };
      // Unlimited approval on purpose: "first time only" (spec 5.3). Every call is one signature for Passport BTC accounts.
      return { status: "done", hash: await write(d.MUSD, E20, "approve", [d.HouseExchange, maxUint256], { onHash }) };
    }
    const bal = (await publicClient.readContract({ address: d.MUSD, abi: E20, functionName: "balanceOf", args: [f.who] })) as bigint;
    if (bal < margin0) throw new Error(`MUSD balance ${num(bal)} < margin ${num(margin0)}`);
    return { status: "done", hash: await write(d.HouseExchange, EX, "requestOpen", [f.isLong, margin0, BigInt(f.lev), 0n], { onHash }) };
  }

  const runFlow = (f0: Flow) => {
    const label = f0.route === "musd" ? `requestOpen ${f0.isLong ? "long" : "short"} ${num(BigInt(f0.margin))} MUSD × ${f0.lev}x` : `${ROUTE_LABEL[f0.route]}: ${f0.isLong ? "long" : "short"} ${num(BigInt(f0.margin))} MUSD × ${f0.lev}x`;
    return run(label, async () => {
      let f = f0;
      const upd = (i: number, patch: Partial<Step>) => {
        f = { ...f, steps: f.steps.map((s, j) => (j === i ? { ...s, ...patch } : s)) };
        setFlow(f);
      };
      let last: Hex | undefined;
      for (let i = 0; i < f.steps.length; i++) {
        if (f.steps[i].status === "done" || f.steps[i].status === "skipped") continue;
        upd(i, { status: "running", error: undefined });
        try {
          const res = await execStep(f, i, (h) => upd(i, { hash: h }));
          upd(i, res);
          last = res.hash ?? last;
        } catch (e) {
          upd(i, { status: "failed", error: errMsg(e) });
          throw new Error(`step ${i + 1} (${f.steps[i].key}) failed: ${errMsg(e)}`);
        }
      }
      return last;
    });
  };

  const start = () => {
    if (!who) return;
    const amount = route === "btc" ? borrow : route === "trove" ? more : 0n;
    const f: Flow = { route, who, coll: String(route === "btc" ? coll : 0n), borrow: String(amount), margin: String(marginW), isLong: side === "long", lev, steps: STEPS[route].map((key) => ({ key, status: "todo" as StepStatus })) };
    setFlow(f);
    void runFlow(f);
  };
  const failedAt = flow ? flow.steps.findIndex((s) => s.status === "failed" || s.status === "running" || s.status === "todo") : -1;

  const doRepay = () => run(`repayMUSD ${num(repay)}`, async () => {
    const [pr, tr] = await Promise.all([readProtocol(mz), readTrove(mz, who!)]);
    const q = repayQuote(pr, tr, repay);
    if (repay > q.maxRepay) throw new Error(`max repayable is ${num(q.maxRepay)} MUSD (net debt must stay ≥ ${num(pr.minNetDebt, 0)})`);
    const h = await computeHints(mz, tr.coll, q.principal);
    return write(mz.BorrowerOperations, BorrowerOperationsAbi as Abi, "repayMUSD", [repay, h.upper, h.lower]);
  });

  // ---- view ------------------------------------------------------------------------------------------------------------
  const options: Route[] = flowActive ? [flow!.route] : [hasTrove ? "trove" : "btc", "musd"];
  const steps = flow && (flowActive || isFinished(flow)) ? flow : null;
  const canStart = !!who && !readOnly && !busy && problems.length === 0 && !flowActive;
  const markN = props.mark;
  const dist = (x?: bigint) => (x && markN ? `${(((Number(x) - Number(markN)) / Number(markN)) * 100).toFixed(1)}%` : "");
  const rateTxt = (bps?: number) => (bps === undefined ? "–" : `${(bps / 100).toFixed(2)}% / yr, simple`);

  return (
    <div className="funding" data-panel="funding">
      <div className="lbl left fundlbl">FUND THIS TRADE</div>
      <div className="seg route" role="radiogroup" aria-label="deposit method">
        {options.map((r) => (
          <button key={r} role="radio" aria-checked={route === r} className={route === r ? "on" : ""} disabled={flowActive || (r !== "musd" && !troveRoutes)}
            title={flowActive ? "Finish or discard the current steps first" : r !== "musd" && !troveRoutes ? "MUSD PriceFeed unavailable" : undefined}
            onClick={() => setRoute(r)}>
            {ROUTE_LABEL[r]}
          </button>
        ))}
      </div>
      {!troveRoutes && proto.isFetched && <div className="fine">Trove routes need the Mezo PriceFeed{proto.isError ? "" : " (not readable here — local fork or stale feed)"}. Deposit MUSD you already hold.</div>}
      {hasTrove && !flowActive && <div className="fine">You already have a trove, so “Start with BTC” is replaced by “From my trove” (one trove per address).</div>}
      {p?.recovery && <div className="note warn">Recovery mode (TCR {pct(p.tcr)} &lt; 150%): new troves need ICR ≥ 150%; borrowing more from a trove is paused.</div>}

      {route === "btc" && (
        <div className="fundbox">
          <div className="kv"><span className="k">BTC in wallet</span><span className="v">{btc(btcBal.data, 5)} BTC</span></div>
          <a className="faucet" href={BTC_FAUCET_URL} target="_blank" rel="noreferrer">Need testnet BTC? Faucet · 0.05 BTC per claim ↗</a>
          <div className="lbl">DEPOSIT (BTC)</div>
          <input aria-label="btc collateral" className="num" value={collIn} onChange={(e) => { setCollTouched(true); setCollIn(e.target.value); }} />
          <div className="inrow">
            {[150, 200, 250].map((x) => (
              <button key={x} className="chipbtn" disabled={!p?.price || !oq} onClick={() => { setCollTouched(true); setCollIn(formatUnits(collForIcr(oq!.debt, p!.price!, BigInt(x) * 10n ** 16n), 18)); }}>ICR {x}%</button>
            ))}
          </div>
          <div className="lbl">BORROW (MUSD)</div>
          <input aria-label="musd borrow" className="num" value={borrowIn} onChange={(e) => setBorrowIn(e.target.value)} />
          <div className="readouts">
            <Row k="Borrowing fee (0.1%, once)" v={oq ? `${num(oq.fee)} MUSD` : "–"} />
            <Row k="Gas compensation (added to debt)" v={`${num(GAS_COMPENSATION, 0)} MUSD`} />
            <Row k={`Trove debt · net ≥ ${num(p?.minNetDebt, 0)}`} v={oq ? `${num(oq.debt)} MUSD` : "–"} />
            <Row k="Interest" v={rateTxt(p?.interestBps)} />
            <Row k="Trove ICR" v={pct(oq?.icr)} cls={icrV.level === "block" || icrV.level === "warn" ? "neg" : icrV.level === "info" ? "amber" : "pos"} />
            <Row k="Trove liquidation (110%)" v={oq && coll > 0n ? `${usd(oq.liq)} ${dist(oq.liq)}` : "–"} />
            <Row k="Stays in your wallet" v={borrow > marginW ? `${num(borrow - marginW)} MUSD` : "–"} />
          </div>
        </div>
      )}

      {route === "trove" && t && hasTrove && (
        <div className="fundbox">
          <Row k="Trove collateral" v={`${btc(t.coll, 5)} BTC`} />
          <Row k="Trove debt" v={`${num(t.debt)} MUSD`} />
          <Row k="Trove ICR" v={pct(curIcr)} cls={curIcr && curIcr < ICR_RECOMMENDED ? "amber" : "pos"} />
          <Row k="Interest (fixed at open)" v={rateTxt(t.interestBps)} />
          <div className="lbl">BORROW MORE (MUSD)</div>
          <div className="inrow">
            <button className="chipbtn" disabled={marginW === 0n} onClick={() => setMoreIn(formatUnits(marginW, 18))}>= margin</button>
            <button className="chipbtn" disabled={!wq} onClick={() => setMoreIn(formatUnits(wq!.maxAmount, 18))}>Max</button>
            <input aria-label="musd borrow more" className="num" value={moreIn} onChange={(e) => setMoreIn(e.target.value)} />
          </div>
          <div className="readouts">
            <Row k="Borrowing fee (0.1%)" v={wq ? `${num(wq.fee)} MUSD` : "–"} />
            <Row k="Capacity left" v={wq ? `${num(wq.maxAmount)} MUSD` : "–"} />
            <Row k="ICR after" v={pct(wq?.icr)} cls={icrV.level === "block" || icrV.level === "warn" ? "neg" : icrV.level === "info" ? "amber" : "pos"} />
            <Row k="Trove liquidation (110%)" v={wq ? `${usd(wq.liq)} ${dist(wq.liq)}` : "–"} />
          </div>
        </div>
      )}

      {route === "musd" && (
        <div className="fundbox">
          <Row k="MUSD in wallet" v={props.musd === undefined ? "–" : `${num(props.musd)} MUSD`} />
          <div className="fine">Approve once, then request the trade. MUSD comes from any source (a trove, a swap, a transfer).</div>
        </div>
      )}

      {icrV.text && icrV.level !== "block" && <div className={`note ${icrV.level === "warn" ? "warn" : ""}`}>{icrV.text}</div>}
      {(route === "btc" || route === "trove") && (
        <div className="twolines">
          <div><i className="sw" style={{ borderTop: `1.5px dashed ${side === "long" ? "var(--green)" : "var(--red)"}` }} /> Bust line <b className="num">{props.bust ? usd(props.bust) : "–"}</b> <span className="k">{dist(props.bust)}</span></div>
          <div><i className="sw trove" /> Trove liq. <b className="num">{planLiq ? usd(planLiq) : "–"}</b> <span className="k">{dist(planLiq)}</span></div>
          <div className="fine">The position busts at its own line; the trove is a separate loan and is liquidated only at its 110% line.</div>
        </div>
      )}
      {hintArgs && <div className="fine hint">Sorted-list hints {hints.data ? <span className="num">{shortH(hints.data.upper)} / {shortH(hints.data.lower)}</span> : hints.isError ? "unavailable" : "computing…"} · recomputed before sending</div>}

      {props.needConnect ? (
        <button className="primary" onClick={() => props.connect?.()}>Connect wallet</button>
      ) : flowActive ? (
        <button className="primary" disabled={busy || readOnly} onClick={() => runFlow(flow!)}>Resume from step {failedAt + 1}</button>
      ) : (
        <button className="primary" disabled={!canStart} onClick={start}>
          {route === "musd" ? `Request ${side} open` : `${ROUTE_LABEL[route]} → request ${side} · ${STEPS[route].length} steps`}
        </button>
      )}
      {readOnly && <div className="note">Read-only preview of {who ? shortH(who) : "–"} — nothing can be signed here.</div>}
      {!readOnly && !flowActive && problems.length > 0 && marginW > 0n && <div className="fine neg">{problems[0]}</div>}

      <ol className="steps" aria-label="progress">
        {(steps ? steps.steps : STEPS[route].map((key): Step => ({ key, status: "todo" }))).map((s: Step, i) => {
          const f = steps ?? { route, who: who ?? "0x", coll: String(coll), borrow: String(route === "btc" ? borrow : more), margin: String(marginW), isLong: side === "long", lev, steps: [] };
          return (
            <li key={s.key} className={`st ${s.status}`}>
              <span className="dot" aria-hidden>{s.status === "done" ? "✓" : s.status === "skipped" ? "–" : s.status === "failed" ? "!" : s.status === "running" ? "…" : i + 1}</span>
              <span className="sl">
                {stepLabel(s.key, f)}
                {s.note && <span className="k"> · {s.note}</span>}
                {s.hash && <> · <a className="num" href={`${EXPLORER_URL}/tx/${s.hash}`} target="_blank" rel="noreferrer">{shortH(s.hash)}</a></>}
                {s.error && <span className="err">{s.error}</span>}
              </span>
            </li>
          );
        })}
      </ol>
      {steps && (
        <div className="inrow">
          {isFinished(steps) ? <span className="fine pos">All steps confirmed. The keeper fills the order at the next price.</span> : <span className="fine">One signature per step. If a step fails, resume from it — MUSD already borrowed stays in your wallet.</span>}
          <button className="pill" disabled={busy} onClick={() => setFlow(null)}>{isFinished(steps) ? "Clear" : "Discard"}</button>
        </div>
      )}
      {!steps && route !== "musd" && <div className="fine">One signature per step (Passport BTC accounts send one call per signature).</div>}

      {hasTrove && t && rq && (
        <div className="fundbox repay">
          <div className="lbl left">REPAY TROVE</div>
          <div className="fine">After you close a position, its MUSD returns to your wallet. Repaying is never automatic.</div>
          <div className="inrow">
            <button className="chipbtn" disabled={rq.maxRepay === 0n || musd === 0n} onClick={() => setRepayIn(formatUnits(musd < rq.maxRepay ? musd : rq.maxRepay, 18))}>Max</button>
            <input aria-label="repay amount" className="num" placeholder="MUSD" value={repayIn} onChange={(e) => setRepayIn(e.target.value)} />
          </div>
          <Row k="Repayable now" v={`${num(rq.maxRepay)} MUSD`} />
          {rq.maxRepay === 0n && <div className="fine">Net debt is at the {num(p?.minNetDebt, 0)} MUSD minimum. Paying the rest means closing the trove (not done in this app).</div>}
          <button className="primary sm" disabled={busy || readOnly || repay === 0n || repay > rq.maxRepay || repay > musd} onClick={doRepay}>Repay trove</button>
        </div>
      )}
    </div>
  );
}

