#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - AWS Continuum（Security Agent）ハンズオンの事前確認
# このスクリプトは、AWS には何も作りません。次のことを確かめ、結果を記録フォルダーの resource-ids.env に書きます。
#   1. 道具（aws・git・python3・zip・curl）
#   2. AWS の認証情報とアカウント ID
#   3. AWS CLI が Security Agent の脅威モデリング・差分スキャン・予算の上限と検証の方式に対応しているか（接続せずに確かめる）
#   4. AWS Price List で、コードレビューと脅威モデリングの単価が 0.00 USD/時か（0 でなければ止まる）
#   5. Security Agent の API を呼び出せるか
#   6. このハンズオンで作られるものと同じ名前のロール・バケットが、前からあるか
# macOS の bash 3.2 でも動くように、連想配列・mapfile・sed -i・stat・md5sum・jq を使っていません。

readonly ROLE_NAME="SecurityAgentScanRole"
readonly RESULTS_DIR="${DEEPCUTS_RESULTS_DIR:-${HOME}/deepcuts-results}"
readonly WORKSPACE="${DEEPCUTS_WORKSPACE:-${HOME}/deepcuts-record-shop}"
readonly RESOURCE_FILE="${RESULTS_DIR}/resource-ids.env"
readonly PRICE_URL_BASE="https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/SecAgent/current"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - AWS Continuum 事前確認"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/7] リージョンの環境変数と、前回の記録 ─────────────────────
echo "[1/7] リージョンの環境変数を確認..."
REGION="${AWS_REGION:-}"
if [[ -z "${REGION}" ]]; then
  echo "❌ Error: 環境変数 AWS_REGION が設定されていません。" >&2
  echo "   export AWS_REGION=ap-northeast-1 AWS_DEFAULT_REGION=ap-northeast-1 を実行してから、もう一度実行してください。" >&2
  exit 1
fi
if [[ -n "${AWS_DEFAULT_REGION:-}" && "${AWS_DEFAULT_REGION}" != "${REGION}" ]]; then
  echo "❌ Error: AWS_REGION（${REGION}）と AWS_DEFAULT_REGION（${AWS_DEFAULT_REGION}）が違います。" >&2
  echo "   AI コーディングツールが実行するコマンドには --region が付かないため、2 つを同じ値にしてください。" >&2
  exit 1
fi
if [[ -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が既にあります。前回のハンズオンの記録が残っています。" >&2
  echo "   前回のリソースを消す場合は bash ./cleanup.sh を、記録だけを消す場合は rm \"${RESOURCE_FILE}\" を実行してください。" >&2
  exit 1
fi
echo "  リージョン: ${REGION}"
echo ""

# ─── [2/7] 道具 ───────────────────────────────────────────────
echo "[2/7] 道具を確認..."
for cmd in aws git python3 zip curl; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "❌ Error: ${cmd} コマンドが見つかりません。インストールしてから、もう一度実行してください。" >&2; exit 1; }
done
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
  echo "❌ Error: Python 3.9 以上が必要です。現在: $(python3 --version 2>&1)" >&2
  exit 1
fi
if command -v md5sum >/dev/null 2>&1; then
  echo "  md5sum: あり"
else
  echo "  ⚠️  md5sum がありません。プラグインのスキルは作業フォルダーの ID を md5sum で作ります。"
  echo "     README のトラブルシューティングの md5sum の行を確認してください（止めずに続けます）。"
fi
echo "  $(aws --version 2>&1)"
echo ""

# ─── [3/7] 認証情報 ─────────────────────────────────────────────
echo "[3/7] AWS の認証情報を確認..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "${REGION}" 2>/dev/null) || {
  echo "❌ Error: AWS の認証情報を取得できません。aws login などでサインインしてから、もう一度実行してください。" >&2
  exit 1
}
echo "  アカウント: ${ACCOUNT_ID}"
echo ""

# ─── [4/7] AWS CLI の機能（接続しない） ─────────────────────────
echo "[4/7] AWS CLI が Security Agent の機能に対応しているかを確認（接続しません）..."
if ! aws securityagent create-threat-model --generate-cli-skeleton input >/dev/null 2>&1; then
  echo "❌ Error: この AWS CLI は aws securityagent create-threat-model に対応していません。" >&2
  echo "   AWS CLI v2 を最新版に更新してから、もう一度実行してください（2.36.23 以降が必要です）。" >&2
  exit 1
fi
SKELETON=$(aws securityagent start-code-review-job --generate-cli-skeleton input 2>/dev/null || true)
if [[ "${SKELETON}" != *'"diffSource"'* ]]; then
  echo "❌ Error: この AWS CLI は差分スキャン（start-code-review-job の --diff-source）に対応していません。" >&2
  echo "   AWS CLI v2 を最新版に更新してから、もう一度実行してください（2.36.23 以降が必要です）。" >&2
  exit 1
fi
# 予算の上限 maxTaskHours は AWS CLI 2.36.23 で入った。古い版では、手順 5-2 の出力にこの項目が現れない
CR_SKELETON=$(aws securityagent create-code-review --generate-cli-skeleton input 2>/dev/null || true)
if [[ "${CR_SKELETON}" != *'"maxTaskHours"'* || "${CR_SKELETON}" != *'"validationMode"'* ]]; then
  echo "❌ Error: この AWS CLI は create-code-review の maxTaskHours（予算の上限）か validationMode（検証の方式）に対応していません。" >&2
  echo "   AWS CLI v2 を最新版に更新してから、もう一度実行してください（2.36.23 以降が必要です）。" >&2
  exit 1
fi
echo "  脅威モデリング・差分スキャン・予算の上限・検証の方式: あり"
echo ""

# ─── [5/7] AWS Price List の単価 ───────────────────────────────
echo "[5/7] AWS Price List で Security Agent の単価を確認..."
PRICE_JSON=$(mktemp)
trap 'rm -f "${PRICE_JSON}"' EXIT
HTTP_CODE=$(curl -s -o "${PRICE_JSON}" -w '%{http_code}' "${PRICE_URL_BASE}/${REGION}/index.json" || true)
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "❌ Error: ${REGION} の Security Agent の Price List を取得できませんでした（HTTP ${HTTP_CODE}）。" >&2
  echo "   このリージョンに Security Agent の単価が載っていない可能性があります。README のリージョンの説明を確認してください。" >&2
  exit 1
fi
# 使用タイプと単価を表示し、コードレビューと脅威モデリングの単価がどちらも 0 であれば終了コード 0 を返す
if ! python3 -I - "${PRICE_JSON}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)
usage = {sku: p["attributes"].get("usagetype", "") for sku, p in doc.get("products", {}).items()}
prices = {}
for sku, terms in doc.get("terms", {}).get("OnDemand", {}).items():
    for term in terms.values():
        for dim in term.get("priceDimensions", {}).values():
            prices[usage.get(sku, sku)] = (float(dim["pricePerUnit"].get("USD", "nan")), dim.get("unit", ""))
for name in sorted(prices):
    value, unit = prices[name]
    print(f"  {name:<40} {value:>8.2f} USD / {unit}")
print(f"  publicationDate: {doc.get('publicationDate', '')}")
required = {"repository-code-review": None, "threat-modeling": None}
for name, (value, _) in prices.items():
    for key in required:
        if name.lower().endswith("-" + key):
            required[key] = value
ok = True
for key, value in required.items():
    if value is None:
        print(f"  ✗ {key} の使用タイプが見つかりません")
        ok = False
    elif value != 0.0:
        print(f"  ✗ {key} の単価が 0.00 USD ではありません")
        ok = False
sys.exit(0 if ok else 1)
PY
then
  echo "❌ Error: Security Agent のコードレビューか脅威モデリングの単価が 0.00 USD ではありません。" >&2
  echo "   README の費用の見積もりは当てはまりません。料金ページを確認してから、続けるかを判断してください。" >&2
  exit 1
fi
PRICE_PUBLICATION=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("publicationDate",""))' "${PRICE_JSON}")
echo "  ✓ コードレビューと脅威モデリングは 0.00 USD/時です"
echo ""

# ─── [6/7] Security Agent を呼び出せるか ──────────────────────────
echo "[6/7] Security Agent の API を呼び出せるかを確認..."
SA_ERR=$(mktemp)
trap 'rm -f "${PRICE_JSON}" "${SA_ERR}"' EXIT
if ! aws securityagent list-agent-spaces --max-results 1 --region "${REGION}" >/dev/null 2>"${SA_ERR}"; then
  echo "❌ Error: aws securityagent list-agent-spaces が失敗しました。" >&2
  sed 's/^/   /' "${SA_ERR}" >&2
  echo "   リージョン・権限を確認してください。初回の設定を求める内容であれば、README のトラブルシューティングを見てください。" >&2
  exit 1
fi
echo "  ✓ list-agent-spaces が成功しました"
echo ""

# ─── [7/7] 前からあるリソース ─────────────────────────────────────
echo "[7/7] このハンズオンで作られるものと同じ名前のリソースが、前からあるかを確認..."
SCAN_BUCKET="security-agent-scans-${ACCOUNT_ID}-${REGION}"
TM_BUCKET="security-agent-threat-model-${ACCOUNT_ID}-${REGION}"

PRE_ROLE=0
ROLE_ERR=$(mktemp)
trap 'rm -f "${PRICE_JSON}" "${SA_ERR}" "${ROLE_ERR}"' EXIT
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>"${ROLE_ERR}"; then
  PRE_ROLE=1
elif ! grep -q 'NoSuchEntity' "${ROLE_ERR}"; then
  echo "❌ Error: IAM ロール ${ROLE_NAME} の有無を確認できませんでした。" >&2
  sed 's/^/   /' "${ROLE_ERR}" >&2
  exit 1
fi
if [[ "${PRE_ROLE}" == "1" ]]; then
  if [[ "${DEEPCUTS_ALLOW_EXISTING_ROLE:-0}" != "1" ]]; then
    echo "❌ Error: IAM ロール ${ROLE_NAME} が既にあります。" >&2
    echo "   手順 4 のプラグインの準備は、このロールの信頼ポリシーと許可を上書きします。" >&2
    echo "   ハンズオン用の別のアカウントで行ってください。上書きを了承する場合だけ、" >&2
    echo "   DEEPCUTS_ALLOW_EXISTING_ROLE=1 bash ./precheck.sh で続けられます（cleanup.sh はこのロールを消しません）。" >&2
    exit 1
  fi
  echo "  ⚠️  ${ROLE_NAME}: 前からあります（上書きを了承済み。cleanup.sh は消しません）"
else
  echo "  ${ROLE_NAME}: ありません"
fi

# バケットの持ち主が自分であることも確かめる。403 は、他のアカウントが同じ名前のバケットを持っていることを示す
bucket_state() {
  local bucket="$1" err
  err=$(aws s3api head-bucket --bucket "${bucket}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${REGION}" 2>&1 >/dev/null) && { echo "own"; return 0; }
  case "${err}" in
    *404*|*"Not Found"*|*NoSuchBucket*) echo "none" ;;
    *403*|*Forbidden*) echo "foreign" ;;
    *) echo "error" ;;
  esac
}
PRE_SCAN_BUCKET=0
PRE_TM_BUCKET=0
for PAIR in "${SCAN_BUCKET}:SCAN" "${TM_BUCKET}:TM"; do
  BUCKET="${PAIR%%:*}"; KIND="${PAIR##*:}"
  STATE=$(bucket_state "${BUCKET}")
  case "${STATE}" in
    own)
      echo "  ⚠️  ${BUCKET}: 前からあります（cleanup.sh は消しません）"
      if [[ "${KIND}" == "SCAN" ]]; then PRE_SCAN_BUCKET=1; else PRE_TM_BUCKET=1; fi
      ;;
    none)
      echo "  ${BUCKET}: ありません"
      ;;
    foreign)
      echo "❌ Error: バケット ${BUCKET} は、他のアカウントが持っています（403）。" >&2
      echo "   このバケットにコードを送らないよう、ここで止めます。別のアカウントかリージョンで行ってください。" >&2
      exit 1
      ;;
    *)
      echo "❌ Error: バケット ${BUCKET} の有無を確認できませんでした。権限を確認してください。" >&2
      exit 1
      ;;
  esac
done

PRE_AGENT_SPACES=$(aws securityagent list-agent-spaces --region "${REGION}" \
  --query 'agentSpaceSummaries[].agentSpaceId' --output text) || {
  echo "❌ Error: エージェントスペースの一覧を取得できません。権限を確認してください。" >&2
  exit 1
}
[[ "${PRE_AGENT_SPACES}" == "None" ]] && PRE_AGENT_SPACES=""
PRE_AGENT_SPACES=$(echo "${PRE_AGENT_SPACES}" | tr '\t' ' ')
if [[ -n "${PRE_AGENT_SPACES}" ]]; then
  echo "  エージェントスペース: 前からあるもの ${PRE_AGENT_SPACES}（cleanup.sh は消しません）"
else
  echo "  エージェントスペース: ありません"
fi

PRE_LOG_GROUPS=$(aws logs describe-log-groups --log-group-name-prefix /aws/securityagent --region "${REGION}" \
  --query 'logGroups[].logGroupName' --output text) || {
  echo "❌ Error: ロググループの一覧を取得できません。権限を確認してください。" >&2
  exit 1
}
[[ "${PRE_LOG_GROUPS}" == "None" ]] && PRE_LOG_GROUPS=""
PRE_LOG_GROUPS=$(echo "${PRE_LOG_GROUPS}" | tr '\t' ' ')
echo "  /aws/securityagent で始まるロググループ: ${PRE_LOG_GROUPS:-ありません}"
echo ""

# ─── 記録 ─────────────────────────────────────────────────────
mkdir -p "${RESULTS_DIR}"
chmod 700 "${RESULTS_DIR}"
PRECHECK_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "${RESOURCE_FILE}" <<EOF
# AWS Deep Cuts AWS Continuum - 記録（precheck.sh が作成。README の手順で行を追記します）
REGION="${REGION}"
ACCOUNT_ID="${ACCOUNT_ID}"
PRECHECK_AT="${PRECHECK_AT}"
PRICE_PUBLICATION="${PRICE_PUBLICATION}"
SCAN_BUCKET="${SCAN_BUCKET}"
TM_BUCKET="${TM_BUCKET}"
PRE_ROLE="${PRE_ROLE}"
PRE_SCAN_BUCKET="${PRE_SCAN_BUCKET}"
PRE_TM_BUCKET="${PRE_TM_BUCKET}"
PRE_AGENT_SPACES="${PRE_AGENT_SPACES}"
PRE_LOG_GROUPS="${PRE_LOG_GROUPS}"
WORKSPACE="${WORKSPACE}"
EOF
chmod 600 "${RESOURCE_FILE}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 事前確認が完了しました（AWS には何も作っていません）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "記録: ${RESOURCE_FILE}"
echo ""
echo "次のステップ: 作業フォルダーを作ります。"
echo "  bash ./make-workspace.sh"
