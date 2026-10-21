"use client";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ConnectButton, useConnectModal } from "@rainbow-me/rainbowkit";
import { useAccount, useWriteContract } from "wagmi";
import { parseUnits, formatUnits, maxUint256, type Address, type Abi } from "viem";
import Providers from "./Providers";
import PriceChart, { type Candle, type Guide } from "./PriceChart";
import { HouseExchangeAbi, RebateStakingAbi, RebateTokenAbi, MockERC20Abi, MockOracleAbi } from "@/abi";
import { ANVIL_ACCOUNTS, MODE, RPC_URL, loadDeployment, type Deployment } from "@/lib/config";
import { publicClient, localWallet } from "@/lib/chain";
import { num, usd, signed } from "@/lib/format";

const EX = HouseExchangeAbi as Abi;
const E20 = MockERC20Abi as Abi;
const WAD = 10n ** 18n;
const r = <T,>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) =>
  publicClient.readContract({ address, abi, functionName, args }) as Promise<T>;

type Pos = { id: bigint; owner: Address; isLong: boolean; open: boolean; margin: bigint; size: bigint; entryPrice: bigint };
type Ord = { id: bigint; trader: Address; kind: number; status: number; isLong: boolean; createdAt: bigint; margin: bigint; size: bigint; positionId: bigint };

async function readMarket(d: Deployment) {
  const x = d.HouseExchange;
  const [[price, updatedAt], houseCash, queueTotal, equity, longOi, shortOi, mintRate, maxLev, bufDiv, orderCount, openIds, head, qlen, totalStaked, toStakers] =
    await Promise.all([
      r<readonly [bigint, bigint]>(x, EX, "lastPrice"), r<bigint>(x, EX, "houseCash"), r<bigint>(x, EX, "queueTotal"),
      r<bigint>(x, EX, "houseEquity"), r<bigint>(x, EX, "longOi"), r<bigint>(x, EX, "shortOi"), r<bigint>(x, EX, "mintRate"),
      r<bigint>(x, EX, "maxLeverage"), r<bigint>(x, EX, "bustBufferDiv"), r<bigint>(x, EX, "orderCount"),
      r<readonly bigint[]>(x, EX, "openPositionIds"), r<bigint>(x, EX, "queueHead"), r<bigint>(x, EX, "queueLength"),
      r<bigint>(d.RebateStaking, RebateStakingAbi as Abi, "totalStaked"), r<bigint>(x, EX, "totalToStakers"),
    ]);
  const positions = await Promise.all(openIds.map(async (id) => ({ id, ...(await r<Omit<Pos, "id">>(x, EX, "getPosition", [id])) })));
  const from = orderCount > 50n ? orderCount - 50n : 0n;
  const pend = await r<readonly bigint[]>(x, EX, "pendingOrderIds", [from, orderCount]);
  const orders = await Promise.all(pend.map(async (id) => ({ id, ...(await r<Omit<Ord, "id">>(x, EX, "getOrder", [id])) })));
  const queue: { idx: bigint; to: Address; amount: bigint }[] = [];
  for (let i = head; i < qlen && i < head + 100n; i++) {
    const [to, amount] = await r<readonly [Address, bigint]>(x, EX, "queueEntry", [i]);
    queue.push({ idx: i, to, amount });
  }
  const settleable = await r<readonly [bigint, bigint]>(x, EX, "currentPrice").then(() => true, () => false);
  const [tokenName, tokenSymbol] = await Promise.all([
    r<string>(d.RebateToken, RebateTokenAbi as Abi, "name"), r<string>(d.RebateToken, RebateTokenAbi as Abi, "symbol"),
  ]);
  return { settleable, tokenName, tokenSymbol, price, updatedAt, houseCash, queueTotal, equity, longOi, shortOi, mintRate, maxLev, bufDiv, positions, orders, queue, totalStaked, toStakers };
}

async function readUser(d: Deployment, who: Address) {
  const S = RebateStakingAbi as Abi;
  const [musd, allowance, rebate, staked, pending, queued, rtAllow] = await Promise.all([
    r<bigint>(d.MUSD, E20, "balanceOf", [who]), r<bigint>(d.MUSD, E20, "allowance", [who, d.HouseExchange]),
    r<bigint>(d.RebateToken, E20, "balanceOf", [who]), r<bigint>(d.RebateStaking, S, "staked", [who]),
    r<bigint>(d.RebateStaking, S, "pending", [who]), r<bigint>(d.HouseExchange, EX, "queuedOf", [who]),
    r<bigint>(d.RebateToken, E20, "allowance", [who, d.RebateStaking]),
  ]);
  return { musd, allowance, rebate, staked, pending, queued, rtAllow };
}

/** Client-side mirror of ImpactLib.bustPrice (hard-bust trigger incl. 5 bps buffer). */
function bustPrice(isLong: boolean, margin: bigint, size: bigint, entry: bigint, bufDiv: bigint) {
  if (size === 0n) return 0n;
  const dist = (entry * margin) / size;
  const buf = bufDiv === 0n ? 0n : entry / bufDiv;
  return isLong ? (entry > dist ? entry - dist : 0n) + buf : entry + dist - buf;
}
const ORACLE_LABEL: Record<string, string> = { pyth: "Pyth pull", signed: "keeper-signed, Skip-bounded", mock: "mock oracle" };

const rawPnl = (p: Pos, price: bigint) => {
  const d = ((price > p.entryPrice ? price - p.entryPrice : p.entryPrice - price) * p.size) / p.entryPrice;
  const up = price >= p.entryPrice;
  return up === p.isLong ? d : -d;
};

const f = (v?: bigint) => (v === undefined ? NaN : Number(formatUnits(v, 18)));
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const compact = (v?: bigint) => {
  if (v === undefined) return "–";
  const n = f(v);
  const a = Math.abs(n);
  return a >= 1e6 ? `$${(n / 1e6).toFixed(2)}M` : a >= 1e3 ? `$${(n / 1e3).toFixed(1)}K` : `$${n.toFixed(2)}`;
};

/** Public Coinbase candles (CORS *, no key) — display-only context for the chart; settlement uses the on-chain price. */
const GRAN = { "1m": 60, "5m": 300, "15m": 900 } as const;
type Gran = keyof typeof GRAN;
async function fetchCandles(g: Gran): Promise<Candle[]> {
  const res = await fetch(`https://api.exchange.coinbase.com/products/BTC-USD/candles?granularity=${GRAN[g]}`);
  if (!res.ok) throw new Error(`candles ${res.status}`);
  const rows = (await res.json()) as number[][];
  return rows.map((r) => ({ t: r[0], c: r[4] })).sort((a, b) => a.t - b.t).slice(-240);
}
async function fetchStats(): Promise<{ open: number; last: number; volume: number }> {
  const res = await fetch("https://api.exchange.coinbase.com/products/BTC-USD/stats");
  const j = await res.json();
  return { open: Number(j.open), last: Number(j.last), volume: Number(j.volume) };
}

function Row({ k, v, cls }: { k: React.ReactNode; v: React.ReactNode; cls?: string }) {
  return (
    <div className="kv">
      <span className="k">{k}</span>
      <span className={`v ${cls ?? ""}`}>{v}</span>
    </div>
  );
}

function Panel({ title, right, children, className, testid }: { title: string; right?: React.ReactNode; children: React.ReactNode; className?: string; testid?: string }) {
  return (
    <section className={`panel ${className ?? ""}`} data-panel={testid}>
      <div className="ph"><h3>{title}</h3>{right}</div>
      {children}
    </section>
  );
}

type Tab = "trade" | "house" | "mpaper";

function Dashboard() {
  const qc = useQueryClient();
  const { address: passportAddr } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { writeContractAsync } = useWriteContract();
  const [dep, setDep] = useState<Deployment | null | undefined>(undefined);
  const [acct, setAcct] = useState<Address>(ANVIL_ACCOUNTS[1].address);
  const [log, setLog] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [side, setSide] = useState<"long" | "short">("long");
  const [margin, setMargin] = useState("100");
  const [lev, setLev] = useState(50);
  const [stakeAmt, setStakeAmt] = useState("");
  const [tab, setTab] = useState<Tab>("trade");
  const [btab, setBtab] = useState<"positions" | "orders" | "activity" | "status">("positions");
  const [gran, setGran] = useState<Gran>("1m");

  useEffect(() => { loadDeployment().then(setDep); }, []);
  const who: Address | undefined = MODE === "local" ? acct : passportAddr;
  const m = useQuery({ queryKey: ["market", dep?.HouseExchange], queryFn: () => readMarket(dep!), enabled: !!dep, refetchInterval: 3000 });
  const u = useQuery({ queryKey: ["user", dep?.HouseExchange, who], queryFn: () => readUser(dep!, who!), enabled: !!dep && !!who, refetchInterval: 3000 });
  const candles = useQuery({ queryKey: ["candles", gran], queryFn: () => fetchCandles(gran), refetchInterval: 15000, retry: 1 });
  const stats = useQuery({ queryKey: ["cbstats"], queryFn: fetchStats, refetchInterval: 30000, retry: 1 });
  const push = (s: string) => setLog((l) => [`${new Date().toLocaleTimeString()} ${s}`, ...l].slice(0, 60));

  const write = useCallback(
    async (address: Address, abi: Abi, functionName: string, args: readonly unknown[], from?: Address) => {
      if (MODE === "local") {
        const w = await localWallet(from ?? acct);
        const hash = await w.writeContract({ address, abi, functionName, args, chain: w.chain, account: from ?? acct, gas: 3_000_000n } as never);
        const rc = await publicClient.waitForTransactionReceipt({ hash });
        if (rc.status !== "success") throw new Error(`tx reverted ${hash}`);
        return hash;
      }
      const hash = await writeContractAsync({ address, abi, functionName, args } as never);
      const rc = await publicClient.waitForTransactionReceipt({ hash });
      if (rc.status !== "success") throw new Error(`tx reverted ${hash}`);
      return hash;
    },
    [acct, writeContractAsync],
  );
  const run = async (label: string, fn: () => Promise<unknown>) => {
    setBusy(true);
    try {
      const res = await fn();
      push(`✅ ${label} ${typeof res === "string" ? res.slice(0, 12) + "…" : ""}`);
    } catch (e) {
      push(`❌ ${label}: ${(e as { shortMessage?: string }).shortMessage ?? (e as Error).message}`);
    } finally {
      setBusy(false);
      qc.invalidateQueries();
    }
  };

  const mk = m.data;
  const us = u.data;
  const marginW = (() => { try { return parseUnits(margin || "0", 18); } catch { return 0n; } })();
  const sizeW = marginW * BigInt(lev);
  const estBust = mk ? bustPrice(side === "long", marginW, sizeW, mk.price, mk.bufDiv) : 0n;
  const myPositions = (mk?.positions ?? []).filter((p) => who && p.owner.toLowerCase() === who.toLowerCase());
  const myOrders = (mk?.orders ?? []).filter((o) => who && o.trader.toLowerCase() === who.toLowerCase());
  const qIdx = (mk?.queue ?? []).findIndex((q) => who && q.to.toLowerCase() === who.toLowerCase());
  const aheadOfMe = qIdx >= 0 ? mk!.queue.slice(0, qIdx).reduce((a, q) => a + q.amount, 0n) : 0n;
  const marginInUse = myPositions.reduce((a, p) => a + p.margin, 0n);
  const openPnl = mk ? myPositions.reduce((a, p) => a + rawPnl(p, mk.price), 0n) : undefined;
  const maxLev = Number(mk?.maxLev ?? 100n);

  const guides = useMemo<Guide[]>(() => {
    const g: Guide[] = [];
    if (mk && marginW > 0n) g.push({ price: f(estBust), label: `BUST ${side.toUpperCase()} ${lev}x (order)`, color: side === "long" ? "#2E6B3F" : "#9B2C2C", dashed: true });
    for (const p of myPositions) {
      g.push({ price: f(bustPrice(p.isLong, p.margin, p.size, p.entryPrice, mk?.bufDiv ?? 2000n)), label: `#${p.id} BUST`, color: "#9B2C2C", dashed: true });
      g.push({ price: f(p.entryPrice), label: `#${p.id} ENTRY ${p.isLong ? "L" : "S"}`, color: "#7A5C2E" });
    }
    return g;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mk, estBust, side, lev, marginW, myPositions.length]);

  if (dep === undefined) return <main className="center">Loading deployment…</main>;
  if (dep === null)
    return (
      <main className="center">
        <div className="banner">No deployment found for mode “{MODE}”. Local: run <code>scripts/dev-fork.sh</code>. Testnet: add <code>public/deployment.testnet.json</code>.</div>
      </main>
    );
  const d = dep;

  const openOrder = () =>
    run(`requestOpen ${side} ${margin} MUSD × ${lev}x`, async () => {
      if ((us?.allowance ?? 0n) < marginW) await write(d.MUSD, E20, "approve", [d.HouseExchange, maxUint256]);
      return write(d.HouseExchange, EX, "requestOpen", [side === "long", marginW, BigInt(lev), 0n]);
    });
  const closeAll = () =>
    run(`requestClose all (${myPositions.length})`, async () => {
      let h: unknown;
      for (const p of myPositions) h = await write(d.HouseExchange, EX, "requestClose", [p.id, 0n]);
      return h;
    });

  // LOCAL demo only: what the Python keeper does (+ a mock-oracle tick standing in for Skip's per-block updates)
  const keeperStep = () =>
    run("keeper step", async () => {
      const owner = ANVIL_ACCOUNTS[0].address;
      const p = await r<bigint>(d.MockOracle!, MockOracleAbi as Abi, "priceValue");
      await publicClient.request({ method: "evm_increaseTime" as never, params: [1] as never } as never);
      await write(d.MockOracle!, MockOracleAbi as Abi, "setPrice", [p], owner);
      const mm = await readMarket(d);
      for (const o of mm.orders) await write(d.HouseExchange, EX, "executeOrder", [o.id, []], owner);
      for (const p2 of mm.positions) if (await r<boolean>(d.HouseExchange, EX, "isLiquidatable", [p2.id])) await write(d.HouseExchange, EX, "liquidate", [p2.id, []], owner);
      return `filled ${mm.orders.length}`;
    });
  const movePrice = (pct: number) =>
    run(`oracle ${pct > 0 ? "+" : ""}${pct}%`, async () => {
      const p = await r<bigint>(d.MockOracle!, MockOracleAbi as Abi, "priceValue");
      await publicClient.request({ method: "evm_increaseTime" as never, params: [1] as never } as never);
      return write(d.MockOracle!, MockOracleAbi as Abi, "setPrice", [(p * BigInt(Math.round((100 + pct) * 100))) / 10000n], ANVIL_ACCOUNTS[0].address);
    });

  const priceN = f(mk?.price);
  const chg = stats.data && stats.data.open ? ((stats.data.last - stats.data.open) / stats.data.open) * 100 : undefined;
  const ageS = mk ? Math.max(0, Math.floor(Date.now() / 1000 - Number(mk.updatedAt))) : 0;
  const live = !!mk && (mk.settleable || ageS <= 360); // keeper heartbeat pushes every 5 min
  const ageTxt = ageS < 90 ? `${ageS}s` : ageS < 5400 ? `${Math.round(ageS / 60)}m` : `${Math.round(ageS / 3600)}h`;
  const setMarginMul = (k: number) => setMargin(String(Math.max(0, Math.round(Number(margin || "0") * k * 100) / 100)));
  const balN = f(us?.musd);

  const nav = (
    <header className="nav">
      <div className="wordmark">bustline<span className="cursor">_</span></div>
      <nav>
        {(["trade", "house", "mpaper"] as Tab[]).map((t) => (
          <a key={t} className={tab === t ? "active" : ""} onClick={() => setTab(t)} role="tab" aria-selected={tab === t}>
            {t === "trade" ? "Trade" : t === "house" ? "House" : "MPAPER"}
          </a>
        ))}
        <a href="https://github.com/naoto13/mezo-paperperp" target="_blank" rel="noreferrer" className="muted">Docs</a>
      </nav>
      <div className="navr">
        <span className="chip tag-testnet">TESTNET · UNAUDITED</span>
        {who && <span className="navbal"><span className="k">MUSD</span> <b className="num">{num(us?.musd)}</b></span>}
        {MODE === "local" ? (
          <select className="acct" value={acct} onChange={(e) => setAcct(e.target.value as Address)}>
            {ANVIL_ACCOUNTS.map((a) => <option key={a.address} value={a.address}>{a.label} {a.address.slice(0, 8)}…</option>)}
          </select>
        ) : (
          <ConnectButton.Custom>
            {({ account, openAccountModal, openConnectModal: oc, openChainModal, chain, mounted }) =>
              !mounted ? null : !account ? (
                <button className="navbtn" onClick={oc}>Connect</button>
              ) : chain?.unsupported ? (
                <button className="navbtn red" onClick={openChainModal}>Wrong network</button>
              ) : (
                <button className="navbtn" onClick={openAccountModal}>{account.displayName}</button>
              )
            }
          </ConnectButton.Custom>
        )}
      </div>
    </header>
  );

  const banner = (
    <div className="banner">
      TESTNET DEMO / UNAUDITED — {MODE === "local" ? `local anvil fork (${RPC_URL}), unlocked anvil accounts, no keys` : "Mezo testnet (31611) via Mezo Passport"}. Max {maxLev}x. Losses can be total. MUSD margin; losers receive non-transferable MPAPER; winners are paid FIFO from the house queue when the house is short.
    </div>
  );

  const statRow = (
    <div className="statrow">
      <div className="asset">
        <span className="sym">BTC</span>
        <span className="num big" data-stat="price">{usd(mk?.price)}</span>
        {chg !== undefined && <span className={`num ${chg >= 0 ? "pos" : "neg"}`}>{chg >= 0 ? "+" : ""}{chg.toFixed(2)}%</span>}
      </div>
      <div className="chips">
        <span className="stat"><span className="k">LONG OI</span><span className="num">{compact(mk?.longOi)}</span></span>
        <span className="stat"><span className="k">SHORT OI</span><span className="num">{compact(mk?.shortOi)}</span></span>
        <span className="stat"><span className="k">HOUSE</span><span className="num" data-stat="house">{compact(mk?.houseCash)}</span></span>
        <span className="stat"><span className="k">QUEUE</span><span className="num" data-stat="queue">{compact(mk?.queueTotal)}</span></span>
        <span className="stat"><span className="k">EQUITY</span><span className={`num ${(mk?.equity ?? 0n) < 0n ? "neg" : ""}`} data-stat="equity">{signed(mk?.equity)}</span></span>
        <span className="stat" title={ORACLE_LABEL[d.oracleMode ?? "mock"] ?? d.oracleMode}><span className="k">ORACLE</span><span>{d.oracleMode === "signed" ? "signed · Skip ±1%" : d.oracleMode ?? "mock"}</span></span>
        <span className="stat"><span className="k">PUBLISHED</span><span className="num">{mk ? `${ageTxt} ago` : "–"}</span></span>
        <span className={`live ${live ? "" : "stale"}`} title={live ? "on-chain price is fresh (keeper heartbeat every 5 min; fills use a newer signed price)" : "stale — keeper pushes a fresh price every 5 min and with each fill/liquidation"}>{live ? "LIVE" : "STALE"}</span>
      </div>
    </div>
  );

  const orderCol = (
    <aside className="ordercol">
      <div className="equity">
        <div className="eqh"><span>▾ Account Equity</span><b className="num">{us ? usd((us.musd ?? 0n) + marginInUse + (openPnl ?? 0n)) : "– –"}</b></div>
        <Row k="Available to Trade" v={us ? `${num(us.musd)}` : "– –"} />
        <Row k="Margin in Use" v={us ? num(marginInUse) : "– –"} />
        <Row k="Open PnL" v={us ? signed(openPnl) : "– –"} cls={openPnl === undefined ? "" : openPnl < 0n ? "neg" : "pos"} />
        <Row k="Queued Payout" v={us ? num(us.queued) : "– –"} />
      </div>
      <div className="seg">
        <button className={side === "long" ? "on long" : ""} onClick={() => setSide("long")}>Long</button>
        <button className={side === "short" ? "on short" : ""} onClick={() => setSide("short")}>Short</button>
      </div>
      <Row k="Available Collateral" v={us ? `${num(us.musd)} MUSD` : "– –"} />
      <div className="lbl">MARGIN (MUSD)</div>
      <div className="inrow">
        <button className="chipbtn" onClick={() => setMarginMul(0.5)}>½×</button>
        <button className="chipbtn" onClick={() => setMarginMul(2)}>2×</button>
        <button className="chipbtn" disabled={!us} onClick={() => setMargin(String(Math.floor(balN * 100) / 100))}>Max</button>
        <input aria-label="margin" className="num" value={margin} onChange={(e) => setMargin(e.target.value)} />
      </div>
      <div className="lbl">LEVERAGE MULTIPLIER</div>
      <div className="inrow">
        <button className="chipbtn" onClick={() => setLev(Math.min(maxLev, 10))}>10x</button>
        <button className="chipbtn" onClick={() => setLev(Math.min(maxLev, 50))}>50x</button>
        <button className="chipbtn" onClick={() => setLev(maxLev)}>{maxLev}x</button>
        <input aria-label="leverage" className="num" type="number" min={1} max={maxLev} value={lev}
          onChange={(e) => setLev(Math.max(1, Math.min(maxLev, Math.round(Number(e.target.value) || 1))))} />
      </div>
      <input aria-label="lev slider" className="levslider" type="range" min={1} max={maxLev} value={lev} onChange={(e) => setLev(Number(e.target.value))}
        style={{ ["--pct" as string]: `${((lev - 1) / Math.max(1, maxLev - 1)) * 100}%` }} />
      <div className="kv tiny"><span>x1 Safe</span><span>Wild x{maxLev}</span></div>
      <div className="readouts">
        <Row k="Order Value" v={usd(sizeW, 0)} />
        <Row k="Bust Price" v={<span className={side === "long" ? "pos" : "neg"}>{mk ? usd(estBust) : "– –"}</span>} />
        <Row k="Fill" v="next oracle update" />
      </div>
      {MODE !== "local" && !who ? (
        <button className="primary" onClick={() => openConnectModal?.()}>Connect wallet</button>
      ) : (
        <button className="primary" disabled={busy || !who} onClick={openOrder}>Request {side} open</button>
      )}
      <div className="fine">2-step: keeper fills at the next signed price (Skip ±1% bound). No funding, no spread; winners pay an impact haircut + 2% win fee. Bust = liquidation.</div>
      {MODE === "local" && (
        <div className="demo">
          <div className="lbl">DEMO CONTROLS (LOCAL ANVIL)</div>
          <button className="primary sm" onClick={keeperStep} disabled={busy}>Run keeper step</button>
          <div className="inrow wrap">
            {[-6, -2, -0.5, 0.5, 2, 6].map((p) => <button key={p} className="chipbtn" disabled={busy} onClick={() => movePrice(p)}>BTC {p > 0 ? "+" : ""}{p}%</button>)}
          </div>
        </div>
      )}
    </aside>
  );

  const positionsTable = (
    <table className="tbl">
      <thead><tr><th>#</th><th>Side</th><th>Size</th><th>Margin</th><th>Lev</th><th>Entry</th><th>Mark</th><th>Bust Price</th><th>Raw PnL</th><th></th></tr></thead>
      <tbody>
        {myPositions.map((p) => {
          const pnl = mk ? rawPnl(p, mk.price) : 0n;
          return (
            <tr key={String(p.id)}>
              <td>{String(p.id)}</td>
              <td><span className={`tag ${p.isLong ? "tlong" : "tshort"}`}>{p.isLong ? "LONG" : "SHORT"}</span></td>
              <td>{usd(p.size, 0)}</td><td>{num(p.margin)}</td><td>{String(p.size / (p.margin || 1n))}x</td>
              <td>{usd(p.entryPrice)}</td><td>{usd(mk?.price)}</td>
              <td className="neg">{usd(bustPrice(p.isLong, p.margin, p.size, p.entryPrice, mk?.bufDiv ?? 2000n))}</td>
              <td className={pnl < 0n ? "neg" : "pos"}>{signed(pnl)}</td>
              <td><button className="pill" disabled={busy} onClick={() => run(`requestClose #${p.id}`, () => write(d.HouseExchange, EX, "requestClose", [p.id, 0n]))}>Close</button></td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );

  const bottom = (
    <div className="bottom">
      <div className="btabs">
        {(["positions", "orders", "activity", "status"] as const).map((t) => (
          <a key={t} className={btab === t ? "active" : ""} onClick={() => setBtab(t)}>
            {t === "positions" ? `Positions${myPositions.length ? ` (${myPositions.length})` : ""}` : t === "orders" ? `Pending${myOrders.length ? ` (${myOrders.length})` : ""}` : t === "activity" ? "Activity" : "Status"}
          </a>
        ))}
      </div>
      <div className="bbody">
        {btab === "positions" && (
          <>
            {positionsTable}
            {myPositions.length === 0 && <div className="empty">{who ? "No open positions." : "Connect wallet to view your positions."}</div>}
          </>
        )}
        {btab === "orders" && (
          <>
            <table className="tbl">
              <thead><tr><th>#</th><th>Type</th><th>Side</th><th>Margin</th><th>Size</th><th>Created</th><th>Status</th></tr></thead>
              <tbody>
                {myOrders.map((o) => (
                  <tr key={String(o.id)}>
                    <td>{String(o.id)}</td><td>{o.kind === 0 ? "OPEN" : "CLOSE"}</td>
                    <td><span className={`tag ${o.isLong ? "tlong" : "tshort"}`}>{o.isLong ? "LONG" : "SHORT"}</span></td>
                    <td>{num(o.margin)}</td><td>{usd(o.size, 0)}</td><td>{new Date(Number(o.createdAt) * 1000).toLocaleTimeString()}</td>
                    <td><span className="tag tgrey">WAITING FOR KEEPER</span></td>
                  </tr>
                ))}
              </tbody>
            </table>
            {myOrders.length === 0 && <div className="empty">No pending orders. Orders are filled by the keeper at the next oracle update.</div>}
          </>
        )}
        <div className="log" style={{ display: btab === "activity" ? "block" : "none" }}>{log.join("\n") || "—"}</div>
        {btab === "status" && (
          <div className="statusgrid">
            <Row k="Network" v={MODE === "local" ? `local anvil (${RPC_URL})` : "Mezo testnet · 31611"} />
            <Row k="RPC" v={RPC_URL} />
            <Row k="Oracle" v={ORACLE_LABEL[d.oracleMode ?? "mock"] ?? d.oracleMode} />
            <Row k="Price published" v={mk ? new Date(Number(mk.updatedAt) * 1000).toLocaleString() : "–"} />
            <Row k="Price state" v={mk ? (mk.settleable ? "fresh" : "stale — keeper pushes a fresh price every 5 min and with each fill/liquidation") : "–"} />
            <Row k="HouseExchange" v={<span className="num">{d.HouseExchange}</span>} />
            <Row k="Chart feed" v={candles.isError ? "Coinbase candles unavailable" : "Coinbase BTC-USD (display only)"} />
          </div>
        )}
      </div>
    </div>
  );

  const trade = (
    <div className="trade">
      <div className="tleft">
        {statRow}
        <div className="chartwrap">
          <PriceChart data={candles.data ?? []} mark={isFinite(priceN) ? priceN : undefined} guides={guides} />
          <div className="gran">
            {(Object.keys(GRAN) as Gran[]).map((g) => <button key={g} className={`pill ${gran === g ? "on" : ""}`} onClick={() => setGran(g)}>{g}</button>)}
          </div>
          <div className="legend">
            <span><i className="sw line" /> BTC-USD (Coinbase, {gran})</span>
            <span><i className="sw mark" /> on-chain mark</span>
            <span><i className="sw bust" /> bust price</span>
          </div>
        </div>
        <div className="opbar">
          <span>Open Positions <b className="num">{myPositions.length || "– –"}</b></span>
          <button className="pill" disabled={busy || myPositions.length === 0} onClick={closeAll}>Close All</button>
        </div>
      </div>
      {orderCol}
    </div>
  );

  const house = (
    <div className="pgrid house">
      <Panel title="Stats" testid="stats">
        <Row k="House Cash" v={<span className="pos">{num(mk?.houseCash)} MUSD</span>} />
        <Row k="Payout Queue" v={`${num(mk?.queueTotal)} MUSD`} />
        <Row k="House Equity" v={<span className={(mk?.equity ?? 0n) < 0n ? "neg" : "pos"}>{signed(mk?.equity)}</span>} />
        <Row k="Waiting Winners" v={mk?.queue.length ?? "–"} />
        <Row k="Max Leverage" v={mk ? `${String(mk.maxLev)}x` : "–"} />
        <Row k="Oracle" v={ORACLE_LABEL[d.oracleMode ?? "mock"] ?? d.oracleMode} />
        <div className="fine">House cash grows only from trader losses. Equity = cash − queued (can be &lt; 0).</div>
      </Panel>
      <Panel title="User Positions" testid="oi">
        <table className="tbl compact">
          <thead><tr><th></th><th>Long</th><th>Short</th><th>Net</th></tr></thead>
          <tbody>
            <tr><td>BTC</td><td className="pos">{compact(mk?.longOi)}</td><td className="neg">{compact(mk?.shortOi)}</td><td>{mk ? compact(mk.longOi - mk.shortOi) : "–"}</td></tr>
          </tbody>
        </table>
        <Row k="Open Positions" v={mk?.positions.length ?? "–"} />
        <Row k="Pending Orders" v={mk?.orders.length ?? "–"} />
        <div className="exposure">
          <div className="pos-bg" style={{ width: mk && mk.longOi + mk.shortOi > 0n ? `${(f(mk.longOi) / (f(mk.longOi) + f(mk.shortOi))) * 100}%` : "50%" }} />
        </div>
        <div className="kv tiny"><span>LONG</span><span>SHORT</span></div>
      </Panel>
      <Panel title="My Payout Queue" testid="myqueue">
        <div className="bigv num">{num(us?.queued)} <span className="k">MUSD</span></div>
        <div className="k">{qIdx >= 0 ? `position #${qIdx + 1} in line · ${num(aheadOfMe)} MUSD ahead of you` : "nothing queued"}</div>
        <div className="fine">Paid FIFO as later trader losses arrive (harvest is automatic on each loss; anyone can call it).</div>
        <button className="primary sm" disabled={busy || !mk || mk.queueTotal === 0n} onClick={() => run("harvest", () => write(d.HouseExchange, EX, "harvest", [32n]))}>Harvest</button>
      </Panel>
      <Panel title="Bust Map" className="wide chartpanel" right={<span className="k">BTC · every open position&apos;s bust price · {gran}</span>}>
        <div className="chartwrap fixed">
          <PriceChart data={candles.data ?? []} mark={isFinite(priceN) ? priceN : undefined}
            guides={(mk?.positions ?? []).map((p) => ({ price: f(bustPrice(p.isLong, p.margin, p.size, p.entryPrice, mk!.bufDiv)), label: `#${p.id} ${p.isLong ? "LONG" : "SHORT"} BUST`, color: p.isLong ? "#2E6B3F" : "#9B2C2C", dashed: true }))} />
        </div>
      </Panel>
      <Panel title="Payout Queue" className="wide" right={<span className="k">FIFO · {mk?.queue.length ?? 0} entries</span>}>
        <table className="tbl">
          <thead><tr><th>#</th><th>User</th><th>Amount</th><th>Ahead</th></tr></thead>
          <tbody>
            {(mk?.queue ?? []).map((q, i) => (
              <tr key={String(q.idx)} className={who && q.to.toLowerCase() === who.toLowerCase() ? "me" : ""}>
                <td>{String(q.idx)}</td><td className="num">{short(q.to)}</td><td>{num(q.amount)} MUSD</td>
                <td>{num(mk!.queue.slice(0, i).reduce((a, x) => a + x.amount, 0n))}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {(mk?.queue.length ?? 0) === 0 && <div className="empty">Queue empty — every winner has been paid.</div>}
      </Panel>
      <Panel title="Open Positions (All)" className="wide">
        <table className="tbl">
          <thead><tr><th>#</th><th>User</th><th>Side</th><th>Size</th><th>Entry</th><th>Bust</th><th>Raw PnL</th></tr></thead>
          <tbody>
            {(mk?.positions ?? []).map((p) => {
              const pnl = rawPnl(p, mk!.price);
              return (
                <tr key={String(p.id)}>
                  <td>{String(p.id)}</td><td className="num">{short(p.owner)}</td>
                  <td><span className={`tag ${p.isLong ? "tlong" : "tshort"}`}>{p.isLong ? "LONG" : "SHORT"}</span></td>
                  <td>{usd(p.size, 0)}</td><td>{usd(p.entryPrice)}</td>
                  <td className="neg">{usd(bustPrice(p.isLong, p.margin, p.size, p.entryPrice, mk!.bufDiv))}</td>
                  <td className={pnl < 0n ? "neg" : "pos"}>{signed(pnl)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
        {(mk?.positions.length ?? 0) === 0 && <div className="empty">No open positions on the exchange.</div>}
      </Panel>
    </div>
  );

  const mpaper = (
    <div className="pgrid paper">
      <Panel title="Claimable Rewards" testid="claim">
        <div className="bigv num">{us ? num(us.pending, 4) : "– –"} <span className="k">MUSD</span></div>
        {MODE !== "local" && !who ? (
          <button className="primary green" onClick={() => openConnectModal?.()}>Connect wallet</button>
        ) : (
          <button className="primary green" disabled={busy || !us || us.pending === 0n} onClick={() => run("claim", () => write(d.RebateStaking, RebateStakingAbi as Abi, "claim", []))}>Claim MUSD</button>
        )}
      </Panel>
      <Panel title={`${mk?.tokenSymbol ?? "MPAPER"} Staked`} testid="staked">
        <div className="bigv num">{us ? num(us.staked, 0) : "– –"}</div>
        <div className="lbl left">{mk?.tokenSymbol ?? "MPAPER"} WALLET BALANCE</div>
        <div className="num">{us ? num(us.rebate, 0) : "– –"}</div>
      </Panel>
      <Panel title="Stake / Unstake">
        <div className="fine">Minted on realised losses · non-transferable · stake for MUSD revenue share.</div>
        <input aria-label="stake amount" className="num" placeholder="amount (blank = all)" value={stakeAmt} onChange={(e) => setStakeAmt(e.target.value)} />
        <div className="inrow" style={{ marginTop: 6 }}>
          <button className="primary sm" disabled={busy || !us || us.rebate === 0n} onClick={() => run("stake", async () => {
            const a = stakeAmt ? parseUnits(stakeAmt, 18) : us!.rebate;
            if (us!.rtAllow < a) await write(d.RebateToken, RebateTokenAbi as Abi, "approve", [d.RebateStaking, maxUint256]);
            return write(d.RebateStaking, RebateStakingAbi as Abi, "stake", [a]);
          })}>Stake</button>
          <button className="pill" disabled={busy || !us || us.staked === 0n} onClick={() => run("unstake", () => write(d.RebateStaking, RebateStakingAbi as Abi, "unstake", [stakeAmt ? parseUnits(stakeAmt, 18) : us!.staked]))}>Unstake</button>
        </div>
      </Panel>
      <Panel title="Rewards">
        <Row k="Total Staked" v={num(mk?.totalStaked, 0)} />
        <Row k="Your Stake Share" v={us && mk && mk.totalStaked > 0n ? `${((f(us.staked) / f(mk.totalStaked)) * 100).toFixed(2)}%` : "– –"} />
        <Row k="Paid to Stakers" v={`${num(mk?.toStakers)} MUSD`} />
        <Row k="Mint Rate" v={`${num(mk?.mintRate, 1)} / MUSD lost`} />
        <Row k="Reward Token" v="MUSD" />
      </Panel>
      <Panel title={mk?.tokenName ?? "Mezo Paper"}>
        <Row k="Symbol" v={mk?.tokenSymbol ?? "MPAPER"} />
        <Row k="Token" v={<span className="num">{short(d.RebateToken)}</span>} />
        <Row k="Staking Contract" v={<span className="num">{short(d.RebateStaking)}</span>} />
        <Row k="Transferable" v={<span className="tag tgrey">NO</span>} />
      </Panel>
      <Panel title="Activity" className="wide" right={<span className="k">this session</span>}>
        <table className="tbl">
          <thead><tr><th>Time</th><th>Type</th><th>Detail</th></tr></thead>
          <tbody>
            {log.map((l, i) => {
              const [time, ...restParts] = l.split(" ");
              const rest = restParts.join(" ");
              const kind = /stake|unstake|claim/.test(rest) ? (rest.match(/unstake|stake|claim/)![0]) : /close|liq/.test(rest) ? "close" : "tx";
              return (
                <tr key={i}><td>{time}</td><td><span className={`tag ${kind === "close" ? "tshort" : "tgrey"}`}>{kind.toUpperCase()}</span></td><td>{rest}</td></tr>
              );
            })}
          </tbody>
        </table>
        {log.length === 0 && <div className="empty">{who ? "No activity yet this session." : "Connect a wallet to stake or unstake MPAPER."}</div>}
      </Panel>
    </div>
  );

  return (
    <div className="app">
      {nav}
      {banner}
      {tab === "trade" ? trade : tab === "house" ? house : mpaper}
      {tab === "trade" && bottom}
      {tab !== "trade" && <div className="hiddenlog">{bottom}</div>}
      <footer className="foot">Bustline · mechanism inspired by public docs of Papertrade (asymmetric impact, solvency queue) and Rollbit&apos;s market-impact model; independent implementation, not affiliated. Chart: Coinbase public BTC-USD candles (display only); settlement uses the on-chain keeper-signed price.</footer>
    </div>
  );
}

export default function App() {
  return (
    <Providers>
      <Dashboard />
    </Providers>
  );
}
