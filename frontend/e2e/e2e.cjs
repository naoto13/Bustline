// E2E: headless Chrome drives the UI against a fresh local anvil fork (scripts/dev-fork.sh + `npm run build && npm start`).
const { chromium } = require("playwright-core");
const path = require("path");
(async () => {
  const b = await chromium.launch({ executablePath: process.env.CHROME_PATH || "/usr/bin/google-chrome", args: ["--no-sandbox"] });
  const p = await b.newPage({ viewport: { width: 1280, height: 1600 } });
  const errs = [];
  p.on("pageerror", (e) => errs.push(e.message));
  await p.goto(process.env.APP_URL || "http://127.0.0.1:3100/", { waitUntil: "networkidle" });
  await p.getByText("House cash").waitFor({ timeout: 30000 });
  const stat = async (k) => (await p.locator(".card", { has: p.locator(".k", { hasText: new RegExp(`^${k}`) }) }).first().locator(".v").innerText()).trim();
  const snap = async (tag) => console.log(tag, JSON.stringify({ price: await stat("BTC/USD"), house: await stat("House cash"), queue: await stat("Payout queue"), equity: await stat("House equity") }));
  let seen = 0;
  const waitLog = async (label) => {
    const t0 = Date.now();
    let lines = [];
    for (;;) {
      const t = (await p.locator(".log").innerText()).trim();
      lines = t === "—" ? [] : t.split("\n");
      if (lines.length > seen && new RegExp(`(✅|❌) ${label}`).test(lines[0])) break;
      if (Date.now() - t0 > 60000) throw new Error(`timeout waiting for ${label}`);
      await p.waitForTimeout(250);
    }
    seen = lines.length;
    const first = lines[0];
    console.log("  log:", first);
    if (first.includes("❌")) throw new Error(first);
    await p.waitForTimeout(3500);
  };
  const trade = async (side, margin, lev) => {
    await p.getByRole("button", { name: side === "long" ? "Long" : "Short", exact: true }).click();
    await p.getByLabel("margin").fill(String(margin));
    await p.getByLabel("leverage").fill(String(lev));
    await p.getByRole("button", { name: new RegExp(`Request ${side} open`) }).click();
    await waitLog("requestOpen");
  };
  const keeper = async () => { await p.getByRole("button", { name: "Run keeper step" }).click(); await waitLog("keeper step"); };
  const acct = async (i) => { await p.locator("select").selectOption({ index: i }); await p.waitForTimeout(3500); };

  await snap("initial");
  await p.screenshot({ path: path.join(__dirname, "../../docs/demo/frontend-initial.png"), fullPage: true });
  await acct(1); await trade("long", 500, 20);           // alice long 10k
  await acct(2); await trade("short", 200, 100);         // bob short 20k @100x
  await keeper(); await snap("after fills");
  console.log("  bob liq price row:", (await p.locator("tbody tr").first().innerText()).replace(/\s+/g, " "));
  await p.getByRole("button", { name: "BTC +0.5%" }).click(); await waitLog("oracle");
  await acct(1); await p.getByRole("button", { name: "Close" }).first().click(); await waitLog("requestClose");
  await keeper(); await snap("alice closed in profit (house empty → queued)");
  console.log("  alice queue card:", (await p.locator(".card", { has: p.locator("h3", { hasText: "My payout queue" }) }).innerText()).replace(/\s+/g, " "));
  await p.getByRole("button", { name: "BTC +2%" }).click(); await waitLog("oracle");
  await keeper(); await snap("bob 100x short liquidated → queue repaid");
  await acct(2);
  console.log("  bob rebate card:", (await p.locator(".card", { has: p.locator("h3", { hasText: "Rebate token" }) }).innerText()).replace(/\s+/g, " "));
  await p.getByRole("button", { name: "Stake", exact: true }).click(); await waitLog("stake");
  console.log("  bob rebate card after stake:", (await p.locator(".card", { has: p.locator("h3", { hasText: "Rebate token" }) }).innerText()).replace(/\s+/g, " "));
  await p.screenshot({ path: path.join(__dirname, "../../docs/demo/frontend-after-e2e.png"), fullPage: true });
  console.log("page errors:", errs.length ? errs : "none");
  await b.close();
})().catch((e) => { console.error("E2E FAIL", e.message); process.exit(1); });
