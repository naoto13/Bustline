"use client";
import { useCallback, useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount, useWriteContract } from "wagmi";
import { parseUnits, maxUint256, type Address, type Abi } from "viem";
import Providers from "./Providers";
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

function Stat({ k, v, sub }: { k: string; v: React.ReactNode; sub?: React.ReactNode }) {
  return (
    <div className="card">
      <div className="k">{k}</div>
      <div className="v">{v}</div>
      {sub && <div className="k" style={{ marginTop: 4 }}>{sub}</div>}
    </div>
  );
}

function Dashboard() {
  const qc = useQueryClient();
  const { address: passportAddr } = useAccount();
  const { writeContractAsync } = useWriteContract();
  const [dep, setDep] = useState<Deployment | null | undefined>(undefined);
  const [acct, setAcct] = useState<Address>(ANVIL_ACCOUNTS[1].address);
  const [log, setLog] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [side, setSide] = useState<"long" | "short">("long");
  const [margin, setMargin] = useState("100");
  const [lev, setLev] = useState(50);
  const [stakeAmt, setStakeAmt] = useState("");

  useEffect(() => { loadDeployment().then(setDep); }, []);
  const who: Address | undefined = MODE === "local" ? acct : passportAddr;
  const m = useQuery({ queryKey: ["market", dep?.HouseExchange], queryFn: () => readMarket(dep!), enabled: !!dep, refetchInterval: 3000 });
  const u = useQuery({ queryKey: ["user", dep?.HouseExchange, who], queryFn: () => readUser(dep!, who!), enabled: !!dep && !!who, refetchInterval: 3000 });
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

  if (dep === undefined) return <main>Loading deployment…</main>;
  if (dep === null)
    return (
      <main>
        <div className="banner">No deployment found for mode “{MODE}”. Local: run <code>scripts/dev-fork.sh</code>. Testnet: add <code>public/deployment.testnet.json</code>.</div>
      </main>
    );

  const d = dep;
  const mk = m.data;
  const us = u.data;
  const marginW = (() => { try { return parseUnits(margin || "0", 18); } catch { return 0n; } })();
  const sizeW = marginW * BigInt(lev);
  const estBust = mk ? bustPrice(side === "long", marginW, sizeW, mk.price, mk.bufDiv) : 0n;
  const myPositions = (mk?.positions ?? []).filter((p) => who && p.owner.toLowerCase() === who.toLowerCase());
  const myOrders = (mk?.orders ?? []).filter((o) => who && o.trader.toLowerCase() === who.toLowerCase());
  const qIdx = (mk?.queue ?? []).findIndex((q) => who && q.to.toLowerCase() === who.toLowerCase());
  const aheadOfMe = qIdx >= 0 ? mk!.queue.slice(0, qIdx).reduce((a, q) => a + q.amount, 0n) : 0n;

  const openOrder = () =>
    run(`requestOpen ${side} ${margin} MUSD × ${lev}x`, async () => {
      if ((us?.allowance ?? 0n) < marginW) await write(d.MUSD, E20, "approve", [d.HouseExchange, maxUint256]);
      return write(d.HouseExchange, EX, "requestOpen", [side === "long", marginW, BigInt(lev), 0n]);
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

  return (
    <main>
      <div className="banner">
        TESTNET DEMO / UNAUDITED — {MODE === "local" ? `local anvil fork (${RPC_URL}), unlocked anvil accounts, no keys` : "Mezo testnet (31611) via Mezo Passport"}. Max 100x. Losses can be total.
      </div>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h2 style={{ margin: 0 }}>BTC House Perp <span className="k">· MUSD-margined · house funded only by trader losses</span></h2>
        {MODE === "local" ? (
          <select value={acct} onChange={(e) => setAcct(e.target.value as Address)} style={{ width: 260 }}>
            {ANVIL_ACCOUNTS.map((a) => <option key={a.address} value={a.address}>{a.label} {a.address.slice(0, 8)}…</option>)}
          </select>
        ) : (
          <ConnectButton />
        )}
      </div>

      <div className="grid">
        <Stat k={`BTC/USD (${ORACLE_LABEL[d.oracleMode ?? "mock"] ?? d.oracleMode})`} v={usd(mk?.price)} sub={mk ? `published ${new Date(Number(mk.updatedAt) * 1000).toLocaleTimeString()} · ${mk.settleable ? "fresh" : "stale — keeper pushes a fresh price with each fill/liquidation"}` : ""} />
        <Stat k="House cash" v={`${num(mk?.houseCash)} MUSD`} sub="grows only from trader losses" />
        <Stat k="Payout queue" v={`${num(mk?.queueTotal)} MUSD`} sub={`${mk?.queue.length ?? 0} waiting winners (FIFO)`} />
        <Stat k="House equity" v={<span style={{ color: (mk?.equity ?? 0n) < 0n ? "#f87171" : "#4ade80" }}>{signed(mk?.equity)}</span>} sub="cash − queued (can be < 0)" />
        <Stat k="Open interest" v={`L ${num(mk?.longOi, 0)} / S ${num(mk?.shortOi, 0)}`} />
        <Stat k="Rebate mint rate" v={`${num(mk?.mintRate, 1)} / MUSD lost`} sub={`staked ${num(mk?.totalStaked, 0)} · paid ${num(mk?.toStakers)} MUSD`} />
      </div>

      <div className="forms">
        <div className="card">
          <h3>Trade BTC/USD</h3>
          <div className="row" style={{ marginBottom: 8 }}>
            <button className={side === "long" ? "" : "ghost"} onClick={() => setSide("long")}>Long</button>
            <button className={side === "short" ? "" : "ghost"} onClick={() => setSide("short")}>Short</button>
          </div>
          <div className="k">Margin (MUSD) — balance {num(us?.musd)}</div>
          <input aria-label="margin" value={margin} onChange={(e) => setMargin(e.target.value)} />
          <div className="k" style={{ marginTop: 8 }}>Leverage: <b>{lev}x</b> (max {mk ? String(mk.maxLev) : 100}x)</div>
          <input aria-label="leverage" type="range" min={1} max={Number(mk?.maxLev ?? 100n)} value={lev} onChange={(e) => setLev(Number(e.target.value))} />
          <div className="k" style={{ marginTop: 8 }}>Size {usd(sizeW, 0)} · est. liquidation price <b>{usd(estBust)}</b></div>
          <div className="k">Filled by keeper at the next oracle update (2-step). No funding, no spread; winners pay an impact haircut + 2% win fee.</div>
          <button style={{ marginTop: 8, width: "100%" }} disabled={busy || !who} onClick={openOrder}>Request {side} open</button>
        </div>

        <div className="card">
          <h3>{mk?.tokenName ?? "Mezo Paper"} ({mk?.tokenSymbol ?? "MPAPER"}) · rebate token & staking</h3>
          <div className="k">Minted on realised losses · non-transferable · stake for MUSD revenue share</div>
          <div className="grid" style={{ margin: "8px 0" }}>
            <div><div className="k">Wallet</div><div>{num(us?.rebate, 0)}</div></div>
            <div><div className="k">Staked</div><div>{num(us?.staked, 0)}</div></div>
            <div><div className="k">Claimable MUSD</div><div>{num(us?.pending, 4)}</div></div>
          </div>
          <input aria-label="stake amount" placeholder="amount (blank = all)" value={stakeAmt} onChange={(e) => setStakeAmt(e.target.value)} />
          <div className="row" style={{ marginTop: 8 }}>
            <button disabled={busy || !us || us.rebate === 0n} onClick={() => run("stake", async () => {
              const a = stakeAmt ? parseUnits(stakeAmt, 18) : us!.rebate;
              if (us!.rtAllow < a) await write(d.RebateToken, RebateTokenAbi as Abi, "approve", [d.RebateStaking, maxUint256]);
              return write(d.RebateStaking, RebateStakingAbi as Abi, "stake", [a]);
            })}>Stake</button>
            <button className="ghost" disabled={busy || !us || us.staked === 0n} onClick={() => run("unstake", () => write(d.RebateStaking, RebateStakingAbi as Abi, "unstake", [stakeAmt ? parseUnits(stakeAmt, 18) : us!.staked]))}>Unstake</button>
            <button className="ghost" disabled={busy || !us || us.pending === 0n} onClick={() => run("claim", () => write(d.RebateStaking, RebateStakingAbi as Abi, "claim", []))}>Claim MUSD</button>
          </div>
        </div>

        <div className="card">
          <h3>My payout queue</h3>
          <div className="v">{num(us?.queued)} MUSD</div>
          <div className="k">{qIdx >= 0 ? `position #${qIdx + 1} in line · ${num(aheadOfMe)} MUSD ahead of you` : "nothing queued"}</div>
          <div className="k" style={{ marginTop: 6 }}>Paid FIFO as later trader losses arrive (harvest is automatic on each loss; anyone can call it).</div>
          <button className="ghost" style={{ marginTop: 8 }} disabled={busy || !mk || mk.queueTotal === 0n} onClick={() => run("harvest", () => write(d.HouseExchange, EX, "harvest", [32n]))}>Harvest</button>
        </div>
      </div>

      <div className="card" style={{ marginTop: 12 }}>
        <h3>My positions</h3>
        <table style={{ width: "100%", fontSize: 13 }}>
          <thead><tr className="k"><td>#</td><td>Side</td><td>Size</td><td>Margin</td><td>Lev</td><td>Entry</td><td>Liq. price</td><td>Raw PnL</td><td></td></tr></thead>
          <tbody>
            {myPositions.map((p) => {
              const pnl = mk ? rawPnl(p, mk.price) : 0n;
              return (
                <tr key={String(p.id)}>
                  <td>{String(p.id)}</td>
                  <td style={{ color: p.isLong ? "#4ade80" : "#f87171" }}>{p.isLong ? "LONG" : "SHORT"}</td>
                  <td>{usd(p.size, 0)}</td><td>{num(p.margin)}</td><td>{String(p.size / (p.margin || 1n))}x</td>
                  <td>{usd(p.entryPrice)}</td><td>{usd(bustPrice(p.isLong, p.margin, p.size, p.entryPrice, mk?.bufDiv ?? 2000n))}</td>
                  <td style={{ color: pnl < 0n ? "#f87171" : "#4ade80" }}>{signed(pnl)}</td>
                  <td><button className="ghost" disabled={busy} onClick={() => run(`requestClose #${p.id}`, () => write(d.HouseExchange, EX, "requestClose", [p.id, 0n]))}>Close</button></td>
                </tr>
              );
            })}
          </tbody>
        </table>
        {myPositions.length === 0 && <div className="k">No open positions.</div>}
        {myOrders.length > 0 && <div className="k" style={{ marginTop: 8 }}>Pending (waiting for keeper fill at a later oracle update): {myOrders.map((o) => `#${o.id} ${o.kind === 0 ? "open" : "close"}`).join(", ")}</div>}
      </div>

      {MODE === "local" && (
        <div className="card" style={{ marginTop: 12 }}>
          <h3>Demo controls (local anvil only)</h3>
          <div className="row">
            <button onClick={keeperStep} disabled={busy}>Run keeper step</button>
            {[-6, -2, -0.5, 0.5, 2, 6].map((p) => <button key={p} className="ghost" disabled={busy} onClick={() => movePrice(p)}>BTC {p > 0 ? "+" : ""}{p}%</button>)}
          </div>
        </div>
      )}
      <div className="card" style={{ marginTop: 12 }}><h3>Log</h3><div className="log">{log.join("\n") || "—"}</div></div>
      <p className="k">Mechanism inspired by public docs of Papertrade (asymmetric impact, solvency queue) and Rollbit's market-impact model; independent implementation. Not affiliated.</p>
    </main>
  );
}

export default function App() {
  return (
    <Providers>
      <Dashboard />
    </Providers>
  );
}
