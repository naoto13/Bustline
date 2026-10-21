/** @type {import('next').NextConfig} */
// STATIC_EXPORT=1 builds a static site into ./out for Cloudflare Pages (see docs/DEPLOY-CLOUDFLARE.md).
const staticExport = process.env.STATIC_EXPORT === "1";
const nextConfig = {
  reactStrictMode: true,
  ...(staticExport ? { output: "export", images: { unoptimized: true } } : {}),
  // orangekit ships raw .ts sources imported from its dist
  transpilePackages: ["@mezo-org/passport", "@mezo-org/orangekit", "@mezo-org/orangekit-smart-account", "@mezo-org/orangekit-contracts", "@mezo-org/mezo-clay", "@mezo-org/sign-in-with-wallet"],
  webpack: (config) => {
    // wagmi/walletconnect optional deps not needed in the browser bundle
    config.externals.push("pino-pretty", "lokijs", "encoding");
    return config;
  },
};
export default nextConfig;
