# Deploying the frontend to Cloudflare Pages

Live (Mezo testnet): https://bustline-c8p.pages.dev/  (Pages project `bustline`)

```bash
cd frontend
npm ci --legacy-peer-deps
STATIC_EXPORT=1 NEXT_PUBLIC_MODE=testnet NEXT_PUBLIC_RPC_URL=https://rpc.test.mezo.org npx next build
npx -p node@22 -p wrangler@latest -- wrangler pages deploy out --project-name bustline --branch main
```

The app is a single static page (no API routes), so `output: "export"` works. Wrangler needs Node >= 22.
