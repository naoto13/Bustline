# Wave 2: Mezo の仕組みとの統合 仕様

- 作成日: 2026-11-02
- 対象: Bustline（HEAD 84fa47e 時点のコード）
- 締切: Wave 2 の提出 2026-11-15
- 状態: 実装済み（コントラクト・keeper-worker・画面）。testnet へのデプロイと実ウォレットでの確認は未実施（2026-11-02）
- 参照した一次資料: `mezo-org/musd`（SHA `da7888a10949c8a5d3f884454cec8978cfa87e48`）、`@mezo-org/passport` 0.17.2、`@mezo-org/orangekit` 1.0.0-beta.40、`@mezo-org/orangekit-smart-account` 1.0.0-beta.24

## 1. 目的

MUSD を「Bustline を素通りするだけの ERC-20」から、Mezo の仕組みの中で生まれ、運用されるお金に変える。具体的には次の4つを行う。

| 記号 | 変更 | 使う Mezo の仕組み |
| --- | --- | --- |
| C | 価格の妥当性の境界を、MUSD の PriceFeed で取る | `PriceFeed.fetchPrice()` |
| B | ハウスの遊休 MUSD を Stability Pool で運用し、清算で得た BTC を MPAPER のステーカーに配る | `StabilityPool` |
| A | 「BTC で始める」入金経路。画面の中で trove を開き、借りた MUSD をそのまま証拠金にする | `BorrowerOperations`、`HintHelpers`、`SortedTroves`、`TroveManager` |
| T | オーナー権限を timelock の下に置き、鍵を役割ごとに分ける | OpenZeppelin `TimelockController` |

## 2. 対象外

- trove を代わりに開く Router コントラクト、`BorrowerOperationsSignatures` を使う署名経路、`requestOpenFor`（理由は 3.3）。余裕があれば、Wave 2 の後に EVM ウォレット向けの改善として検討する
- 清算で得た BTC を MUSD に交換すること（Mezo Pools は使わない。BTC のまま配る）
- MEZO トークンの組み込み、veBTC/veMEZO の投票
- mainnet へのデプロイ、外部監査、multisig
- クレカ入金（展望として 10 章に記す）
- 手数料・インパクト・mint 曲線の調整

## 3. 前提と制約

### 3.1 コントラクトは再デプロイが必要

- HouseExchange はプロキシではない（`src/HouseExchange.sol:22`、`musd` と `rebateToken` が immutable）
- RebateStaking の `funder` は immutable（`src/RebateStaking.sol:17`）
- したがって HouseExchange と RebateStaking は v3 として新規にデプロイする。v1 → v2 と同じく、資金を移すコードはない（6 章）

### 3.2 MUSD プロトコルの仕様（一次資料で確認済み）

| 項目 | 値 |
| --- | --- |
| 担保 | ネイティブ BTC を `msg.value` で送る |
| 最低純債務 | 1,800 MUSD（通常モードでは借入額 + 手数料 0.1% で判定） |
| ガス補償 | 200 MUSD（債務に加算される） |
| 金利 | 年 1% の単利（開設時の値に固定） |
| MCR / CCR | 110% / 150%。TCR < 150% で回復モード（新規 trove は ICR ≥ 150% が必要） |
| trove の数 | 1アドレスに1つ。既にある場合 `openTrove` は revert する |
| PriceFeed | `fetchPrice()` は BTC/USD を 18 桁で返す。元は Skip（`0x7b7c…0015`）。60 秒更新がないと revert |
| Stability Pool | 入出金にプロトコル手数料はない。清算時は、ICR に関係なく MUSD が burn され、担保の 99.5% の BTC を受け取る。MUSD やトークンの報酬はない |
| SP の出金制限 | ICR が最も低い trove が 110% 未満の間、または PriceFeed が止まっている間は `withdrawFromSP(amount > 0)` が revert する。`withdrawFromSP(0)`（BTC の利益の回収）は制限を受けない |
| SP の BTC 送金 | `provideToSP` と `withdrawFromSP` は、呼ぶたびにそれまでに貯まった BTC の利益を `call{value}` で送ってくる |

testnet のアドレス:

| コントラクト | アドレス |
| --- | --- |
| MUSD | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` |
| BorrowerOperations | `0xCdF7028ceAB81fA0C6971208e83fa7872994beE5` |
| StabilityPool | `0x1CCA7E410eE41739792eA0A24e00349Dd247680e` |
| PriceFeed | `0x86bCF0841622a5dAC14A313a15f96A95421b9366` |
| TroveManager | `0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0` |
| HintHelpers | `0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6` |
| SortedTroves | `0x722E4D24FD6Ff8b0AC679450F3D91294607268fA` |

### 3.3 Passport の BTC ウォレットはスマートアカウント

ソースで確認した事実:

- BTC ウォレット（Unisat・OKX・Xverse）で接続すると、EVM のアドレスは Safe のスマートアカウントになる（`orangekit/src/wallet/connector.ts` の `OrangeKitSmartAccount.predictAddress`）
- `signTypedData` は "Unsupported method" で失敗する（`orangekit/src/wallet/client.ts`）
- 送信は1回に1つの呼び出しだけ。Safe の `operation` は `0`（CALL）に固定で、MultiSend によるまとめ送りはできない（`orangekit-smart-account/src/lib/index.ts`）。`value` 付きの呼び出しは送れる
- `BorrowerOperationsSignatures` の署名は EOA の ECDSA のみで、ERC-1271 に対応していない

**決定**: どのウォレットでも、トレーダーが `BorrowerOperations` と HouseExchange を直接呼ぶ。「1回で取引まで」は、画面で手順を一続きに案内することで実現する。

### 3.4 鍵

v2（凍結）では owner、keeper、価格署名者が同じ EOA（`0x715211CA…`）だった。keeper の鍵は Cloudflare Worker の secret にあり、漏れると owner として `setOracle` を呼べてしまう。v3 ではこの3つを別の鍵に分け、owner は timelock にした。

## 4. 全体構成（変更後）

```text
                          ┌─────────── Mezo MUSD プロトコル ────────────┐
 [トレーダー]              │                                             │
   ├ BTC で始める ── openTrove{value: BTC} ──► BorrowerOperations ──mint──┼──► トレーダーの MUSD
   ├ 既存 trove ──── withdrawMUSD ─────────► BorrowerOperations ──mint──┤
   └ MUSD で入金 ─────────────────────────────────────────────────────┤
                                                                         │
   approve + requestOpen ◄───────────────────────────────────────────────┘
        ▼
 ┌──────────────── HouseExchange v3 ─────────────────┐
 │ escrow → margin → 決済（v2 と同じ）                 │
 │ houseCash（手元）                                    │── provideToSP ──► StabilityPool
 │   ＋ spDeposit()（SP の実際の預入額）＝ ハウスの資産  │◄─ withdrawFromSP ─┘   │
 │ 勝ちの支払い: 手元 → SP から補充 → FIFO キュー        │                      │ BTC の利益
 │ receive(): StabilityPool からの BTC だけ受け付ける     │◄─────────────────────┘
 └──────────────┬──────────────────────────────────────┘
                │ forwardBtc()（BTC）、手数料（MUSD）
                ▼
        RebateStaking v3（MUSD と BTC の2種類の配当）

 価格: SignedPriceOracle ─ 境界 ─► PriceFeed.fetchPrice()（失敗時は境界なしで通す）
 権限: TimelockController ─ owner ─► HouseExchange v3 / RebateToken / 各オラクル
```

## 5. 機能仕様

### 5.1 C: PriceFeed による価格境界

- `src/oracles/SkipBound.sol` を `MezoPriceBound`（仮称）に置き換える。読む相手を Skip の aggregator から MUSD の `PriceFeed` に替える
- 境界: 署名オラクル（と Pyth）の価格が `PriceFeed.fetchPrice()` から `boundBps`（既定 100 = ±1%）以内であること。外れたら更新を revert する（今と同じ）
- 境界をかける場所（明確化）: `latest()` は view でイベントを出せないので、`update()` で境界をかけてイベントを出し、`latest()` でも同じ判定をする（Pyth は誰でも直接更新できるため）
- **PriceFeed が失敗したとき**（60 秒更新なしで revert、その他の revert）は、`try/catch` で受けて境界をかけずに通し、イベント `PriceBoundSkipped` を出す。今の SkipBound が古い Skip を無視して通すのと同じ挙動にする
  - 理由: 境界のせいで価格の更新が止まると、清算が止まる。清算が止まることのほうが危ない
- 価格の単位: PriceFeed は 18 桁。Bustline の内部の桁数に合わせて変換する

受入条件:

- [ ] 単体: PriceFeed の mock で「境界内なら更新できる」「境界外なら revert」「PriceFeed が revert したら境界なしで更新でき、イベントが出る」の3つが通る
- [ ] **PriceFeed が revert している状態でも `liquidate` と `executeOrder` が成功する**
- [ ] fork: testnet の実 PriceFeed を読み、境界の判定ができる（Skip の precompile への対応は 8.2）

### 5.2 B: Stability Pool での運用

#### 状態と会計

- `houseCash` の意味を「コントラクトの中にある手元の MUSD」に限る。SP に預けた分は含めない
- `spDeposit()`（view）: `StabilityPool.getCompoundedMUSDDeposit(address(this))`。清算による目減りが反映された実際の預入額
- 会計の恒等式は v2 と同じ: `accountingDelta = MUSD.balanceOf(this) − (houseCash + totalMargin + totalEscrow) == 0`。SP に預けた分はコントラクトの残高にも `houseCash` にも入らないので、恒等式は崩れない
- `houseEquity()` = `houseCash + spDeposit() − queueTotal`
- `sweepExcess` の判定は `houseCash + spDeposit()` と `houseCap` で行い、送るのは手元の `houseCash` からだけ
  - SP に預入があるとき（`spDeposit() > 0`）は、送った後の `houseCash` が `spMinLiquid` 以上に残る分までしか送らない。SP の出金が止まっても、手元の最低額で勝ちを払えるようにするため。預入がないときは今までどおり
- **SP に入れるのは `houseCash` だけ。** `totalMargin` と `totalEscrow` は返金の義務があるので入れない

#### パラメータ（owner = timelock が設定）

| 名前 | 意味 | 初期値（仮） |
| --- | --- | --- |
| `spEnabled` | SP での運用の有効・無効 | `false`（デプロイ後に有効化） |
| `spMinLiquid` | 手元に残す最低額 | 1,000 MUSD |
| `spMaxShareBps` | ハウスの資産のうち SP に預ける上限の割合 | 5,000（50%） |
| `spBandBps` | 出し入れを始める幅（ヒステリシス） | 2,000（±20%） |

初期値は testnet の規模に合わせた仮の値。8 章で、実際の houseCash を読んでから決める。

#### 関数

- `rebalance()`（誰でも呼べる。keeper が定期的に呼ぶ）
  - 手元が `spMinLiquid × (1 + spBandBps)` を超えたら、超えた分を `provideToSP` する。ただし SP の預入額は、ハウスの資産の `spMaxShareBps` 以下に抑える
  - 手元が `spMinLiquid × (1 − spBandBps)` を下回り、SP に預入があれば、`spMinLiquid` まで `withdrawFromSP` する
  - `withdrawFromSP` が revert したら、`try/catch` で受けてイベント `SpWithdrawBlocked` を出し、正常終了する
  - 実際に受け取った MUSD の額は、残高の差分で測って `houseCash` に足す
  - **出金が止まっている間は預け入れない**: `SortedTroves.getLast()` の trove の ICR が MCR 未満のとき（＝今は出金できないとき）は、`provideToSP` をしない。預けた後に引き出せなくなるのを避けるため
    - 2026-11-02 時点の testnet では、ICR が最も低い trove が約 109.3% で MCR を下回っており、SP の出金が止まっている。この状態は、誰かがその trove を清算（`TroveManager.liquidate`）するまで続く
- `_payWinner` の変更
  - キューが空で手元が支払い額に足りないときは、足りない分を `withdrawFromSP` で補充してみる（`try/catch`）
  - それでも足りない分は、今と同じく FIFO キューに積む
- `harvest(n)` の変更: キューが残っていて手元が足りないときは、キューの合計まで SP から補充してみてから消化する（`try/catch`）
- 実装での明確化（2026-11-02）
  - 「超えた分」は、手元を `spMinLiquid` まで下げる量とする（上限の帯まででなく）。帯の内側では出し入れしないので、細かい預け入れを繰り返さない
  - キューが空でないときは預け入れない。キューがあって手元が `spMinLiquid + queueTotal` より少なければ、その差を引き出してから `_harvest` する
  - `spEnabled = false` にしたら、`rebalance()` は預入をすべて引き出す（止めるための手順）
  - PriceFeed が失敗しているときも預け入れない（このとき SP の出金も止まるため）
  - 外部呼び出しには固定のガス上限を付け、残りのガスが足りなければ、`catch` に入れず全体を revert する。呼び出し側がガスを絞って、わざと `catch`（境界を外す・勝ちをキューに回す）に入れることを防ぐため
  - keeper 用の view: `rebalanceAction()`（何をするか）、`spWithdrawable()`、`forwardableBtc()`
- `receive()`: `msg.sender == stabilityPool` のときだけ受け付け、それ以外は revert する。中で状態は変えない（受け取った BTC は残高として貯まるだけ）
  - SP からの BTC は、`nonReentrant` の関数（決済や `rebalance`）の途中で届く。`receive()` には `nonReentrant` を付けない
- `forwardBtc()`（誰でも呼べる）
  1. `withdrawFromSP(0)` で BTC の利益を回収する（出金制限を受けない）。SP に一度も預けていないときは、この呼び出しが revert するので省く
  2. ステーカーがいれば、コントラクトの BTC の残高をすべて `RebateStaking.notifyRewardBtc{value}` で送る
  3. いなければ、そのまま保有して次の機会に送る

#### RebateStaking v3

- v2 の MUSD の配当に、ネイティブ BTC の配当を足す。配当は reward-per-token の積み上げを、MUSD と BTC で別々に持つ
- `notifyRewardBtc() payable`: funder（HouseExchange v3）だけが呼べる
- `claim()`: MUSD と BTC の両方を払う。`nonReentrant` を付ける。戻り値は `(uint256 musd, uint256 btc)`（`btc` は実際に払った額）
  - MUSD は必ず払う。BTC は `call{value}` で送り、失敗しても revert しない。BTC は `owedBtc` に残し、イベント `BtcClaimFailed(user, amount)` を出す
- `claimBtcTo(address payable to)`: BTC だけを `to` に送る（BTC を受け取れないコントラクトのステーカー向け）。送金に失敗したら revert する。`nonReentrant` を付ける
- `funder` は v2 と同じく immutable

#### リスクと対処

| リスク | 対処 |
| --- | --- |
| ICR 100% 未満の清算で SP の預入額が目減りする | `spMaxShareBps` で上限を設ける。目減りした分はハウスの損失として `houseEquity` に表れる |
| BTC の急落時に出金が止まる。そのタイミングで勝つのはショート側 | 手元に `spMinLiquid` を残す。払えない分は既存の FIFO キューで受け、後から消化する |
| SP から BTC が届かず入金が止まる | `receive()` を用意する。受入条件で確かめる |

受入条件:

- [ ] 単体（SP の mock）: 預け入れ、引き出し、上限、幅の判定、引き出しの revert を受けたときの動き、清算による目減り、BTC の受け取りと `forwardBtc`
- [ ] **すべての状態遷移の後で `accountingDelta == 0` と `queueTotal == キューの合計` が成り立つ**（既存のファジングに SP の操作を加える）
- [ ] 引き出しが revert していても、勝ちの決済は成功する（足りない分はキューに積まれる）
- [ ] StabilityPool 以外からの BTC の送金は revert する
- [ ] RebateStaking v3: MUSD と BTC の配当が、ステーク量に比例して配られる
- [ ] fork: testnet の実 StabilityPool に預け入れ・引き出しができる

### 5.3 A: 入金の3経路（画面の変更）

コントラクトは変えない。トレーダーが自分で `BorrowerOperations` と HouseExchange を呼ぶ。

| 経路 | 条件 | 手順 |
| --- | --- | --- |
| BTC で始める | trove を持っていない | ① `openTrove{value: BTC}(debt, upperHint, lowerHint)` → ② MUSD の `approve`（初回だけ） → ③ `requestOpen` |
| 既存の trove から | trove を持っている | ① `withdrawMUSD(amount, upperHint, lowerHint)` → ② `approve`（初回だけ） → ③ `requestOpen` |
| MUSD で入金 | MUSD を持っている | ① `approve`（初回だけ） → ② `requestOpen`（v2 と同じ） |

画面の要件:

- 接続したアドレスの trove の状態を `TroveManager` で読み、「BTC で始める」と「既存の trove から」を自動で切り替える
- 入力: 使う BTC の量と、借りる MUSD の量。借入額のうち証拠金に使わない分は、トレーダーの手元に残る
- 次を表示する
  - trove の ICR と、trove の清算価格（ICR 110%）
  - 建玉の清算価格（bust line）
  - 両方を同じチャートに表示する（2本の清算ライン）
  - 最低借入額（純債務 1,800 MUSD）と、ガス補償 200 MUSD が債務に加わること
  - 金利（年 1%）と借入手数料（0.1%）
  - 回復モード中は ICR 150% 以上が必要であること
- 既定の ICR の目安は 150% 以上にし、110% に近い入力には警告を出す
- hints: `HintHelpers.getApproxHint` と `SortedTroves.findInsertPosition` で、画面側で計算する
- 手順の進み具合を1つの画面で表示し、途中で失敗したら、その手順から再開できるようにする。trove を開いた後に建玉で失敗しても、MUSD はトレーダーの手元に残る
- 決済後: 「trove に返済する」ボタン（`repayMUSD` を直接呼ぶ）を置く。自動では返済しない
- **既定の入金方法**: 「BTC で始める」を既定にする。ただし testnet の faucet で必要な BTC（約 0.03〜0.04 BTC）が手に入らない場合は、「MUSD で入金」を既定にする（8 章で確認する）

受入条件:

- [ ] EVM ウォレットと Passport の BTC ウォレットの両方で、3つの経路それぞれ testnet で建玉まで完了する
- [ ] trove を持っているアドレスに「BTC で始める」が出ない
- [ ] 2本の清算ラインが表示される
- [ ] 途中で失敗してから再開できる

### 5.4 T: timelock と鍵の分離

- `TimelockController` を owner にするもの: HouseExchange v3、RebateToken、SignedPriceOracle、PythPullOracle
- 遅延: testnet は 1 時間。デモの前にパラメータを調整できるようにするため。mainnet では 48 時間以上にすることを README に書く
- proposer と canceller: デプロイヤーの EOA。executor: 誰でも（`address(0)`）
- 鍵を3つに分ける: timelock の proposer（デプロイヤー）、keeper、価格署名者。keeper の鍵が漏れても、owner の権限は使えない
- **timelock を通さないもの**: なし。緊急停止の機能は今回は作らない（README の制約に書く）

受入条件:

- [ ] owner 権限の関数をデプロイヤーが直接呼ぶと revert し、timelock から遅延後に実行すると成功する
- [x] deployments の JSON に timelock、keeper、価格署名者の3つのアドレスが別々に記録されている → `deployments/testnet-v3.json`（2026-11-06）

## 6. v2 → v3 への移行

**決定（2026-11-06）: v2 のデプロイヤー鍵を紛失したため、RebateToken も新しくデプロイする。v2 は記録として凍結する。**

- v3 として、HouseExchange、RebateStaking、オラクルに加えて、RebateToken（"Mezo Paper"／`MPAPER`、譲渡不可）も新規にデプロイする（`script/DeployTestnetV3.s.sol`）
  - デプロイの中で `setMinter(HouseExchange v3)` と `setStaking(RebateStaking v3)` を済ませてから、owner を timelock に移す。timelock 操作 A（v2 の RebateToken の切り替え）は不要になった
  - ~~RebateToken（MPAPER）は使い回す。timelock 経由で `setMinter(v3)` と `setStaking(v3)` を実行する~~ → 中止（理由: v2 デプロイヤー鍵の紛失により新トークンで再デプロイ）
- v2 の扱い
  - v2（`deployments/testnet.json`）は凍結し、Wave 1 の記録として残す。鍵がないので操作できない
  - v2 の建玉 #2、MPAPER の保有量とステークは v3 に移さない。README と docs/DEPLOYMENTS.md に書く
  - ~~建玉と escrow が残っていれば、決済とキャンセルで空にしてから切り替える~~ → 中止（同上）
  - v2 にはオーナーが資金を引き出す関数がない。残った houseCash（約 110 MUSD）は v2 に残る
- 鍵: デプロイヤー（timelock の proposer）、keeper、価格署名者を3つの別の鍵にする。鍵は git の外に置く
- v3 のアドレスは `deployments/testnet-v3.json` に記録する（v2 の `deployments/testnet.json` はそのまま）
- keeper-worker: アドレスを設定（`wrangler.toml` の `EXCHANGE_ADDRESS`・`ORACLE_ADDRESS`）から読むように変え、v3 に向ける。tick の中で `rebalance()` と `forwardBtc()` を呼ぶ（`SP_OPS = "1"`、間隔は `SP_INTERVAL_SECONDS`）。2026-11-06 に v3 で再デプロイ済み
- フロント: deployment の JSON を読む仕組みは今のまま（`frontend/src/lib/config.ts:30`）。本番の `deployment.testnet.json` を v3 に切り替えるのは未実施

## 7. テスト方針

- 既存のテスト（Foundry 33 件、keeper 23 件）を弱めない
- 単体: StabilityPool、PriceFeed、BorrowerOperations の mock を `test/mocks/` に作る
- ファジング: 既存のランダム取引（`test/HouseExchange.t.sol:282-312`）に `rebalance`、SP の清算による目減り、引き出しの revert を加え、毎ステップで会計の恒等式を確かめる
- fork: `MEZO_FORK_URL` があるときだけ動かす（今と同じ）。実 StabilityPool と PriceFeed を使う

## 8. 着手前に確かめること

1. ~~fork テストで Skip の precompile が動くか~~ → **確認済み（2026-11-02）**: そのままでは revert するが、`vm.etch` で mock の aggregator を置けば、PriceFeed、BorrowerOperations、StabilityPool がすべて fork で動く（`test/fork/MezoPrimitivesFork.t.sol`）
2. ~~testnet の faucet で、1回にどれだけ BTC がもらえるか~~ → **確認済み（2026-11-02）**: 1回 0.05 BTC。1回で trove を開けるので、既定の入金方法は「BTC で始める」のまま
3. ~~v2 の建玉、escrow、キュー、houseCash、RebateStaking のステーク量（RPC で読む）~~ → **確認済み（2026-11-02）**。todo 0 章
4. ~~`RebateToken.setStaking` を切り替えた後も、v2 の RebateStaking から unstake できるか~~ → **確認済み**: できない。ただし 2026-11-06 の決定で RebateToken を新しくしたので、切り替え自体を行わない
5. ~~SP の初期パラメータ（`spMinLiquid` など）を 3 の結果で決める~~ → **決定済み**: 50 MUSD、5,000、2,000（todo 0 章）

## 9. 完了の条件

- 5 章の受入条件がすべて満たされている
- v3 が testnet にデプロイされ、エクスプローラでコントラクトが検証されている
- デプロイヤー以外のウォレットで、3つの入金経路それぞれ取引が成立している
- README（Built for Mezo、What's live vs mocked、Security & limitations、Wave log）と docs/DEPLOYMENTS.md、docs/OPERATIONS.md が更新されている

## 10. 展望（Wave 2 の後）

- **クレカ入金（Q1 2027 予定）**: on-ramp の提携先を通じてカードで支払い、BTC の担保として届き、最初の取引まで一続きの流れで済ませる。提携先は未定
- **EVM ウォレット向けの1トランザクション化**: Router と `BorrowerOperationsSignatures` で、trove を開いてから建玉までを1回で行う（3.3 のとおり、BTC ウォレットには使えない）
- **Mezo の TVL への寄与**
  - 「BTC で始める」たびに trove が開かれ、借入が続く間 BTC が Mezo にロックされる
  - trove が新しい MUSD を mint し、借入手数料と金利はプロトコルに入る
  - ハウスの遊休 MUSD が Stability Pool を厚くし、MUSD の借り手すべてを守る清算余力になる
  - クレカ入金で、暗号資産を持っていない人のお金を BTC の担保として直接 Mezo に入れられる
- Hardening（外部レビュー、multisig、権限のない keeper）、mainnet のベータ
