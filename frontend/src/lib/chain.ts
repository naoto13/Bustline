import { createPublicClient, createWalletClient, http, defineChain, type Address } from "viem";
import { CHAIN_ID, RPC_URL } from "./config";

export const mezoChain = defineChain({
  id: CHAIN_ID,
  name: "Mezo Testnet (31611)",
  nativeCurrency: { name: "Bitcoin", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

export const publicClient = createPublicClient({ chain: mezoChain, transport: http(RPC_URL) });

const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]"]);

/** Wallet client that sends eth_sendTransaction to a LOCAL anvil node from an unlocked anvil account.
 *  Refuses unless the RPC host is local AND the node answers anvil_nodeInfo. No private key is used. */
export async function localWallet(account: Address) {
  const host = new URL(RPC_URL).hostname;
  if (!LOCAL_HOSTS.has(host)) throw new Error(`refusing: ${host} is not a local anvil RPC`);
  await publicClient.request({ method: "anvil_nodeInfo" as never } as never);
  return createWalletClient({ chain: mezoChain, transport: http(RPC_URL), account });
}

export const UINT_MAX = 2n ** 256n - 1n;
