import { formatUnits } from "viem";
import { UINT_MAX } from "./chain";

export const num = (v: bigint | undefined, d = 2) =>
  v === undefined ? "–" : Number(formatUnits(v, 18)).toLocaleString("en-US", { maximumFractionDigits: d, minimumFractionDigits: d });
export const usd = (v?: bigint, d = 2) => (v === undefined ? "–" : `$${num(v, d)}`);
export const signed = (v?: bigint, d = 2) => (v === undefined ? "–" : `${v < 0n ? "-" : "+"}${num(v < 0n ? -v : v, d)}`);
export const _u = UINT_MAX;
