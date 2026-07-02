#!/usr/bin/env bash
# gh-find-run.sh —— 从 GitHub Issue 最新评论中提取 CI Run 链接
# =========================================================================
# 用法:
#   ./gh-find-run.sh <owner/repo> <issue_number>    获取最新一条 CI run 链接
#   ./gh-find-run.sh <owner/repo> <issue_number> -a  列出全部 run 链接
#   ./gh-find-run.sh <owner/repo> <issue_number> -j  输出 JSON（含 run_id/job_id）
# =========================================================================
set -uo pipefail

TOKEN="${GH_COMMENT_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.gh-token" ]; then
  TOKEN="$(cat "$HOME/.gh-token")"
fi
: "${TOKEN:?请设置 GH_TOKEN 环境变量或创建 ~/.gh-token 文件}"

REPO="${1:?用法: $0 <owner/repo> <issue_number> [-a|-j]}"
ISSUE="${2:?用法: $0 <owner/repo> <issue_number> [-a|-j]}"
MODE="${3:-latest}"

api() {
  curl -s --max-time 30 -H "Authorization: token ${TOKEN}" -H "Accept: application/vnd.github+json" "$@"
}

# 获取评论总数
TOTAL=$(api "https://api.github.com/repos/${REPO}/issues/${ISSUE}/comments?per_page=1" \
  | python3 -c "import sys; r=sys.stdin.read(); print(r.split('Link:')[1].split('page=')[-1].split('>')[0] if 'Link:' in r else '1')" 2>/dev/null || echo 1)

# 从后往前翻评论，找 bot 评论中的 run 链接
PAGE="$TOTAL"
FOUND=""
ALL_RUNS=""

while [ "$PAGE" -gt 0 ] && [ -z "$FOUND" ]; do
  RESP=$(api "https://api.github.com/repos/${REPO}/issues/${ISSUE}/comments?per_page=100&page=${PAGE}&sort=created&direction=asc")
  
  # 倒序处理当前页评论
  RUNS=$(echo "$RESP" | python3 -c "
import json, sys, re
try:
    comments = json.load(sys.stdin)
except:
    sys.exit(0)
for c in reversed(comments):
    if c['user']['login'] != 'github-actions[bot]':
        continue
    body = c['body']
    # 匹配 run 链接
    urls = re.findall(r'https://github\.com/[^/\s]+/[^/\s]+/actions/runs/\d+', body)
    for u in urls:
        run_match = re.search(r'/runs/(\d+)', u)
        if run_match:
            print(run_match.group(1) + '|||' + u + '|||' + c['created_at'])
            break
    else:
        continue
    break
" 2>/dev/null)
  
  if [ -n "$RUNS" ]; then
    FOUND="$RUNS"
  fi
  PAGE=$((PAGE - 1))
done

if [ -z "$FOUND" ]; then
  echo "未找到 CI run 链接"
  exit 1
fi

RUN_ID=$(echo "$FOUND" | cut -d'|' -f1)
RUN_URL=$(echo "$FOUND" | cut -d'|' -f2)
RUN_TIME=$(echo "$FOUND" | cut -d'|' -f3)

case "$MODE" in
  -j)
    # 尝试获取该 run 的 job 列表
    JOBS=$(api "https://api.github.com/repos/${REPO}/actions/runs/${RUN_ID}/jobs?per_page=5" \
      | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    jobs = data.get('jobs', [])
    for j in jobs:
        if j.get('status') == 'completed':
            print(json.dumps({
                'run_id': '${RUN_ID}',
                'run_url': '${RUN_URL}',
                'run_time': '${RUN_TIME}',
                'job_id': j['id'],
                'job_name': j['name'],
                'job_url': j['html_url'],
                'conclusion': j.get('conclusion', '?')
            }, ensure_ascii=False))
            break
    else:
        print(json.dumps({
            'run_id': '${RUN_ID}',
            'run_url': '${RUN_URL}',
            'run_time': '${RUN_TIME}',
            'note': 'no completed jobs found'
        }, ensure_ascii=False))
except Exception as e:
    print(json.dumps({'error': str(e), 'run_url': '${RUN_URL}'}, ensure_ascii=False))
" 2>/dev/null)
    echo "$JOBS"
    ;;
  *)
    echo "$RUN_URL"
    ;;
esac
