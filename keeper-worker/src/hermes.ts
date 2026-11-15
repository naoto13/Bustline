/**
 * Pyth Hermes price source for PythPullOracle, plus picking the price source from the exchange's on-chain `oracle()`.
 * Leaf module (no imports) so it can be unit-tested with `node --experimental-strip-types --test` (like pause.ts).
 *
 * The Hermes response is untrusted: parseHermes rejects anything PythPullOracle.latest() would revert on (stale, wide
 * confidence) and anything malformed, with short errors that never echo more than ~80 chars of the response.
 */

/** Pyth BTC/USD feed id (keeper/perp_keeper/prices.py PYTH_BTC_USD). */
export const PYTH_BTC_USD = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43";
export const HERMES_HOST = "hermes.pyth.network";
export const hermesUrl = (feedId: string = PYTH_BTC_USD) =>
  `https://${HERMES_HOST}/v2/updates/price/latest?ids[]=${feedId}&encoding=hex&parsed=true`;

/** `HouseExchange.oracle()` (keeper/abi/HouseExchange.selectors.json). */
export const ORACLE_SELECTOR = "0x7dc0d1d0";
/** `IPriceOracle.updateFee(bytes[])` (out/PythPullOracle.sol/PythPullOracle.json methodIdentifiers). */
export const UPDATE_FEE_SELECTOR = "0x7311cdcf";
/** Refuse to send if the oracle asks for more than this (wei). PythPullOracle currently charges 1 wei. */
export const MAX_UPDATE_FEE_WEI = 10_000n;

const MAX_UPDATES = 4;
const MAX_UPDATE_HEX = 32_768; // 16 KB per update
const MAX_AGE_S = 55; // < PythPullOracle.maxAge (60 s)
const MAX_FUTURE_S = 10;
const MAX_CONF_BPS = 100n; // PythPullOracle.maxConfBps

const ZERO = "0x" + "0".repeat(40);
const clip = (v: unknown) => String(typeof v === "string" ? v : JSON.stringify(v)).slice(0, 80);
const bare = (h: string) => (h.startsWith("0x") || h.startsWith("0X") ? h.slice(2) : h).toLowerCase();
const UINT = /^[0-9]+$/;

export interface HermesPrice { price: bigint; publishTime: number; data: `0x${string}`[] }

/** Parse a Hermes `/v2/updates/price/latest?encoding=hex&parsed=true` response into a WAD price + update data. */
export function parseHermes(json: unknown, feedId: string, nowSec: number): HermesPrice {
  const j = json as any;
  const raw = j?.binary?.data;
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_UPDATES) throw new Error("hermes: bad binary.data");
  const data = raw.map((h: unknown) => {
    if (typeof h !== "string") throw new Error("hermes: update is not a string");
    const b = bare(h);
    if (b.length === 0 || b.length % 2 || !/^[0-9a-f]+$/.test(b)) throw new Error(`hermes: update is not hex: ${clip(h)}`);
    if (b.length > MAX_UPDATE_HEX) throw new Error(`hermes: update too long (${b.length / 2} bytes)`);
    return `0x${b}` as `0x${string}`;
  });
  const parsed = j?.parsed;
  if (!Array.isArray(parsed) || parsed.length !== 1) throw new Error("hermes: bad parsed");
  const q = parsed[0];
  if (typeof q?.id !== "string" || bare(q.id) !== bare(feedId)) throw new Error(`hermes: wrong feed ${clip(q?.id)}`);
  const p = q.price;
  if (typeof p?.price !== "string" || !UINT.test(p.price) || BigInt(p.price) === 0n) throw new Error(`hermes: bad price ${clip(p?.price)}`);
  if (!Number.isInteger(p.expo) || p.expo < -18 || p.expo > 0) throw new Error(`hermes: bad expo ${clip(p?.expo)}`);
  if (typeof p.conf !== "string" || !UINT.test(p.conf)) throw new Error(`hermes: bad conf ${clip(p?.conf)}`);
  const px = BigInt(p.price), conf = BigInt(p.conf);
  if (conf * 10_000n > px * MAX_CONF_BPS) throw new Error(`hermes: confidence too wide (${clip(p.conf)} vs ${clip(p.price)})`);
  const t = p.publish_time;
  if (!Number.isInteger(t)) throw new Error(`hermes: bad publish_time ${clip(t)}`);
  if (t < nowSec - MAX_AGE_S) throw new Error(`hermes: stale price (${nowSec - t} s old)`);
  if (t > nowSec + MAX_FUTURE_S) throw new Error(`hermes: publish_time ${t - nowSec} s in the future`);
  // same as prices.HermesSource: price_raw * 10 ** (18 + expo); expo in [-18, 0] so the exponent is never negative
  return { price: px * 10n ** BigInt(18 + p.expo), publishTime: t, data };
}

export type SourceMode = "signed" | "pyth";

/** Which price source the exchange's current `oracle()` needs; null = unknown oracle (do not push prices). */
export function pickSource(onchainOracle: string, signedOracle: string, pythOracle: string | undefined): SourceMode | null {
  const o = onchainOracle.toLowerCase();
  if (o === ZERO) return null;
  if (o === signedOracle.toLowerCase()) return "signed";
  if (pythOracle && pythOracle.toLowerCase() !== ZERO && o === pythOracle.toLowerCase()) return "pyth";
  return null;
}

/** Last 20 bytes of a 32-byte ABI word as a lowercase 0x address; anything malformed → the zero address. */
export function wordToAddress(word: unknown): string {
  if (typeof word !== "string") return ZERO;
  const h = bare(word);
  if (h.length < 64 || !/^[0-9a-f]{64}/.test(h)) return ZERO;
  return "0x" + h.slice(24, 64);
}
