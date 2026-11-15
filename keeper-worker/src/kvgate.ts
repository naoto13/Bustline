/**
 * When the keeper persists its run state to Workers KV. Leaf module (no imports) so it can be unit-tested with
 * `node --experimental-strip-types --test` (like pause.ts).
 *
 * KV free tier = 1000 writes/day and a cron run is every minute, so a write per run (1440/day) exhausts it; after that
 * `put` throws and the cursor is no longer saved. Errors therefore no longer force a write every run: only a CHANGE in
 * the kind of errors does, and at most once per ERROR_WRITE_MIN_INTERVAL_S. A steady error state is reported by the
 * 10-minute periodic write (~144/day). Worst case (error kinds flip every run): 1440/300 s ≈ 288 + 144 periodic < 1000.
 */

/** Minimum seconds between two writes caused only by an error-kind change. */
export const ERROR_WRITE_MIN_INTERVAL_S = 300;
const MAX_SIG = 200;
const MAX_KIND = 48;

/**
 * Kind of one error line: the fixed head before the first ":" or " — ", with addresses, "#ids" and numbers removed.
 * e.g. "unknown oracle 0xab… — not pushing prices" → "unknown oracle"; "fill #7 failed: …" → "fill failed".
 */
export function errorKind(msg: string): string {
  const head = String(msg).split(":")[0].split(" — ")[0];
  return head.replace(/0x[0-9a-fA-F]*/g, "").replace(/#?\d+/g, "").replace(/\s+/g, " ").trim().slice(0, MAX_KIND);
}

/** Sorted, de-duplicated error kinds of all ticks of a run, joined with "|"; "" when no tick had an error. */
export function errorSignature(ticks: { errors: string[] }[]): string {
  const kinds = new Set<string>();
  for (const t of ticks) for (const e of t.errors ?? []) kinds.add(errorKind(e));
  return [...kinds].sort().join("|").slice(0, MAX_SIG);
}

export interface WriteInput {
  /** a fill, liquidation, harvest or Stability Pool tx happened this run */
  activity: boolean;
  pauseChanged: boolean;
  cursorMoved: boolean;
  /** the 10-minute periodic write is due */
  periodic: boolean;
  errSig: string;
  /** errSig saved by the last write; undefined = old state format or empty KV */
  prevErrSig: string | undefined;
  /** unix seconds of the last write; undefined = old state format or empty KV */
  prevWroteAt: number | undefined;
  nowSec: number;
}

export function shouldWriteState(i: WriteInput): { write: boolean; reason: string } {
  if (i.activity) return { write: true, reason: "activity" };
  if (i.pauseChanged) return { write: true, reason: "pause-changed" };
  if (i.cursorMoved) return { write: true, reason: "cursor-moved" };
  if (i.periodic) return { write: true, reason: "periodic" };
  if (i.prevErrSig !== undefined && i.errSig === i.prevErrSig) return { write: false, reason: "errors-unchanged" };
  if (i.prevWroteAt !== undefined && i.nowSec - i.prevWroteAt < ERROR_WRITE_MIN_INTERVAL_S) return { write: false, reason: "errors-changed-too-soon" };
  return { write: true, reason: "errors-changed" };
}
