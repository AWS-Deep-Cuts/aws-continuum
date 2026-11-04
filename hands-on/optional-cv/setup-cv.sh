#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - AWS Continuum 任意の発展: CV（Continuum for Code Vulnerabilities）の事前準備
# CV そのものの操作（Integration・Environment・スキャン）は、発展の README の手順で 1 コマンドずつ実行します。
# このスクリプトは、その前提になる次の 2 つだけを作成します。
#   1. S3 バケット                … コード（code/）と補足情報（context/）を置き、CV が作るパッチを受け取る
#   2. Integration のロール        … CV が外部 ID を示して引き受け、バケットを読み、パッチを書き込む
# CV のエンドポイントは、2026 年 11 月 1 日の時点でバージニア北部とオレゴンにしかないため、us-east-1 で作ります。
# macOS の bash 3.2 でも動くように、連想配列・mapfile・sed -i・stat・jq を使っていません。

# ─── 著者が公開の前に書き込む値 ─────────────────────────────────
# 要確認: Integration のロールの信頼ポリシーの Principal の JSON の全体。
#   どの一次情報にも書かれていないため、著者がユーザーガイドかコンソールの Integration の作成画面で確かめてから書き込む。
#   形の例 1（サービスプリンシパル）: {"Service": "<サービス名>"}
#   形の例 2（別のアカウントのプリンシパル）: {"AWS": "arn:aws:iam::<アカウント ID>:root"}
#   名前を推測で書かない。空のままなら、このスクリプトは何も作らずに止まる。
CONTINUUM_TRUST_PRINCIPAL_JSON=''

readonly CV_REGION="us-east-1"
export AWS_REGION="${CV_REGION}" AWS_DEFAULT_REGION="${CV_REGION}"
readonly PROJECT_NAME="aws-deepcuts"
readonly ROLE_NAME="${PROJECT_NAME}-continuum-s3-role"
readonly POLICY_NAME="${PROJECT_NAME}-continuum-s3-access"
readonly INTEGRATION_NAME="${PROJECT_NAME}-s3"
readonly ENVIRONMENT_NAME="${PROJECT_NAME}-record-shop"
readonly SCAN_TOKEN="${PROJECT_NAME}-scan-1"
# 要確認: CV がパッチを書き込む接頭辞（検索の要約による）
readonly PATCH_PREFIX="continuum-patches/"
readonly CV_DIR="${DEEPCUTS_CV_DIR:-${HOME}/deepcuts-results/cv}"
readonly RESOURCE_FILE="${CV_DIR}/resource-ids.env"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - AWS Continuum 発展 CV の事前準備"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/5] 前提の確認 ─────────────────────────────────────────
echo "[1/5] 前提を確認..."
if [[ -z "${CONTINUUM_TRUST_PRINCIPAL_JSON}" ]]; then
  echo "❌ Error: 信頼ポリシーのプリンシパルが未設定です。" >&2
  echo "   この発展は、著者が信頼ポリシーのプリンシパルを確かめるまで実行できません。何も作らずに止めます。" >&2
  exit 1
fi
if ! python3 -I -c 'import json,sys; v=json.loads(sys.argv[1]); sys.exit(0 if isinstance(v, dict) and v else 1)' "${CONTINUUM_TRUST_PRINCIPAL_JSON}"; then
  echo "❌ Error: CONTINUUM_TRUST_PRINCIPAL_JSON が JSON のオブジェクトとして読めません。" >&2
  exit 1
fi
if [[ -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が既にあります。前回の環境が残っています。" >&2
  echo "   先に bash ./cleanup-cv.sh を実行してください。" >&2
  exit 1
fi
for cmd in aws git python3 curl; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "❌ Error: ${cmd} コマンドが見つかりません。" >&2; exit 1; }
done
if ! aws continuum list-environments --region "${CV_REGION}" --max-results 1 >/dev/null 2>&1; then
  echo "❌ Error: aws continuum list-environments が失敗しました。" >&2
  echo "   AWS CLI が古いか（2.38.5 以降が必要）、このアカウントで CV を使えない可能性があります。" >&2
  echo "   現在のバージョン: $(aws --version 2>&1)" >&2
  exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "${CV_REGION}" 2>/dev/null) || {
  echo "❌ Error: AWS の認証情報を取得できません。" >&2
  exit 1
}
# 同じ名前の Integration や Environment が残っていると、手順で二重に作るおそれがあるため止める
LEFT_INT=$(aws continuum list-integrations --region "${CV_REGION}" \
  --query "items[?name=='${INTEGRATION_NAME}'].integrationId" --output text)
LEFT_ENV=$(aws continuum list-environments --region "${CV_REGION}" \
  --query "items[?name=='${ENVIRONMENT_NAME}'].environmentId" --output text)
if [[ -n "${LEFT_INT}" && "${LEFT_INT}" != "None" ]] || [[ -n "${LEFT_ENV}" && "${LEFT_ENV}" != "None" ]]; then
  echo "❌ Error: 既に同じ名前の Integration（${INTEGRATION_NAME}）または Environment（${ENVIRONMENT_NAME}）があります。" >&2
  echo "   前回の残りです。cleanup-cv.sh で消すか、CV のコンソールで確かめてから、もう一度実行してください。" >&2
  exit 1
fi
echo "  アカウント: ${ACCOUNT_ID} / リージョン: ${CV_REGION}"

# 作成したリソースは、作成した直後に resource-ids.env へ書き足す。
# 途中で失敗しても、cleanup-cv.sh がこのファイルを読んで、作成済みのリソースを削除できるようにするため。
mkdir -p "${CV_DIR}"
chmod 700 "${CV_DIR}"
EXTERNAL_ID="deepcuts-$(python3 -I -c 'import secrets; print(secrets.token_hex(8))')"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
cat > "${RESOURCE_FILE}" <<EOF
# AWS Deep Cuts AWS Continuum 発展 CV - リソース情報（setup-cv.sh が作成。発展の README の手順で行を追記します）
CV_REGION="${CV_REGION}"
ACCOUNT_ID="${ACCOUNT_ID}"
ROLE_NAME="${ROLE_NAME}"
ROLE_ARN="${ROLE_ARN}"
POLICY_NAME="${POLICY_NAME}"
EXTERNAL_ID="${EXTERNAL_ID}"
INTEGRATION_NAME="${INTEGRATION_NAME}"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME}"
SCAN_TOKEN="${SCAN_TOKEN}"
CV_DIR="${CV_DIR}"
EOF
chmod 600 "${RESOURCE_FILE}"
echo "  リソース情報の保存先: ${RESOURCE_FILE}"
echo ""

# ─── [2/5] S3 バケット ─────────────────────────────────────────
echo "[2/5] コードを置く S3 バケットを作成..."
BUCKET_NAME="${PROJECT_NAME}-continuum-${ACCOUNT_ID}-$(date +%Y%m%d-%H%M%S)"
# us-east-1 では --create-bucket-configuration を付けない
aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${CV_REGION}" >/dev/null
echo "BUCKET_NAME=\"${BUCKET_NAME}\"" >> "${RESOURCE_FILE}"
aws s3api head-bucket --bucket "${BUCKET_NAME}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${CV_REGION}"
aws s3api put-public-access-block --bucket "${BUCKET_NAME}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${CV_REGION}" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  作成: s3://${BUCKET_NAME}（パブリックアクセスをブロック。バージョニングは付けない）"
echo ""

# ─── [3/5] Integration のロール ─────────────────────────────────
echo "[3/5] Integration のロールを作成..."
# 信頼ポリシーは python3 で組み立てる。サービスプリンシパルの形なら、混乱した代理の対策として aws:SourceAccount の条件も付ける
TRUST_POLICY=$(python3 -I -c '
import json, sys
principal = json.loads(sys.argv[1])
condition = {"StringEquals": {"sts:ExternalId": sys.argv[2]}}
if "Service" in principal:
    condition["StringEquals"]["aws:SourceAccount"] = sys.argv[3]
print(json.dumps({"Version": "2012-10-17", "Statement": [{
    "Effect": "Allow", "Principal": principal, "Action": "sts:AssumeRole", "Condition": condition}]}))
' "${CONTINUUM_TRUST_PRINCIPAL_JSON}" "${EXTERNAL_ID}" "${ACCOUNT_ID}")
ACCESS_POLICY=$(python3 -I -c '
import json, sys
b, patch = sys.argv[1], sys.argv[2]
print(json.dumps({"Version": "2012-10-17", "Statement": [
    {"Sid": "ReadCodeAndContext", "Effect": "Allow", "Action": ["s3:GetObject", "s3:GetObjectVersion"],
     "Resource": [f"arn:aws:s3:::{b}/code/*", f"arn:aws:s3:::{b}/context/*"]},
    {"Sid": "ListBucket", "Effect": "Allow", "Action": "s3:ListBucket", "Resource": f"arn:aws:s3:::{b}"},
    {"Sid": "WritePatches", "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject"],
     "Resource": f"arn:aws:s3:::{b}/{patch}*"}]}))
' "${BUCKET_NAME}" "${PATCH_PREFIX}")
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "  既に存在するため、信頼ポリシーを更新して使います: ${ROLE_NAME}"
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "${TRUST_POLICY}"
else
  aws iam create-role --role-name "${ROLE_NAME}" \
    --description "AWS Deep Cuts AWS Continuum CV hands-on" \
    --tags "Key=Project,Value=${PROJECT_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" >/dev/null
  echo "  作成: ${ROLE_NAME}"
fi
aws iam put-role-policy --role-name "${ROLE_NAME}" --policy-name "${POLICY_NAME}" --policy-document "${ACCESS_POLICY}"
echo "  許可ポリシー: ${POLICY_NAME}（code/ と context/ の読み取り、${PATCH_PREFIX} への書き込み）"
echo ""

# ─── [4/5] 記録フォルダー ─────────────────────────────────────
echo "[4/5] 結果を保存するフォルダーを確認..."
echo "  ${CV_DIR}"
echo ""

# ─── [5/5] IAM の反映待ち ──────────────────────────────────────
echo "[5/5] IAM ロールの反映を待機（10 秒）..."
sleep 10
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 発展 CV のセットアップが完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "作成したリソースは、マネジメントコンソールの次の画面で確認できます。"
echo "  S3 バケット: https://${CV_REGION}.console.aws.amazon.com/s3/buckets/${BUCKET_NAME}?region=${CV_REGION}"
echo "  IAM ロール:  https://us-east-1.console.aws.amazon.com/iam/home#/roles/details/${ROLE_NAME}"
echo ""
echo "次のステップ: 発展の README の発展 1 に戻り、次のコマンドで変数を読み込んでください。"
echo "  source ${RESOURCE_FILE}"
