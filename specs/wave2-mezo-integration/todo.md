# Wave 2 todo

仕様: [spec.md](spec.md)。締切 2026-11-15。実装の順番は 0 → C → B → T → 移行 → A → 仕上げ。

## 0. 着手前の確認（spec 8 章）

- [ ] fork テストで、Skip の precompile（`0x7b7c…0015`）に `vm.etch` で mock の aggregator を置き、PriceFeed の `fetchPrice()` が動くか → 確認方法: fork テストで `fetchPrice()` が値を返す
- [ ] testnet の faucet で1回にもらえる BTC の量 → 確認方法: faucet.test.mezo.org で実際に受け取る。約 0.03〜0.04 BTC に届かなければ、既定の入金方法を「MUSD で入金」にする
- [ ] v2 の状態を読む: `houseCash`、`queueTotal`、`openPositionIds`、`pendingOrderIds`、`accountingDelta`、RebateStaking の `totalStaked` → 確認方法: `cast call`（読み取りのみ）
- [ ] `RebateToken.setStaking` を切り替えても、v2 の RebateStaking から unstake できるか → 確認方法: `src/RebateToken.sol` の転送制限を読み、単体テストで確かめる
- [ ] SP の初期パラメータを決める（`spMinLiquid`、`spMaxShareBps`、`spBandBps`）

## C. PriceFeed による価格境界

- [ ] `MezoPriceBound` を作り、SignedPriceOracle と PythPullOracle の境界を置き換える
- [ ] PriceFeed の mock と単体テスト（境界内、境界外、PriceFeed の revert）
- [ ] PriceFeed が revert しても `liquidate` と `executeOrder` が成功するテスト
- [ ] fork テスト（実 PriceFeed）

## B. Stability Pool

- [ ] HouseExchange v3: `spDeposit()`、`rebalance()`、`_payWinner` と `harvest` での補充、`receive()`、`forwardBtc()`、`houseEquity` と `sweepExcess` の変更、パラメータの setter
- [ ] RebateStaking v3: BTC の配当（`notifyRewardBtc`、`claim` で両方を払う）
- [ ] StabilityPool の mock と単体テスト（spec 5.2 の受入条件）
- [ ] ファジングに SP の操作を加え、毎ステップで会計の恒等式を確かめる
- [ ] fork テスト（実 StabilityPool への預け入れと引き出し）

## T. timelock と鍵

- [ ] デプロイスクリプトに TimelockController を加え、各コントラクトの owner を移す（testnet の遅延は 1 時間）
- [ ] keeper と価格署名者の鍵を新しく分ける。Worker の secret を差し替える（**秘密情報の変更なので、実行前にユーザーの確認が必要**）
- [ ] timelock を通さないと owner 権限が使えないテスト

## 移行（v2 → v3）

- [ ] v2 の建玉と escrow を空にする（0 の結果しだい）
- [ ] v3 を testnet にデプロイする（**デプロイなので、実行前にユーザーの確認が必要**）
- [ ] エクスプローラでコントラクトを検証する
- [ ] timelock 経由で RebateToken の `setMinter` と `setStaking` を v3 に向ける
- [ ] keeper-worker: アドレスを設定から読むように変える。tick で `rebalance()` と `forwardBtc()` を呼ぶ。Worker の再デプロイ（**実行前にユーザーの確認が必要**）
- [ ] deployments/testnet.json を v3 にする。v2 は別ファイルに残す

## A. 入金の3経路（フロント）

- [ ] 入金方法の選択（BTC で始める／既存の trove から／MUSD で入金）と、trove の状態による自動の切り替え
- [ ] hints の計算（HintHelpers、SortedTroves）
- [ ] 手順の表示と、途中からの再開
- [ ] trove の ICR、2本の清算ライン、最低借入額・ガス補償・金利・手数料の表示
- [ ] 決済後の「trove に返済する」ボタン
- [ ] EVM ウォレットと Passport の BTC ウォレットで、3経路それぞれ testnet で建玉まで確かめる。画面のスクリーンショットを `snapshot/` に保存する

## 仕上げ

- [ ] デプロイヤー以外のウォレットで、3経路それぞれ取引する
- [ ] README（Built for Mezo、What's live vs mocked、Security & limitations、Wave log）を更新する
- [ ] docs/DEPLOYMENTS.md と docs/OPERATIONS.md を更新する
- [ ] テスト件数を README に反映する
- [ ] 独立レビュー（on-chain、金額計算に当たるので必須）
