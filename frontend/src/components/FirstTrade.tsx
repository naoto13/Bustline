"use client";
import { useEffect, useMemo, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { formatUnits, type Address } from "viem";
import { BTC_FAUCET_URL, mezoProtocol, type Deployment } from "@/lib/config";
import { publicClient } from "@/lib/chain";
import { readProtocol, readTrove } from "@/lib/mezo";
import { num, usd } from "@/lib/format";
import type { Route } from "./Funding";

/** The first-trade preset: small margin, low leverage. 20 MUSD is above the 10 MUSD on-chain minimum. */
export const PRESET = { margin: 20, lev: 5 } as const;

const MIN_MARGIN = 10n * 10n ** 18n; // HouseExchange.minMargin on testnet

export type History = { opened: number; closed: number };

type Key = "connect" | "btc" | "musd" | "order" | "fill" | "close";
const TITLES: Record<Key, string> = {
  connect: "Connect a wallet",
  btc: "Get testnet BTC",
  musd: "Get MUSD margin",
  order: "Place a small first order",
  fill: "Wait for the fill",
  close: "Close it",
};
const ROUTE_BTN: Record<Route, string> = { btc: "Show “Start with BTC”", trove: "Show “From my trove”", musd: "Show “Deposit MUSD”" };

/**
 * "First trade" guide for newcomers to MUSD. Every check is read from live state (wallet, BTC balance, MUSD balance,
 * trove, pending orders, the exchange's position history). It never signs: its actions only fill the order form,
 * pick a funding route, scroll, or open the faucet.
 */
export default function FirstTrade(props: {
  d: Deployment; who?: Address; readOnly: boolean; needConnect: boolean; connect: () => void;
  musd?: bigint; openCount: number; pendingOpen: boolean; history?: History; presetBust?: bigint; presetLev: number;
  /** bumped by the header's "Start here" link: expands the card even when every step is done */
  expandNonce: number;
  onDismiss: () => void; onPreset: () => void; onRoute: (r: Route) => void; onShowBottom: (t: "positions" | "orders") => void;
}) {
  const { d, who, readOnly, history } = props;
  const mz = useMemo(() => mezoProtocol(d), [d]);
  // Same query keys and fetchers as Funding, so both share one cache entry (no extra RPC traffic).
  const btcBal = useQuery({ queryKey: ["btc-bal", who], queryFn: () => publicClient.getBalance({ address: who! }), enabled: !!who, refetchInterval: 10000 });
  const trove = useQuery({ queryKey: ["mezo-trove", mz.TroveManager, who], queryFn: () => readTrove(mz, who!), enabled: !!who, refetchInterval: 6000, retry: 1 });
  const proto = useQuery({ queryKey: ["mezo-proto", mz.BorrowerOperations], queryFn: () => readProtocol(mz), refetchInterval: 15000, retry: 1 });
  const hasTrove = trove.data?.status === "active";
  const troveRoutes = !!proto.data?.price;

  // Loading: never decide "all done" (and collapse) before the reads that decide it have answered.
  const settled = !who || ((btcBal.isFetched || btcBal.isError) && (trove.isFetched || trove.isError) && props.musd !== undefined && history !== undefined);

  const opened = Math.max(history?.opened ?? 0, props.openCount);
  const raw: Record<Key, boolean> = {
    connect: !!who,
    btc: (btcBal.data ?? 0n) > 0n,
    musd: (props.musd ?? 0n) >= MIN_MARGIN || hasTrove || opened > 0, // dust below the 10 MUSD minimum cannot fund an order
    order: props.pendingOpen || opened > 0,
    fill: opened > 0,
    close: (history?.closed ?? 0) > 0,
  };
  // A later step implies the earlier ones (e.g. BTC spent on gas after a finished trade still counts as done).
  const keys = Object.keys(TITLES) as Key[];
  const done = keys.map((k, i) => keys.slice(i).some((k2) => raw[k2]));
  const count = done.filter(Boolean).length;
  const cur = done.indexOf(false); // -1 = all done
  const allDone = settled && cur === -1;

  const [expanded, setExpanded] = useState<boolean | undefined>(undefined);
  // First settle per address decides the default: expanded until everything is done.
  useEffect(() => { setExpanded(undefined); }, [who]);
  useEffect(() => { if (settled && expanded === undefined) setExpanded(!allDone); }, [settled, allDone, expanded]);
  useEffect(() => { if (props.expandNonce > 0) setExpanded(true); }, [props.expandNonce]);
  // Finishing the last step during the session collapses the card (a reopen of an already finished guide stays open).
  const wasDone = useRef(allDone);
  useEffect(() => {
    if (settled && allDone && !wasDone.current) setExpanded(false);
    if (settled) wasDone.current = allDone;
  }, [settled, allDone]);

  const fundRoute: Route = !troveRoutes || (props.musd ?? 0n) >= BigInt(PRESET.margin) * 10n ** 18n ? "musd" : hasTrove ? "trove" : "btc";
  const minDebt = proto.data?.minNetDebt;

  const body = (k: Key) => {
    switch (k) {
      case "connect":
        return (
          <>
            <p>Bustline uses Mezo Passport: sign in with a Bitcoin wallet or an EVM wallet on Mezo testnet.</p>
            {props.needConnect && !readOnly && <button className="chipbtn ftgo" onClick={props.connect}>Connect wallet</button>}
          </>
        );
      case "btc":
        return (
          <>
            <p>Testnet BTC pays gas and is the collateral you borrow MUSD against. The faucet gives 0.05 BTC per claim.</p>
            <a className="chipbtn ftgo" href={BTC_FAUCET_URL} target="_blank" rel="noreferrer">Open the faucet ↗</a>
          </>
        );
      case "musd":
        return (
          <>
            <p>
              Margin is <b>MUSD</b>, Mezo&apos;s BTC-backed dollar. Without MUSD, open a <b>trove</b>: deposit BTC and borrow MUSD
              {minDebt ? <> (debt at least <span className="num">{num(minDebt, 0)}</span> MUSD; what the order does not use stays in your wallet)</> : null}.
              The trove is a separate loan with its own liquidation line at a 110% collateral ratio.
            </p>
            <button className="chipbtn ftgo" onClick={() => props.onRoute(fundRoute)}>{ROUTE_BTN[fundRoute]}</button>
          </>
        );
      case "order":
        return (
          <>
            <p>Start small and with low leverage. The preset fills the order form; you still review it and press the request button.</p>
            <button className="chipbtn ftgo" onClick={props.onPreset}>Use preset · {PRESET.margin} MUSD × {props.presetLev}x long</button>
            <p className="ftbust">
              If BTC falls to <b className="num">{props.presetBust ? usd(props.presetBust) : "–"}</b>, this position is closed and the{" "}
              {PRESET.margin} MUSD margin is lost.
            </p>
          </>
        );
      case "fill":
        return (
          <>
            <p>
              {props.pendingOpen ? "Your order is waiting. " : ""}The keeper fills it at the next oracle price, usually within about 15 s.
              Orders not filled within 5 minutes become refundable.
            </p>
            {props.pendingOpen && <button className="chipbtn ftgo" onClick={() => props.onShowBottom("orders")}>Show pending orders</button>}
          </>
        );
      case "close":
        return (
          <>
            <p>In the Positions tab, press <b>Close</b>. Closing is 2-step too: the keeper fills it at the next price. A bust also ends the trade.</p>
            <button className="chipbtn ftgo" onClick={() => props.onShowBottom("positions")}>Show positions</button>
          </>
        );
    }
  };

  const head = (
    <div className="fth">
      <span className="ftt">First trade</span>
      <span className="ftn num" aria-label={`${count} of 6 steps done`}>{settled ? `${count}/6` : "…"}</span>
      <span className="ftsp" />
      {expanded !== undefined && (
        <button className="ftx" aria-expanded={!!expanded} onClick={() => setExpanded(!expanded)}>{expanded ? "Hide" : "Show"}</button>
      )}
      <button className="ftx" aria-label="Dismiss the first-trade guide" title="Dismiss (reopen with “Start here”)" onClick={props.onDismiss}>✕</button>
    </div>
  );

  return (
    <section className={`ft ${allDone ? "complete" : ""}`} data-panel="first-trade" aria-label="First trade guide">
      {head}
      <div className="ftbar" aria-hidden><i style={{ width: `${(count / 6) * 100}%` }} /></div>
      {!settled && <div className="fine ftload">Checking this address…</div>}
      {settled && !expanded && (
        <div className="fine ftsum">{allDone ? "All six steps done: funded, traded, filled and closed." : `Next: ${TITLES[keys[cur]]}.`}</div>
      )}
      {settled && expanded && (
        <>
          {readOnly && <div className="fine ftro">Read-only preview: checks use {who ? `${who.slice(0, 6)}…${who.slice(-4)}` : "this address"}. Nothing here signs.</div>}
          <ol className="ftsteps">
            {keys.map((k, i) => {
              const st = done[i] ? "done" : i === cur ? "cur" : "todo";
              return (
                <li key={k} className={`fts ${st}`} aria-current={st === "cur" ? "step" : undefined}>
                  <span className="ftd" aria-hidden>{done[i] ? "✓" : i + 1}</span>
                  <div className="ftc">
                    <div className="ftl">{TITLES[k]}{k === "btc" && who && btcBal.data !== undefined && <span className="k num"> · {Number(formatUnits(btcBal.data, 18)).toFixed(4)} BTC</span>}</div>
                    {st === "cur" && <div className="ftbody">{body(k)}</div>}
                  </div>
                </li>
              );
            })}
          </ol>
          {allDone && <div className="fine pos">Done. Every later trade works the same way.</div>}
        </>
      )}
    </section>
  );
}
