#!/usr/bin/env bash
# gh-log-errors.sh —— 从缓存的 Action 日志中提取错误行及上下文
# =========================================================================
# 用法:
#   ./gh-log-errors.sh <repo> <job_id>          直接从缓存提取错误
#   ./gh-log-errors.sh -f <log_file>            指定日志文件
#   ./gh-log-errors.sh -c <context_lines> ...   自定义上下文行数（默认 5）
# =========================================================================
set -uo pipefail

CONTEXT=5
LOG_FILE=""
REPO=""
JOB_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONTEXT="$2"; shift 2 ;;
    -f) LOG_FILE="$2"; shift 2 ;;
    *)  [ -z "$REPO" ] && REPO="$1" || JOB_ID="$1"; shift ;;
  esac
done

if [ -z "$LOG_FILE" ] && [ -n "$REPO" ] && [ -n "$JOB_ID" ]; then
  CACHE_DIR="${HOME}/.gh-actions-cache"
  LOG_FILE="${CACHE_DIR}/${REPO//\//-}/${JOB_ID}.log"
fi

if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
  echo "用法: $0 [-c context_lines] [-f log_file] [repo job_id]"
  echo ""
  echo "日志文件不存在: ${LOG_FILE:-未指定}"
  echo "请先执行 gh-actions.sh log 下载日志到缓存"
  exit 1
fi

# 错误关键词模式（大小写不敏感）
PATTERNS=(
  "error"
  "fail(ure|ed)?"
  "fatal"
  "panic"
  "exception"
  "traceback"
  "abort(ed|ing)?"
  "timeout"
  "killed"
  "signal"
  "segfault|segmentation fault"
  "cannot|can't"
  "not found"
  "denied"
  "missing"
  "invalid"
  "unexpected"
  "unknown"
  "refused"
  "unreachable"
  "certificate"
  "unauthorized"
)

# 构建 grep 正则
REGEX=""
for p in "${PATTERNS[@]}"; do
  [ -n "$REGEX" ] && REGEX="${REGEX}|"
  REGEX="${REGEX}(${p})"
done

# 先找所有匹配行号
MATCH_LINES=$(grep -inE "$REGEX" "$LOG_FILE" 2>/dev/null | cut -d: -f1 | sort -nu)

if [ -z "$MATCH_LINES" ]; then
  echo "未发现错误相关关键词"
  exit 0
fi

TOTAL=$(wc -l < "$LOG_FILE" | tr -d ' ')
HALF=$((CONTEXT / 2))

# 合并相邻的匹配区间
echo "═══ 错误日志提取 ═══"
echo "文件: $LOG_FILE"
echo "总行数: $TOTAL"
echo "匹配行数: $(echo "$MATCH_LINES" | wc -l | tr -d ' ')"
echo "上下文行数: ±${HALF}"
echo ""

# 用 awk 提取每个匹配块并去重合并
awk -v context="$HALF" -v total="$TOTAL" -v patterns="$REGEX" '
BEGIN {
  IGNORECASE = 1
}
{
  line = $0
  if (line ~ patterns) {
    start = NR - context
    if (start < 1) start = 1
    end = NR + context
    if (end > total) end = total
    blocks[++block_count] = start ":" end
  }
}
END {
  if (block_count == 0) exit

  # 合并重叠区间
  n = 1
  split(blocks[1], range, ":")
  merged_start = range[1]
  merged_end = range[2]

  for (i = 2; i <= block_count; i++) {
    split(blocks[i], range, ":")
    if (range[1] <= merged_end + 1) {
      # 重叠或相邻，合并
      if (range[2] > merged_end) merged_end = range[2]
    } else {
      # 不重叠，输出前一个块
      print merged_start "," merged_end
      merged_start = range[1]
      merged_end = range[2]
    }
  }
  print merged_start "," merged_end
}
' "$LOG_FILE" | while IFS=',' read -r start end; do
  echo "──── 行 ${start}-${end} ────"
  sed -n "${start},${end}p" "$LOG_FILE"
  echo ""
done

rm -f "$tmp"
