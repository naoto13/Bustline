// Layout regression: trade page at several viewports (headless Chrome, `pnpm build && pnpm start`, testnet read-only).
// Checks: chart column stays inside .trade, the bottom tabs do not overlap it, every header stat is visible, no page h-scroll.
const { chromium } = require("playwright-core");

const URL = process.env.APP_URL || "http://127.0.0.1:3100/";
const SIZES = [[1440, 900], [1280, 800], [1046, 1470], [1000, 700], [430, 900]];

const measure = (p) => p.evaluate(() => {
  const r = (sel) => { const e = document.querySelector(sel); if (!e) return null; const b = e.getBoundingClientRect(); return { top: b.top + scrollY, bottom: b.bottom + scrollY, left: b.left, right: b.right, height: b.height }; };
  const chips = document.querySelector(".chips");
  const cb = chips.getBoundingClientRect();
  const outside = [...chips.children].map((c) => ({ c, b: c.getBoundingClientRect() }))
    .filter(({ b }) => b.left < cb.left - 0.5 || b.right > cb.right + 0.5 || b.top < cb.top - 0.5 || b.bottom > cb.bottom + 0.5)
    .map(({ c, b }) => `${(c.textContent || "").trim().slice(0, 14)}@${Math.round(b.left)}-${Math.round(b.right)}`);
  return {
    trade: r(".trade"), tleft: r(".tleft"), chartwrap: r(".chartwrap"), bottom: r(".bottom"), statrow: r(".statrow"),
    chipsScroll: chips.scrollWidth, chipsClient: chips.clientWidth, outside,
    docScroll: document.documentElement.scrollWidth, inner: innerWidth,
  };
});

// Poll until the measured geometry stops changing (the order column loads late and the chart re-renders on resize).
async function settle(p) {
  let prev = "", m, same = 0;
  for (let i = 0; i < 40; i++) {
    await p.waitForTimeout(250);
    m = await measure(p);
    const key = JSON.stringify(m);
    same = key === prev ? same + 1 : 0;
    prev = key;
    if (same >= 6) break;
  }
  await p.waitForTimeout(1500); // a late re-render (e.g. RPC data) must not change it either
  return measure(p);
}

function check(tag, w, m) {
  const f = [];
  if (m.tleft.bottom > m.trade.bottom + 1) f.push(`.tleft bottom ${m.tleft.bottom.toFixed(1)} > .trade bottom ${m.trade.bottom.toFixed(1)}`);
  const above = w > 900 ? m.tleft.bottom : m.trade.bottom;
  if (m.bottom.top < above - 1) f.push(`.bottom top ${m.bottom.top.toFixed(1)} < ${w > 900 ? ".tleft" : ".trade"} bottom ${above.toFixed(1)} (overlap ${(above - m.bottom.top).toFixed(1)}px)`);
  if (m.outside.length) f.push(`chips outside .chips: ${m.outside.join(", ")}`);
  if (m.chipsScroll > m.chipsClient) f.push(`.chips scrollWidth ${m.chipsScroll} > clientWidth ${m.chipsClient}`);
  if (m.docScroll > m.inner) f.push(`page h-scroll: scrollWidth ${m.docScroll} > innerWidth ${m.inner}`);
  const dims = ["trade", "tleft", "chartwrap", "bottom"].map((k) => `${k} top=${m[k].top.toFixed(0)} h=${m[k].height.toFixed(0)}`).join(" | ");
  console.log(`${f.length ? "FAIL" : "ok  "} ${tag} ${dims} | statrow h=${m.statrow.height.toFixed(0)}`);
  f.forEach((x) => console.log(`       - ${x}`));
  return f.length;
}

(async () => {
  // headless: false + --headless=new: current Chrome removed the old headless mode this playwright-core version asks for
  const b = await chromium.launch({ executablePath: process.env.CHROME_PATH || "/usr/bin/google-chrome", headless: false, args: ["--no-sandbox", "--headless=new", "--hide-scrollbars"] });
  let fails = 0;
  const open = async ([w, h]) => {
    const p = await b.newPage({ viewport: { width: w, height: h } });
    await p.goto(URL, { waitUntil: "networkidle" });
    await p.waitForFunction(() => /\$\d/.test(document.querySelector('[data-stat="price"]')?.textContent || ""), null, { timeout: 30000 });
    return p;
  };
  for (const [w, h] of SIZES) {
    const p = await open([w, h]);
    fails += check(`${w}x${h}`, w, await settle(p));
    await p.close();
  }
  // resize in both directions on a live page: the chart must shrink back, not keep the old height
  for (const [from, to] of [[[1440, 900], [1000, 700]], [[1000, 700], [1440, 900]], [[1046, 1470], [1440, 900]]]) {
    const p = await open(from);
    await settle(p);
    await p.setViewportSize({ width: to[0], height: to[1] });
    fails += check(`${from.join("x")}→${to.join("x")}`, to[0], await settle(p));
    await p.close();
  }
  await b.close();
  console.log(fails ? `layout: ${fails} failure(s)` : "layout: all ok");
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
