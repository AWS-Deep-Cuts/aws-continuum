#!/bin/bash
set -euo pipefail

# AWS Deep Cuts - AWS Continuum（Security Agent）ハンズオンの作業フォルダーを作る
# このスクリプトは AWS を呼び出しません。次の 2 つだけを行います。
#   1. hands-on/app/ の中身を、作業フォルダー ~/deepcuts-record-shop に複製し、最初のコミットだけがある git リポジトリにする
#      （GitHub などには push しません）
#   2. 採点表の見本を、記録フォルダー ~/deepcuts-results/scorecard.md に複製する
# 作業フォルダーには、答え・この README・記事・AI エージェント向けの指示のファイルを入れません。
# プラグインは作業フォルダー全体を zip にして Security Agent に送り、AI だけのレビューも同じフォルダーを読むためです。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly APP_DIR="${SCRIPT_DIR}/app"
readonly RESULTS_DIR="${DEEPCUTS_RESULTS_DIR:-${HOME}/deepcuts-results}"
readonly WORKSPACE="${DEEPCUTS_WORKSPACE:-${HOME}/deepcuts-record-shop}"
readonly RESOURCE_FILE="${RESULTS_DIR}/resource-ids.env"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - AWS Continuum 作業フォルダーの作成"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "[1/4] 前提を確認..."
if [[ ! -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} がありません。先に bash ./precheck.sh を実行してください。" >&2
  exit 1
fi
if [[ -e "${WORKSPACE}" ]]; then
  echo "❌ Error: ${WORKSPACE} が既にあります。" >&2
  echo "   前回の作業フォルダーが残っています。中身を確かめてから rm -rf \"${WORKSPACE}\" で消し、もう一度実行してください。" >&2
  exit 1
fi
command -v git >/dev/null 2>&1 || { echo "❌ Error: git コマンドが見つかりません。" >&2; exit 1; }
echo "  作業フォルダー: ${WORKSPACE}"
echo ""

echo "[2/4] アプリを作業フォルダーに複製..."
mkdir -p "${WORKSPACE}"
# 末尾の /. で、.gitignore のような隠しファイルも含めて複製する
cp -R "${APP_DIR}/." "${WORKSPACE}/"
find "${WORKSPACE}" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "${WORKSPACE}" -name '*.pyc' -type f -exec rm -f {} +
echo "  複製元: ${APP_DIR}"
echo ""

echo "[3/4] git リポジトリにして、最初のコミットを作成..."
(
  cd "${WORKSPACE}"
  git init -q
  # 古い git でも既定のブランチを main にする
  git symbolic-ref HEAD refs/heads/main
  git add -A
  # あなたの git の設定に頼らず、このコミットだけの名前とメールアドレスを使う
  git -c user.name=deepcuts -c user.email=deepcuts@example.com -c commit.gpgsign=false \
    commit -q -m "record shop: initial"
)
echo "  コミット: $(git -C "${WORKSPACE}" log --oneline -1)"
echo ""

echo "[4/4] 答えや AI 向けの指示のファイルが無いことを確認..."
FOUND=""
for NAME in CLAUDE.md AGENTS.md .kiro .github docs .claude; do
  if [[ -e "${WORKSPACE}/${NAME}" ]]; then
    FOUND="${FOUND} ${NAME}"
  fi
done
if [[ -n "${FOUND}" ]]; then
  echo "❌ Error: 作業フォルダーに、次のファイルかフォルダーがあります:${FOUND}" >&2
  echo "   Security Agent と AI だけのレビューに答えが見えてしまうため、ここで止めます。" >&2
  exit 1
fi
echo "  ✓ CLAUDE.md・AGENTS.md・.kiro・.github・docs・.claude はありません"
if [[ -f "${RESULTS_DIR}/scorecard.md" ]]; then
  echo "  採点表は既にあるため、上書きしません: ${RESULTS_DIR}/scorecard.md"
else
  cp "${SCRIPT_DIR}/scorecard-template.md" "${RESULTS_DIR}/scorecard.md"
  echo "  採点表を複製しました: ${RESULTS_DIR}/scorecard.md"
fi
echo ""

echo "作業フォルダーのファイル（git ls-files）:"
git -C "${WORKSPACE}" ls-files | sed 's/^/  /'
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 作業フォルダー ${WORKSPACE} を作りました"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "次のステップ: README の手順 2 に進み、作業フォルダーでアプリを読んでください。"
echo "  cd \"${WORKSPACE}\""
