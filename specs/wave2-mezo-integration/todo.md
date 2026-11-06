# Wave 2 todo

仕様: [spec.md](spec.md)。締切 2026-11-15。実装の順番は 0 → C → B → T → 移行 → A → 仕上げ。

## 0. 着手前の確認（spec 8 章）

- [x] fork テストで、Skip の precompile（`0x7b7c…0015`）に `vm.etch` で mock の aggregator を置き、PriceFeed の `fetchPrice()` が動くか → 結果（2026-11-02）: 動く。`test/fork/MezoPrimitivesFork.t.sol` の 8 件が通過
  - etch しないと、fork では precompile のスタブが自分自身を呼び続けて revert する
  - etch すると `fetchPrice()`、`openTrove`、`provideToSP`／`withdrawFromSP`、出金制限（ICR < 110%）がすべて動く
  - 手順: `new MockSkipAggregator(18)` → `vm.etch(SKIP, code)` → `setPrice(p)`。ストレージはコピーされないので、価格は etch の後に入れる
  - 注意: 2026-11-02 の testnet では ICR が最も低い trove が約 109.3% で MCR を下回っていた（2026-11-06 には約 113%）。実際の値は動くので、テストでは価格を高めに置くか、その trove の coll／debt から価格を決める（`test_fork_etch_derivedPrice_lowestTroveUnderMcr_blocksWithdraw` は live の状態に依存しない形に直した）
- [x] testnet の faucet で1回にもらえる BTC の量 → 結果（2026-11-02）: 0.05 BTC（faucet のアドレス `0xc2a9…A6EA` からの直近の送金がすべて 0.05 BTC）。captcha（Turnstile）が必要で、IP ごとに 24 時間に1回の見込み。1回で trove（ICR 150% で約 0.039 BTC）を開けるので、**既定の入金方法は「BTC で始める」のままにする**
- [x] v2 の状態を読む: `houseCash`、`queueTotal`、`openPositionIds`、`pendingOrderIds`、`accountingDelta`、RebateStaking の `totalStaked` → 結果（2026-11-02、block 16521439、`cast call`）: houseCash 109.7749 MUSD、queueTotal 0（queueLength 0）、openPositionIds `[2]`（totalMargin 10 MUSD）、pendingOrderIds `[]`（orderCount 5）、totalEscrow 0、accountingDelta 0、RebateStaking.totalStaked 0（totalDistributed 0）。RebateToken: owner `0x7152…`（デプロイヤー）、minter = v2 HouseExchange、staking = v2 RebateStaking、transferable false、totalSupply 11,032.49
  - **建玉 #2 が残っている**。~~minter を v3 に切り替える前に、決済か清算で閉じる~~ → 中止（理由: v2 デプロイヤー鍵の紛失により新トークンで再デプロイ）。建玉 #2 は凍結した v2 に残る
- [x] `RebateToken.setStaking` を切り替えても、v2 の RebateStaking から unstake できるか → 結果: **できない**。`_update` は今の `staking` との転送しか許さないので、v2 の unstake は `NonTransferable` で revert する（`test/RebateStakingV3.t.sol` `test_migration_setStakingBlocksOldUnstake`）。今は v2 の totalStaked が 0 なので実害はない
  - 同様に、`setMinter(v3)` の後は v2 の負けの決済と清算が `NotMinter` で revert する（`test_migration_setMinterBlocksOldLossSettlement`）
  - 2026-11-06 の決定で RebateToken を新しくしたので、v2 のトークンは切り替えない（この確認は記録として残す）
- [x] SP の初期パラメータを決める（`spMinLiquid`、`spMaxShareBps`、`spBandBps`）→ 結果: `spMinLiquid` 50 MUSD、`spMaxShareBps` 5,000、`spBandBps` 2,000、`spEnabled` false（timelock で有効化）。根拠: v2 は Wave 1 全体で houseCash が約 110 MUSD。v3 は 0 から始まる。1,000 MUSD では SP を一度も使わない。50 MUSD なら、手元が 60 を超えたら預け、40 を下回ったら戻す。testnet の上限（1建玉の名目 100k、証拠金 10 MUSD〜）では、勝ちの支払いの多くは手元 50 で払え、足りない分は SP から補充する

## C. PriceFeed による価格境界

- [x] `MezoPriceBound` を作り、SignedPriceOracle と PythPullOracle の境界を置き換える → `src/oracles/MezoPriceBound.sol`。境界は update（イベント付き）と latest（読み取り）の両方でかける
- [x] PriceFeed の mock と単体テスト（境界内、境界外、PriceFeed の revert）→ `test/MezoPriceBound.t.sol`
- [x] PriceFeed が revert しても `liquidate` と `executeOrder` が成功するテスト → `test_priceFeedReverting_*`（signed、Pyth）と fork の `test_fork_bound_unetchedStub_*`
- [x] fork テスト（実 PriceFeed）→ `test/fork/WaveTwoFork.t.sol` `test_fork_bound_realPriceFeed`

## B. Stability Pool

- [x] HouseExchange v3: `spDeposit()`、`rebalance()`、`_payWinner` と `harvest` での補充、`receive()`、`forwardBtc()`、`houseEquity` と `sweepExcess` の変更、パラメータの setter → 加えて `rebalanceAction()`・`spWithdrawable()`・`forwardableBtc()`（keeper 用の view）
- [x] RebateStaking v3: BTC の配当（`notifyRewardBtc`、`claim` で両方を払う）→ `test/RebateStakingV3.t.sol`
- [x] StabilityPool の mock と単体テスト（spec 5.2 の受入条件）→ `test/mocks/MezoMocks.sol`、`test/StabilityPool.t.sol`
- [x] ファジングに SP の操作を加え、毎ステップで会計の恒等式を確かめる → `testFuzz_randomTradingKeepsAccounting`（48 手、8 種類の操作。取引と価格の手は平均 24 で v2 と同等以上）
- [x] fork テスト（実 StabilityPool への預け入れと引き出し）→ `test_fork_sp_*`

## T. timelock と鍵

- [x] デプロイスクリプトに TimelockController を加え、各コントラクトの owner を移す（testnet の遅延は 1 時間）→ `script/DeployTestnetV3.s.sol`。2026-11-06 に broadcast 済み（timelock `0x5837…8d90`、遅延 3600 秒）
- [x] keeper と価格署名者の鍵を新しく分ける。Worker の secret を差し替える → 2026-11-06。デプロイヤー（proposer）`0xcDf4…8a21`、keeper `0x8560…2a42`、価格署名者 `0x0BFf…2AEe`。Worker の secret は `KEEPER_PRIVATE_KEY` と `PRICE_SIGNER_PRIVATE_KEY`。鍵は git の外に置く
- [x] timelock を通さないと owner 権限が使えないテスト → `test/Timelock.t.sol`、fork の `test_fork_deployScriptV3_ownersAndTimelockFlow`

## 移行（v2 → v3）

決定（2026-11-06）: v2 のデプロイヤー鍵を紛失したため、RebateToken も新しくデプロイし、v2 は記録として凍結する（spec 6 章）。

- [ ] ~~v2 の建玉と escrow を空にする~~ → 中止（理由: v2 デプロイヤー鍵の紛失により新トークンで再デプロイ）。建玉 #2 と v2 の MPAPER の保有量は移さない
- [x] v3 を testnet にデプロイする → 2026-11-06、19 tx（block 16603807〜16603833）。新しい RebateToken（"Mezo Paper"／`MPAPER`）を含む。HouseExchange v3、両オラクル、RebateToken v3 の owner は timelock
- [ ] エクスプローラでコントラクトを検証する
- [ ] ~~timelock 経由で RebateToken の `setMinter` と `setStaking` を v3 に向ける（操作 A）~~ → 中止（理由: v2 デプロイヤー鍵の紛失により新トークンで再デプロイ）。新しいトークンはデプロイの中で minter = HouseExchange v3、staking = RebateStaking v3 に設定済み
- [x] keeper-worker: アドレスを設定から読むように変える。tick で `rebalance()` と `forwardBtc()` を呼ぶ。Worker の再デプロイ → 2026-11-06 に v3 で再デプロイ（`EXCHANGE_ADDRESS`・`ORACLE_ADDRESS` = v3、`SP_OPS = "1"`）。keeper に 0.0001 BTC を送金済み
- [x] timelock 操作 B（`setSpParams(true, 50e18, 5000, 2000)`）を実行する → 実行済み（2026-11-06、spEnabled = true）。schedule（id `0xbdef…0d35`、実行可能 2026-11-06 15:41:23 JST）。execute の tx: `0x1cf7de08e02f9628c34c075f7695ddd8049891a4851f8f6b72af68a9cc4b25a0`
- [x] v3 のアドレスを deployments に記録する → `deployments/testnet-v3.json`。v2 は `deployments/testnet.json` のまま残す
- [ ] 本番フロントの `deployment.testnet.json` を v3 に切り替えて再デプロイする（**実行前にユーザーの確認が必要**）

## A. 入金の3経路（フロント）

- [x] 入金方法の選択（BTC で始める／既存の trove から／MUSD で入金）と、trove の状態による自動の切り替え → `frontend/src/components/Funding.tsx`（画面の確認は読み取りのみ。`?viewAs=` で trove あり／なしを表示）
- [x] hints の計算（HintHelpers、SortedTroves） → `frontend/src/lib/mezo.ts` の `computeHints`。testnet で `validInsertPosition` が true を返すことを確認
- [x] 手順の表示と、途中からの再開（署名を伴う実際の再開は未確認）
- [x] trove の ICR、2本の清算ライン、最低借入額・ガス補償・金利・手数料の表示
- [x] 決済後の「trove に返済する」ボタン（`repayMUSD` の送信は未確認）
- [ ] EVM ウォレットと Passport の BTC ウォレットで、3経路それぞれ testnet で建玉まで確かめる。画面のスクリーンショットを `snapshot/` に保存する

## 仕上げ

- [ ] デプロイヤー以外のウォレットで、3経路それぞれ取引する
- [x] README（Built for Mezo、What's live vs mocked、Security & limitations、Wave log）を更新する → 2026-11-06 に v3 のデプロイを反映
- [x] docs/DEPLOYMENTS.md と docs/OPERATIONS.md を更新する → 2026-11-06（v3 のアドレス、鍵の役割、timelock 操作、v2 の凍結）
- [x] テスト件数を README に反映する → 2026-11-06: Foundry 単体・ファジング 80、fork 44、keeper 23
- [ ] 独立レビュー（on-chain、金額計算に当たるので必須）
