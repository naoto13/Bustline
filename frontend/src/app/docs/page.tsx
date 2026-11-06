import type { Metadata } from "next";
import Link from "next/link";
import DocsContracts from "@/components/DocsContracts";
import { BTC_FAUCET_URL, EXPLORER_URL } from "@/lib/config";

export const metadata: Metadata = {
  title: "Docs — Bustline",
  description: "How Bustline works: 2-step fills, bust lines, the house and payout queue, MPAPER, fees, oracles, governance and contracts. Mezo testnet only, unaudited.",
};

const REPO = "https://github.com/naoto13/Bustline";

const TOC: [id: string, label: string][] = [
  ["what", "What Bustline is"],
  ["trade", "How a trade works"],
  ["funding", "Funding a trade"],
  ["house", "The house & payout queue"],
  ["mpaper", "MPAPER & staking"],
  ["fees", "Fees & revenue"],
  ["prices", "Prices & oracles"],
  ["governance", "Governance & keys"],
  ["contracts", "Contracts"],
  ["risks", "Risks & limitations"],
  ["links", "Links"],
];

function Toc() {
  return (
    <ol className="docs-toclist">
      {TOC.map(([id, label]) => (
        <li key={id}><a href={`#${id}`}>{label}</a></li>
      ))}
    </ol>
  );
}

function Facts({ rows }: { rows: [k: string, v: React.ReactNode][] }) {
  return (
    <dl className="docs-facts">
      {rows.map(([k, v]) => (
        <div key={k} className="docs-fact"><dt>{k}</dt><dd>{v}</dd></div>
      ))}
    </dl>
  );
}

export default function DocsPage() {
  return (
    <div className="app">
      <header className="nav">
        <Link href="/" className="wordmark" aria-label="Bustline — back to the trade screen">bustline<span className="cursor">_</span></Link>
        <nav aria-label="App">
          <Link href="/">Trade</Link>
          <Link href="/?tab=house">House</Link>
          <Link href="/?tab=mpaper">MPAPER</Link>
          <a className="active" aria-current="page" href="#top">Docs</a>
        </nav>
        <div className="navr">
          <span className="chip tag-testnet">TESTNET</span>
          <Link href="/" className="navbtn docs-open">Open app →</Link>
        </div>
      </header>
      <div className="banner">
        Testnet demo — Mezo testnet (31611) only. Up to 100x leverage; losses can be total.
      </div>

      <div className="docs" id="top">
        <aside className="docs-toc">
          <details className="docs-tocm">
            <summary>On this page</summary>
            <Toc />
          </details>
          <div className="docs-tocd">
            <div className="docs-toch">On this page</div>
            <Toc />
          </div>
        </aside>

        <article className="docs-body">
          <header className="docs-hero">
            <div className="docs-eyebrow">Bustline docs</div>
            <h1>A 100x BTC perp where the house is funded only by trader losses.</h1>
            <p className="docs-lede">
              Everything a trader needs to know before pressing <b>Request long open</b>: how fills work, where the bust line
              comes from, who pays winners, and what you get back when you lose.
            </p>
          </header>

          <section id="what">
            <h2>What Bustline is</h2>
            <p>
              Bustline is a single-market <b>BTC/USD synthetic perpetual</b> on <b>Mezo testnet</b>, margined in <b>MUSD</b>.
              There are no LP deposits. The counterparty is a <b>house that starts at 0 MUSD</b> and grows only from trader losses.
            </p>
            <Facts rows={[
              ["Market", "BTC/USD, isolated margin"],
              ["Size", <>margin × leverage, <span className="num">1–100x</span></>],
              ["Minimum margin", <span className="num">10 MUSD</span>],
              ["Funding rate / spread", "none"],
              ["Caps", "max position size and per-side open-interest caps"],
            ]} />
            <p>
              Winners are paid from the house. When the house is short, the rest waits in a FIFO payout queue. Losers receive
              non-transferable <b>MPAPER</b>, which can be staked for a share of MUSD fees. The contract never pays out more than it
              holds: <code>MUSD held == houseCash + open margin + escrow</code>.
            </p>
          </section>

          <section id="trade">
            <h2>How a trade works</h2>
            <p>
              Every open and close is <b>2-step</b>, so nobody can trade against a price they have already seen.
            </p>
            <ol className="docs-flow">
              <li><b>Request.</b> You call <code>requestOpen</code> (or <code>requestClose</code>). Your margin is escrowed and the block time is recorded.</li>
              <li><b>Fill.</b> The keeper ticks every 15 s and calls <code>executeOrder</code> with a price published <em>after</em> your request. Earlier prices revert with <code>NotYetFillable</code>.</li>
              <li><b>Settle.</b> The position opens or closes. Profit is paid (or queued); a loss goes to the house and mints MPAPER.</li>
            </ol>
            <p className="docs-muted">
              Orders not filled within 5 minutes become refundable. Slippage or OI-cap failures cancel and refund.
            </p>

            <h3>The bust line</h3>
            <p>
              The bust line is the liquidation price, drawn on the chart before you submit. It is the zero-equity price moved
              5 bps back toward entry. When the price crosses it, anyone can call <code>liquidate</code> and the{" "}
              <b>full margin is forfeited</b>. A close that lands past the line is treated as a bust.
            </p>
            <Facts rows={[
              ["Buffer", <span className="num">5 bps toward entry</span>],
              ["Liquidator reward", <span className="num">0.5% of margin</span>],
              ["To stakers", <><span className="num">2% of margin</span> (only when the queue is empty)</>],
            ]} />

            <h3>Wins: impact haircut and fees</h3>
            <p>
              A winning close is measured <span className="num">entry/50,000</span> worse (deadband), then scaled by an asymmetric
              impact haircut that depends on the size of the move and the position. Two fees are taken from that adjusted gain:{" "}
              <b>2% to MPAPER stakers</b> and, from v3.1, a <b>1% protocol fee</b> to the treasury (see{" "}
              <a className="docs-link" href="#fees">Fees &amp; revenue</a>). Fees apply only when the profit is paid in full right
              away; a queued or partial payout is fee-free.
            </p>
            <h3>Losses</h3>
            <p>
              You can lose up to your margin. A <b>2% loss fee</b> goes to stakers only when the payout queue is empty and someone is
              staking; otherwise the whole loss goes to the house.
            </p>
          </section>

          <section id="funding">
            <h2>Funding a trade</h2>
            <p>The order panel offers three routes to get MUSD margin.</p>
            <div className="docs-routes">
              <div className="docs-route">
                <div className="docs-rh">Start with BTC</div>
                <p>Opens a Mezo trove with your BTC (<code>openTrove</code>), borrows MUSD, then requests the trade.</p>
              </div>
              <div className="docs-route">
                <div className="docs-rh">From my trove</div>
                <p>Borrows more MUSD from the trove you already have (<code>withdrawMUSD</code>). One trove per address.</p>
              </div>
              <div className="docs-route">
                <div className="docs-rh">Deposit MUSD</div>
                <p>Uses MUSD already in your wallet. No trove involved.</p>
              </div>
            </div>

            <h3>Two liquidation lines</h3>
            <p>
              A trove-funded trade has <b>two separate lines</b> on the chart. The position busts at its own bust line. The trove is a
              separate loan and is liquidated only at its <b>110% ICR</b> line (shown as <i>TROVE LIQ 110%</i>).
            </p>
            <Facts rows={[
              ["Minimum ICR (MCR)", <><span className="num">110%</span> — below this the protocol rejects the trove</>],
              ["Warning", <>ICR under <span className="num">125%</span></>],
              ["Recommended", <><span className="num">150%</span> — also the recovery-mode floor for new troves</>],
              ["Minimum net debt", <><span className="num">1,800 MUSD</span> (read from the protocol at runtime)</>],
              ["Gas compensation", <><span className="num">200 MUSD</span>, added to the trove debt</>],
            ]} />
            <p className="docs-muted">
              Mezo Passport BTC wallets sign one call at a time, so “Start with BTC” is three transactions:{" "}
              <code>openTrove</code> → <code>approve</code> (first time only) → <code>requestOpen</code>. If a later step fails, the
              borrowed MUSD stays in your wallet and the flow resumes from that step. Use “Repay trove” (<code>repayMUSD</code>) to pay
              debt back.
            </p>
          </section>

          <section id="house">
            <h2>The house &amp; payout queue</h2>
            <p>
              The house holds only what losers paid in. House equity is <code>houseCash − queueTotal</code> and may go negative while
              the contract stays fully backed.
            </p>
            <ul className="docs-list">
              <li><b>Margin is always returned immediately.</b> Only profit can be queued.</li>
              <li>When the house can’t pay a winner in full, the rest enters a <b>FIFO queue</b>. New winners never jump the queue.</li>
              <li><code>harvest(n)</code> pays the queue in order. Anyone can call it, and it runs on every loss.</li>
            </ul>
            <h3>Stability Pool</h3>
            <p>
              Idle house MUSD earns in the Mezo MUSD Stability Pool. <code>rebalance()</code> deposits house cash above a liquid
              floor and withdraws when cash runs low. Winners are paid from cash first, then topped up from the pool, then the queue.
              Margin and escrow never go into the pool.
            </p>
            <Facts rows={[
              ["Liquid floor (spMinLiquid)", <span className="num">50 MUSD</span>],
              ["Max pool share", <><span className="num">50%</span> of house assets</>],
            ]} />
          </section>

          <section id="mpaper">
            <h2>MPAPER &amp; staking</h2>
            <p>
              <b>Mezo Paper (MPAPER)</b> is minted to you on a realised loss (a bust counts the full margin). It is{" "}
              <b>non-transferable</b>. While house equity is below a threshold you receive{" "}
              <span className="num">100 MPAPER per MUSD</span> lost; after that the rate follows a decreasing curve.
            </p>
            <p>Stake MPAPER in the <Link className="docs-link" href="/?tab=mpaper">MPAPER tab</Link> to earn:</p>
            <ul className="docs-list">
              <li><b>MUSD</b> — loss, win and liquidation fees, plus house cash above the house cap.</li>
              <li><b>BTC</b> — collateral gains from Stability Pool liquidations, forwarded by <code>forwardBtc()</code>.</li>
            </ul>
            <p className="docs-muted"><code>claim()</code> pays both. MPAPER and stakes from the earlier v2 market were not carried over.</p>
          </section>

          <section id="fees">
            <h2>Fees &amp; revenue</h2>
            <p>
              There is no seed capital, no LP and no funding rate. The house is funded only by trader losses, and a winner it
              can’t pay in full waits in the FIFO queue. Fees come out of trading results only:
            </p>
            <div className="docs-tablewrap">
              <table className="tbl docs-otbl">
                <thead><tr><th>Fee</th><th>Charged on</th><th>Goes to</th></tr></thead>
                <tbody>
                  <tr><td className="docs-cname">Win fee</td><td><span className="num">2%</span> of the impact-adjusted gain</td><td>MPAPER stakers</td></tr>
                  <tr><td className="docs-cname">Protocol fee (v3.1)</td><td><span className="num">1%</span> of the same gain</td><td>Treasury</td></tr>
                  <tr><td className="docs-cname">Loss fee</td><td><span className="num">2%</span> of a loss, only when the queue is empty and someone stakes</td><td>MPAPER stakers</td></tr>
                  <tr><td className="docs-cname">Liquidation</td><td><span className="num">0.5%</span> of margin / <span className="num">2%</span> of margin (queue empty)</td><td>Liquidator / stakers</td></tr>
                </tbody>
              </table>
            </div>
            <ul className="docs-list">
              <li>Win and protocol fees are collected only when the winner is paid in full right away, including when the payout is topped up from the Stability Pool. Queued and partial payouts never pay a fee, not even later at harvest.</li>
              <li>The rest of every loss stays in the house and repays the queue first.</li>
              <li><b>Operator revenue funds the keeper and the oracle.</b> The treasury share pays for the keeper’s gas and price updates, so running the market does not depend on outside capital.</li>
            </ul>
            <p className="docs-muted">The protocol fee is read on-chain (<code>protocolFeeBps</code>) and capped in the contract; it is changed only through the timelock.</p>
          </section>

          <section id="prices">
            <h2>Prices &amp; oracles</h2>
            <p>
              Settlement is pull-based: the keeper puts a fresh price update in the same transaction as each fill or liquidation.
              The owner can switch the source with one <code>setOracle</code> call.
            </p>
            <div className="docs-tablewrap">
              <table className="tbl docs-otbl">
                <thead><tr><th>Source</th><th>How</th><th>Status</th></tr></thead>
                <tbody>
                  <tr>
                    <td className="docs-cname">Keeper-signed</td>
                    <td>Median of Coinbase / Kraken / Bitstamp spot (≥ 2 sources, ≤ 0.5% spread), signed report, max age 60 s</td>
                    <td><span className="tag tlong">ACTIVE</span></td>
                  </tr>
                  <tr>
                    <td className="docs-cname">Pyth pull</td>
                    <td>Mezo testnet Pyth, max age 60 s, confidence ≤ 1%</td>
                    <td><span className="tag tgrey">DEPLOYED, NOT ACTIVE</span></td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p>
              <b>Price bound.</b> Every price must stay within <span className="num">±1%</span> of Mezo’s MUSD <code>PriceFeed</code>,
              which is sourced from Skip Connect, Mezo’s native oracle. If the PriceFeed fails (no update for 60 s, or any revert) the
              bound is skipped with a <code>PriceBoundSkipped</code> event, so fills and liquidations never stop.
            </p>
            <p className="docs-muted">The chart is Coinbase public candles for display only; settlement uses the on-chain price.</p>
          </section>

          <section id="governance">
            <h2>Governance &amp; keys</h2>
            <p>
              HouseExchange, both oracles and the RebateToken are owned by an OpenZeppelin <b>TimelockController</b> with a{" "}
              <b>1-hour delay</b> on testnet. Every admin change — oracle switch, keeper whitelist, risk / fee parameters, price-signer
              rotation, Stability Pool settings, MPAPER transfers — is scheduled, waits the delay, then executes.
            </p>
            <Facts rows={[
              ["Owner", "the timelock (proposer = deployer key; anyone can execute a ready operation)"],
              ["Guardian (v3.1)", "set at deploy (the deployer key unless configured; never the keeper key) — can pause immediately, cannot unpause or change anything else"],
              ["Keeper", "separate key — fills, liquidations, price pushes, queue harvest, rebalance"],
              ["Price signer", "separate key — signs price reports only"],
            ]} />
            <h3>Emergency pause (v3.1)</h3>
            <p>
              The guardian (or the owner) can call <code>pause()</code>, which takes effect in the same block. Only the timelock can
              call <code>unpause()</code>, so resuming always waits the 1-hour delay and a guardian key alone cannot undo a pause.
            </p>
            <Facts rows={[
              ["Blocked while paused", <>new positions (<code>requestOpen</code>), all fills (<code>executeOrder</code>), <code>liquidate</code>, <code>sweepExcess</code>, and Stability Pool deposits</>],
              ["Still allowed", <><code>requestClose</code> (filled after unpause), <code>cancelExpired</code> refunds, <code>harvest</code>, pool withdrawals, <code>forwardBtc</code>, price pushes, and MPAPER stake / unstake / claim</>],
            ]} />
            <p className="docs-muted">
              A close requested during a pause that expires before unpause can be cleared with <code>cancelExpired</code>; the
              position stays open and can be closed again. A leaked keeper key cannot call owner functions.
            </p>
          </section>

          <section id="contracts">
            <h2>Contracts</h2>
            <DocsContracts />
          </section>

          <section id="risks">
            <h2>Risks &amp; limitations</h2>
            <ul className="docs-list docs-risks">
              <li><b>Testnet only.</b> Mezo testnet (chainId 31611); no real funds.</li>
              <li><b>Unaudited hackathon build.</b> Single market, isolated margin, no partial closes.</li>
              <li><b>Losses can be total.</b> At up to 100x, a small move can bust the full margin.</li>
              <li><b>Profit can wait.</b> If the house is short, winnings sit in the FIFO queue until later losses repay it.</li>
              <li><b>Stability Pool risk.</b> Trove liquidations can shrink the house’s pool deposit, and pool withdrawals are blocked while the lowest trove is below 110% ICR or the PriceFeed is down.</li>
              <li><b>Pause halts liquidations too.</b> While paused, positions can’t be filled or liquidated; prices that move past a bust line during a pause settle only after unpause.</li>
              <li><b>Permissioned keeper.</b> A single keeper run by the team fills orders; unfilled orders become refundable after 5 minutes.</li>
              <li><b>Trove routes</b> are checked read-only on testnet; the signed flows are not yet verified with real wallets.</li>
            </ul>
          </section>

          <section id="links">
            <h2>Links</h2>
            <ul className="docs-links">
              <li><a className="docs-link" href={REPO} target="_blank" rel="noreferrer">GitHub — naoto13/Bustline ↗</a></li>
              <li><a className="docs-link" href={`${REPO}/blob/main/CHANGELOG.md`} target="_blank" rel="noreferrer">CHANGELOG ↗</a></li>
              <li><a className="docs-link" href={`${REPO}/blob/main/docs/DEPLOYMENTS.md`} target="_blank" rel="noreferrer">Deployments &amp; on-chain proof ↗</a></li>
              <li><a className="docs-link" href={BTC_FAUCET_URL} target="_blank" rel="noreferrer">Mezo testnet BTC faucet ↗</a></li>
              <li><a className="docs-link" href={EXPLORER_URL} target="_blank" rel="noreferrer">Mezo testnet explorer ↗</a></li>
            </ul>
            <p><Link href="/" className="primary sm docs-back">Back to trading</Link></p>
          </section>
        </article>
      </div>

      <footer className="foot">Bustline · testnet demo, unaudited · independent implementation; mechanism inspired by public docs of Papertrade and Rollbit&apos;s market-impact model.</footer>
    </div>
  );
}
