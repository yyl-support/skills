#!/usr/bin/env bash
# gh-comment.sh —— 向 GitHub Issue/PR 发布评论
# =========================================================================
# 用法:
#   echo "评论正文" | ./gh-comment.sh <owner/repo> <issue_number>
#   ./gh-comment.sh <owner/repo> <issue_number> -f <file>
#   ./gh-comment.sh <owner/repo> <issue_number> -p "/ai-develop-preview" <<< "评论"
#
# 选项:
#   -f <file>     从文件读取评论内容（默认从 stdin）
#   -p <prefix>   评论前缀命令，如 "/ai-develop-preview"（自动追加空格）
#   -d            仅预览不发布（dry-run）
# =========================================================================
set -uo pipefail

TOKEN="${GH_COMMENT_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.gh-token" ]; then
  TOKEN="$(cat "$HOME/.gh-token")"
fi
: "${TOKEN:?请设置 GH_TOKEN 环境变量或创建 ~/.gh-token 文件}"

REPO="${1:?用法: $0 <owner/repo> <issue_number> [-f file] [-p prefix] [-d]}"
shift
ISSUE="${1:?用法: $0 <owner/repo> <issue_number> [-f file] [-p prefix] [-d]}"
shift

PREFIX=""
BODY_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PREFIX="$2"; shift 2 ;;
    -f) BODY_FILE="$2"; shift 2 ;;
    -d) DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

# 读取正文
if [ -n "$BODY_FILE" ]; then
  BODY="$(cat "$BODY_FILE")"
else
  BODY="$(cat)"
fi

# 组装完整评论（前缀 + 空行 + 正文）
if [ -n "$PREFIX" ]; then
  COMMENT="$(printf '%s\n\n%s' "$PREFIX" "$BODY")"
else
  COMMENT="${BODY}"
fi

# 预览
echo "═══ 评论预览 ═══"
echo "目标: https://github.com/${REPO}/issues/${ISSUE}"
echo "前缀: ${PREFIX:-（无）}"
echo "---"
echo -e "$COMMENT"
echo "---"

if $DRY_RUN; then
  echo "[dry-run] 取消发布"
  exit 0
fi

# 发布（使用 python3 正确编码 JSON）
URL="https://api.github.com/repos/${REPO}/issues/${ISSUE}/comments"

RESULT=$(python3 -c "
import json, sys, urllib.request

body = sys.stdin.read()
data = json.dumps({'body': body}).encode('utf-8')
req = urllib.request.Request(
    '${URL}',
    data=data,
    headers={
        'Authorization': 'token ${TOKEN}',
        'Accept': 'application/vnd.github+json',
        'Content-Type': 'application/json; charset=utf-8'
    },
    method='POST'
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = json.loads(resp.read())
        print(result.get('html_url', 'UNKNOWN'))
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" <<< "$COMMENT" 2>/dev/null)

if [ $? -eq 0 ] && [ -n "$RESULT" ]; then
  echo "已发布: $RESULT"
else
  echo "发布失败"
  exit 1
fi
