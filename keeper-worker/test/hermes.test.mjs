// Pyth Hermes parsing + price-source pick (pure logic from src/hermes.ts). Run: pnpm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  PYTH_BTC_USD, HERMES_HOST, hermesUrl, ORACLE_SELECTOR, UPDATE_FEE_SELECTOR, MAX_UPDATE_FEE_WEI,
  parseHermes, pickSource, wordToAddress,
} from "../src/hermes.ts";

const FIX = JSON.parse(readFileSync(new URL("./fixtures/hermes-btcusd-latest.json", import.meta.url), "utf8"));
const T = 1794733931; // fixture publish_time
const fx = (edit) => { const j = structuredClone(FIX); edit?.(j); return j; };
const bad = (j, now, re) => assert.throws(() => parseHermes(j, PYTH_BTC_USD, now), re);

test("constants", () => {
  assert.equal(ORACLE_SELECTOR, "0x7dc0d1d0"); // HouseExchange oracle()
  assert.equal(UPDATE_FEE_SELECTOR, "0x7311cdcf"); // updateFee(bytes[])
  assert.equal(MAX_UPDATE_FEE_WEI, 10_000n);
  assert.equal(HERMES_HOST, "hermes.pyth.network");
  assert.equal(hermesUrl(), `https://hermes.pyth.network/v2/updates/price/latest?ids[]=${PYTH_BTC_USD}&encoding=hex&parsed=true`);
});

test("happy path: real Hermes response", () => {
  const h = parseHermes(FIX, PYTH_BTC_USD, T + 3);
  assert.equal(h.price, 6600665337099n * 10n ** 10n); // 66006.65337099e18
  assert.equal(h.price, 66006653370990000000000n);
  assert.equal(h.publishTime, T);
  assert.equal(h.data.length, 1);
  assert.equal(h.data[0].length, 2 + 1262);
  assert.ok(h.data[0].startsWith("0x504e4155")); // "PNAU"
});

test("accepts 0x-prefixed data and feed id without 0x / upper case", () => {
  const h = parseHermes(fx((j) => { j.binary.data[0] = "0x" + j.binary.data[0].toUpperCase(); }), PYTH_BTC_USD.slice(2).toUpperCase(), T);
  assert.ok(/^0x[0-9a-f]+$/.test(h.data[0]));
});

test("wrong feed id", () => {
  bad(fx((j) => { j.parsed[0].id = "ff" + j.parsed[0].id.slice(2); }), T, /wrong feed/);
  assert.throws(() => parseHermes(FIX, "0x" + "11".repeat(32), T), /wrong feed/);
});

test("bad update data: non-hex, odd length, empty, too many, too long", () => {
  bad(fx((j) => { j.binary.data[0] = "zz" + j.binary.data[0].slice(2); }), T, /not hex/);
  bad(fx((j) => { j.binary.data[0] = j.binary.data[0].slice(1); }), T, /not hex/);
  bad(fx((j) => { j.binary.data[0] = ""; }), T, /not hex/);
  bad(fx((j) => { j.binary.data = []; }), T, /bad binary/);
  bad(fx((j) => { delete j.binary; }), T, /bad binary/);
  bad(fx((j) => { j.binary.data = Array(5).fill(j.binary.data[0]); }), T, /bad binary/);
  bad(fx((j) => { j.binary.data[0] = 7; }), T, /not a string/);
  bad(fx((j) => { j.binary.data[0] = "ab".repeat(16_385); }), T, /too long/);
});

test("bad parsed shape", () => {
  bad(fx((j) => { j.parsed = []; }), T, /bad parsed/);
  bad(fx((j) => { j.parsed.push(j.parsed[0]); }), T, /bad parsed/);
  bad(null, T, /bad binary/);
});

test("price: zero / negative / non-integer", () => {
  bad(fx((j) => { j.parsed[0].price.price = "0"; }), T, /bad price/);
  bad(fx((j) => { j.parsed[0].price.price = "-5"; }), T, /bad price/);
  bad(fx((j) => { j.parsed[0].price.price = "1.5"; }), T, /bad price/);
  bad(fx((j) => { j.parsed[0].price.price = 6600665337099; }), T, /bad price/);
});

test("expo out of range / conf invalid", () => {
  bad(fx((j) => { j.parsed[0].price.expo = -19; }), T, /bad expo/);
  bad(fx((j) => { j.parsed[0].price.expo = 1; }), T, /bad expo/);
  bad(fx((j) => { j.parsed[0].price.expo = "-8"; }), T, /bad expo/);
  bad(fx((j) => { j.parsed[0].price.conf = "-1"; }), T, /bad conf/);
  assert.equal(parseHermes(fx((j) => { j.parsed[0].price.expo = 0; }), PYTH_BTC_USD, T).price, 6600665337099n * 10n ** 18n);
  assert.equal(parseHermes(fx((j) => { j.parsed[0].price.expo = -18; }), PYTH_BTC_USD, T).price, 6600665337099n);
});

test("confidence wider than 1% of price is rejected (mirrors maxConfBps = 100)", () => {
  bad(fx((j) => { j.parsed[0].price.price = "10000"; j.parsed[0].price.conf = "101"; }), T, /confidence/);
  const h = parseHermes(fx((j) => { j.parsed[0].price.price = "10000"; j.parsed[0].price.conf = "100"; }), PYTH_BTC_USD, T);
  assert.equal(h.price, 10000n * 10n ** 10n);
});

test("staleness: 55 s ok, 56 s rejected", () => {
  assert.equal(parseHermes(FIX, PYTH_BTC_USD, T + 55).publishTime, T);
  bad(FIX, T + 56, /stale/);
});

test("future: 10 s ok, 11 s rejected", () => {
  assert.equal(parseHermes(FIX, PYTH_BTC_USD, T - 10).publishTime, T);
  bad(FIX, T - 11, /future/);
  bad(fx((j) => { j.parsed[0].price.publish_time = "1794733931"; }), T, /publish_time/);
});

test("errors never echo much of the response", () => {
  const long = "z".repeat(5000);
  try { parseHermes(fx((j) => { j.binary.data[0] = long; }), PYTH_BTC_USD, T); assert.fail(); }
  catch (e) { assert.ok(e.message.length < 140, e.message.length); }
});

const SIGNED = "0x75a3071482883d9616bf0473B7eE25B4222b181F";
const PYTH = "0xf05B4108B93A83a1a87Ba1E392a81226aAC63619";
const ZERO = "0x" + "0".repeat(40);

test("pickSource: signed / pyth / unknown, case-insensitive", () => {
  assert.equal(pickSource(SIGNED.toLowerCase(), SIGNED, PYTH), "signed");
  assert.equal(pickSource(PYTH.toLowerCase(), SIGNED, PYTH), "pyth");
  assert.equal(pickSource(PYTH.toUpperCase().replace("0X", "0x"), SIGNED.toLowerCase(), PYTH.toLowerCase()), "pyth");
  assert.equal(pickSource("0x" + "12".repeat(20), SIGNED, PYTH), null);
});

test("pickSource: pyth unset or zero address never matches", () => {
  assert.equal(pickSource(PYTH, SIGNED, undefined), null);
  assert.equal(pickSource(ZERO, SIGNED, ZERO), null);
  assert.equal(pickSource(ZERO, SIGNED, undefined), null);
  assert.equal(pickSource(SIGNED, SIGNED, undefined), "signed");
});

test("wordToAddress decodes the oracle() return word", () => {
  const w = "0x000000000000000000000000" + PYTH.slice(2);
  assert.equal(wordToAddress(w), PYTH.toLowerCase());
  assert.equal(wordToAddress(w.slice(2)), PYTH.toLowerCase());
  assert.equal(wordToAddress("0x"), ZERO);
  assert.equal(wordToAddress(undefined), ZERO);
  assert.equal(wordToAddress("0x" + "g".repeat(64)), ZERO);
});

test("wide-confidence error clips huge numbers from the response", () => {
  const big = "9".repeat(500);
  try { parseHermes(fx((j) => { j.parsed[0].price.price = "1"; j.parsed[0].price.conf = big; }), PYTH_BTC_USD, T); assert.fail(); }
  catch (e) { assert.match(e.message, /confidence/); assert.ok(e.message.length < 220, e.message.length); }
});
