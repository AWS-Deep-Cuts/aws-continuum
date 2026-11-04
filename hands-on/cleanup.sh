#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - AWS Continuum（Security Agent）ハンズオンの後片付け
# precheck.sh が書いた記録（~/deepcuts-results/resource-ids.env）を読み、このハンズオンで作られたものだけを消します。
#   1. エージェントスペース  … 実行中のジョブを止め、コードレビューと脅威モデルを消してから、エージェントスペースを消す
#   2. S3 バケット          … security-agent-scans-<アカウント>-<リージョン> と、Kiro の経路の security-agent-threat-model-...
#   3. IAM ロール           … SecurityAgentScanRole
#   4. CloudWatch Logs      … /aws/securityagent で始まるロググループ（作られた場合）
#   5. ローカル             … 記録フォルダーの app.pid の番号で動いているアプリと、攻撃の確認に使った CSV
# precheck.sh の前からあったロール・バケット・エージェントスペース・ロググループは消しません。
# precheck.sh の後に作られた /aws/securityagent で始まるロググループと、名前が deepcuts-record-shop か
# security-scans のエージェントスペースは、このハンズオンのものとして消します。同じアカウントで他の人が
# Security Agent を使っていると、そのリソースも対象になるため、消す前に一覧を表示して確認を求めます。
# 作業フォルダーと記録フォルダーは消さず、消すコマンドを表示します。

readonly RESULTS_DIR="${DEEPCUTS_RESULTS_DIR:-${HOME}/deepcuts-results}"
readonly RESOURCE_FILE="${RESULTS_DIR}/resource-ids.env"
readonly ROLE_NAME="SecurityAgentScanRole"
# AI コーディングツールが作るエージェントスペースの名前。README で頼む名前と、プラグインの既定の名前
readonly SPACE_NAMES="deepcuts-record-shop security-scans"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - AWS Continuum 後片付け"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ ! -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が見つかりません。" >&2
  echo "   前からあったリソースを誤って消さないよう、何も消さずに止めます。" >&2
  echo "   残っているものは、次のコマンドで確かめられます（リージョンは ap-northeast-1 の例）。" >&2
  echo "     aws securityagent list-agent-spaces --region ap-northeast-1 --query 'agentSpaceSummaries[].[name,agentSpaceId]' --output table" >&2
  echo "     aws iam get-role --role-name ${ROLE_NAME} --query Role.Arn" >&2
  echo "     aws s3api list-buckets --query \"Buckets[?starts_with(Name, 'security-agent-')].Name\"" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${RESOURCE_FILE}"
REGION="${REGION:?resource-ids.env に REGION がありません}"
ACCOUNT_ID="${ACCOUNT_ID:?resource-ids.env に ACCOUNT_ID がありません}"
PRECHECK_AT="${PRECHECK_AT:-}"
AGENT_SPACE_ID="${AGENT_SPACE_ID:-}"
PRE_AGENT_SPACES="${PRE_AGENT_SPACES:-}"
PRE_LOG_GROUPS="${PRE_LOG_GROUPS:-}"
PRE_ROLE="${PRE_ROLE:-0}"
PRE_SCAN_BUCKET="${PRE_SCAN_BUCKET:-0}"
PRE_TM_BUCKET="${PRE_TM_BUCKET:-0}"
SCAN_BUCKET="${SCAN_BUCKET:-security-agent-scans-${ACCOUNT_ID}-${REGION}}"
TM_BUCKET="${TM_BUCKET:-security-agent-threat-model-${ACCOUNT_ID}-${REGION}}"
WORKSPACE="${WORKSPACE:-${HOME}/deepcuts-record-shop}"
# IAM のコマンドにもリージョンが要る環境があるため、記録のリージョンを環境変数にも設定する
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
echo "  アカウント: ${ACCOUNT_ID} / リージョン: ${REGION}"
echo ""

LEFT=0
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

# 空白で区切った一覧（$2）に、値（$1）が含まれるか
in_list() {
  local needle="$1" item
  for item in $2; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

# 一覧の JSON（標準入力）から ID を取り出す。$3 に日時があれば、それより後に作られたものだけにする
ids_from_json() {
  python3 -I -c '
import json, sys
from datetime import datetime, timezone
def parse(value):
    value = value.replace("Z", "+00:00")
    dt = datetime.fromisoformat(value)
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
doc = json.load(sys.stdin)
since = parse(sys.argv[3]) if sys.argv[3] else None
for item in doc.get(sys.argv[1]) or []:
    created = item.get("createdAt")
    if since is not None and (not created or parse(str(created)) <= since):
        continue
    print(item[sys.argv[2]])
' "$1" "$2" "${3:-}"
}

# エージェントスペースの中の、実行中のジョブを止め、コードレビューと脅威モデルを消す
# $1: エージェントスペースの ID、$2: 空でなければ、この日時より後に作られたものだけを対象にする
clean_space_contents() {
  local space="$1" since="${2:-}" cr_ids tm_ids id job
  cr_ids=$(aws securityagent list-code-reviews --agent-space-id "${space}" --region "${REGION}" --output json \
    | ids_from_json codeReviewSummaries codeReviewId "${since}") || cr_ids=""
  for id in ${cr_ids}; do
    for job in $(aws securityagent list-code-review-jobs-for-code-review --agent-space-id "${space}" --code-review-id "${id}" \
        --region "${REGION}" --query "codeReviewJobSummaries[?status=='IN_PROGRESS'].codeReviewJobId" --output text 2>/dev/null || true); do
      [[ "${job}" == "None" ]] && continue
      aws securityagent stop-code-review-job --agent-space-id "${space}" --code-review-job-id "${job}" --region "${REGION}" >/dev/null 2>&1 \
        && echo "    停止を依頼: コードレビューのジョブ ${job}"
    done
  done
  tm_ids=$(aws securityagent list-threat-models --agent-space-id "${space}" --region "${REGION}" --output json \
    | ids_from_json threatModelSummaries threatModelId "${since}") || tm_ids=""
  for id in ${tm_ids}; do
    for job in $(aws securityagent list-threat-model-jobs --agent-space-id "${space}" --threat-model-id "${id}" \
        --region "${REGION}" --query "threatModelJobSummaries[?status=='IN_PROGRESS'].threatModelJobId" --output text 2>/dev/null || true); do
      [[ "${job}" == "None" ]] && continue
      aws securityagent stop-threat-model-job --agent-space-id "${space}" --threat-model-job-id "${job}" --region "${REGION}" >/dev/null 2>&1 \
        && echo "    停止を依頼: 脅威モデルのジョブ ${job}"
    done
  done
  if [[ -n "${cr_ids}" ]]; then
    # shellcheck disable=SC2086  # ID を空白で区切って複数渡すため、引用符で囲まない
    aws securityagent batch-delete-code-reviews --agent-space-id "${space}" --code-review-ids ${cr_ids} --region "${REGION}" \
      --query '{deleted: deleted, failed: failed}' --output json 2>&1 | sed 's/^/    コードレビューの削除: /' || true
  fi
  if [[ -n "${tm_ids}" ]]; then
    # shellcheck disable=SC2086
    aws securityagent batch-delete-threat-models --agent-space-id "${space}" --threat-model-ids ${tm_ids} --region "${REGION}" \
      --query '{deleted: deleted, failed: failed}' --output json 2>&1 | sed 's/^/    脅威モデルの削除: /' || true
  fi
}

space_exists() {
  local found
  found=$(aws securityagent list-agent-spaces --region "${REGION}" \
    --query "agentSpaceSummaries[?agentSpaceId=='$1'].agentSpaceId" --output text 2>/dev/null || echo "unknown")
  [[ -n "${found}" && "${found}" != "None" ]]
}

# ─── 消す対象の一覧 ─────────────────────────────────────────────
echo "消す対象を確認しています..."
SPACES=$(aws securityagent list-agent-spaces --region "${REGION}" \
  --query 'agentSpaceSummaries[].[agentSpaceId,name]' --output text 2>/dev/null) || {
  echo "  ❌ エージェントスペースの一覧を取得できませんでした。権限とリージョンを確認してください。" >&2
  SPACES=""; LEFT=1
}
TARGETS=""
PRE_SPACE_TO_CLEAN=""
echo "  エージェントスペース:"
while IFS=$'\t' read -r SPACE_ID SPACE_NAME; do
  [[ -z "${SPACE_ID}" || "${SPACE_ID}" == "None" ]] && continue
  if in_list "${SPACE_ID}" "${PRE_AGENT_SPACES}"; then
    if [[ "${SPACE_ID}" == "${AGENT_SPACE_ID}" ]]; then
      PRE_SPACE_TO_CLEAN="${SPACE_ID}"
      echo "    ⚠️  ${SPACE_NAME}（${SPACE_ID}）は前からあったエージェントスペースです。消さずに、${PRECHECK_AT} より後に作られたコードレビューと脅威モデルだけを消します。"
    fi
    continue
  fi
  if [[ "${SPACE_ID}" == "${AGENT_SPACE_ID}" ]] || in_list "${SPACE_NAME}" "${SPACE_NAMES}"; then
    TARGETS="${TARGETS} ${SPACE_ID}"
    echo "    消す: ${SPACE_NAME}（${SPACE_ID}）"
  else
    echo "    ⚠️  ${SPACE_NAME}（${SPACE_ID}）は precheck.sh の後に作られましたが、名前が想定と違うため消しません。不要なら手で消してください。"
  fi
done <<< "${SPACES}"
[[ -n "${TARGETS}" || -n "${PRE_SPACE_TO_CLEAN}" ]] || echo "    対象なし"

bucket_state() {
  local err
  err=$(aws s3api head-bucket --bucket "$1" --expected-bucket-owner "${ACCOUNT_ID}" --region "${REGION}" 2>&1 >/dev/null) && { echo "own"; return 0; }
  case "${err}" in
    *404*|*"Not Found"*|*NoSuchBucket*) echo "none" ;;
    *403*|*Forbidden*) echo "foreign" ;;
    *) echo "error" ;;
  esac
}
echo "  S3 バケット:"
for PAIR in "${SCAN_BUCKET}:${PRE_SCAN_BUCKET}" "${TM_BUCKET}:${PRE_TM_BUCKET}"; do
  BUCKET="${PAIR%%:*}"; PRE="${PAIR##*:}"
  if [[ "${PRE}" == "1" ]]; then
    echo "    前からあるため消さない: ${BUCKET}"
  elif [[ "$(bucket_state "${BUCKET}")" == "own" ]]; then
    echo "    消す: ${BUCKET}"
  else
    echo "    消さない（無いか、自分のものではない）: ${BUCKET}"
  fi
done

echo "  IAM ロール:"
if [[ "${PRE_ROLE}" == "1" ]]; then
  echo "    前からあるため消さない: ${ROLE_NAME}"
elif aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "    消す: ${ROLE_NAME}"
else
  echo "    ありません: ${ROLE_NAME}"
fi

echo "  CloudWatch Logs のロググループ:"
GROUPS_NOW=$(aws logs describe-log-groups --log-group-name-prefix /aws/securityagent --region "${REGION}" \
  --query 'logGroups[].logGroupName' --output text 2>/dev/null) || {
  echo "    ❌ ロググループの一覧を取得できませんでした。ロググループは消しません。" >&2
  GROUPS_NOW=""; LEFT=1
}
NEW_GROUPS=""
for GROUP in ${GROUPS_NOW}; do
  [[ "${GROUP}" == "None" ]] && continue
  if in_list "${GROUP}" "${PRE_LOG_GROUPS}"; then
    echo "    前からあるため消さない: ${GROUP}"
  else
    NEW_GROUPS="${NEW_GROUPS} ${GROUP}"
    echo "    消す: ${GROUP}"
  fi
done
[[ -n "${NEW_GROUPS}" ]] || echo "    precheck.sh の後に作られたものはありません"
echo ""
echo "  上の「消す」は、precheck.sh の後に作られたものです。同じアカウントで他の人が Security Agent を"
echo "  使っている場合は、その人のリソースが含まれていないかを確かめてください。"
ANSWER=""
read -r -p "消してよければ y を入力してください: " ANSWER || ANSWER=""
if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]]; then
  echo "何も消さずに終了します。"
  exit 1
fi
echo ""

# ─── [1/5] エージェントスペース ─────────────────────────────────
echo "[1/5] このハンズオンで作られたエージェントスペースを削除..."
if [[ -n "${PRE_SPACE_TO_CLEAN}" ]]; then
  clean_space_contents "${PRE_SPACE_TO_CLEAN}" "${PRECHECK_AT:-1970-01-01T00:00:00Z}"
  echo "  ⚠️  前からあったエージェントスペース ${PRE_SPACE_TO_CLEAN} には、ロールとバケットの登録が残ります。"
fi
[[ -n "${TARGETS}" ]] || echo "  対象なし"
for SPACE_ID in ${TARGETS}; do
  clean_space_contents "${SPACE_ID}" ""
  DELETED=0
  # 停止中のジョブが残っていると消せないことがあるため、60 秒おきに 5 回まで試す
  for TRY in 1 2 3 4 5; do
    if aws securityagent delete-agent-space --agent-space-id "${SPACE_ID}" --region "${REGION}" >/dev/null 2>"${TMP_DIR}/space.err"; then
      DELETED=1
      break
    fi
    echo "    削除できませんでした（${TRY}/5）: $(head -1 "${TMP_DIR}/space.err")"
    [[ "${TRY}" == "5" ]] || sleep 60
  done
  if [[ "${DELETED}" == "1" ]]; then
    echo "  削除を依頼: ${SPACE_ID}"
  else
    echo "  ❌ エージェントスペース ${SPACE_ID} を削除できませんでした。実行中のジョブが終わるのを待ってから、もう一度 bash ./cleanup.sh を実行してください。" >&2
    LEFT=1
  fi
done
echo ""

# ─── [2/5] S3 バケット ─────────────────────────────────────────
echo "[2/5] S3 バケットを削除..."
# バケットのすべてのオブジェクト・バージョン・削除マーカーを、持ち主を確かめながら消す
empty_bucket() {
  local bucket="$1" i count
  for i in $(seq 1 50); do
    aws s3api list-object-versions --bucket "${bucket}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${REGION}" \
      --max-items 1000 --output json > "${TMP_DIR}/versions.json" || return 1
    count=$(python3 -I -c '
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
objs = [{"Key": o["Key"], "VersionId": o["VersionId"]} for o in (doc.get("Versions") or []) + (doc.get("DeleteMarkers") or [])]
json.dump({"Objects": objs, "Quiet": True}, open(sys.argv[2], "w", encoding="utf-8"))
print(len(objs))
' "${TMP_DIR}/versions.json" "${TMP_DIR}/delete.json") || return 1
    [[ "${count}" == "0" ]] && return 0
    aws s3api delete-objects --bucket "${bucket}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${REGION}" \
      --delete "file://${TMP_DIR}/delete.json" >/dev/null || return 1
    echo "    オブジェクトを削除: ${count} 件（${i} 回目）"
  done
  return 1
}
for PAIR in "${SCAN_BUCKET}:${PRE_SCAN_BUCKET}" "${TM_BUCKET}:${PRE_TM_BUCKET}"; do
  BUCKET="${PAIR%%:*}"; PRE="${PAIR##*:}"
  STATE=$(bucket_state "${BUCKET}")
  if [[ "${STATE}" == "none" ]]; then
    echo "  ありません: ${BUCKET}"
    continue
  fi
  if [[ "${STATE}" == "foreign" ]]; then
    echo "  ⚠️  ${BUCKET} は他のアカウントのバケットです。触れません。"
    continue
  fi
  if [[ "${STATE}" != "own" ]]; then
    echo "  ❌ ${BUCKET} の状態を確認できませんでした。" >&2
    LEFT=1
    continue
  fi
  if [[ "${PRE}" == "1" ]]; then
    echo "  ⚠️  ${BUCKET} は前からあったバケットです。消しません。${PRECHECK_AT} より後に置かれたオブジェクトは次のとおりです。"
    aws s3api list-objects-v2 --bucket "${BUCKET}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${REGION}" --output json \
      | python3 -I -c '
import json, sys
from datetime import datetime
since = sys.argv[1].replace("Z", "+00:00")
for o in json.load(sys.stdin).get("Contents") or []:
    if not since or datetime.fromisoformat(o["LastModified"].replace("Z", "+00:00")) > datetime.fromisoformat(since):
        print("    " + o["Key"])
' "${PRECHECK_AT}" || true
    echo "     バケットに 30 日で消えるライフサイクルがあれば、これらは 30 日後に消えます。"
    continue
  fi
  if empty_bucket "${BUCKET}" && aws s3api delete-bucket --bucket "${BUCKET}" --expected-bucket-owner "${ACCOUNT_ID}" --region "${REGION}"; then
    echo "  削除: s3://${BUCKET}"
  else
    echo "  ❌ s3://${BUCKET} を削除できませんでした。" >&2
    LEFT=1
  fi
done
echo ""

# ─── [3/5] IAM ロール ─────────────────────────────────────────
echo "[3/5] IAM ロール ${ROLE_NAME} を削除..."
if [[ "${PRE_ROLE}" == "1" ]]; then
  echo "  ⚠️  前からあったロールのため、消しません。"
elif ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "  ありません"
else
  for POLICY in $(aws iam list-role-policies --role-name "${ROLE_NAME}" --query 'PolicyNames[]' --output text); do
    [[ "${POLICY}" == "None" ]] && continue
    aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "${POLICY}"
    echo "  インラインポリシーを削除: ${POLICY}"
  done
  for ARN in $(aws iam list-attached-role-policies --role-name "${ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text); do
    [[ "${ARN}" == "None" ]] && continue
    aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${ARN}"
    echo "  管理ポリシーをデタッチ: ${ARN}"
  done
  if aws iam delete-role --role-name "${ROLE_NAME}"; then
    echo "  削除: ${ROLE_NAME}"
  else
    LEFT=1
  fi
fi
echo ""

# ─── [4/5] CloudWatch Logs ────────────────────────────────────
echo "[4/5] precheck.sh の後に作られた /aws/securityagent で始まるロググループを削除..."
for GROUP in ${NEW_GROUPS}; do
  if aws logs delete-log-group --log-group-name "${GROUP}" --region "${REGION}"; then
    echo "  削除: ${GROUP}"
  else
    LEFT=1
  fi
done
[[ -n "${NEW_GROUPS}" ]] || echo "  対象なし"
echo ""

# ─── [5/5] ローカル ───────────────────────────────────────────
echo "[5/5] ローカルの後片付け..."
# README の手順で起動したアプリの番号だけを止める。番号が他のプログラムに再利用されていないかを、コマンドの名前で確かめる
APP_PID_FILE="${RESULTS_DIR}/app.pid"
if [[ -f "${APP_PID_FILE}" ]]; then
  APP_PID=$(head -1 "${APP_PID_FILE}" | tr -cd '0-9')
  if [[ -n "${APP_PID}" ]] && ps -p "${APP_PID}" -o command= 2>/dev/null | grep -q 'app\.py'; then
    kill "${APP_PID}" 2>/dev/null && echo "  動いていたアプリを止めました（プロセス ${APP_PID}）"
  fi
  rm -f "${APP_PID_FILE}"
fi
rm -f "${RESULTS_DIR}/evil-order.csv"
echo "  削除: ${RESULTS_DIR}/evil-order.csv（あれば）"
echo ""

echo "残っているリソースを確認..."
for SPACE_ID in ${TARGETS}; do
  for _ in 1 2 3 4 5 6; do
    space_exists "${SPACE_ID}" || break
    sleep 10
  done
  if space_exists "${SPACE_ID}"; then
    echo "  ⚠️  エージェントスペースが残っています: ${SPACE_ID}"; LEFT=1
  fi
done
for PAIR in "${SCAN_BUCKET}:${PRE_SCAN_BUCKET}" "${TM_BUCKET}:${PRE_TM_BUCKET}"; do
  BUCKET="${PAIR%%:*}"; PRE="${PAIR##*:}"
  if [[ "${PRE}" != "1" && "$(bucket_state "${BUCKET}")" == "own" ]]; then
    echo "  ⚠️  S3 バケットが残っています: ${BUCKET}"; LEFT=1
  fi
done
if [[ "${PRE_ROLE}" != "1" ]] && aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "  ⚠️  IAM ロールが残っています: ${ROLE_NAME}"; LEFT=1
fi
if [[ "${LEFT}" == "1" ]]; then
  echo ""
  echo "❌ 削除できなかったリソースがあります。数分待ってから、もう一度 bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
echo "  なし"
mv "${RESOURCE_FILE}" "${RESOURCE_FILE}.done"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ このハンズオンで作ったリソースの削除が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "記録の名前を ${RESOURCE_FILE}.done に変えました。"
echo ""
echo "作業フォルダーの .security-agent/ と、記録フォルダーの findings-full.json・threats.json には、"
echo "攻撃の手順になりうる詳細が入っています。採点が済んだら、次のコマンドで消してください。"
if [[ -f "${RESULTS_DIR}/cv/resource-ids.env" ]]; then
  echo "  ⚠️  発展の CV の記録 ${RESULTS_DIR}/cv/resource-ids.env が残っています。"
  echo "     先に optional-cv/cleanup-cv.sh を実行してから、次のコマンドを実行してください。"
fi
echo "  rm -rf \"${WORKSPACE}\" \"${RESULTS_DIR}\""
echo "プラグインのスキルが書いた一時ファイルも、次のコマンドで消してください。"
echo "  rm -f /tmp/source.zip /tmp/diff.patch /tmp/sa-*.json /tmp/sa-*.err"
echo "Kiro の経路（MCP サーバー）を使った場合は、~/.securityagent/ も消してください。"
