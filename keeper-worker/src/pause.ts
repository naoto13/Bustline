/**
 * HouseExchange v3.1 emergency pause, as seen by the keeper. Leaf module (no imports) so it can be unit-tested with
 * `node --experimental-strip-types --test` without the viem / Workers runtime.
 *
 * While paused the contract reverts `EnforcedPause` on requestOpen, executeOrder, liquidate and sweepExcess, and
 * rebalance only withdraws. The keeper therefore skips fills and liquidations (they would only burn gas and spam
 * errors), keeps its order-scan cursor where it is (so orders queued during the pause — e.g. requestClose — are still
 * scanned after unpause), and keeps doing what stays allowed: price pushes, queue harvest, rebalance, forwardBtc.
 */

/** `paused()` selector (`cast sig "paused()"`). */
export const PAUSED_SELECTOR = "0x5c975abb";

/** One JSON-RPC batch entry for `eth_call(paused())`. */
export type PausedRes = { result?: string; error?: unknown } | undefined;

/**
 * v3 has no `paused()` and no `fallback()`, so the call reverts: treat any error (or an empty return) as "not paused".
 * A transient RPC error therefore also reads as "not paused"; the worst case is one fill attempt that reverts.
 */
export function parsePaused(r: PausedRes): boolean {
  if (!r || r.error || typeof r.result !== "string") return false;
  const h = r.result.startsWith("0x") ? r.result.slice(2) : r.result;
  if (h.length < 64) return false;
  return BigInt("0x" + h.slice(0, 64)) !== 0n;
}

export interface PauseDecision {
  /** skip executeOrder / liquidate this tick */
  skipTrading: boolean;
  /** advance the pending-order scan cursor this tick (false while paused) */
  moveCursor: boolean;
  /** a one-line log message on a state change only, else null */
  log: string | null;
  /** new remembered state (persist it so a long pause logs once, not once per tick / cron run) */
  paused: boolean;
}

/** `wasPaused` = last state the keeper saw (persisted in KV); `paused` = this tick's `paused()` read. */
export function pauseGate(paused: boolean, wasPaused: boolean): PauseDecision {
  let log: string | null = null;
  if (paused && !wasPaused) log = "exchange PAUSED — skipping fills and liquidations (harvest / rebalance / price pushes continue)";
  else if (!paused && wasPaused) log = "exchange unpaused — resuming fills and liquidations";
  return { skipTrading: paused, moveCursor: !paused, log, paused };
}
