"use client";
import dynamic from "next/dynamic";

// Passport / RainbowKit touch `window` at import time → client-only.
const App = dynamic(() => import("@/components/App"), { ssr: false, loading: () => <main>Loading…</main> });

export default function Page() {
  return <App />;
}
