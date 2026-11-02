# Wave 2 todo

仕様: [spec.md](spec.md)。締切 2026-11-15。実装の順番は 0 → C → B → T → 移行 → A → 仕上げ。

## 0. 着手前の確認（spec 8 章）

- [x] fork テストで、Skip の precompile（`0x7b7c…0015`）に `vm.etch` で mock の aggregator を置き、PriceFeed の `fetchPrice()` が動くか → 結果（2026-11-02）: 動く。`test/fork/MezoPrimitivesFork.t.sol` の 8 件が通過
  - etch しないと、fork では precompile のスタブが自分自身を呼び続けて revert する
  - etch すると `fetchPrice()`、`openTrove`、`provideToSP`／`withdrawFromSP`、出金制限（ICR < 110%）がすべて動く
  - 手順: `new MockSkipAggregator(18)` → `vm.etch(SKIP, code)` → `setPrice(p)`。ストレージはコピーされないので、価格は etch の後に入れる
  - 注意: 今の testnet では ICR が最も低い trove が約 109.3% で MCR を下回っている。実価格に近い mock の価格では SP の出金が revert するので、テストでは価格を高めに置く
- [x] testnet の faucet で1回にもらえる BTC の量 → 結果（2026-11-02）: 0.05 BTC（faucet のアドレス `0xc2a9…A6EA` からの直近の送金がすべて 0.05 BTC）。captcha（Turnstile）が必要で、IP ごとに 24 時間に1回の見込み。1回で trove（ICR 150% で約 0.039 BTC）を開けるので、**既定の入金方法は「BTC で始める」のままにする**
- [x] v2 の状態を読む: `houseCash`、`queueTotal`、`openPositionIds`、`pendingOrderIds`、`accountingDelta`、RebateStaking の `totalStaked` → 結果（2026-11-02、block 16521439、`cast call`）: houseCash 109.7749 MUSD、queueTotal 0（queueLength 0）、openPositionIds `[2]`（totalMargin 10 MUSD）、pendingOrderIds `[]`（orderCount 5）、totalEscrow 0、accountingDelta 0、RebateStaking.totalStaked 0（totalDistributed 0）。RebateToken: owner `0x7152…`（デプロイヤー）、minter = v2 HouseExchange、staking = v2 RebateStaking、transferable false、totalSupply 11,032.49
  - **建玉 #2 が残っている**。minter を v3 に切り替える前に、決済か清算で閉じる（下の項目）
- [x] `RebateToken.setStaking` を切り替えても、v2 の RebateStaking から unstake できるか → 結果: **できない**。`_update` は今の `staking` との転送しか許さないので、v2 の unstake は `NonTransferable` で revert する（`test/RebateStakingV3.t.sol` `test_migration_setStakingBlocksOldUnstake`）。今は v2 の totalStaked が 0 なので実害はない。timelock の操作を実行する直前に、もう一度 0 を確かめる
  - 同様に、`setMinter(v3)` の後は v2 の負けの決済と清算が `NotMinter` で revert する（`test_migration_setMinterBlocksOldLossSettlement`）。v2 の建玉を先に空にする
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

- [x] デプロイスクリプトに TimelockController を加え、各コントラクトの owner を移す（testnet の遅延は 1 時間）→ `script/DeployTestnetV3.s.sol`。fork 上の dry-run（broadcast なし）が通過。broadcast はまだしていない
- [ ] keeper と価格署名者の鍵を新しく分ける。Worker の secret を差し替える（**秘密情報の変更なので、実行前にユーザーの確認が必要**）
- [x] timelock を通さないと owner 権限が使えないテスト → `test/Timelock.t.sol`、fork の `test_fork_deployScriptV3_ownersAndTimelockFlow`

## 移行（v2 → v3）

- [ ] v2 の建玉と escrow を空にする（0 の結果しだい）
- [ ] v3 を testnet にデプロイする（**デプロイなので、実行前にユーザーの確認が必要**）
- [ ] エクスプローラでコントラクトを検証する
- [ ] timelock 経由で RebateToken の `setMinter` と `setStaking` を v3 に向ける
- [ ] keeper-worker: アドレスを設定から読むように変える。tick で `rebalance()` と `forwardBtc()` を呼ぶ。Worker の再デプロイ（**実行前にユーザーの確認が必要**）
  - コードの変更は済み（vars: `EXCHANGE_ADDRESS`・`ORACLE_ADDRESS`・`SP_OPS`・`SP_INTERVAL_SECONDS`、secret: `PRICE_SIGNER_PRIVATE_KEY`。未設定なら keeper の鍵で署名＝v2 と同じ）。SP の出金が止まっている間は harvest と引き出しの rebalance を送らない。型チェックと再デプロイは未実施
- [ ] deployments/testnet.json を v3 にする。v2 は別ファイルに残す

## A. 入金の3経路（フロント）

- [x] 入金方法の選択（BTC で始める／既存の trove から／MUSD で入金）と、trove の状態による自動の切り替え → `frontend/src/components/Funding.tsx`（画面の確認は読み取りのみ。`?viewAs=` で trove あり／なしを表示）
- [x] hints の計算（HintHelpers、SortedTroves） → `frontend/src/lib/mezo.ts` の `computeHints`。testnet で `validInsertPosition` が true を返すことを確認
- [x] 手順の表示と、途中からの再開（署名を伴う実際の再開は未確認）
- [x] trove の ICR、2本の清算ライン、最低借入額・ガス補償・金利・手数料の表示
- [x] 決済後の「trove に返済する」ボタン（`repayMUSD` の送信は未確認）
- [ ] EVM ウォレットと Passport の BTC ウォレットで、3経路それぞれ testnet で建玉まで確かめる。画面のスクリーンショットを `snapshot/` に保存する

## 仕上げ

- [ ] デプロイヤー以外のウォレットで、3経路それぞれ取引する
- [ ] README（Built for Mezo、What's live vs mocked、Security & limitations、Wave log）を更新する
- [ ] docs/DEPLOYMENTS.md と docs/OPERATIONS.md を更新する
- [ ] テスト件数を README に反映する
- [ ] 独立レビュー（on-chain、金額計算に当たるので必須）
