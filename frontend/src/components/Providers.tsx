"use client";
import "@rainbow-me/rainbowkit/styles.css";
import { RainbowKitProvider, darkTheme } from "@rainbow-me/rainbowkit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { getConfig, mezoTestnet } from "@mezo-org/passport";
import { useState } from "react";
import { WC_PROJECT_ID } from "@/lib/config";

// Mezo Passport: RainbowKit + BTC wallets (Unisat/OKX/Xverse) masqueraded as Mezo testnet accounts.
const wagmiConfig = getConfig({ appName: "Bustline (testnet demo)", mezoNetwork: "testnet", walletConnectProjectId: WC_PROJECT_ID });

export default function Providers({ children }: { children: React.ReactNode }) {
  const [qc] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={qc}>
        <RainbowKitProvider initialChain={mezoTestnet} theme={darkTheme()}>
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
