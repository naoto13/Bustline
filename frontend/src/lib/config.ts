export type Mode = "local" | "testnet";
export const MODE: Mode = process.env.NEXT_PUBLIC_MODE === "testnet" ? "testnet" : "local";
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || (MODE === "local" ? "http://127.0.0.1:8545" : "https://rpc.test.mezo.org");
export const WC_PROJECT_ID = process.env.NEXT_PUBLIC_WC_PROJECT_ID || "bustline-local-dev";
export const CHAIN_ID = 31611;

/** anvil default accounts (addresses only — unlocked on anvil, no keys involved) */
export const ANVIL_ACCOUNTS = [
  { label: "#0 owner / keeper", address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" },
  { label: "#1 alice", address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" },
  { label: "#2 bob", address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" },
  { label: "#3 carol", address: "0x90F79bf6EB2c4f870365E785982E1f101E93b906" },
  { label: "#4 dave", address: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65" },
] as const;

export type Deployment = {
  chainId: number;
  owner: `0x${string}`;
  MUSD: `0x${string}`;
  MockOracle?: `0x${string}`;
  OracleAdapter?: `0x${string}`;
  Oracle?: `0x${string}`;
  oracleMode?: "pyth" | "signed" | "mock";
  RebateToken: `0x${string}`;
  RebateStaking: `0x${string}`;
  HouseExchange: `0x${string}`;
};

export async function loadDeployment(): Promise<Deployment | null> {
  const file = MODE === "local" ? "/deployment.json" : "/deployment.testnet.json";
  try {
    const r = await fetch(file, { cache: "no-store" });
    if (!r.ok) return null;
    return (await r.json()) as Deployment;
  } catch {
    return null;
  }
}
