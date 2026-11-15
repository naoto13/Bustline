// KV write gating (pure logic from src/kvgate.ts). Run: pnpm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { ERROR_WRITE_MIN_INTERVAL_S, errorKind, errorSignature, shouldWriteState } from "../src/kvgate.ts";

// every error line src/index.ts can produce (grep "errors.push" / "tick failed"), with two variants each
const LINES = [
  ["unknown oracle 0x1212121212121212121212121212121212121212 — not pushing prices", "unknown oracle 0x0000000000000000000000000000000000000000 — not pushing prices", "unknown oracle"],
  ["price source unavailable — using on-chain price: Error: hermes HTTP 500", "price source unavailable — using on-chain price: Error: hermes: stale price (56 s old)", "price source unavailable"],
  ["oracle unavailable — fills/liquidations paused: execution reverted: StalePrice(123)", "oracle unavailable — fills/liquidations paused: ", "oracle unavailable"],
  ["fill #7 failed: RpcError: tx reverted: 0xabc", "fill #12345 failed: RpcError: no receipt yet: 0xdef", "fill failed"],
  ["liquidation #3 failed: RpcError: tx reverted: 0x1", "liquidation #99 failed: Error: nonce too low", "liquidation failed"],
  ["price push failed: RpcError: tx reverted: 0x2", "price push failed: RpcError: rpc http 502", "price push failed"],
  ["harvest failed: RpcError: tx reverted: 0x3", "harvest failed: TypeError: fetch failed", "harvest failed"],
  ["sp preview failed: execution reverted", "sp preview failed: undefined", "sp preview failed"],
  ["rebalance failed: RpcError: tx reverted: 0x4", "rebalance failed: Error: x", "rebalance failed"],
  ["forwardBtc failed: RpcError: tx reverted: 0x5", "forwardBtc failed: Error: y", "forwardBtc failed"],
  ["tick failed: RpcError: refusing: chainId 1 != 31611", "tick failed: RpcError: rpc http 429", "tick failed"],
];

test("errorKind: every index.ts error line maps to its fixed head, variable parts dropped", () => {
  for (const [a, b, kind] of LINES) {
    assert.equal(errorKind(a), kind, a);
    assert.equal(errorKind(b), kind, b);
  }
});

test("errorSignature: same kinds with different addresses / numbers give the same signature", () => {
  const s1 = errorSignature([{ errors: [LINES[0][0], LINES[3][0]] }, { errors: [LINES[1][0]] }]);
  const s2 = errorSignature([{ errors: [LINES[1][1]] }, { errors: [LINES[3][1], LINES[0][1], LINES[0][0]] }]);
  assert.equal(s1, s2);
  assert.equal(s1, "fill failed|price source unavailable|unknown oracle"); // sorted, de-duplicated
});

test("errorSignature: empty when there are no errors; length is capped", () => {
  assert.equal(errorSignature([]), "");
  assert.equal(errorSignature([{ errors: [] }, { errors: [] }]), "");
  const many = Array.from({ length: 50 }, (_, i) => `kind${"abcdefghij"[i % 10]}${"klmnopqrst"[Math.floor(i / 10)]} failed: x`);
  assert.ok(errorSignature([{ errors: many }]).length <= 200);
  assert.ok(errorKind("x".repeat(500)).length <= 48);
});

const base = { activity: false, pauseChanged: false, cursorMoved: false, periodic: false, errSig: "", prevErrSig: "", prevWroteAt: 1000, nowSec: 1060 };
const dec = (o) => shouldWriteState({ ...base, ...o });

test("activity / pause change / cursor move / periodic always write (regardless of errors and interval)", () => {
  for (const k of ["activity", "pauseChanged", "cursorMoved", "periodic"]) {
    const d = dec({ [k]: true, errSig: "unknown oracle", prevErrSig: "unknown oracle", nowSec: 1001 });
    assert.equal(d.write, true, k);
  }
  assert.equal(dec({ activity: true }).reason, "activity");
  assert.equal(dec({ periodic: true }).reason, "periodic");
});

test("nothing happened and no errors: no write", () => {
  assert.equal(dec({}).write, false);
});

test("error kind changed: write only after the minimum interval", () => {
  assert.equal(ERROR_WRITE_MIN_INTERVAL_S, 300);
  assert.deepEqual(dec({ errSig: "unknown oracle", nowSec: 1000 + 300 }), { write: true, reason: "errors-changed" });
  assert.deepEqual(dec({ errSig: "unknown oracle", nowSec: 1000 + 299 }), { write: false, reason: "errors-changed-too-soon" });
});

test("same errors as last write: no write (left to the periodic write)", () => {
  assert.deepEqual(dec({ errSig: "unknown oracle", prevErrSig: "unknown oracle", nowSec: 99_999 }), { write: false, reason: "errors-unchanged" });
});

test("errors cleared (non-empty → empty) counts as a change", () => {
  assert.equal(dec({ errSig: "", prevErrSig: "unknown oracle", nowSec: 1300 }).write, true);
  assert.equal(dec({ errSig: "", prevErrSig: "unknown oracle", nowSec: 1100 }).write, false);
});

test("old state format (no errSig / wroteAt) reads as changed + long enough ago", () => {
  assert.equal(dec({ errSig: "unknown oracle", prevErrSig: undefined, prevWroteAt: undefined }).write, true);
  assert.equal(dec({ errSig: "", prevErrSig: undefined, prevWroteAt: undefined }).write, true);
  assert.equal(dec({ errSig: "x", prevErrSig: undefined, prevWroteAt: 1050 }).write, false); // wroteAt known and recent
});
