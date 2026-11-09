"use client";
import { useEffect, useState } from "react";
import type { Abi, Address } from "viem";
import { HouseExchangeAbi } from "@/abi";
import { publicClient } from "@/lib/chain";
import { loadDeployment } from "@/lib/config";
import { num } from "@/lib/format";
import { readHouseExtra } from "@/lib/v31";

type Live = { orders: bigint; fees?: bigint; sp?: bigint; cash: bigint; queue: bigint };

const read = <T,>(address: Address, functionName: string) =>
  publicClient.readContract({ address, abi: HouseExchangeAbi as Abi, functionName }) as Promise<T>;

/** Read-only strip of HouseExchange v3.1 state, so the numbers below can be checked against the chain right now. */
export default function ProofLive() {
  const [live, setLive] = useState<Live | null | undefined>(undefined);
  useEffect(() => {
    (async () => {
      const d = await loadDeployment();
      if (!d) return setLive(null);
      const x = d.HouseExchange;
      const [orders, cash, queue, extra] = await Promise.all([
        read<bigint>(x, "orderCount"), read<bigint>(x, "houseCash"), read<bigint>(x, "queueTotal"), readHouseExtra(x),
      ]);
      setLive({ orders, cash, queue, fees: extra.totalProtocolFees, sp: extra.spDeposit });
    })().catch(() => setLive(null));
  }, []);

  const v = (x: string | undefined) => (live === undefined ? "…" : x ?? "–");
  return (
    <div className="proof-live" aria-live="polite">
      <div className="proof-livehead">
        <span className="docs-eyebrow">Live from HouseExchange v3.1</span>
        {live === null && <span className="docs-muted"> · could not read the chain right now</span>}
      </div>
      <dl className="proof-stats">
        <div><dt>Orders</dt><dd className="num">{v(live ? String(live.orders) : undefined)}</dd></div>
        <div><dt>Protocol fees</dt><dd className="num">{v(live?.fees !== undefined ? `${num(live.fees, 4)}` : undefined)} <span>MUSD</span></dd></div>
        <div><dt>Stability Pool</dt><dd className="num">{v(live?.sp !== undefined ? num(live.sp, 4) : undefined)} <span>MUSD</span></dd></div>
        <div><dt>House cash</dt><dd className="num">{v(live ? num(live.cash, 4) : undefined)} <span>MUSD</span></dd></div>
        <div><dt>Payout queue</dt><dd className="num">{v(live ? num(live.queue, 2) : undefined)} <span>MUSD</span></dd></div>
      </dl>
    </div>
  );
}
