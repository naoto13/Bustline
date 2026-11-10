import type { Metadata } from "next";
import Link from "next/link";
import ProofLive from "@/components/ProofLive";
import { EXPLORER_URL } from "@/lib/config";
import { CONTRACTS, GROUPS, TOTAL_TXS, WALLETS, type ProofTx, type WalletKey } from "@/lib/proof";

export const metadata: Metadata = {
  title: "Proof — Bustline",
  description: "Every Bustline v3.1 transaction on Mezo testnet, labelled by the wallet that sent it, plus the limits of what has been shown so far.",
};

const REPO = "https://github.com/naoto13/Bustline";
const short = (h: string) => `${h.slice(0, 8)}…${h.slice(-6)}`;

const TOC: [id: string, label: string][] = [
  ["limits", "Limits"],
  ["wallets", "Who is who"],
  ["contracts", "Contracts"],
  ...GROUPS.map((g): [string, string] => [g.id, g.title]),
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

function Who({ k }: { k: WalletKey }) {
  const w = WALLETS[k];
  return (
    <a className={`who who-${k}`} href={`${EXPLORER_URL}/address/${w.address}`} target="_blank" rel="noreferrer" title={w.address}>
      {w.label}
    </a>
  );
}

function TxLink({ tx }: { tx: string }) {
  return (
    <a className="docs-link num" href={`${EXPLORER_URL}/tx/${tx}`} target="_blank" rel="noreferrer" title={tx}>
      {short(tx)}
    </a>
  );
}

function TxTable({ rows }: { rows: ProofTx[] }) {
  return (
    <div className="docs-tablewrap">
      <table className="tbl docs-otbl proof-tbl proof-txtbl">
        <thead><tr><th>What</th><th>Sent by</th><th>Tx</th></tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.tx}>
              <td>{r.what}</td>
              <td className="proof-who"><Who k={r.from} />{r.via && <span className="docs-muted"> via <Who k={r.via} /></span>}</td>
              <td className="proof-tx"><TxLink tx={r.tx} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default function ProofPage() {
  return (
    <div className="app">
      <header className="nav">
        <Link href="/" className="wordmark" aria-label="Bustline — back to the trade screen">bustline<span className="cursor">_</span></Link>
        <nav aria-label="App">
          <Link href="/">Trade</Link>
          <Link href="/docs">Docs</Link>
          <a className="active" aria-current="page" href="#top">Proof</a>
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
            <div className="docs-eyebrow">On-chain proof · v3.1</div>
            <h1>What happened on-chain, and who sent it.</h1>
            <p className="docs-lede">
              {TOTAL_TXS} transactions behind Bustline v3.1 on Mezo testnet, each labelled by the wallet that signed it. Every
              hash opens in the Mezo testnet explorer, so you can check the sender yourself.
            </p>
            <p className="docs-muted">
              Complete for the 22-tx deploy broadcast, the timelock operations, the test wallets (every transaction they have
              sent) and all twelve order fills. Other keeper traffic (price pushes, harvest and rebalance calls) is not listed
              beyond the first Stability Pool deposit; see the keeper address in the explorer.
            </p>
          </header>

          <ProofLive />

          <section id="limits" className="proof-limits" aria-labelledby="limits-h">
            <h2 id="limits-h">Limits</h2>
            <p>What this page does <b>not</b> show yet:</p>
            <ul className="docs-list">
              <li><b>Testnet only.</b> Mezo testnet, chainId <span className="num">31611</span>. No real funds.</li>
              <li><b>No external audit yet.</b> Two independent AI-assisted reviews; their fixes are in v3.1.</li>
              <li><b>Outside users so far: 0.</b> Every trade below comes from test wallets the team generated (A and B funded by the deployer, C from the testnet faucet).</li>
              <li><b>UI run used a scripted injected EVM wallet.</b> The 2026-11-10 run clicked through the live app with a team test wallet, not with Mezo Passport&apos;s BTC (Safe) accounts, which are still untested.</li>
              <li><b>One permissioned keeper.</b> A single team-run key fills orders; unfilled orders become refundable after 5 minutes.</li>
              <li><b>Stability Pool floor lowered to 0.25 MUSD</b> for the testnet demo (op C). It must go back to 50 MUSD before real use.</li>
              <li><b>Keeper-signed price.</b> Bounded to ±1% of Mezo&apos;s MUSD PriceFeed. The Pyth oracle is deployed but not active.</li>
            </ul>
          </section>

          <section id="wallets">
            <h2>Who is who</h2>
            <div className="docs-tablewrap">
              <table className="tbl docs-otbl proof-tbl">
                <thead><tr><th>Wallet</th><th>Address</th><th className="docs-hide-sm">Role</th></tr></thead>
                <tbody>
                  {Object.values(WALLETS).map((w) => (
                    <tr key={w.key}>
                      <td className="proof-who"><span className={`who who-${w.key}`}>{w.label}</span></td>
                      <td className="proof-tx">
                        <a className="docs-link num" href={`${EXPLORER_URL}/address/${w.address}`} target="_blank" rel="noreferrer" title={w.address}>{short(w.address)}</a>
                      </td>
                      <td className="docs-hide-sm docs-muted">{w.role}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="docs-muted">
              Test wallets A and B were generated by the team and funded by the deployer; C was generated for the BTC route and funded from the Mezo testnet faucet. None are outside users. Deployer,
              guardian and treasury are the same key. The timelock is a contract: admin changes are scheduled by the
              deployer and executed through it after a 1-hour delay.
            </p>
          </section>

          <section id="contracts">
            <h2>Contracts</h2>
            <p>Six contracts deployed for v3.1 on 2026-11-07, all verified on the explorer. The deployer sent every deploy transaction.</p>
            <div className="docs-tablewrap">
              <table className="tbl docs-otbl proof-tbl">
                <thead><tr><th>Contract</th><th>Address</th><th>Deploy tx</th></tr></thead>
                <tbody>
                  {CONTRACTS.map((c) => (
                    <tr key={c.address}>
                      <td><b>{c.name}</b><div className="docs-muted proof-sub">{c.role}</div></td>
                      <td className="proof-tx">
                        <a className="docs-link num" href={`${EXPLORER_URL}/address/${c.address}`} target="_blank" rel="noreferrer" title={c.address}>{short(c.address)}</a>
                      </td>
                      <td className="proof-tx"><TxLink tx={c.deployTx} /></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="docs-muted">
              Mezo&apos;s own MUSD contracts (BorrowerOperations, TroveManager, Stability Pool, PriceFeed…) are listed on the{" "}
              <Link className="docs-link" href="/docs#contracts">Docs page</Link>.
            </p>
          </section>

          {GROUPS.map((g) => (
            <section key={g.id} id={g.id}>
              <h2>{g.title}</h2>
              {g.note && <p className="docs-muted">{g.note}</p>}
              <TxTable rows={g.rows} />
            </section>
          ))}

          <section id="more">
            <h2>Sources</h2>
            <ul className="docs-links">
              <li><a className="docs-link" href={`${REPO}/blob/main/docs/DEPLOYMENTS.md`} target="_blank" rel="noreferrer">docs/DEPLOYMENTS.md — runbook, payloads and salts ↗</a></li>
              <li><a className="docs-link" href={`${REPO}/blob/main/deployments/testnet-v3.1.json`} target="_blank" rel="noreferrer">deployments/testnet-v3.1.json ↗</a></li>
              <li><Link className="docs-link" href="/docs">How Bustline works (Docs)</Link></li>
            </ul>
            <p><Link href="/" className="primary sm docs-back">Back to trading</Link></p>
          </section>
        </article>
      </div>

      <footer className="foot">Bustline · testnet demo · every row above links to the Mezo testnet explorer.</footer>
    </div>
  );
}
