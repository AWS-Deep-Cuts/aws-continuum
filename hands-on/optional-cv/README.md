この README は、AWS Deep Cuts の AWS Continuum のハンズオンの、任意の発展です。主な手順は [リポジトリの README](../../README.md) にあります。

<!-- 要確認: 次の 2 つが済むまで、この README を公開しない。(1) 著者の翌日の請求額と料金ページの単価で、冒頭の費用の注意と「費用の見積もり」を置き換える。(2) Integration のロールの信頼ポリシーのプリンシパルを確かめ、setup-cv.sh の CONTINUUM_TRUST_PRINCIPAL_JSON に書き込み、発展 1 に出典を 1 文書く -->

> **Note**: この発展では、AWS Continuum に含まれる **Continuum for Code Vulnerabilities** を使います。この README では CV と書きます。CV は、コードをビルドしてから脆弱性を見つけ、悪用できるかを検証し、修正パッチを作成する機能です。API と AWS CLI のコマンドの名前は `continuum` です。
> - 2026 年 11 月 1 日の時点で、CV のエンドポイントはバージニア北部 `us-east-1` とオレゴン `us-west-2` にしかありません。そのため、この発展は `us-east-1` で行います。すべてのコマンドに `--region "${CV_REGION}"` を付けます。
> - AWS CLI は、`aws continuum` コマンドに対応した v2.38.5 以降が必要です。
> - 主な手順と同じく、あなたの PC のターミナルで行います。AI コーディングツールは使いません。CV の操作は、あなたが AWS CLI のコマンドを 1 つずつ実行して行います。

> ⚠️ **コストに関する注意**
>
> CV は有料です。CV の単価は AWS Price List にありません。料金ページの検索の要約によると、CV の料金は、保護するコードの行数に応じた月額の **行数の料金** と、CV が行う作業の量に応じた **推論の料金** でできています。単価は、行数の料金が 100 万行あたり月 $200、推論の料金が 1 CIU あたり $10 です。CIU は Continuum inference unit の略で、推論の料金の単位です。CIU の正式な定義は見つかっていません。<!-- 要確認: 料金ページの単価・CIU の定義・最低料金と切り上げの有無・日割り -->
>
> | 場面 | 概算 |
> | --- | --- |
> | 手順どおりに、スキャンを 1 回実行した場合 | 約 **$20〜$60**（約 3,200〜9,600 円）の目安。上限の目安の式は「Finding の数 × 2 CIU × $10」。発展 5 で、あなたの Finding の数で計算し修正する |
> | 後片付けを忘れて 1 か月放置した場合の追加 | スキャンの間隔を手動だけにしていれば、行数の料金が行数に比例する場合は、行数の料金と S3 で $1 未満の見込み |
> | 行数の料金に最低料金や 100 万行単位の切り上げがある場合 | 1 か月で最大 **$200**（約 32,000 円） |
> | 仮定に基づく最大。行数の料金が 1 単位分かかり、Finding が 3 件で各 2 CIU の場合 | 合計 **約 $260**（約 41,600 円）。内訳は [費用の見積もり](#費用の見積もり) にあります |
>
> この金額は、料金ページの単価と、料金ページの計算例の「1 脆弱性あたり 1〜2 CIU」を仮定した計算です。1 ドル 160 円で換算しています。**CV の API には、費用の上限を決める項目がありません。始めたスキャンを止める操作もありません。** そのため、上の「最大」は、API の設定で保証される上限ではありません。
>
> - 始める前に、AWS Budgets で月の予算と、実績が予算の 80% を超えたときのメールの通知を設定することを勧めます。通知だけの予算は無料です。ただし、予算の通知は通知するだけで、スキャンも課金も止まりません。請求のデータの反映には時間がかかるため、通知はスキャンの後に届くことがあります。
> - 侵入テストは使いません。
>
> **検証が終わったら速やかに後片付けを実施し、翌日に請求を確認してください。**

# 発展のゴール

主な手順と同じレコード店のアプリを CV にスキャンさせ、CV が残す記録を読みます。次の特徴を自分の目で確かめます。

| 確かめる特徴 | 発展の手順 |
| --- | --- |
| CV は、あなたの S3 バケットのコードを、あなたが作成したロールと外部 ID で読む | 1・2 |
| Environment の設定で、スキャンの間隔とパッチの作成を決める | 3 |
| スキャンは、コードをビルドしてから分析する | 4 |
| 見つけた Finding を検証し、本物と判定したものだけを Issue にする。Issue にしなかったものにも理由が残る | 5 |
| 検証の証拠に入った証明の種類を、API の項目の名前で見分けられる | 6 |
| 修正パッチは届くだけで、照合と適用はあなたが行う | 7 |

最後に、主な手順の採点表 1 に「CV」の列を足し、Security Agent の結果と並べます。

## 主な手順との違い

| 観点 | 主な手順の Security Agent | この発展の CV |
| --- | --- | --- |
| API | `securityagent` | `continuum` |
| リージョン | 東京 | バージニア北部 |
| 操作する人 | AI コーディングツールが依頼し、あなたが承認する | あなたが AWS CLI で操作する |
| コードの渡し方 | バケットに保存した zip | バケットの `code/` と `context/` の下に保存したファイル |
| 悪用できるかの確かめ方 | Finding ごとのシミュレーションによる検証の状態 | コードをビルドしてから検証し、検証の証拠を成果物として残す |
| 修正 | 修正の提案を、AI コーディングツールが手元で当てる | unified diff の修正パッチと SHA-256 を残し、バケットに届ける |
| 始めたスキャンを止める | できる | できない |
| 予算の上限 | `maxTaskHours` | 無い |
| 単価 | Price List で $0.00/時 | Price List に無い。料金ページによると行数の料金と推論の料金 |

# 発展の手順

## 所要時間の目安

| 部分 | 目安 | 待つ間 |
| --- | --- | --- |
| 発展 1〜3 | 約 30 分 | |
| 発展 4 のスキャン | API の説明によると、数分から数時間 | ターミナルを閉じてよい。スキャンは AWS の中で進む |
| 発展 5〜6 | スキャンの後も、Finding の振り分けと Issue の作成が続く <!-- 要確認: 著者の実測 --> | ターミナルを閉じてよい |
| 発展 7〜9 | 約 40 分 | |

中断した場合は、新しいターミナルで次の 2 行を実行してから、中断した手順の待つループを再実行してください。

```bash
cd ~/aws-continuum/hands-on/optional-cv
source ~/deepcuts-results/cv/resource-ids.env
```

**ID を取り出すコマンドの共通の形**: `--output text` は、値が無いと文字列の `None` を返します。そのまま次のコマンドに渡すと、ID の形式に合わない `ValidationException` になり、原因が分かりにくくなります。そのため、主な手順と同じく、取り出した直後に値があるかを確かめてから、`resource-ids.env` に追記します。

## 発展 1．事前準備

S3 バケットと、CV が引き受ける IAM ロールを、`setup-cv.sh` で作成します。

```bash
cd ~/aws-continuum/hands-on/optional-cv
bash ./setup-cv.sh

# 以下の文言が表示されればセットアップ成功です
# ✅ 発展 CV のセットアップが完了しました！

source ~/deepcuts-results/cv/resource-ids.env
cat ~/deepcuts-results/cv/resource-ids.env
```

`❌ Error: 信頼ポリシーのプリンシパルが未設定です。` と表示された場合は、この発展はまだ実行できません。何も作成されていません。

| リソース | 名前 | 用途 |
| --- | --- | --- |
| S3 バケット | `aws-deepcuts-continuum-<アカウント ID>-<日時>` | コード・補足情報・届いたパッチを保存する。パブリックアクセスをブロックする |
| Integration のロール | `aws-deepcuts-continuum-s3-role` | CV が外部 ID を示して引き受け、`code/` と `context/` を読み、パッチを書き込む |

| 変数 | 中身 | 使う手順 |
| --- | --- | --- |
| `CV_REGION` | `us-east-1` | すべて |
| `BUCKET_NAME` | バケットの名前 | 2・7 |
| `ROLE_ARN` | Integration のロールの ARN | 2 |
| `EXTERNAL_ID` | 外部 ID。`deepcuts-` に 16 桁の 16 進数を続けた値 | 2 |
| `INTEGRATION_NAME` | `aws-deepcuts-s3` | 2 |
| `ENVIRONMENT_NAME` | `aws-deepcuts-record-shop` | 3 |
| `SCAN_TOKEN` | スキャンを二重に始めないための値 `aws-deepcuts-scan-1` | 4 |
| `CV_DIR` | 結果を保存する記録フォルダー `~/deepcuts-results/cv` | 5〜8 |

**外部 ID** は、ロールの信頼ポリシーの条件に書き、ロールを引き受ける側が示す必要のある、あらかじめ決めた文字列です。信頼ポリシーで誰を信頼するかは、ユーザーガイドの記述に合わせています。<!-- 要確認: 著者が確かめた出典 -->

<!-- 画面写真: IAM コンソールの aws-deepcuts-continuum-s3-role の「信頼関係」タブ。信頼されたエンティティの欄と sts:ExternalId の条件を枠で囲む -->

> **この手順で確かめること**
> - **やること**: IAM コンソールの左のメニューから「ロール」を選び、`aws-deepcuts-continuum-s3-role` を開いて「信頼関係」タブと「許可」タブを確認します。
> - **期待する結果**: 信頼されたエンティティの欄に CV があり、あなた自身のユーザーやロールはありません。信頼ポリシーの `Condition` に `sts:ExternalId` があり、値が `EXTERNAL_ID` と同じです。許可ポリシーでは、読み取りが `code/*` と `context/*` に、書き込みがパッチの接頭辞に絞られています。
> - **ここから分かること**: このロールを引き受けるのは、あなたではなく CV です。外部 ID を示さない限り、ロールを引き受けられません。

## 発展 2．コードを S3 に保存して Integration を作成する

CV は、S3 のソースのコードを `code/`、利用者が書いた補足情報を `context/` の接頭辞から読みます。API の説明によると、どちらも既定の接頭辞です。主な手順の `OPERATIONS.md` を、補足情報として保存します。アップロードするのは、リポジトリの `hands-on/app/` で、主な手順の手順 7 で修正する前のコードです。

```bash
cd ~/aws-continuum/hands-on
aws s3 cp app/ "s3://${BUCKET_NAME}/code/" --recursive --exclude "*__pycache__*" --region "${CV_REGION}"
aws s3 cp app/OPERATIONS.md "s3://${BUCKET_NAME}/context/app-context.md" --region "${CV_REGION}"
cd optional-cv
```

`code/` の下にファイルをそのまま保存するか、アーカイブにするかは確かめられていません。<!-- 要確認: code/ の下の置き方 -->

次に、**Integration** を作成します。Integration は、コードの保存先との接続の設定です。S3 の Integration は、バケットの名前・CV が引き受けるロール・外部 ID の 3 つで作成します。

```bash
INTEGRATION_ID=$(aws continuum create-integration \
  --region "${CV_REGION}" \
  --name "${INTEGRATION_NAME}" \
  --provider-configuration "s3={bucket=${BUCKET_NAME},roleArn=${ROLE_ARN},externalId=${EXTERNAL_ID}}" \
  --query integrationId --output text)
[[ -n "${INTEGRATION_ID}" && "${INTEGRATION_ID}" != "None" ]] && echo "INTEGRATION_ID=\"${INTEGRATION_ID}\"" >> ~/deepcuts-results/cv/resource-ids.env || echo "⚠️ INTEGRATION_ID を取り出せませんでした。トラブルシューティングを見てください"
echo "${INTEGRATION_ID}"
```

`--client-token` は渡しません。API の説明によると、作成の要求の記録は、成功や失敗の後 8 時間残ります。失敗した要求を同じトークンで再送すると、記録された同じ失敗が返ります。トークンを省くと、再実行のたびに新しい作成の要求になります。同じ名前の Integration が既にあると、作成は `ConflictException` になり、メッセージにその Integration の ID が入るため、二重には作成されません。

IAM のロールを作成した直後は、反映が間に合わずに失敗することがあります。その場合は、10 秒ほど待ってから同じコマンドを再実行してください。`ConflictException` が返った場合は、前の実行で作成済みです。次のコマンドで `INTEGRATION_ID` を取り修正します。

```bash
INTEGRATION_ID=$(aws continuum list-integrations --region "${CV_REGION}" \
  --query "items[?name=='${INTEGRATION_NAME}'].integrationId | [0]" --output text)
[[ -n "${INTEGRATION_ID}" && "${INTEGRATION_ID}" != "None" ]] && echo "INTEGRATION_ID=\"${INTEGRATION_ID}\"" >> ~/deepcuts-results/cv/resource-ids.env || echo "⚠️ INTEGRATION_ID を取り出せませんでした"
```

作成した Integration を確かめます。

```bash
aws continuum get-integration --integration-id "${INTEGRATION_ID}" --region "${CV_REGION}"
```

<!-- 画面写真: S3 コンソールのバケット aws-deepcuts-continuum-... のオブジェクトの一覧。code/ と context/ を枠で囲む -->
<!-- 要確認: CV のコンソールで Integration の一覧を開く画面の名前と順序 -->

> **この手順で確かめること**
> - **やること**: S3 コンソールでバケットを開き、`get-integration` の出力を読みます。
> - **期待する結果**: バケットの `code/` に `app.py`・`partner_report.py` などが、`context/` に `app-context.md` があります。`get-integration` の出力では、種類が `S3` で、`providerDetails.s3` にバケットとロールの ARN があります。外部 ID が出力に含まれるかも観察します。
> - **ここから分かること**: Integration は、コードの保存先と、そこを読むためのロールの組です。

## 発展 3．Environment を作成する

**Environment** は、どのコードを、どの方針でスキャンするかの単位です。

### 3-0. 同じ名前の Environment が無いか確かめる

`CreateEnvironment` には、二重の作成を防ぐトークンがありません。再実行すると Environment が 2 つできるおそれがあるため、先に確かめます。

```bash
aws continuum list-environments --region "${CV_REGION}" \
  --query "items[?name=='${ENVIRONMENT_NAME}'].environmentId" --output text
```

何も表示されなければ 3-1 へ進みます。ID が表示された場合は、前の実行で作成済みです。3-1 を実行せず、次のコマンドで `ENVIRONMENT_ID` を取り修正してから、3-2 へ進みます。

```bash
ENVIRONMENT_ID=$(aws continuum list-environments --region "${CV_REGION}" \
  --query "items[?name=='${ENVIRONMENT_NAME}'].environmentId | [0]" --output text)
[[ -n "${ENVIRONMENT_ID}" && "${ENVIRONMENT_ID}" != "None" ]] && echo "ENVIRONMENT_ID=\"${ENVIRONMENT_ID}\"" >> ~/deepcuts-results/cv/resource-ids.env || echo "⚠️ ENVIRONMENT_ID を取り出せませんでした"
```

### 3-1. Environment を作成する

コードをアップロードした後に作成してください。検索の要約によると、Environment を作成すると、最初のビルドとスキャンが始まることがあります。

```bash
ENVIRONMENT_ID=$(aws continuum create-environment \
  --region "${CV_REGION}" \
  --name "${ENVIRONMENT_NAME}" \
  --configuration "{
    \"codeConfiguration\": {
      \"sourceConfiguration\": {
        \"s3Sources\": [{\"integrationId\": \"${INTEGRATION_ID}\", \"codePrefix\": \"code/\", \"contextPrefix\": \"context/\"}]
      },
      \"environmentConfiguration\": {
        \"scanFrequency\": \"PT0H\",
        \"network\": {},
        \"patchCreationPolicy\": \"ENABLED\"
      }
    }
  }" \
  --query environmentId --output text)
[[ -n "${ENVIRONMENT_ID}" && "${ENVIRONMENT_ID}" != "None" ]] && echo "ENVIRONMENT_ID=\"${ENVIRONMENT_ID}\"" >> ~/deepcuts-results/cv/resource-ids.env || echo "⚠️ ENVIRONMENT_ID を取り出せませんでした。トラブルシューティングを見てください"
echo "${ENVIRONMENT_ID}"
```

| パラメータ | 指定した値 | 意味 |
| --- | --- | --- |
| `s3Sources` | 発展 2 の Integration | CV が読む S3 のソース |
| `codePrefix`・`contextPrefix` | `code/`・`context/` | ソースコードと補足情報の接頭辞 |
| `scanFrequency` | `PT0H` | スキャンの間隔。`PT0H` は手動だけ。**省くと既定の `P1D` になり、毎日スキャンされる。そのたびに推論の料金がかかるおそれがある** |
| `network` | `{}` | エージェントの実行が通信してよいドメインの許可リスト `allowedDomains` を指定しない。このアプリは標準ライブラリだけで、ビルドに外部のパッケージが要らない |
| `patchCreationPolicy` | `ENABLED` | 修正パッチを作成する |

更新の API の説明では、`allowedDomains` の無い `network` は、どのドメインも許可しません。作成のときに同じ意味になるかは、API の説明に書かれていません。<!-- 要確認: 作成時に network に {} を渡したときに保存される値 --> `ConflictException` が返った場合は、3-0 のコマンドで既存の Environment の ID を取り修正してください。

API の説明によると、作成は検証と準備を始め、準備は応答の後も続きます。

### 3-2. Environment の設定を確かめる

```bash
aws continuum get-environment --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
  --query configuration.codeConfiguration
```

出力の `latestScan` には頼りません。最新のスキャンが入るかは、API の説明どうしが食い違っています。スキャンは、3-3 の `list-code-scans` で確かめます。

### 3-3. スキャンが始まっていないか確かめる

```bash
aws continuum list-code-scans --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
  --query 'scans[].{id:scanRunId,status:status,origin:origin,createdAt:createdAt}' --output table
```

何も表示されなければ、発展 4 の 4-1 へ進みます。1 件表示された場合は、CV が Environment の作成に合わせてスキャンを始めています。4-1 を飛ばし、次のコマンドでそのスキャンの ID を `SCAN_RUN_ID` にして、4-2 へ進みます。

```bash
SCAN_RUN_ID=$(aws continuum list-code-scans --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
  --query 'scans[0].scanRunId' --output text)
[[ -n "${SCAN_RUN_ID}" && "${SCAN_RUN_ID}" != "None" ]] && echo "SCAN_RUN_ID=\"${SCAN_RUN_ID}\"" >> ~/deepcuts-results/cv/resource-ids.env || echo "⚠️ SCAN_RUN_ID を取り出せませんでした"
```

<!-- 要確認: CV のコンソールで Environment の設定を開く画面の名前と順序 -->
<!-- 画面写真: CV のコンソールの Environment の設定。スキャンの間隔とパッチの作成を枠で囲む -->

> **この手順で確かめること**
> - **やること**: 3-2 と 3-3 の出力を読みます。
> - **期待する結果**: `scanFrequency` が `PT0H`、`patchCreationPolicy` が `ENABLED` で、`s3Sources` に 2 つの接頭辞があります。`network` に何が保存されたかを記録します。スキャンは 0 件か 1 件です。
> - **ここから分かること**: Environment は、どのコードをどの方針でスキャンするかの単位です。間隔を `PT0H` にしたため、あなたが依頼しない限り、スキャンは始まりません。

## 発展 4．スキャンを実行して完了を待つ

**始めたスキャンを止める API はありません。** 費用の注意を読んでから、4-1 を実行してください。

### 4-1. スキャンを依頼する

```bash
SCAN_RUN_ID=$(aws continuum create-code-scan \
  --region "${CV_REGION}" \
  --environment-id "${ENVIRONMENT_ID}" \
  --client-token "${SCAN_TOKEN}" \
  --query scan.scanRunId --output text)
[[ -n "${SCAN_RUN_ID}" && "${SCAN_RUN_ID}" != "None" ]] && echo "SCAN_RUN_ID=\"${SCAN_RUN_ID}\"" >> ~/deepcuts-results/cv/resource-ids.env || echo "⚠️ SCAN_RUN_ID を取り出せませんでした。トラブルシューティングを見てください"
echo "${SCAN_RUN_ID}"
```

`--client-token` を固定の値にするのは、このコマンドを再実行しても、二重にスキャンが始まらないようにするためです。API の説明によると、トークンを省くと、毎回新しいスキャンが始まります。

### 4-2. 完了を待つ

次のループは、60 秒ごとにスキャンの状態を表示し、`SUCCEEDED` か `FAILED` になったら終わります。上限は 180 回、約 3 時間です。

```bash
DONE=0
for i in $(seq 1 180); do
  STATUS=$(aws continuum get-code-scan --environment-id "${ENVIRONMENT_ID}" \
    --scan-run-id "${SCAN_RUN_ID}" --region "${CV_REGION}" --query scan.status --output text)
  echo "$(date +%H:%M:%S) ${STATUS}"
  if [[ "${STATUS}" == "SUCCEEDED" || "${STATUS}" == "FAILED" ]]; then DONE=1; break; fi
  sleep 60
done
[[ "${DONE}" == "1" ]] || echo "⚠️ 3 時間待っても終わりませんでした。表示された状態を記録し、後でこのループを再実行してください"
```

API の説明によると、スキャンは必ず、選んだソースをビルドしてから、その結果を分析します。状態は `SUBMITTED`・`WAITING_FOR_BUILD`・`BUILDING`・`WAITING_FOR_SCAN`・`SCANNING`・`SUCCEEDED`・`FAILED` です。60 秒ごとに確かめるため、すべての状態が表示されるとは限りません。待つ間にターミナルを閉じてもかまいません。スキャンは AWS の中で進みます。

### 4-3. 所要時間を確かめる

```bash
aws continuum get-code-scan --environment-id "${ENVIRONMENT_ID}" --scan-run-id "${SCAN_RUN_ID}" --region "${CV_REGION}" \
  --query 'scan.{status:status,origin:origin,createdAt:createdAt,completedAt:completedAt,failureStage:failureStage,failureMessage:failureMessage}'
```

> **この手順で確かめること**
> - **やること**: 4-3 の出力の `createdAt` と `completedAt` の差を記録します。
> - **期待する結果**: 状態が最後に `SUCCEEDED` になります。`FAILED` の場合は、`failureStage` と `failureMessage` を記録し、トラブルシューティングを確認してください。
> - **ここから分かること**: CV のスキャンは、ビルドから始まります。ビルドできないコードは、スキャンできません。

## 発展 5．Finding の振り分けを確かめる

CV では、スキャンが見つけた脆弱性の候補を **Finding** と呼びます。CV は、Finding を検証して本物かどうかを判定し、本物と判定したものだけを **Issue** にします。Issue は、悪用できるかの証拠作り・優先度付け・修正が進む単位です。GitHub の Issue とは別のものです。Finding が `CONFIRMED` か `DISCARDED` になるまでの処理を、この README では振り分けと呼びます。

### 5-1. 振り分けの完了を待つ

API の説明によると、Finding の振り分けは、スキャンが成功した後も非同期に続きます。次のループは、このスキャンの Finding の総数と、振り分け中の数を表示し、振り分け中が 0 になったら終わります。`list-code-findings` にはスキャンで絞り込む引数が無いため、`--query` で `scanRunId` を確認して絞り込みます。

```bash
DONE=0
for i in $(seq 1 180); do
  TOTAL=$(aws continuum list-code-findings --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
    --query "length(items[?scanRunId=='${SCAN_RUN_ID}'])" --output text)
  LEFT=$(aws continuum list-code-findings --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
    --query "length(items[?scanRunId=='${SCAN_RUN_ID}' && (status=='SUBMITTED' || status=='VALIDATING')])" --output text)
  echo "$(date +%H:%M:%S) Finding: ${TOTAL} 件、振り分け中: ${LEFT} 件"
  if [[ "${LEFT}" == "0" ]]; then DONE=1; break; fi
  sleep 60
done
[[ "${DONE}" == "1" ]] || echo "⚠️ 3 時間待っても振り分けが終わりませんでした。表示された件数を記録し、後でこのループを再実行してください"
```

スキャンが `SUCCEEDED` で Finding が 0 件なら、それがこのスキャンの結果です。採点表に「Finding なし」と記録し、発展 6 と 7 を飛ばして発展 8 へ進みます。

### 5-2. 一覧を表示して保存する

```bash
aws continuum list-code-findings --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
  --query "items[?scanRunId=='${SCAN_RUN_ID}'].{title:title,severity:severity,file:filePath,status:status,reason:discardReason,issue:createdIssueId}" \
  --output table
aws continuum list-code-findings --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
  --output json > "${CV_DIR}/findings.json"
```

### 5-3. 1 件の詳細を確認する

5-2 の一覧から、Issue にならなかった Finding があれば 1 件、本物と判定された Finding を 1 件選び、それぞれの ID を `FINDING_ID` に代入して実行します。Finding の ID は、`findings.json` の `findingId` で確かめられます。

```bash
FINDING_ID=<5-2 で選んだ Finding の ID>
aws continuum get-code-finding --environment-id "${ENVIRONMENT_ID}" --finding-id "${FINDING_ID}" --region "${CV_REGION}" \
  --query '{title:title,cwe:cweIds,file:filePath,line:lineNumber,verdict:validation.verdict,blocking:validation.blockingReason,confidence:validation.confidence,rationale:validation.rationale}'
```

| 項目 | 意味 |
| --- | --- |
| `verdict` | 真偽の判定。`TRUE_POSITIVE`・`FALSE_POSITIVE`・`BENIGN_TRUE_POSITIVE`・`NEEDS_REVIEW` |
| `blocking` | 悪用を止めている理由。`UNREACHABLE`・`PROTECTED`・`MISCLASSIFIED`・`EXCLUDED`・`NOT_FEASIBLE`・`RISK_MITIGATED`・`NONE` |
| `confidence` | 検証の確信度。0.0〜1.0 の参考の値 |

Issue にならなかった Finding には、一覧の `reason` に理由が入ります。理由は、誤検知・重複・補う統制の存在・範囲外・証拠不足など 10 種類です。

> **この手順で確かめること**
> - **やること**: 5-2 の一覧と、5-3 の 2 件の詳細を読みます。費用の上限の目安を、「推論の料金 ≒ このスキャンの Finding の数 × 2 CIU × $10」で計算し修正します。
> - **期待する結果**: 予想では、`/records` と `partner_report.py` の Finding が `CONFIRMED` になり、`issue` に Issue の ID が付きます。`/records/top` の Finding は、報告されないか、`DISCARDED` になり、理由が付きます。`partner_report.py` の Finding が `DISCARDED` になった場合は、理由と止めている理由を記録します。
> - **ここから分かること**: CV は、見つけたものをそのまま報告せず、本物かどうかを判定してから Issue にします。Issue にしなかったものにも、理由が残ります。

## 発展 6．Issue の検証の証拠を読む

Issue には、作業の記録が **成果物** として付きます。成果物の種類のうち、**検証の証拠** `VALIDATION_EVIDENCE` には、悪用できるかの判定と、その証明が入ります。証明は 3 種類あり、1 つの検証の証拠に入るのは多くても 1 つです。どれも入らないこともあります。

| 証明 | API の項目 | 中身 |
| --- | --- | --- |
| HTTP の証明 | `exploitArtifact` | 実際に送った HTTP のリクエストと、観測した影響 `effect` |
| 実行の証明 | `executedProof` | 実際に実行したコードと、観測した影響 `observedEffect` |
| ソースの分析 | `sourceAnalysis` | ソースを読んだだけの分析と、推論した影響 `inferredEffect` |

### 6-1. Issue の処理の完了を待つ

Issue の作成は、振り分けの後に非同期で進みます。次のループは、本物と判定された Finding の数と、そのうち Issue が作成された数が等しく、処理中の Issue が 0 になったら終わります。

```bash
DONE=0
for i in $(seq 1 180); do
  CONFIRMED=$(aws continuum list-code-findings --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
    --query "length(items[?scanRunId=='${SCAN_RUN_ID}' && status=='CONFIRMED'])" --output text)
  LINKED=$(aws continuum list-code-findings --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
    --query "length(items[?scanRunId=='${SCAN_RUN_ID}' && status=='CONFIRMED' && createdIssueId])" --output text)
  OPEN=$(aws continuum list-code-issues --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
    --query "length(items[?status=='CREATED' || status=='IN_PROGRESS'])" --output text)
  echo "$(date +%H:%M:%S) 本物と判定: ${CONFIRMED} 件、Issue 作成済み: ${LINKED} 件、処理中の Issue: ${OPEN} 件"
  if [[ "${LINKED}" == "${CONFIRMED}" && "${OPEN}" == "0" ]]; then DONE=1; break; fi
  sleep 60
done
[[ "${DONE}" == "1" ]] || echo "⚠️ 3 時間待っても Issue の処理が終わりませんでした。表示された件数を記録し、トラブルシューティングを見てください"
```

処理中の Issue が 0 なのに、Issue 作成済みが 0 のまま 15 分以上変わらない場合は、Finding に `createdIssueId` が付かない可能性があります。Ctrl+C でループを止め、トラブルシューティングの「`createdIssueId` が付かない」の行を確認してください。

Issue の一覧を表示します。

```bash
aws continuum list-code-issues --environment-id "${ENVIRONMENT_ID}" --region "${CV_REGION}" \
  --query 'items[].{id:issueId,name:name,severity:severity,confidence:confidence,status:status,phase:phase}' --output table
```

### 6-2. Issue を 1 つ選んで読む

最初は、`/records` の Issue を選びます。

```bash
ISSUE_ID=<6-1 で表示された Issue の ID>
aws continuum get-code-issue --environment-id "${ENVIRONMENT_ID}" --issue-id "${ISSUE_ID}" --region "${CV_REGION}" \
  --query '{name:name,synopsis:synopsis,severity:severity,confidence:confidence,reasoning:severityReasoning,status:status,phase:phase,findings:findingIds,evidence:evidenceAvailability,delivery:patchDelivery}'
aws continuum get-code-issue --environment-id "${ENVIRONMENT_ID}" --issue-id "${ISSUE_ID}" --region "${CV_REGION}" \
  --output json > "${CV_DIR}/issue-${ISSUE_ID}.json"
aws continuum list-code-issue-artifacts --environment-id "${ENVIRONMENT_ID}" --issue-id "${ISSUE_ID}" --region "${CV_REGION}" \
  --query 'items[].{id:artifactId,type:artifactType,agent:producer.agent,bytes:contentSizeBytes,createdAt:createdAt}' --output table
```

`severityReasoning` の先頭の文は、深刻度をどこから決めたかを示します。Issue の深刻度は `LOW`・`MEDIUM`・`HIGH`・`CRITICAL`、確信度は 0〜100 です。

### 6-3. 検証の証拠を読む

```bash
ARTIFACT_ID=$(aws continuum list-code-issue-artifacts --environment-id "${ENVIRONMENT_ID}" \
  --issue-id "${ISSUE_ID}" --artifact-type VALIDATION_EVIDENCE --region "${CV_REGION}" \
  --query 'items[0].artifactId' --output text)
[[ -z "${ARTIFACT_ID}" || "${ARTIFACT_ID}" == "None" ]] && echo "⚠️ この Issue には VALIDATION_EVIDENCE がありません。採点表に「証拠なし」と記録します"
aws continuum get-code-issue-artifact --environment-id "${ENVIRONMENT_ID}" --issue-id "${ISSUE_ID}" \
  --artifact-id "${ARTIFACT_ID}" --region "${CV_REGION}" \
  --query 'body.validationEvidence.{exploitable:exploitable,status:terminalStatus,http:exploitArtifact,executed:executedProof,source:sourceAnalysis,perFinding:perFindingResults[].{finding:findingId,exploitable:exploitable,http:exploitArtifact}}'
aws continuum get-code-issue-artifact --environment-id "${ENVIRONMENT_ID}" --issue-id "${ISSUE_ID}" \
  --artifact-id "${ARTIFACT_ID}" --region "${CV_REGION}" --output json > "${CV_DIR}/artifact-${ARTIFACT_ID}.json"
```

`exploitable` は、悪用できるかの判定で、`EXPLOITABLE`・`NOT_EXPLOITABLE`・`UNCERTAIN` のどれかです。複数の Finding をまとめた検証の証拠では、HTTP の証明は `perFinding` の中に入ります。`http`・`executed`・`source` の 3 つがすべて `null` で、`perFinding` にも証明が無い場合は、`exploitable` と `status` の値を記録します。

**検証の証拠には、攻撃の手順が入ることがあります。共有したり、Git に登録したりしないでください。**

2 つ目の Issue、つまり `partner_report.py` の Issue でも、6-2 と 6-3 を繰り返します。

<!-- 要確認: CV のコンソールで Issue の詳細と証拠を開く画面の名前と順序 -->
<!-- 画面写真: CV のコンソールの Issue の詳細と検証の証拠。悪用できるかの判定と、証明の種類を枠で囲む -->

> **この手順で確かめること**
> - **やること**: 2 つの Issue で、6-2 と 6-3 を行います。
> - **期待する結果**: Issue の状態は `COMPLETED` か `FAILED` です。`FAILED` の場合は `statusReason` を記録します。予想では、成果物に `VALIDATION_EVIDENCE` と `PATCH` があります。検証の証拠では、`exploitable` と、3 つの証明のうちどれが入っているかを観察します。**2 つの Issue で証明の種類が違うか** を記録します。`/records` には HTTP で届き、`partner_report.py` には HTTP からは届かないためです。
> - **ここから分かること**: 悪用できるという判定の根拠が、実際に送ったリクエストか、実行したコードか、ソースを読んだだけの推論かを、API の項目の名前で見分けられます。

## 発展 7．修正パッチを確かめて適用する

CV は、修正パッチを成果物 `PATCH` として残し、届け先に届けます。この発展の届け先は、発展 1 のバケットです。CV には、パッチを適用する API はありません。照合・テスト・適用の判断は、あなたが行います。

### 7-0. パッチの配送を待つ

次のコマンドの値が `PENDING` の間は待ちます。`None` が表示された場合は、届け先のあるパッチがありません。7-1 で成果物を確かめます。

```bash
aws continuum get-code-issue --environment-id "${ENVIRONMENT_ID}" --issue-id "${ISSUE_ID}" --region "${CV_REGION}" \
  --query patchDelivery.status --output text
```

### 7-1. パッチを取り出して照合する

パッチの本文は、`python3` で UTF-8 のバイト列のまま書き出します。`--output text` は末尾に改行を足すため、SHA-256 の値が変わるからです。SHA-256 は、ファイルの中身から計算する 64 桁の値で、1 文字でも違えば値が変わります。

```bash
PATCH_ARTIFACT_ID=$(aws continuum list-code-issue-artifacts --environment-id "${ENVIRONMENT_ID}" \
  --issue-id "${ISSUE_ID}" --artifact-type PATCH --region "${CV_REGION}" \
  --query 'items[0].artifactId' --output text)
[[ -z "${PATCH_ARTIFACT_ID}" || "${PATCH_ARTIFACT_ID}" == "None" ]] && echo "⚠️ PATCH がありません。下の「PATCH が無いとき」に進みます"
aws continuum get-code-issue-artifact --environment-id "${ENVIRONMENT_ID}" --issue-id "${ISSUE_ID}" \
  --artifact-id "${PATCH_ARTIFACT_ID}" --region "${CV_REGION}" --output json > "${CV_DIR}/patch-artifact.json"
python3 -c 'import json,sys; b=json.load(open(sys.argv[1]))["body"]["patch"]; print("format:", b.get("format"), "sizeBytes:", b["sizeBytes"], "sha256:", b["patchSha256"])' "${CV_DIR}/patch-artifact.json"
python3 -c 'import json,sys; sys.stdout.buffer.write(json.load(open(sys.argv[1]))["body"]["patch"]["patch"].encode("utf-8"))' \
  "${CV_DIR}/patch-artifact.json" > "${CV_DIR}/fix.diff"
python3 -c 'import hashlib,os,sys; d=open(sys.argv[1],"rb").read(); print("sha256:", hashlib.sha256(d).hexdigest(), "bytes:", len(d))' "${CV_DIR}/fix.diff"
cat "${CV_DIR}/fix.diff"
```

2 つの `sha256` の値が一致し、`bytes` が `sizeBytes` と同じことを確かめます。API の説明によると、パッチは `git apply` で当てられる unified diff です。

**PATCH が無いとき**: `--artifact-type REMEDIATION_PROPOSAL` の成果物があれば、`body.remediationProposal.patch` を同じ形で書き出し、`body.remediationProposal.patchSha256` と照合します。修正案も無ければ、Issue の `statusReason` を記録し、採点表に「パッチなし」と書きます。

### 7-2. バケットに届いたパッチを確かめる

```bash
aws continuum get-code-issue --environment-id "${ENVIRONMENT_ID}" --issue-id "${ISSUE_ID}" --region "${CV_REGION}" --query patchDelivery
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["body"]["patch"].get("delivery"), indent=2))' "${CV_DIR}/patch-artifact.json"
aws s3api list-objects-v2 --bucket "${BUCKET_NAME}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${CV_REGION}" \
  --query 'Contents[].[Key,Size,LastModified]' --output table
```

届け先のキーが分かったら、`aws s3 cp "s3://${BUCKET_NAME}/<キー>" "${CV_DIR}/fix-from-s3.diff" --region "${CV_REGION}"` で取り出し、7-1 と同じ `python3` のコマンドで SHA-256 を比べます。届いたオブジェクトが diff そのものかは確かめられていません。<!-- 要確認: 届いたオブジェクトのキーと形 --> 配送が `FAILED` か `SKIPPED` の場合は、`failureReasons` を記録し、7-1 のパッチで続けます。

<!-- 画面写真: S3 コンソールのバケットの、パッチが届いた接頭辞。届いたオブジェクトを枠で囲む -->

### 7-3. コピーに当ててテストする

```bash
rm -rf "${CV_DIR}/app-patched" && cp -R ~/aws-continuum/hands-on/app "${CV_DIR}/app-patched"
cd "${CV_DIR}/app-patched"
git apply --check -v "${CV_DIR}/fix.diff" && git apply "${CV_DIR}/fix.diff"
python3 -m unittest -v
cd ~/aws-continuum/hands-on/optional-cv
```

`git apply --check` がパスの違いで失敗する場合は、`head -5 "${CV_DIR}/fix.diff"` でパスの形を確かめ、パスが `code/app.py` のように接頭辞付きなら `-p2` を付けて試します。<!-- 要確認: パッチのパスの形 --> 2 つの Issue のパッチを両方当てる場合は、新しいコピーに 2 つのパッチを順に当てます。

### 7-4. 同じ攻撃をパッチの前と後で試す

**攻撃は、あなたの PC の中で動かした、あなた自身のアプリにだけ試してください。**

次のコマンドは、括弧の中でフォルダーを移ってからアプリを起動し、最後の `&` でアプリを裏で動かします。`exec` を付けると、括弧の中の処理がそのままアプリになるため、直後の `$!` がアプリのプロセスの番号になります。この番号を `app.pid` に保存し、止めるときは、この番号のプロセスだけを `kill` で止めます。

```bash
# 前: パッチを当てる前のアプリ
(cd ~/aws-continuum/hands-on/app && exec python3 app.py > "${CV_DIR}/app.log" 2>&1) &
echo $! > "${CV_DIR}/app.pid"
sleep 1
curl -s "http://127.0.0.1:8080/health"
curl -s --get "http://127.0.0.1:8080/records" --data-urlencode "q=x' UNION SELECT name, email, 0, 0 FROM customers -- "
kill "$(cat "${CV_DIR}/app.pid")"

# 後: パッチを当てたアプリ
(cd "${CV_DIR}/app-patched" && exec python3 app.py > "${CV_DIR}/app.log" 2>&1) &
echo $! > "${CV_DIR}/app.pid"
sleep 1
curl -s "http://127.0.0.1:8080/health"
curl -s --get "http://127.0.0.1:8080/records" --data-urlencode "q=x' UNION SELECT name, email, 0, 0 FROM customers -- "
kill "$(cat "${CV_DIR}/app.pid")"
```

`partner_report.py` には HTTP からは届かないため、コマンドで確かめます。

```bash
printf 'title,jacket\nBlue Harbor Lights,../data/customers.csv\n' > "${CV_DIR}/evil-order.csv"
(cd ~/aws-continuum/hands-on/app && python3 partner_report.py "${CV_DIR}/evil-order.csv")
(cd "${CV_DIR}/app-patched" && python3 partner_report.py "${CV_DIR}/evil-order.csv")
```

検証の証拠に HTTP の証明があれば、その `payload` と、上の攻撃のリクエストを見比べます。実行の証明があれば、その `code` と上のコマンドを見比べます。

> **この手順で確かめること**
> - **やること**: 7-1〜7-4 を行います。
> - **期待する結果**: SHA-256 が一致し、`git apply --check` が成功し、テスト 5 件がすべて `ok` です。`/health` が応答したうえで、パッチの前は攻撃で顧客の情報が返り、パッチの後は返りません。
> - **ここから分かること**: CV はパッチを届けるだけで、マージや適用の API はありません。照合・テスト・適用の判断は、あなたが行います。

## 発展 8．採点表に CV の列を足す

主な手順の採点表 1 に「CV」の列を足し、各対象について、Finding の状態・Issue の有無・悪用できるかの判定・証明の種類・パッチで攻撃が止まったかを書きます。

| 対象 | 手順 6: Security Agent の深刻度・確信度・検証の状態 | 発展 5〜7: CV の Finding の状態・判定・証明の種類・パッチの結果 |
| --- | --- | --- |
| `GET /records` | | |
| `partner_report.py` | | |
| `GET /records/top` | | |
| 想定外の指摘 | | |

この比較も、1 つの小さなアプリでの 1 回の結果です。AWS が発表したベンチマークの数値を確かめるものではありません。

> **この手順で確かめること**
> - **やること**: 上の表を埋めます。
> - **期待する結果**: 各行に記入があります。
> - **ここから分かること**: 同じ AWS Continuum の中でも、Security Agent と CV では、悪用できるかの確かめ方と、残る記録の形が違います。

## 発展 9．後片付け

```bash
cd ~/aws-continuum/hands-on/optional-cv
bash ./cleanup-cv.sh

# 以下の文言が表示されればクリーンアップ成功です
# ✅ すべてのリソースの削除が完了しました！
```

`cleanup-cv.sh` は、Environment・Integration・S3 バケット・IAM ロールの順に削除します。API の説明によると、Environment を削除すると、関連するスキャン・Finding・Issue・成果物も削除されます。Issue の処理の途中だと、Environment を削除できないことがあります。`cleanup-cv.sh` は 60 秒おきに 5 回まで試し、それでも削除できなければ `❌` を表示します。その場合は、Issue の処理が終わるのを待ってから再実行してください。

消し忘れが無いことを、次のコマンドで確かめます。

```bash
aws continuum list-environments --region us-east-1 --query 'items[].name'
aws continuum list-integrations --region us-east-1 --query 'items[].name'
aws iam get-role --role-name aws-deepcuts-continuum-s3-role
aws iam list-roles --query "Roles[?contains(RoleName,'ontinuum')].RoleName" --output text
```

4 つ目のコマンドは、CV が作成したロールが無いかを確かめます。CV がサービスリンクロールを作成するかは、確かめられていません。後片付けの後に何か表示された場合は、CV が作成したロールの可能性があります。IAM ロールは無料のため、消すかは任意です。<!-- 要確認: サービスリンクロールの有無 -->

記録フォルダーの JSON とパッチは残しています。採点が済んだら、`rm -rf ~/deepcuts-results/cv` で消してください。主な手順の記録フォルダー `~/deepcuts-results` を消す前に、`cleanup-cv.sh` を実行してください。AWS Budgets の予算を作成した場合、消すかは任意です。

翌日以降に、Billing and Cost Management のコンソールの請求書の画面で、CV の請求の名前と額を確かめてください。<!-- 要確認: 請求でのサービス名と使用タイプ -->

> **この手順で確かめること**
> - **やること**: 上の確認のコマンドを実行します。
> - **期待する結果**: Environment と Integration の一覧に `aws-deepcuts-record-shop` と `aws-deepcuts-s3` がありません。`get-role` は `NoSuchEntity` のエラーになります。
> - **ここから分かること**: この発展で作成したものは、すべて消えました。

# 費用の見積もり

単価は、料金ページの検索の要約によるものです。<!-- 要確認: 料金ページの単価と、翌日の請求額で置き換える -->

| 要素 | 計算 | 目安 |
| --- | --- | --- |
| 行数の料金。行数に比例する場合 | アップロードするコードは全体で約 250 行。多く見積もって 400 行。400 ÷ 100 万 × $200 | 月 $0.08 未満 |
| 行数の料金。最低料金か 100 万行単位の切り上げがある場合 | 料金ページの単価で 1 単位分。日割りの有無は分からない | 1 か月で最大 $200 |
| 推論の料金 | 料金ページの計算例の「1 脆弱性あたり 1〜2 CIU」を仮定。意図的に入れた脆弱性 2 つで 2〜4 CIU。対策済みのコードの Finding の検証にも CIU がかかる場合は、さらに 1〜2 CIU | 約 $20〜$60 |
| S3 | 1 MB 未満、リクエストは数百件。us-east-1 の単価は、保存 1 GB・1 か月あたり $0.023、PUT など 1,000 件あたり $0.005、GET など 10,000 件あたり $0.004。AWS Price List AmazonS3 us-east-1、2026 年 11 月 1 日取得 | $0.01 未満 |
| AWS Budgets | 通知だけの予算。AWS Price List AWSBudgets、2026 年 11 月 1 日取得 | $0 |
| 合計 | 行数の料金が行数に比例する場合 | **約 $20〜$60**（約 3,200〜9,600 円） |
| 仮定に基づく最大 | 行数の料金が 1 単位分かかり、Finding が 3 件で各 2 CIU の場合 | **約 $260**（約 41,600 円） |

- 上限の目安の式「推論の料金 ≒ Finding の数 × 2 CIU × $10」は、料金ページの計算例の「1 脆弱性あたり 1〜2 CIU」の大きい方を、Finding 1 件に当てはめたものです。CIU の正式な定義は見つかっていないため、スキャンそのものにも CIU がかかる場合などは、この式を超えることがあります。
- 想定外の Finding が 1 件増えるごとに、同じ仮定で、最大で $20 増える見込みです。
- スキャンを繰り返すと、そのたびに推論の料金がかかるおそれがあります。`scanFrequency` を省くと、毎日スキャンされます。

# トラブルシューティング

| 症状 | 確かめるコマンド | 対処 |
| --- | --- | --- |
| `Invalid choice: 'continuum'` と表示される | `aws --version` | AWS CLI v2 を最新版に更新する |
| `setup-cv.sh` が `信頼ポリシーのプリンシパルが未設定です` で止まる | なし | この発展は、まだ実行できません。何も作成されていません |
| `setup-cv.sh` が `resource-ids.env が既にあります` で止まる | `cat ~/deepcuts-results/cv/resource-ids.env` | `bash ./cleanup-cv.sh` を実行してから、やり直してください |
| `setup-cv.sh` が `既に同じ名前の Integration または Environment があります` で止まる | `aws continuum list-integrations --region us-east-1`、`aws continuum list-environments --region us-east-1` | 前回の残りです。`cleanup-cv.sh` で消してから、やり直してください |
| `create-integration` が、ロールを引き受けられないという趣旨のエラーで失敗する | `aws iam get-role --role-name aws-deepcuts-continuum-s3-role --query Role.AssumeRolePolicyDocument` | 10 秒ほど待って再実行する。続く場合は、信頼されたエンティティを確かめ、リポジトリの Issue で知らせる |
| `create-integration` か `create-environment` が `ConflictException` | 発展 2 の `list-integrations`、発展 3 の 3-0 のコマンド | 前の実行で作成済みです。ID を取り修正して次へ進む |
| スキャンが `FAILED` | 発展 4 の 4-3 のコマンド | `failureStage` と `failureMessage` を記録する。形式が理由なら `code/` の置き方を見直す。依存の取得が理由なら、`update-environment` で `allowedDomains` に必要なドメインを足し、新しい `--client-token` でスキャンをやり直してください。この場合は費用が増えます |
| `create-code-scan` が `ServiceQuotaExceededException` | `aws continuum list-code-scans --environment-id "${ENVIRONMENT_ID}" --region us-east-1` | 進行中のスキャンが終わるのを待つ |
| 待つループが上限で終わる | ループの中のコマンドを 1 回だけ実行する | 状態を記録し、後で再実行する |
| `createdIssueId` が付かない | `list-code-issues` の後に、各 Issue に `get-code-issue --query findingIds` | Issue の `findingIds` で Finding との対応を調べて、発展 6 に進む |
| `VALIDATION_EVIDENCE` が無い。または 3 つの証明がすべて `null` | `get-code-issue --query evidenceAvailability`、6-3 の `--query` | `exploitable` と `terminalStatus` を記録し、採点表に「証拠なし」か「証明なし」と書く |
| `PATCH` が無い | `get-code-issue --query '{status:status,reason:statusReason,delivery:patchDelivery}'` | 7-1 の「PATCH が無いとき」へ |
| パッチの配送が `FAILED` か `SKIPPED` | `get-code-issue --query patchDelivery` | `failureReasons` を記録し、7-1 のパッチで続ける |
| `git apply --check` が失敗する | `head -5 "${CV_DIR}/fix.diff"` | パスの接頭辞に合わせて `-p2` などを試す |
| 7-4 の `curl` が応答しない | `cat "${CV_DIR}/app.log"`、`ps -p "$(cat "${CV_DIR}/app.pid")"` | 前に起動したアプリを `kill "$(cat "${CV_DIR}/app.pid")"` で止めてから、起動し直してください |
| `ValidationException` が返る | `echo "${ARTIFACT_ID}"` | `None` が入っています。成果物が無いため、上の「無い」場合の行へ |
| `cleanup-cv.sh` が Environment で `❌` | `aws continuum list-environments --region us-east-1` | Issue の処理が終わるのを待ってから、`cleanup-cv.sh` を再実行する |

# 参考リンク

<!-- 要確認: docs.aws.amazon.com と aws.amazon.com の URL は、作成時の環境から開けなかった。著者が開けることを確かめる -->

- [Continuum の API リファレンス（AWS Continuum API Reference）](https://docs.aws.amazon.com/continuum/latest/APIReference/Welcome.html)
- [AWS Continuum for Code Vulnerabilities の一般提供の発表（AWS Continuum for Code Vulnerabilities is now generally available）](https://aws.amazon.com/blogs/aws/aws-continuum-for-code-vulnerabilities-is-now-generally-available/)
- [AWS Continuum の料金（AWS Continuum Pricing）](https://aws.amazon.com/continuum/pricing/)
- [AWS CLI の continuum コマンド（AWS CLI Command Reference: continuum）](https://docs.aws.amazon.com/cli/latest/reference/continuum/)
- [AWS Budgets のユーザーガイド（Managing your costs with AWS Budgets）](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)
