"use client";
import { useEffect, useState } from "react";
import { EXPLORER_URL, loadDeployment, type Deployment } from "@/lib/config";

const REPO = "https://github.com/naoto13/Bustline";
const ADDR = /^0x[0-9a-fA-F]{40}$/;

/** Display order + labels. Keys not listed here are shown after these, under their JSON name. */
const LABELS: [key: string, label: string, note?: string][] = [
  ["HouseExchange", "HouseExchange", "market, house, payout queue"],
  ["SignedPriceOracle", "SignedPriceOracle", "active oracle"],
  ["PythPullOracle", "PythPullOracle", "deployed, not active"],
  ["RebateToken", "RebateToken (MPAPER)", "non-transferable"],
  ["RebateStaking", "RebateStaking", "MUSD + BTC rewards"],
  ["Timelock", "TimelockController", "owner of the contracts above"],
  ["MUSD", "MUSD", "Mezo"],
  ["BorrowerOperations", "BorrowerOperations", "Mezo trove"],
  ["TroveManager", "TroveManager", "Mezo trove"],
  ["HintHelpers", "HintHelpers", "Mezo trove"],
  ["SortedTroves", "SortedTroves", "Mezo trove"],
  ["PriceFeed", "PriceFeed", "Mezo MUSD, price bound"],
  ["StabilityPool", "StabilityPool", "Mezo MUSD"],
  ["Pyth", "Pyth", "Mezo testnet Pyth"],
  ["Keeper", "Keeper", "key: fills, liquidations"],
  ["PriceSigner", "Price signer", "key: signs price reports"],
  ["Deployer", "Deployer", "key: timelock proposer"],
];
// Aliases in the JSON that point at a contract already listed.
const SKIP = new Set(["owner", "Oracle"]);

export default function DocsContracts() {
  const [dep, setDep] = useState<Deployment | null | undefined>(undefined);
  useEffect(() => { loadDeployment().then(setDep); }, []);

  if (dep === undefined) return <p className="docs-muted">Loading addresses from <code>/deployment.testnet.json</code>…</p>;
  if (dep === null)
    return (
      <p className="note">
        Could not load the deployment file. The addresses are listed in{" "}
        <a className="docs-link" href={`${REPO}/blob/main/docs/DEPLOYMENTS.md`} target="_blank" rel="noreferrer">docs/DEPLOYMENTS.md ↗</a>.
      </p>
    );

  const raw = dep as unknown as Record<string, unknown>;
  const known = new Set(LABELS.map(([k]) => k));
  const rows = [
    ...LABELS.filter(([k]) => typeof raw[k] === "string" && ADDR.test(raw[k] as string)),
    ...Object.keys(raw)
      .filter((k) => !known.has(k) && !SKIP.has(k) && typeof raw[k] === "string" && ADDR.test(raw[k] as string))
      .map((k) => [k, k] as [string, string]),
  ];
  const version = typeof raw.version === "string" ? raw.version : undefined;

  return (
    <>
      <p className="docs-muted">
        Read live from <code>/deployment.testnet.json</code>{version ? <> · market <b>{version}</b></> : null} · chainId{" "}
        <span className="num">{dep.chainId}</span>. Each address opens in the Mezo testnet explorer.
      </p>
      <div className="docs-tablewrap">
        <table className="tbl docs-addr">
          <thead><tr><th>Contract</th><th>Address</th><th className="docs-hide-sm">Role</th></tr></thead>
          <tbody>
            {rows.map(([k, label, note]) => (
              <tr key={k}>
                <td className="docs-cname">{label}</td>
                <td>
                  <a className="docs-link" href={`${EXPLORER_URL}/address/${raw[k] as string}`} target="_blank" rel="noreferrer">
                    {raw[k] as string}
                  </a>
                </td>
                <td className="docs-hide-sm docs-muted">{note ?? ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
