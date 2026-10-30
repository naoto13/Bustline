# Bustline — Wave 1 judge guide

**BTC perpetuals settled in MUSD, with a loss-funded house instead of external LP deposits.**
Mezo testnet only (chain ID 31611). Unaudited. Test assets have no promised value.

- [Open the app](https://bustline-c8p.pages.dev)
- [Six-page pitch deck](wave1/bustline-wave1-deck.pdf)
- [2-minute pitch video](https://youtu.be/CWIY4ftYORI)
- [Contracts and deployment evidence](DEPLOYMENTS.md)

## What is different

MUSD is the margin, house cash, settlement asset and staking revenue. Traders request 1–100x BTC/USD longs or shorts. Realised losses fund the house and mint MPAPER. Profitable closes return posted margin immediately; net profit after the impact haircut and win fee is paid from available house cash, respecting existing queue priority. Unpaid net profit enters a FIFO queue.

**The queue makes the liability visible; it does not guarantee repayment.** House equity (`houseCash - queueTotal`) can be negative. The accounting identity `MUSD balance = house cash + open margin + escrow` does not mean queued profit is fully backed. Losses and liquidation can consume the entire margin.

MPAPER is currently non-transferable (the owner can enable transfers). Staking receives variable MUSD fees and house excess when available. It neither reimburses losses nor promises an APY.

## Try the deployed product

1. **Inspect without signing.** Open the app; inspect oracle age, house cash, queued profit and open interest. Open **House** for global positions and queue entries, and **MPAPER** for the staking interface.
2. **Obtain test assets.** Get BTC from [Mezo testnet faucet](https://faucet.test.mezo.org), then swap or borrow MUSD in [Mezo testnet](https://testnet.mezo.org). Test MUSD is not dispensed by Bustline.
3. **Connect with Mezo Passport.** Select Mezo testnet. Use test assets only. Start with the minimum 10 MUSD margin and low leverage.
4. **Request an open.** Choose Long or Short, inspect the bust line and acceptable-price setting, approve MUSD and submit the request. A team-run keeper must fill it at a price published after the request; it is not an instant fill.
5. **Inspect and close.** Watch pending orders and the resulting position. Request a close. Inspect the actual paid/queued outcome rather than assuming a displayed profit is immediately withdrawable. If a request is not filled, it expires after five minutes and can be cancelled/refunded.
6. **Inspect MPAPER.** Realised losses mint MPAPER. Stake/claim only when you choose to sign a testnet transaction; rewards require actual available revenue.

No MUSD or no wallet? The UI, deck and linked evidence below still permit review. The recorded crash is a separate controlled demo, not the live market.

## Evidence and its limits

| Evidence | What it supports | What it does not establish |
|---|---|---|
| [Current v2 live-feed liquidation](https://explorer.test.mezo.org/tx/0xfa67811e9766c14ee3971656b8387a9bf3f7c0964280789a921a3bc265b06a3c) | The regular signed-price keeper liquidated a deployer-owned 100x long on 26 Oct 2026; 10 MUSD margin lost, 0.05 MUSD keeper reward, 1,000 MPAPER minted | Independent users, adoption, production security |
| [Legacy v1 queued profit](https://explorer.test.mezo.org/tx/0xdb820c0729cc0a9479c41b6a3e786d1ea227e78fcedeb5dfe99f401d39b05dc9), [repayment](https://explorer.test.mezo.org/tx/0xb12bba2f6c5596bc8a68ac8c64557c5d9bc92490a652b202acb933b18e0b9193) | Historical testnet queue lifecycle; see [legacy addresses](DEPLOYMENTS.md#earlier-markets-v1-legacy) | Current v2 UI activity or guaranteed future payment |
| [Controlled crash output](demo/crash-demo-output.txt) and [demo deployment](../deployments/testnet-demo.json) | Queue, liquidation and staking behavior using mock prices on a separate demo market/local fork | A real BTC crash or independent market activity |
| [Pyth fork test](../test/fork/PythFork.t.sol) | Integration with Mezo Pyth using signed update data | That Pyth currently settles the public market |

Evidence links refer to recorded tests/deployments. They are not a fresh rerun of all tests or an independent chain audit.

## Active implementation and trust

The active oracle is **team-signed**: a median of Coinbase/Kraken/Bitstamp spot sources. Reports are checked on-chain for signature and age (maximum 60 seconds); order fills require `publishTime` strictly after the request. This reduces known-price execution but does not eliminate trust in the signer, price sources or keeper timing.

Skip Connect is a sanity bound: the configured ±1% bound applies only while Skip data is valid and fresh. Stale (>300 seconds by default), invalid or disabled Skip data bypasses that bound; the primary oracle's age check remains. See [SkipBound.sol](../src/oracles/SkipBound.sol).

`PythPullOracle` is deployed and fork-tested, **not active**. Data access, migration validation and an owner-controlled switch remain. No MEZO-token integration is claimed for Wave 1.

One team-run keeper handles normal execution. Admin powers include changing the oracle and risk/fee settings and enabling MPAPER transfers. Contracts are unaudited. See [exchange](../src/HouseExchange.sol), [oracle](../src/oracles/SignedPriceOracle.sol) and [operations](OPERATIONS.md).

## Product and next steps

The intended users are experienced BTC holders seeking leveraged exposure using borrowed or swapped MUSD. The demand hypothesis is unvalidated; the current test positions are builder-controlled. Win/loss/liquidation fees support variable staker revenue, not a demonstrated profitable business.

Wave 2 priorities: first-trade guidance, queue-risk scenarios and validation of the Pyth migration. Before any mainnet decision: external review, stronger admin controls and conservative limits. These are planned milestones, not completed features.

Built by PLAN-Z / naoto13. Team background: [planz.tech](https://planz.tech).
