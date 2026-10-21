"use client";
import { useEffect, useRef, useState } from "react";

export type Candle = { t: number; c: number };
export type Guide = { price: number; label: string; color: string; dashed?: boolean };

const PAD = { l: 0, r: 64, t: 12, b: 22 };

/** Lightweight SVG line chart: BTC close series + current-price tag + dashed bust/entry guides. */
export default function PriceChart({ data, mark, guides }: { data: Candle[]; mark?: number; guides: Guide[] }) {
  const ref = useRef<HTMLDivElement>(null);
  const [sz, setSz] = useState({ w: 800, h: 400 });
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => setSz({ w: Math.max(200, e.contentRect.width), h: Math.max(160, e.contentRect.height) }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const { w, h } = sz;
  const pw = w - PAD.l - PAD.r;
  const ph = h - PAD.t - PAD.b;
  const closes = data.map((d) => d.c);
  const last = mark ?? closes[closes.length - 1];
  let lo = Math.min(...closes, ...(last ? [last] : []));
  let hi = Math.max(...closes, ...(last ? [last] : []));
  if (!isFinite(lo) || !isFinite(hi)) { lo = 0; hi = 1; }
  // pull guides into the visible range when they are reasonably close (≤ 3% from the mark); others pin to the edge
  const ref0 = last || (lo + hi) / 2;
  for (const g of guides) if (g.price > 0 && Math.abs(g.price - ref0) / ref0 <= 0.03) { lo = Math.min(lo, g.price); hi = Math.max(hi, g.price); }
  const span = Math.max(hi - lo, ref0 * 0.0005);
  lo -= span * 0.08;
  hi += span * 0.08;
  const y = (p: number) => PAD.t + ((hi - p) / (hi - lo)) * ph;
  const t0 = data[0]?.t ?? 0;
  const t1 = data[data.length - 1]?.t ?? 1;
  const x = (t: number) => PAD.l + (t1 === t0 ? pw : ((t - t0) / (t1 - t0)) * pw * 0.94);

  const pts = data.map((d) => `${x(d.t).toFixed(1)},${y(d.c).toFixed(1)}`).join(" ");
  const area = data.length ? `M${x(t0)},${PAD.t + ph} L${pts.replace(/ /g, " L")} L${x(t1)},${PAD.t + ph} Z` : "";

  const ticks: number[] = [];
  const step = niceStep((hi - lo) / 7);
  for (let v = Math.ceil(lo / step) * step; v <= hi; v += step) ticks.push(v);
  const tticks: number[] = [];
  if (data.length > 1) for (let i = 0; i < 6; i++) tticks.push(t0 + ((t1 - t0) * i) / 5);
  const fmt = (p: number) => p.toLocaleString("en-US", { minimumFractionDigits: 1, maximumFractionDigits: 1 });

  return (
    <div className="chart" ref={ref}>
      <div className="watermark">bustline_</div>
      <svg width={w} height={h}>
        {ticks.map((v) => (
          <g key={v}>
            <line x1={PAD.l} x2={PAD.l + pw} y1={y(v)} y2={y(v)} stroke="#E4D8BC" strokeWidth={1} />
            <text x={w - PAD.r + 6} y={y(v) + 3} className="axis">{fmt(v)}</text>
          </g>
        ))}
        <line x1={PAD.l + pw} x2={PAD.l + pw} y1={0} y2={h} stroke="#D9CDB0" />
        <line x1={0} x2={w} y1={PAD.t + ph} y2={PAD.t + ph} stroke="#D9CDB0" />
        {tticks.map((t, i) => (
          <text key={t} x={x(t) + (i === 0 ? 4 : 0)} y={h - 6} className="axis" textAnchor={i === 0 ? "start" : "middle"}>
            {new Date(t * 1000).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", hour12: false })}
          </text>
        ))}
        {area && <path d={area} fill="#E9DDC2" opacity={0.75} />}
        {pts && <polyline points={pts} fill="none" stroke="#2B2418" strokeWidth={1.5} strokeLinejoin="round" />}
        {data.length > 0 && <circle cx={x(t1)} cy={y(closes[closes.length - 1])} r={3} fill="#2B2418" />}
        {guides.map((g, i) => {
          if (!(g.price > 0)) return null;
          const off = g.price < lo ? "below" : g.price > hi ? "above" : null;
          const yy = off === "below" ? PAD.t + ph - 2 : off === "above" ? PAD.t + 2 : y(g.price);
          return (
            <g key={i}>
              {!off && <line x1={PAD.l} x2={PAD.l + pw} y1={yy} y2={yy} stroke={g.color} strokeWidth={1} strokeDasharray={g.dashed ? "5 4" : undefined} />}
              <text x={PAD.l + pw - 6} y={off === "below" ? yy - 4 : yy - 4 + (off === "above" ? 12 : 0)} className="guide" textAnchor="end" fill={g.color}>
                {off === "below" ? "↓ " : off === "above" ? "↑ " : ""}{g.label} {fmt(g.price)}
              </text>
              {!off && (
                <g>
                  <rect x={w - PAD.r + 1} y={yy - 7} width={PAD.r - 2} height={14} fill="#F3EBD8" stroke={g.color} />
                  <text x={w - PAD.r + 5} y={yy + 3} className="axis" fill={g.color}>{fmt(g.price)}</text>
                </g>
              )}
            </g>
          );
        })}
        {last ? (
          <g>
            <line x1={PAD.l} x2={PAD.l + pw} y1={y(last)} y2={y(last)} stroke="#9B2C2C" strokeDasharray="2 3" opacity={0.7} />
            <rect x={w - PAD.r + 1} y={y(last) - 7} width={PAD.r - 2} height={14} fill="#9B2C2C" />
            <text x={w - PAD.r + 5} y={y(last) + 3} className="axis" fill="#fff">{fmt(last)}</text>
          </g>
        ) : null}
      </svg>
    </div>
  );
}

function niceStep(raw: number) {
  const p = Math.pow(10, Math.floor(Math.log10(raw || 1)));
  const n = raw / p;
  return (n < 1.5 ? 1 : n < 3 ? 2 : n < 7 ? 5 : 10) * p;
}
