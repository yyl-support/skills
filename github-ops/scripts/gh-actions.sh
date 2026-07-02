#!/usr/bin/env bash
# gh-actions.sh —— GitHub Actions 运行日志查询工具
# =========================================================================
# 用法:
#   ./gh-actions.sh log <repo> <job_id> [lines]    查看 job 日志（默认尾500行）
#   ./gh-actions.sh log <repo> <job_id> all         查看完整日志
#   ./gh-actions.sh log <repo> <job_id> 50:200      查看第50-200行
#   ./gh-actions.sh runs <repo> [count]             列出最近 N 个 workflow runs
#   ./gh-actions.sh job <repo> <run_id>             列出一个 run 的所有 jobs
#
# 输出缓存: ~/.gh-actions-cache/<repo>/<job_id>.log
# =========================================================================
set -uo pipefail

TOKEN="${GH_COMMENT_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.gh-token" ]; then
  TOKEN="$(cat "$HOME/.gh-token")"
fi
: "${TOKEN:?请设置 GH_TOKEN 环境变量或创建 ~/.gh-token 文件}"

CACHE_DIR="${HOME}/.gh-actions-cache"
mkdir -p "$CACHE_DIR"

api() {
  curl -sL --max-time 30 -H "Authorization: token ${TOKEN}" -H "Accept: application/vnd.github+json" "$@"
}

# ────────── 下载日志到缓存 ──────────
_fetch_log() {
  local repo="$1" job_id="$2"
  local cache_dir="${CACHE_DIR}/${repo//\//-}"
  mkdir -p "$cache_dir"
  local cache_file="${cache_dir}/${job_id}.log"
  if [ -f "$cache_file" ] && [ "$(stat -f%z "$cache_file" 2>/dev/null || stat -c%s "$cache_file" 2>/dev/null || echo 0)" -gt 100 ]; then
    echo "$cache_file"
    return
  fi
  api "https://api.github.com/repos/${repo}/actions/jobs/${job_id}/logs" -o "$cache_file" 2>/dev/null
  echo "$cache_file"
}

# ────────── log: 查看 job 日志 ──────────
cmd_log() {
  local repo="$1" job_id="$2" range="${3:-500}"

  echo "── 获取 Job #${job_id} 日志 ──"
  local log_file
  log_file="$(_fetch_log "$repo" "$job_id")"
  if [ ! -s "$log_file" ]; then
    echo "日志为空或获取失败"
    return 1
  fi

  local total
  total=$(wc -l < "$log_file" | tr -d ' ')
  echo "总行数: ${total}"

  if [ "$range" = "all" ]; then
    cat "$log_file"
  elif [[ "$range" =~ ^([0-9]+):([0-9]+)$ ]]; then
    local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
    sed -n "${start},${end}p" "$log_file"
    echo ""
    echo "── 显示 ${start}-${end} / 共 ${total} 行 ──"
  else
    tail -n "$range" "$log_file"
    echo ""
    echo "── 最后 ${range} / 共 ${total} 行 ──"
  fi
}

# ────────── runs: 列出最近 workflow runs ──────────
cmd_runs() {
  local repo="$1" count="${2:-10}"
  api "https://api.github.com/repos/${repo}/actions/runs?per_page=${count}" | python3 -c "
import json,sys
runs = json.load(sys.stdin).get('workflow_runs', [])
for r in runs:
    icon = '✅' if r['conclusion'] == 'success' else '❌' if r['conclusion'] == 'failure' else '🟡'
    print(f\"{icon} #{r['id']} {r['name'][:60]}  ({r['status']}/{r.get('conclusion','?')})  {r['created_at'][:16]}\")
" 2>/dev/null
}

# ────────── job: 列出 run 的 jobs ──────────
cmd_job() {
  local repo="$1" run_id="$2"
  api "https://api.github.com/repos/${repo}/actions/runs/${run_id}/jobs?per_page=30" | python3 -c "
import json,sys
jobs = json.load(sys.stdin).get('jobs', [])
for j in jobs:
    icon = '✅' if j['conclusion'] == 'success' else '❌' if j['conclusion'] == 'failure' else '🟡'
    print(f\"{icon} #{j['id']} {j['name'][:50]}  ({j['status']}/{j.get('conclusion','?')})  {j.get('started_at','?')[:16]}\")
" 2>/dev/null
}

# ────────── main ──────────
CMD="${1:-}"
REPO="${2:-}"
ARG="${3:-}"
ARG2="${4:-}"

case "$CMD" in
  log)
    : "${REPO:?用法: $0 log <repo> <job_id> [lines|all|start:end]}"
    : "${ARG:?用法: $0 log <repo> <job_id> [lines|all|start:end]}"
    cmd_log "$REPO" "$ARG" "${ARG2:-500}"
    ;;
  runs)
    : "${REPO:?用法: $0 runs <repo> [count]}"
    cmd_runs "$REPO" "${ARG:-10}"
    ;;
  job|jobs)
    : "${REPO:?用法: $0 job <repo> <run_id>}"
    : "${ARG:?用法: $0 job <repo> <run_id>}"
    cmd_job "$REPO" "$ARG"
    ;;
  *)
    echo "用法:"
    echo "  $0 log   <repo> <job_id> [lines|all|start:end]  查看 job 日志"
    echo "  $0 runs  <repo> [count]                         列出最近 workflow runs"
    echo "  $0 job   <repo> <run_id>                        列出一个 run 的所有 jobs"
    echo ""
    echo "日志缓存: ~/.gh-actions-cache/"
    ;;
esac
