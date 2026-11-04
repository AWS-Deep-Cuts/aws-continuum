#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - AWS Continuum 任意の発展: CV の後片付け
# 発展の手順で作った Environment と Integration、setup-cv.sh が作ったバケットとロールを削除します。
# API の説明によると、Environment を削除すると、関連するスキャン・Finding・Issue・成果物も削除されます。
# 記録フォルダーの JSON とパッチは、採点の記録として残し、消すコマンドを表示します。

readonly CV_DIR="${DEEPCUTS_CV_DIR:-${HOME}/deepcuts-results/cv}"
readonly RESOURCE_FILE="${CV_DIR}/resource-ids.env"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - AWS Continuum 発展 CV の後片付け"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [[ ! -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が見つかりません。何も消さずに止めます。" >&2
  echo "   残っているものは、次のコマンドで確かめられます。" >&2
  echo "     aws continuum list-environments --region us-east-1 --query 'items[].[name,environmentId]' --output table" >&2
  echo "     aws continuum list-integrations --region us-east-1 --query 'items[].[name,integrationId]' --output table" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${RESOURCE_FILE}"
CV_REGION="${CV_REGION:-us-east-1}"
export AWS_REGION="${CV_REGION}" AWS_DEFAULT_REGION="${CV_REGION}"
ACCOUNT_ID="${ACCOUNT_ID:?resource-ids.env に ACCOUNT_ID がありません}"
LEFT=0

# ─── [1/5] Environment ───────────────────────────────────────
echo "[1/5] Environment を削除..."
ENV_IDS="${ENVIRONMENT_ID:-}"
if [[ -n "${ENVIRONMENT_NAME:-}" ]]; then
  # CreateEnvironment には clientToken が無いため、同じ名前の Environment が 2 つ以上できていれば、すべて消す
  BY_NAME=$(aws continuum list-environments --region "${CV_REGION}" \
    --query "items[?name=='${ENVIRONMENT_NAME}'].environmentId" --output text 2>/dev/null || true)
  [[ "${BY_NAME}" == "None" ]] && BY_NAME=""
  for ID in ${BY_NAME}; do
    case " ${ENV_IDS} " in *" ${ID} "*) ;; *) ENV_IDS="${ENV_IDS} ${ID}" ;; esac
  done
fi
if [[ -z "${ENV_IDS// /}" ]]; then
  echo "  対象なし"
fi
for ID in ${ENV_IDS}; do
  DELETED=0
  # Issue の処理の途中などで ConflictException が返ることがあるため、60 秒おきに 5 回まで試す
  for TRY in 1 2 3 4 5; do
    if ERR=$(aws continuum delete-environment --environment-id "${ID}" --region "${CV_REGION}" 2>&1); then
      DELETED=1; break
    fi
    case "${ERR}" in
      *ResourceNotFound*) DELETED=1; break ;;
    esac
    echo "    削除できませんでした（${TRY}/5）: $(echo "${ERR}" | tail -1)"
    [[ "${TRY}" == "5" ]] || sleep 60
  done
  if [[ "${DELETED}" == "1" ]]; then
    echo "  削除: ${ID}"
  else
    echo "  ❌ Environment を削除できませんでした。Issue の処理が終わるのを待ってから、もう一度 bash ./cleanup-cv.sh を実行してください。" >&2
    LEFT=1
  fi
done
echo ""

# ─── [2/5] Integration ───────────────────────────────────────
echo "[2/5] Integration を削除..."
INT_IDS="${INTEGRATION_ID:-}"
if [[ -n "${INTEGRATION_NAME:-}" ]]; then
  BY_NAME=$(aws continuum list-integrations --region "${CV_REGION}" \
    --query "items[?name=='${INTEGRATION_NAME}'].integrationId" --output text 2>/dev/null || true)
  [[ "${BY_NAME}" == "None" ]] && BY_NAME=""
  for ID in ${BY_NAME}; do
    case " ${INT_IDS} " in *" ${ID} "*) ;; *) INT_IDS="${INT_IDS} ${ID}" ;; esac
  done
fi
if [[ -z "${INT_IDS// /}" ]]; then
  echo "  対象なし"
fi
for ID in ${INT_IDS}; do
  DELETED=0
  for TRY in 1 2 3 4 5; do
    if ERR=$(aws continuum delete-integration --integration-id "${ID}" --region "${CV_REGION}" 2>&1); then
      DELETED=1; break
    fi
    case "${ERR}" in
      *ResourceNotFound*) DELETED=1; break ;;
    esac
    echo "    削除できませんでした（${TRY}/5）: $(echo "${ERR}" | tail -1)"
    [[ "${TRY}" == "5" ]] || sleep 60
  done
  if [[ "${DELETED}" == "1" ]]; then
    echo "  削除: ${ID}"
  else
    echo "  ❌ Integration ${ID} を削除できませんでした。" >&2
    LEFT=1
  fi
done
COLLECTORS=$(aws continuum list-collectors --region "${CV_REGION}" --query 'items[].collectorId' --output text 2>/dev/null || true)
if [[ -n "${COLLECTORS}" && "${COLLECTORS}" != "None" ]]; then
  echo "  ⚠️  Collector があります: ${COLLECTORS}。このハンズオンでは作らないため、消しません。"
fi
echo ""

# ─── [3/5] S3 バケット ─────────────────────────────────────────
echo "[3/5] S3 バケットを削除..."
if [[ -n "${BUCKET_NAME:-}" ]] && aws s3api head-bucket --bucket "${BUCKET_NAME}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${CV_REGION}" 2>/dev/null; then
  TMP_JSON=$(mktemp)
  trap 'rm -f "${TMP_JSON}" "${TMP_JSON}.del"' EXIT
  for _ in $(seq 1 50); do
    aws s3api list-object-versions --bucket "${BUCKET_NAME}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${CV_REGION}" \
      --max-items 1000 --output json > "${TMP_JSON}"
    COUNT=$(python3 -I -c '
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
objs = [{"Key": o["Key"], "VersionId": o["VersionId"]} for o in (doc.get("Versions") or []) + (doc.get("DeleteMarkers") or [])]
json.dump({"Objects": objs, "Quiet": True}, open(sys.argv[2], "w", encoding="utf-8"))
print(len(objs))
' "${TMP_JSON}" "${TMP_JSON}.del")
    [[ "${COUNT}" == "0" ]] && break
    aws s3api delete-objects --bucket "${BUCKET_NAME}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${CV_REGION}" \
      --delete "file://${TMP_JSON}.del" >/dev/null
    echo "  オブジェクトを削除: ${COUNT} 件"
  done
  if aws s3api delete-bucket --bucket "${BUCKET_NAME}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${CV_REGION}"; then
    echo "  削除: s3://${BUCKET_NAME}"
  else
    LEFT=1
  fi
else
  echo "  対象なし"
fi
echo ""

# ─── [4/5] IAM ロール ─────────────────────────────────────────
echo "[4/5] Integration のロールを削除..."
if [[ -n "${ROLE_NAME:-}" ]] && aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "${POLICY_NAME:-aws-deepcuts-continuum-s3-access}" 2>/dev/null || true
  if aws iam delete-role --role-name "${ROLE_NAME}"; then
    echo "  削除: ${ROLE_NAME}"
  else
    LEFT=1
  fi
else
  echo "  対象なし"
fi
echo ""

# ─── [5/5] ローカル ───────────────────────────────────────────
echo "[5/5] ローカルの後片付け..."
# README の手順で起動したアプリの番号だけを止める。番号が他のプログラムに再利用されていないかを、コマンドの名前で確かめる
if [[ -f "${CV_DIR}/app.pid" ]]; then
  APP_PID=$(head -1 "${CV_DIR}/app.pid" | tr -cd '0-9')
  if [[ -n "${APP_PID}" ]] && ps -p "${APP_PID}" -o command= 2>/dev/null | grep -q 'app\.py'; then
    kill "${APP_PID}" 2>/dev/null && echo "  動いていたアプリを止めました（プロセス ${APP_PID}）"
  fi
  rm -f "${CV_DIR}/app.pid"
fi
rm -rf "${CV_DIR:?}/app-patched"
rm -f "${CV_DIR:?}/evil-order.csv"
echo "  削除: ${CV_DIR}/app-patched、${CV_DIR}/evil-order.csv（あれば）"
echo ""

echo "残っているリソースを確認..."
REMAIN_ENV=$(aws continuum list-environments --region "${CV_REGION}" \
  --query "items[?name=='${ENVIRONMENT_NAME:-aws-deepcuts-record-shop}'].environmentId" --output text 2>/dev/null || echo "unknown")
if [[ -n "${REMAIN_ENV}" && "${REMAIN_ENV}" != "None" ]]; then
  echo "  ⚠️  Environment が残っています: ${REMAIN_ENV}"; LEFT=1
fi
REMAIN_INT=$(aws continuum list-integrations --region "${CV_REGION}" \
  --query "items[?name=='${INTEGRATION_NAME:-aws-deepcuts-s3}'].integrationId" --output text 2>/dev/null || echo "unknown")
if [[ -n "${REMAIN_INT}" && "${REMAIN_INT}" != "None" ]]; then
  echo "  ⚠️  Integration が残っています: ${REMAIN_INT}"; LEFT=1
fi
if [[ -n "${BUCKET_NAME:-}" ]] && aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${CV_REGION}" 2>/dev/null; then
  echo "  ⚠️  S3 バケットが残っています: ${BUCKET_NAME}"; LEFT=1
fi
if [[ -n "${ROLE_NAME:-}" ]] && aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "  ⚠️  IAM ロールが残っています: ${ROLE_NAME}"; LEFT=1
fi
if [[ "${LEFT}" == "1" ]]; then
  echo ""
  echo "❌ 削除できなかったリソースがあります。数分待ってから、もう一度 bash ./cleanup-cv.sh を実行してください。" >&2
  exit 1
fi
echo "  なし"
rm -f "${RESOURCE_FILE}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ すべてのリソースの削除が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "記録フォルダーの JSON とパッチは残しています。採点が済んだら、次のコマンドで消してください。"
echo "  rm -rf \"${CV_DIR}\""
