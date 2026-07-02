#!/usr/bin/env bash
# gh-issue.sh —— GitHub Issue 查询工具
# =========================================================================
# 用法:
#   ./gh-issue.sh get <owner/repo> <issue_number>    查看 issue 详情 + 评论
#   ./gh-issue.sh comments <owner/repo> <issue_number> 仅看评论
#   ./gh-issue.sh watch <owner/repo> <issue_number>   实时监控新评论/变更
#
# Token 优先级: 环境变量 GH_COMMENT_TOKEN > GH_TOKEN > ~/.gh-token 文件
#
# 输出缓存: ~/.gh-issue-cache/<repo>-<num>.json
#   后续调用自动跳过已见评论，只展示增量
# =========================================================================
set -uo pipefail

TOKEN="${GH_COMMENT_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.gh-token" ]; then
  TOKEN="$(cat "$HOME/.gh-token")"
elif [ -z "$TOKEN" ] && [ -f "$HOME/.config/gh/hosts.yml" ]; then
  TOKEN="$(python3 -c "
import yaml,sys
try:
  with open('$HOME/.config/gh/hosts.yml') as f:
    c=yaml.safe_load(f)
  print(c.get('github.com',{}).get('oauth_token','') or '')
except: print('')" 2>/dev/null)"
fi
: "${TOKEN:?请设置 GH_TOKEN 环境变量或创建 ~/.gh-token 文件}"

CACHE_DIR="${HOME}/.gh-issue-cache"
mkdir -p "$CACHE_DIR"

api() {
  curl -s --max-time 30 -H "Authorization: token ${TOKEN}" -H "Accept: application/vnd.github+json" "$@"
}

# ────────── get: 查看 issue 详情 + 评论 ──────────
cmd_get() {
  local repo="$1" num="$2"
  echo "═══ Issue #${num} ═══"
  api "https://api.github.com/repos/${repo}/issues/${num}" | python3 -c "
import json,sys
try:
    i=json.load(sys.stdin)
    print(f'标题: {i[\"title\"]}')
    print(f'状态: {i[\"state\"]}  ·  创建者: @{i[\"user\"][\"login\"]}  ·  创建时间: {i[\"created_at\"][:16]}')
    labels=[l['name'] for l in i.get('labels',[])]
    print(f'标签: {\", \".join(labels) if labels else \"(无)\"}')
    print(f'评论数: {i[\"comments\"]}')
    print()
    body=i.get('body','(无正文)')
    if len(body)>3000:
        print(body[:3000])
        print(f'\n... 正文过长({len(body)}字符)，已截断')
    else:
        print(body)
except Exception as e:
    print(f'解析失败: {e}')
    print(sys.stdin.read()[:500])
"

  echo ""
  echo "═══ 评论 (最近) ═══"
  cmd_comments "$repo" "$num"
}

# ────────── comments: 仅看评论（增量） ──────────
cmd_comments() {
  local repo="$1" num="$2"
  local cache_file="${CACHE_DIR}/${repo//\//-}-${num}.json"
  local last_id=0
  if [ -f "$cache_file" ]; then
    last_id=$(python3 -c "import json; d=json.load(open('$cache_file')); print(max([c['id'] for c in d]) if d else 0)" 2>/dev/null || echo 0)
  fi

  local page=1 new_found=0 all_comments="["
  while true; do
    local resp
    resp="$(api "https://api.github.com/repos/${repo}/issues/${num}/comments?per_page=100&page=${page}&sort=created&direction=asc")"
    local count
    count=$(echo "$resp" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    [ "$count" = "0" ] && break

    python3 - "$resp" "$last_id" <<'PY'
import json, sys
resp = sys.argv[1]
last_id = int(sys.argv[2]) if len(sys.argv) > 2 else 0
comments = json.loads(resp) if resp.strip() else []
new = [c for c in comments if c['id'] > last_id]
for c in new:
    body = c['body'].replace('\r','')
    lines = body.split('\n')
    preview = lines[0][:100] if lines else ''
    more = f' (+{len(lines)-1}行)' if len(lines)>1 else ''
    print(f"--- @{c['user']['login']} {c['created_at'][:16]} ---")
    print(f"    {preview}{more}")
    if len(lines) > 1 and len(body) < 2000:
        for ln in lines[1:8]:
            print(f"    {ln[:120]}")
        if len(lines) > 8:
            print(f"    ... ({len(lines)-8} more lines)")
    print()
PY
    page=$((page + 1))
  done

  # 更新缓存
  local all
  all="$(api "https://api.github.com/repos/${repo}/issues/${num}/comments?per_page=100&sort=created&direction=asc&page=1")"
  echo "$all" | python3 -c "import json,sys; d=json.load(sys.stdin); json.dump(d, open('${cache_file}','w')); print(f'缓存已更新 ({len(d)} 条评论)')" 2>/dev/null
}

# ────────── watch: 监控新评论 ──────────
cmd_watch() {
  local repo="$1" num="$2"
  echo "📡 监控 Issue #${num}，每 60s 检查一次，Ctrl+C 退出"
  local round=0
  while true; do
    round=$((round + 1))
    echo ""
    echo "──── 第 ${round} 轮 ($(date '+%H:%M:%S')) ────"

    # 检查 issue 状态变化
    local state
    state=$(api "https://api.github.com/repos/${repo}/issues/${num}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state','?'))" 2>/dev/null)
    echo "  状态: ${state}"

    # 增量评论
    local cache_file="${CACHE_DIR}/${repo//\//-}-${num}.json"
    local last_id=0
    if [ -f "$cache_file" ]; then
      last_id=$(python3 -c "import json; d=json.load(open('$cache_file')); print(max([c['id'] for c in d]) if d else 0)" 2>/dev/null || echo 0)
    fi
    local resp
    resp=$(api "https://api.github.com/repos/${repo}/issues/${num}/comments?per_page=5&sort=created&direction=desc")
    local new_ids
    new_ids=$(echo "$resp" | python3 -c "import json,sys; cs=json.load(sys.stdin); print(','.join(str(c['id']) for c in cs if c['id']>$last_id))" 2>/dev/null)
    if [ -n "$new_ids" ]; then
      echo "  🆕 新评论 ID: $new_ids"
      # 重新获取全量并缓存
      local all
      all=$(api "https://api.github.com/repos/${repo}/issues/${num}/comments?per_page=100&page=1&sort=created&direction=asc")
      echo "$all" | python3 -c "import json,sys; json.dump(json.load(sys.stdin), open('${cache_file}','w'))" 2>/dev/null
    else
      echo "  (无新评论)"
    fi

    sleep 60
  done
}

# ────────── main ──────────
CMD="${1:-}"
REPO="${2:-}"
NUM="${3:-}"

case "$CMD" in
  get)
    : "${REPO:?用法: $0 get <owner/repo> <issue_number>}"
    : "${NUM:?用法: $0 get <owner/repo> <issue_number>}"
    cmd_get "$REPO" "$NUM"
    ;;
  comments)
    : "${REPO:?用法: $0 comments <owner/repo> <issue_number>}"
    : "${NUM:?用法: $0 comments <owner/repo> <issue_number>}"
    cmd_comments "$REPO" "$NUM"
    ;;
  watch)
    : "${REPO:?用法: $0 watch <owner/repo> <issue_number>}"
    : "${NUM:?用法: $0 watch <owner/repo> <issue_number>}"
    cmd_watch "$REPO" "$NUM"
    ;;
  *)
    echo "用法:"
    echo "  $0 get       <owner/repo> <issue_number>  查看 issue 详情 + 评论"
    echo "  $0 comments  <owner/repo> <issue_number>  仅看评论（增量）"
    echo "  $0 watch     <owner/repo> <issue_number>  实时监控新评论"
    echo ""
    echo "Token: 设置 GH_TOKEN 环境变量或创建 ~/.gh-token 文件"
    ;;
esac
