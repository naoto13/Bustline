// v3.1 pause handling in the keeper (pure decision logic from src/pause.ts). Run: pnpm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { PAUSED_SELECTOR, parsePaused, pauseGate } from "../src/pause.ts";

const word = (v) => "0x" + BigInt(v).toString(16).padStart(64, "0");

test("selector is paused()", () => {
  assert.equal(PAUSED_SELECTOR, "0x5c975abb"); // cast sig "paused()"
});

test("parsePaused: true / false words", () => {
  assert.equal(parsePaused({ result: word(1) }), true);
  assert.equal(parsePaused({ result: word(0) }), false);
});

test("parsePaused: v3 (no paused(), call reverts) reads as not paused", () => {
  assert.equal(parsePaused({ error: { message: "execution reverted" } }), false);
  assert.equal(parsePaused({ result: "0x" }), false); // empty return
  assert.equal(parsePaused(undefined), false); // missing batch entry
});

test("paused: skips fills + liquidations and holds the scan cursor", () => {
  const g = pauseGate(true, false);
  assert.equal(g.skipTrading, true);
  assert.equal(g.moveCursor, false);
  assert.equal(g.paused, true);
});

test("not paused: trades and moves the cursor", () => {
  const g = pauseGate(false, false);
  assert.equal(g.skipTrading, false);
  assert.equal(g.moveCursor, true);
  assert.equal(g.log, null);
});

test("logs once on pause and once on resume, not every tick", () => {
  let was = false;
  const logs = [];
  for (const p of [false, true, true, true, false, false]) {
    const g = pauseGate(p, was);
    was = g.paused;
    if (g.log) logs.push(g.log);
  }
  assert.equal(logs.length, 2);
  assert.match(logs[0], /PAUSED/);
  assert.match(logs[1], /unpaused/);
});
