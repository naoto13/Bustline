# Deployments — Mezo testnet (chainId 31611)

RPC `https://rpc.test.mezo.org` · Explorer `https://explorer.test.mezo.org` · Frontend https://bustline.planz.workers.dev

Unaudited demo. **Current state (2026-11-07):** v3.1 (`deployments/testnet-v3.1.json`) is the live market. The keeper
Worker (https://bustline-keeper.planz.workers.dev) fills, liquidates and pushes prices on v3.1, and the production
frontend at https://bustline.planz.workers.dev (Cloudflare Workers static assets) reads v3.1. All six v3.1 contracts
are verified on the explorer (Blockscout, 2026-11-07). No trades have happened on v3.1 yet. v3 (2026-11-06) is
retired (it never had a trade) and v2 is frozen; both are kept below as history.

## v3.1 (Wave 2, current) — `deployments/testnet-v3.1.json`

Deployed 2026-11-07 (≈03:48 JST) by `script/DeployTestnetV3_1.s.sol` in one broadcast (22 txs, blocks
16615295–16615316; `broadcast/DeployTestnetV3_1.s.sol/31611/run-latest.json`). Same design as v3 plus an emergency
pause (`guardian` can `pause()`, only the timelock can `unpause()`) and a 1% protocol fee on winning profit to
`treasury` (`protocolFeeBps` = 100). It is a fresh, independent set: it also contains the 2026-11-06 review fixes
that v3 did not have. Owner of HouseExchange v3.1, both oracles and the RebateToken is the `TimelockController`.
Pause / resume runbook: [`OPERATIONS.md`](OPERATIONS.md#5-emergency-pause-v31).

| Contract | Address | Deploy tx |
|---|---|---|
| TimelockController (delay 3600 s; proposer + canceller = deployer, executor = anyone, no admin) | [`0x115ba5242fc96c72cb2971D1B0f25439Def8f1C4`](https://explorer.test.mezo.org/address/0x115ba5242fc96c72cb2971D1B0f25439Def8f1C4) | `0x9f244e92a219d79cea16bee0f99c305d1c41ed528fd2394e5564e7ca195c61dc` |
| HouseExchange v3.1 (pause + protocol fee; Stability Pool wired, off until op B) | [`0x3c58314cd5710893519E5d962F553633ECC60cF7`](https://explorer.test.mezo.org/address/0x3c58314cd5710893519E5d962F553633ECC60cF7) | `0x067c54a0d3ebac8592cf0f874792b6baf74df59fde96cca88b253b10089c8af5` |
| SignedPriceOracle (**active**; MUSD PriceFeed bound ±1%) | [`0x75a3071482883d9616bf0473B7eE25B4222b181F`](https://explorer.test.mezo.org/address/0x75a3071482883d9616bf0473B7eE25B4222b181F) | `0xf6083f0f7d138ae28a97437878c464062966136a7a7c1b46866036901178865c` |
| PythPullOracle (switch-ready; MUSD PriceFeed bound ±1%) | [`0xf05B4108B93A83a1a87Ba1E392a81226aAC63619`](https://explorer.test.mezo.org/address/0xf05B4108B93A83a1a87Ba1E392a81226aAC63619) | `0xb6660709d2b56bc4d99981f39fc0cbadc6390bf3bdb54fcbcf88bbec96c7765a` |
| RebateToken — Mezo Paper (`MPAPER`), new token, non-transferable | [`0xDACD4786EDCBB626BA95805E204FD18815a389D0`](https://explorer.test.mezo.org/address/0xDACD4786EDCBB626BA95805E204FD18815a389D0) | `0xd4b4458c11c7592a8f2c07d93f272aadd4e0727e3f5e564a7adc4c9b40636283` |
| RebateStaking (MUSD + BTC rewards) | [`0x9bC4C5076752ec7ee0E4e429D6d95229AA147c98`](https://explorer.test.mezo.org/address/0x9bC4C5076752ec7ee0E4e429D6d95229AA147c98) | `0x327a702d86e1e4377d545a02c7559684a3f30eec9fb4aa0afd76f736669a3215` |
| MUSD (Mezo) | [`0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503`](https://explorer.test.mezo.org/address/0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503) | — |

Mezo contracts wired into HouseExchange v3.1 (Stability Pool `0x1CCA…680e`, PriceFeed `0x86bC…9366`,
BorrowerOperations, TroveManager, HintHelpers, SortedTroves) are the same as v3 and listed in
`deployments/testnet-v3.1.json`.

Configuration txs in the same broadcast: `setPriceBound` on both oracles, RebateToken `setMinter` / `setStaking`,
HouseExchange `setStaking`, `setKeeper`, `setRisk`, `setStabilityPool`, `setSpParams(false, …)`, `setGuardian`,
`setTreasury` (`0x24b227f56f5ad0fd2d2e065f8561b560109566174f0251b710b49beca5078e54`), `setProtocolFee(100)`
(`0xe7ac28f0d53b64e577302b882a8fe7c9304cd47704e83031e9869a720c84433e`), then `transferOwnership(timelock)` for
HouseExchange (`0x039dae9fa47859de2e9b63d15db5afc630c887d36c1a26281e58283ccf84125b`), both oracles and the RebateToken.

Checked on-chain after the deploy (2026-11-07): `owner()` = timelock on all four owned contracts, `guardian` and
`treasury` = deployer, `protocolFeeBps` = 100, `paused` = false, keeper whitelisted, price bound active.

RebateToken v3.1 is a fresh token again: **MPAPER balances and stakes from v3 and v2 are not carried over** (v3 never
had a trade, so it never minted any).

### v3.1 keys and roles

| Role | Address | Used by |
|---|---|---|
| Deployer = timelock proposer / canceller = **guardian** = **treasury** | `0xcDf407c01d38553eA44F250028D19b1d80898a21` | Deploy script, timelock `schedule`, `pause()` (cannot unpause), receives the 1% protocol fee. Owns nothing directly |
| Keeper (`isKeeper` on HouseExchange v3.1) | `0x85601C5Fc9A735a2710ba78024115039a7a32a42` | Worker `KEEPER_PRIVATE_KEY`: fills, liquidations, price pushes, `rebalance` / `forwardBtc` |
| Price signer (`signer` of SignedPriceOracle v3.1) | `0x0BFf571D7c806400Fc00D4Bb06AD1B660D5E2AEe` | Worker `PRICE_SIGNER_PRIVATE_KEY`: signs price reports only, sends no txs |

Same three keys as v3. A leaked keeper or signer key can neither pause nor call owner functions.

### v3.1 timelock operations

| Op | Call | Status |
|---|---|---|
| B — enable the Stability Pool | `HouseExchange v3.1.setSpParams(true, 50e18, 5000, 2000)` (min liquid 50 MUSD, max share 50%, band 20%) | **Done 2026-11-07** (scheduled 03:51 JST, executed after the 1-hour delay; `spEnabled = true`). id `0x77cc7265afb4c8530c759f7d95ea41d49fd3c1596e452bdc7693d4bea0d47909`, salt `keccak256("bustline-v3.1-sp-enable")` = `0x2f2e4a04e8a04eaf31038a0c61aaa833e8ee735299e060bc15d09dc32ef19f3b`, schedule tx `0x72d53fce2a0fb382a10e6ade4a07fdf272d9c74b78f3fab470552162755dd7a4`. Execute tx `0x50eb35942b1941733ee03537563fa49bc62a642875a9e2784822205d4df604cd` |
| C — lower the Stability Pool floor for the testnet demo | `HouseExchange v3.1.setSpParams(true, 0.25e18, 5000, 2000)` (min liquid 50 → 0.25 MUSD; share and band unchanged) | **Done 2026-11-10** (testnet only: without seed capital, house cash never reached 50 MUSD, so no deposit could happen). id `0x6e0d7b24050107e2adb2d0f19e93abfe2be6574e6747f422c5f184cff3dbcf2a`, salt `keccak256("bustline-v3.1-sp-floor-0.25")` = `0xf65c30d8a395260146723e2a98550d5131df471e7bac2138c758827a20311844`, schedule tx `0x7fa71a52a3bf5e6e430847f20561d7331cd6f0eeb90257fa2f4b0041e2fe8b1d`, execute tx `0x94de816eaac8b2c9eb1cd0bbc76ad92b8eac6c348314b30b44dda446c2235bdc`. The keeper's next `rebalance()` made the first deposit: 0.2785 MUSD (`SpDeposited`, tx `0x8dd07d2cc0a75ff66f7ba9c05d5f1c59d127fb6458b1da5f42498cb4eb41e042`). A low floor means a winner can be queued if pool withdrawals freeze; restore 50 MUSD (op B payload) before any real use |

Payload of op B (same as v3):
`0xd48d9abc0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000002b5e3af16b1880000000000000000000000000000000000000000000000000000000000000000138800000000000000000000000000000000000000000000000000000000000007d0`.
Record any `unpause()` operation here too (schedule / execute txs, salt).

### v3.1 runbook (as executed)

1. Broadcast (deployer key only from the environment; `GUARDIAN` / `TREASURY` default to the deployer;
   `TIMELOCK_DELAY` below 3600 is refused):

   ```bash
   CONFIRM_TESTNET_DEPLOY=1 MEZO_TESTNET_PRIVATE_KEY=<deployer> KEEPER=<addr> PRICE_SIGNER=<addr> \
     forge script script/DeployTestnetV3_1.s.sol --rpc-url https://rpc.test.mezo.org --broadcast
   ```

   Checked `deployments/testnet-v3.1.json` against the broadcast file (all six addresses match).
2. Verified all six contracts on Blockscout (2026-11-07); see [`OPERATIONS.md`](OPERATIONS.md#verify-on-the-explorer)
   for the "verified twin" pitfall.
3. Pointed the keeper Worker at v3.1 (`keeper-worker/wrangler.toml`: `EXCHANGE_ADDRESS` / `ORACLE_ADDRESS` = v3.1,
   `SP_OPS = "1"`, same secrets) and redeployed it (2026-11-07).
4. Copied `deployments/testnet-v3.1.json` to `frontend/public/deployment.testnet.json`, rebuilt and redeployed the
   static site (2026-11-07).
5. Scheduled op B (above) from the proposer. Executed after the delay: `0x50eb35942b1941733ee03537563fa49bc62a642875a9e2784822205d4df604cd` (`spEnabled = true`).
6. First v3.1 trades (2026-11-07) from two scripted test wallets, below. Still open: trades by outside users.

### v3.1 test-wallet trades (2026-11-07)

Two wallets generated for this run, funded with testnet BTC by the deployer. They are scripted test wallets, not
independent users and not Mezo Passport / UI sessions. Each step sends the same calls the app's funding flow sends
(`frontend/src/components/Funding.tsx`); the keeper Worker filled every order. All receipts have status 1.

- A `0x13b11d5C03f3B0fd26D376eE1a41D4E2B8c78011`, B `0x9ca9d3760345AABd825422B9128FA81FB8673992`

| Step | Route | From | Tx |
| --- | --- | --- | --- |
| `openTrove` (0.0423 BTC collateral, 1,800 MUSD borrowed) | Start with BTC | A | `0x9cc208ec48a911a98894c812f4aecfa28e116ea75c0cffca68f6a20d9ebcd158` |
| `MUSD.approve` | Start with BTC | A | `0x5f5ae6ed1fd01c3850cde598f92c922a7f7e70969a069ffc60af7ad020d82dcf` |
| `requestOpen` long 50 MUSD × 50 | Start with BTC | A | `0xc22ea65d1252f39ca6f636e23139eb7c8169faf27356e4d6594a6c102f6c3088` |
| `withdrawMUSD` 30 (ICR after: 157.8%) | From my trove | A | `0x33ed31e9eeae5a2acc494aae44a91ffc8c4c450b824165bc8a5d0882488fdcf0` |
| `requestOpen` long 30 MUSD × 50 | From my trove | A | `0xe6398f2e7a2138070f2e38984070cc73193f4ee8f9ab5e415b4faaf9ff24bb99` |
| MUSD transfer A → B, 80 | Deposit MUSD | A | `0x91294843536eae0088243bdfb8580cf7eefa63180c5ed2e1c8629cabda890a2e` |
| `MUSD.approve` | Deposit MUSD | B | `0x0a4b2c25b590bfac03b2d3de19612af85941201deb1e665a8ab3bcb4baa36d77` |
| `requestOpen` short 80 MUSD × 50 | Deposit MUSD | B | `0x85d0e85b57025a8cc58f5098a81eade6e0fd76714a246487752648dd5bacf259` |
| Fills (keeper), all at 75,791.80 | — | keeper | `0xaa8945f8d6513b1bde6ff546ea640a701a6a778dc2542fca3cae17c55b0e75a8`, `0xd5881b17dfd4ccd75e1a7debbaa2cb8eb70d6a37cda94817a41c097dbd131348`, `0x10ba2327bc8cae84f93f6740f0f796a5b306e0abddcfe99b1cbb606ba832daea` |
| `requestClose` short 80 | — | B | `0xe3f6251cc7ccec094e945456e522cba656636eebda9cd7f3397a64eee179667f` |
| Close short (loss 4.10 MUSD to the house, 410.33 MPAPER minted to B) | — | keeper | `0x6fa67a5fabc89ac26dce4a41f8d81cc84b9da6f9b0554f7cdb99362c2e63366c` |
| MPAPER `approve` for RebateStaking | — | B | `0x374e6468cebdd16b9fc94df61094a9feea338101b4e31a6c15c9cf95c2de48e8` |
| B stakes 410.33 MPAPER | — | B | `0x6c5c77deffc635fd6786930430a650ff785f18e3563872659b529ef51a72c12b` |
| `requestClose` long ×2 | — | A | `0xc8d55e255ce0e328a2443404b8c2d68367145d94cf0e8181b5e7a05d34dce1a6`, `0x1f5c793385cfb0a8038b89ef559d7ec4d688b79447f3bd86fddea5ec921c3d7e` |
| Close long 50 (paid in full; protocol fee 0.0222, staker fee 0.0443) | — | keeper | `0x939b8c2c24a1c0e3ddf6a7d7c7b1b50315ddc6bb5f1fa0a7d80ed4ee609435e6` |
| Close long 30 (paid in full; protocol fee 0.0133, staker fee 0.0266) | — | keeper | `0x23ea67fbb6394aa3c4209479c3a554073a2af612aa7f016c6bf668b4089b3f8b` |

With these rows the list covered every transaction A (8) and B (5) had sent by 2026-11-07. The same set, labelled by sender, is on the
site at [`/proof`](https://bustline.planz.workers.dev/proof).

Result: `totalProtocolFees` 0.0355 MUSD (now on the treasury), 0.0709 MUSD to stakers, house cash 0.557 MUSD,
queue empty, no liquidation. House cash never exceeded `spMinLiquid` (50 MUSD) here; the first Stability Pool deposit followed op C (2026-11-10).

### v3.1 UI run with a scripted injected EVM wallet (2026-11-10)

UI run with a scripted injected EVM wallet (team test wallet). Test wallets A and C connected through the app's own connect
modal on the live site (`https://bustline.planz.workers.dev`): an EIP-6963 wallet ("Bustline test signer (scripted)")
injected into the page and backed by a local signer on 127.0.0.1. Every step was clicked in the Funding panel and the
Positions tab. This does **not** exercise Mezo Passport's BTC (Safe) accounts; that is still open. For A, approval was
skipped by the app (allowance already set). All receipts have status 1.

| Step | Route | From | Tx |
| --- | --- | --- | --- |
| `withdrawMUSD` 20 (ICR after: 153.5%) | From my trove | A | `0x79b10714d2438f140f2d16d1dcca7f5114e025e7ca6e12515250b306a51a8d3b` |
| `requestOpen` long 20 MUSD × 50 (order 6) | From my trove | A | `0x93c663fba8416a3585b4268b46d61e1a75b7c6b940142bc3ea4160170399c6c8` |
| Fill: position #3 opened at 74,446.82 | — | keeper | `0xc79e55ace65547bb581ffc8dbc2115d14d418c8f95769475f5c0ca09bb52cf87` |
| `requestClose` #3 (order 7) | — | A | `0x687187880b2adc8d2354c2cdebdc3a4e222aba4498ba16aa89625dd09064882b` |
| Close #3 at 74,469.10 (raw PnL +0.30 MUSD, nothing queued) | — | keeper | `0x608896fb903eb799f92d03152bcbb08cc3c00f2b4fd76f7a885d9ace29efad6f` |
| `requestOpen` short 20 MUSD × 20 (order 8) | Deposit MUSD | A | `0x05b1b292d7c652026e37035ccf5adfe6ef88921b01451b7a2e5f8b6a13762863` |
| Fill: position #4 opened at 74,439.10 | — | keeper | `0x3fd73b29b9d3a14616eb95f53006bc3008c7b19041f93a01e66f94c8c8f25637` |
| `requestClose` #4 (order 9) | — | A | `0x68e6151a6e69feaf7602d4c18d0e054b1d3b875ba3b32ed7ab99cf722815a7cc` |
| Close #4 at 74,424.70 (raw PnL +0.08 MUSD, nothing queued) | — | keeper | `0x9d95e809cd5fe6adab9578be65168bb6fb73b91eea431a03ad321e5e9555720b` |
| `openTrove` (0.0445 BTC collateral, 1,800 MUSD borrowed, ICR 165.6%) | Start with BTC | C | `0x4999da6475e61a602287c75cf28279c847e6bc31f09f5b0228946829af61b1d2` |
| `MUSD.approve` | Start with BTC | C | `0x6a1a5dd02e2e26d53d4edbb84aac8ac071f1daee2c201c826360f80f5c9f34e1` |
| `requestOpen` long 30 MUSD × 30 (order 10) | Start with BTC | C | `0x34054c22f6e346965d5b8b124af1ab4e54a270f91579c60006437fc5c7bff923` |
| Fill: position #5 opened at 74,556.40 | — | keeper | `0x98c125e39ddbbf83399e8d46b3df2c81b2070721eb14b1078f36b0dd8ccc6c39` |
| `requestClose` #5 (order 11) | — | C | `0xfe7534052404b1cc4ecbb1ee638b5c2730724377f8a6d1ba023e4b94f34520a5` |
| Close #5 at 74,570.00 (raw PnL +0.16 MUSD, nothing queued) | — | keeper | `0xb06915717d22aadf8bf6d0646e0849556774b8eeb79886f8f362d28988ed4277` |

Test wallet C `0x2104bce039BAa59C39c4791abbdf054b9c8e8290` was generated for the "Start with BTC" route. The team
claimed 0.05 BTC for it from the Mezo testnet faucet (a scripted request was rejected by the captcha):
`0xaf12c320e189c72922e444b0ca76f48d281bb9c7bd36cee9c4d827e96c6b4d18`, sent by the faucet `0xc2a912d17e0dfae27e17ef0cf3baf5bec659a6ea`.
C's trove after the run: 0.0445 BTC collateral, 2,001.80 MUSD debt, ICR 165.6%.

With these rows the lists cover every transaction A (13), B (5) and C (4) have sent. Outside users so far: 0.

## v3 (Wave 2, retired 2026-11-07) — `deployments/testnet-v3.json`

Retired on 2026-11-07 when v3.1 went live: no trade ever happened on v3, the keeper Worker and the frontend no longer
point at it, and its timelock / contracts are left as they are. Explorer links are kept for the record.

Deployed 2026-11-06 by `script/DeployTestnetV3.s.sol` in one broadcast (19 txs, blocks 16603807–16603833). Owner of
HouseExchange v3, both oracles and RebateToken v3 is the `TimelockController`; every owner action goes through
schedule → wait 1 hour → execute.

| Contract | Address | Deploy tx |
|---|---|---|
| TimelockController (delay 3600 s; proposer + canceller = deployer, executor = anyone, no admin) | [`0x5837370bC22766abb1754bb41C55e2b969288d90`](https://explorer.test.mezo.org/address/0x5837370bC22766abb1754bb41C55e2b969288d90) | `0xe95aefedc7950ebcc9fa0fb035aab0c67516f139fbd3f119b871e14cfe0e7829` |
| HouseExchange v3 (Stability Pool, enabled by op B on 2026-11-06) | [`0x50828BbB08dce68eEf2588357Ef5FAE1f67f9F58`](https://explorer.test.mezo.org/address/0x50828BbB08dce68eEf2588357Ef5FAE1f67f9F58) | `0x7dd70f3f286c94d8fce62ad44bc0b02f33230926748969f87b8554f7931cc3bf` |
| SignedPriceOracle (**active**; MUSD PriceFeed bound ±1%) | [`0xb4321D6d7E6B3f804B386E6A27d9e70DDc8e85A0`](https://explorer.test.mezo.org/address/0xb4321D6d7E6B3f804B386E6A27d9e70DDc8e85A0) | `0xe1ac82a50ffee15d4d1591545a32a998eb88873b2429aee6dd9f56f4cdc8ed77` |
| PythPullOracle (switch-ready; MUSD PriceFeed bound ±1%) | [`0xC6cCeb1EAB44B81587A2713c70C17CB839aa34a0`](https://explorer.test.mezo.org/address/0xC6cCeb1EAB44B81587A2713c70C17CB839aa34a0) | `0xa867ff822aa6b799aaf88cac11eca4bedbe376f860b3a03fd740f39188144c8e` |
| RebateToken v3 — Mezo Paper (`MPAPER`), new token, non-transferable | [`0x8627486B8f49191E492d94d44DF153Cc5983fd9B`](https://explorer.test.mezo.org/address/0x8627486B8f49191E492d94d44DF153Cc5983fd9B) | `0x972c44f3760df1a57724d43c5df7ce3fe714681595b264a5a25324c233d61cae` |
| RebateStaking v3 (MUSD + BTC rewards) | [`0x7EA0bdE3a2221cfdB40623D7EAdB9fCe683D683D`](https://explorer.test.mezo.org/address/0x7EA0bdE3a2221cfdB40623D7EAdB9fCe683D683D) | `0x68fdd002faea7c9bb1d5488f96d6c52256894a15cf97a9f4a93183e8337f4d89` |
| MUSD (Mezo) | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` | — |

Mezo contracts wired into HouseExchange v3 (Stability Pool `0x1CCA…680e`, PriceFeed `0x86bC…9366`, BorrowerOperations,
TroveManager, HintHelpers, SortedTroves) are listed in `deployments/testnet-v3.json`.

RebateToken v3 is wired at deploy time: `minter` = HouseExchange v3, `staking` = RebateStaking v3, `transferable` =
false. It is a fresh token: **MPAPER balances and stakes from v2 are not carried over.**

### v3 keys and roles (three different addresses)

| Role | Address | Used by |
|---|---|---|
| Deployer = timelock proposer / canceller | `0xcDf407c01d38553eA44F250028D19b1d80898a21` | Deploy script and timelock `schedule` only; owns nothing directly |
| Keeper (`isKeeper` on HouseExchange v3) | `0x85601C5Fc9A735a2710ba78024115039a7a32a42` | Worker `KEEPER_PRIVATE_KEY`: fills, liquidations, price pushes, `rebalance` / `forwardBtc`. Funded with 0.0001 BTC (`0xef9a22b1b98aeb150c9b59e8f267672644f9f657e569eac5e71fca265c72bbfd`); a price push costs ≈ 50,838 gas ≈ 5e-11 BTC at ~1,000 wei |
| Price signer (`signer` of SignedPriceOracle v3) | `0x0BFf571D7c806400Fc00D4Bb06AD1B660D5E2AEe` | Worker `PRICE_SIGNER_PRIVATE_KEY`: signs price reports only, sends no txs |

A leaked keeper or signer key cannot call owner functions. All three keys are stored outside git.

### v3 timelock operations

| Op | Call | Status |
|---|---|---|
| B — enable the Stability Pool | `HouseExchange v3.setSpParams(true, 50e18, 5000, 2000)` (min liquid 50 MUSD, max share 50%, band 20%) | **Executed 2026-11-06** (`spEnabled` = true). id `0xbdefab74384c04d135b0f3677a17bd640c0fe255f5b21a1ccc13db2f46130d35`, schedule tx `0xad044ce161e585d0c7329cb7a74ab3c3a7b86bfb5aa534376d3b9e9e8aed2a65`, ready 2026-11-06 15:41:23 JST. Execute tx: `0x1cf7de08e02f9628c34c075f7695ddd8049891a4851f8f6b72af68a9cc4b25a0` |

There is no op A any more: the RebateToken is new and was wired before ownership moved to the timelock.

### What stays frozen

- The **v2 market** (`deployments/testnet.json`, below) is kept as the Wave 1 record. Its owner/keeper/signer key was
  lost, so nothing on v2 can be operated: open position #2 stays open, no keeper pushes v2 prices, and v2 MPAPER
  balances and stakes are not migrated to v3 or v3.1.
- The old Worker keeper (= the v2 deployer) is no longer used.

### v3 runbook (as executed)

1. Created three new keys (deployer/proposer, keeper, price signer) and stored them outside git. Funded the keeper
   with BTC for gas.
2. Broadcast (the deployer key is read only from the environment, never from argv):

   ```bash
   CONFIRM_TESTNET_DEPLOY=1 MEZO_TESTNET_PRIVATE_KEY=<deployer> KEEPER=<addr> PRICE_SIGNER=<addr> \
     [TIMELOCK_DELAY=3600 ORACLE_MODE=signed] \
     forge script script/DeployTestnetV3.s.sol --rpc-url https://rpc.test.mezo.org --broadcast
   ```

   The script deploys the timelock, both oracles, a new RebateToken, HouseExchange v3 and RebateStaking v3, sets the
   token's minter and staking, configures keeper / risk caps / Stability Pool wiring with `spEnabled = false`, and then
   hands ownership of everything to the timelock. It refuses to run unless the deployer, `KEEPER` and `PRICE_SIGNER`
   are three different addresses, and writes `deployments/testnet-v3.json`. Check that file against
   `broadcast/DeployTestnetV3.s.sol/31611/run-latest.json`: on 2026-11-06 the file first held addresses with no code
   on-chain and was corrected to the broadcast addresses.
3. Pointed the keeper Worker at v3 (`keeper-worker/wrangler.toml`: `EXCHANGE_ADDRESS` / `ORACLE_ADDRESS` = v3,
   `SP_OPS = "1"`), set the secrets `KEEPER_PRIVATE_KEY` and `PRICE_SIGNER_PRIVATE_KEY`, and redeployed it
   (2026-11-06).
4. Scheduled op B from the proposer: `schedule(HouseExchange v3, 0, payload, 0x0, salt, 3600)` with
   salt = `keccak256("bustline-v3-sp-enable")` = `0x01aeb75adbde3987c06f395d7e15cc6df41d5e049b87bff8f35ae2db5d39f439` and
   payload =
   `0xd48d9abc0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000002b5e3af16b1880000000000000000000000000000000000000000000000000000000000000000138800000000000000000000000000000000000000000000000000000000000007d0`.
5. After the delay, the deployer called `execute(HouseExchange v3, 0, payload, 0x0, salt)` (tx `0x1cf7de08e02f9628c34c075f7695ddd8049891a4851f8f6b72af68a9cc4b25a0`).
6. Done (2026-11-06): all six v3 contracts verified on the explorer (Blockscout).
7. Copied `deployments/testnet-v3.json` to `frontend/public/deployment.testnet.json`, built the static site and deployed it
   with `wrangler deploy` (`frontend/wrangler.jsonc`). The keeper Worker was redeployed to the same Cloudflare account
   (new KV namespace, same v3 vars and secrets); the Wave 1 Pages site and the old keeper Worker in the previous
   account are being shut down by the owner.

## v2 (Wave 1, frozen) — `deployments/testnet.json`

Deployed 2026-10-21 from a dedicated testnet-only address, `0x715211CAdb65Cc184c955B283933A1F7021d00b0`, which also
ran the keeper, signed prices and opened the test positions below. That key was later lost, so v2 is frozen: it is
kept as the Wave 1 record and nothing on it can be operated any more. Pyth-ready oracle design; the keeper-signed
oracle was active.

| Contract | Address | Deploy tx |
|---|---|---|
| HouseExchange | `0x5e941EEA56DEE50924950E86f24624Be37f02050` | `0xbed9fb1030558f6cc13049ab0dd89c55d4162d515e57204a1426fc82861d4976` |
| SignedPriceOracle (**active**; maxAge 60 s, Skip ±1%) | `0x83401Fc1B16DbCa09531241Dad49700248C8c72c` | `0x177eb45bd3fda1d1d39080c51b0c0457fbdc5a45626438475f22315845c82741` |
| PythPullOracle (switch-ready; BTC/USD feed `0xe62d…5b43`, maxAge 60 s, Skip ±1%) | `0xA1E556D9e659fC879D3c37Bd2490D3274B6c20bB` | `0x59fec8279b3e069e21fd1231dad8cfe5a56a2fe225106fd75884b5bcf8ddbe25` |
| RebateToken — Mezo Paper (`MPAPER`), non-transferable | `0x07F9bd344916571321f494aE00eDD30ac1dE89Bd` | `0x7a24bb5d34ee07f3410c6327be51a6c18a992dd97984ab1204df87e61c07c5cf` |
| RebateStaking | `0x8c76076af61489D8fdc10F6DbA7a9aeC52879fD8` | `0x51095becb892713c48045a5c1aadc0ee4db3254f787ea6f0d0b04816fe8e06cc` |
| MUSD (Mezo) | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` | — |

### Why the signed oracle was active (v2)

Mezo testnet Pyth **accepts mainnet-signed (stable) BTC/USD updates**. This was verified with a real Base-mainnet update
(`parsePriceFeedUpdates` via `eth_call`, fee 10 wei) and in `test/fork/PythFork.t.sol` (accept, fill-in-same-tx and
liquidation-with-update on the real Mezo Pyth bytecode). Pyth Hermes, however, requires an API key since 2026-08.
On v3.1 the switch is one timelock operation — `HouseExchange v3.1.setOracle(PythPullOracle v3.1)` — plus `"oracleMode":
"pyth"` in the deployment file once `PYTH_API_KEY` is set (on frozen v2 it can no longer be done).

Trust model of the signed oracle: the keeper signs `(chainid, oracle, price, publishTime)` (EIP-191). The contract
rejects bad signatures, reports more than 10 s in the future, reports older than the stored one, prices older than 60 s
and prices more than 1% away from Skip Connect. Off-chain price = median of Coinbase / Kraken / Bitstamp spot.

### On-chain proof

Every fill and liquidation below carries its own signed price update in the same tx.

| Step | Tx |
|---|---|
| Long 100 MUSD × 10x requested | `0xa16d1eb08f355e1b11028794a9b3d1cc78bff65d8e738005e6ba026d8d84b965` |
| → filled by the keeper at a later price (PriceReported + PositionOpened) | `0x71e6e05faf30082580cc1ef84642f197cb19371b997f5d44ae818149a45a1704` |
| Close requested | `0x34770da66c81e2a4e280f8a8a4df3f5b0a8f332f41c922462749e6ffe3c81244` |
| → closed at a loss; 32.49 MPAPER minted (PositionClosed + RebateMinted) | `0x94b7aae9b7340b9ae4cbf3f31b23edb5d8f5bea89c6998e4292309022dff425e` |
| Long 10 MUSD × 100x and short 10 MUSD × 100x opened at ≈ $83,032 | `0xcfa564384134ca0317e5bee5153bde7df07f3d537cd59b7f8ff2b149136a5a75`, `0xfd15e12abfeca0016be9abd7b57dd1ed809a20edc1c48080215b8ca47dd6e47e` |
| **Live liquidation** of a test position opened by the deployer account — BTC fell to $80,638 on 2026-10-26 02:38 JST (within Coinbase's BTC-USD 1-minute candle for 17:37 UTC, $80,630–$80,648); the keeper liquidated the 100x long (position #1): 10 MUSD margin forfeited, 0.05 MUSD keeper reward, 1,000 MPAPER minted to the trader. The price came from the regular signed feed; nothing was pushed by hand | `0xfa67811e9766c14ee3971656b8387a9bf3f7c0964280789a921a3bc265b06a3c` |

The v2 keeper pushed signed prices from deployment until the key was lost (54 `PriceReported` events as of 2026-10-26). Regenerate the
full event list with:

```bash
forge build && python3 scripts/list-events.py deployments/testnet.json 16277100
```

## MUSD source

Testnet MUSD came from a real MUSD Trove: 0.045 BTC collateral, 1,800 MUSD net debt (≈ 2,001.8 total including the 0.1%
fee and 200 MUSD gas compensation) — tx `0x4a8dea67ba30961e7601d237cc9c14dc5b3d43debfe8c2f365e32664c82d9fb2`.

## Earlier markets (v1, legacy)

Deployed 2026-10-21 with the first ABI; the rebate token was still named HRP on-chain. Kept for the record.

**Skip market** (`deployments/testnet-v1-skip.json`) — price = Skip Connect BTC/USD, 120 s staleness.

| Contract | Address |
|---|---|
| HouseExchange | `0x608757e82a847f04Ff6E8FeDCB18914c02e54a5c` |
| OracleAdapter (Skip) | `0x53e834CDA15A7dDA36896f182B0feB4302DdF6f7` |
| RebateToken (HRP) | `0xBB96Fb1a7dC41427C286be13C36574DDa27f7cbe` |
| RebateStaking | `0x34C6316a83797C04e8c7003e293A03B65f596e8E` |

Long 300×50 and short 300×50 were filled at a later Skip update; the winning long closed into an empty house →
**Queued** (`0xdb820c0729cc0a9479c41b6a3e786d1ea227e78fcedeb5dfe99f401d39b05dc9`); the losing short's close →
**QueuePaid + RebateMinted** (`0xb12bba2f6c5596bc8a68ac8c64557c5d9bc92490a652b202acb933b18e0b9193`).

**Crash-demo market** (`deployments/testnet-demo.json`) — clearly labelled demo market whose price is a `MockOracle`
owned by the deployer, so liquidations and queue repayment can be shown on demand.

| Contract | Address |
|---|---|
| HouseExchange (DEMO) | `0xF5890Acbe962Eee3F9bB5FB18E535bcac7B0b1bE` |
| MockOracle | `0x68CF665f532345dDbD1002d2d66458A1D3fb29cD` |
| RebateToken (HRP-DEMO) | `0xD5a5D06EcFeF29959785D0f934FF17aD3aBC6e6e` |
| RebateStaking | `0x5890b192f8f1952E402D34A524b51044B13406a9` |

Sequence: long 200×20, short 100×100, short 100×10 → +0.5% close of the long → **Queued**
(`0xcb9d7aad22f8d49d0ce524cc07fef175c64fc6130bb2396b028fb1c8388bfee9`) → +1.5% → keeper **Liquidated** the 100x short,
**QueuePaid** (`0xd78fcc7a3446dcf14dcd277675edd7a35762f04be9e545ed9b1ebc6575567334`) → rebate staked → losing close with
the queue empty → 2% fee → **StakerRevenue** (`0x2aec6496e3e927506c43bf87de52f5a993028f4c40a7663de75b244524b77c10`).
