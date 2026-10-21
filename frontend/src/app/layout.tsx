import "./globals.css";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "BTC House Perp on Mezo — testnet demo",
  description: "BTC/USD synthetic perp margined in MUSD; house funded by trader losses. Testnet only, unaudited.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
