# GitHub Ops — GitHub REST API 底层操作

## 定位

本 Skill 提供与 GitHub 交互的**纯数据层操作**：获取 Issue/PR、拉取 CI 日志、发布评论、查找 Actions Run。不涉及任何分析逻辑。

**与其他 Skill 的关系**:

```
github-ops (原子操作层)
    │
    ├──► github-aiflow-analysis (分析层：模式匹配、根因诊断、feedback 生成)
    │
    └──► 其他 Skill (任意需要 GitHub 数据的场景)
```

## 输入识别

本 Skill 不自行决定管道路由。由上层 Skill（如 `github-aiflow-analysis`）决定调用哪个脚本。

| 用户意图 | 调用脚本 |
|----------|---------|
| 想看某个 Issue/PR 内容 | `gh-issue.sh get` |
| 只看 Issue 最新评论 | `gh-issue.sh comments` |
| 监控 Issue 变化 | `gh-issue.sh watch` |
| 查最近 CI Runs | `gh-actions.sh runs` |
| 查某个 Run 的 Jobs | `gh-actions.sh job` |
| 拉取 Job 日志 | `gh-actions.sh log` |
| 从日志提取错误 | `gh-log-errors.sh` |
| 从 Issue 找最新 CI Run | `gh-find-run.sh` |
| 发布评论到 Issue | `gh-comment.sh` |

---

## 脚本速查

### 1. Issue / PR 操作

```bash
# 获取 Issue 详情 + 评论（自动缓存到 ~/.gh-issue-cache/）
bash github-ops/scripts/gh-issue.sh get <owner/repo> <issue_number>

# 仅获取评论（增量，跳过已缓存的旧评论）
bash github-ops/scripts/gh-issue.sh comments <owner/repo> <issue_number>

# 实时监控新评论/状态变更
bash github-ops/scripts/gh-issue.sh watch <owner/repo> <issue_number>
```

**缓存机制**: `~/.gh-issue-cache/<repo>-<num>.json`
- 首次调用：拉取全部数据，缓存到本地
- 后续调用：只展示增量评论，避免重复分析

### 2. CI 日志

```bash
# 列出最近 N 个 workflow runs（默认 20）
bash github-ops/scripts/gh-actions.sh runs <owner/repo> [count]

# 列出某个 run 的所有 jobs
bash github-ops/scripts/gh-actions.sh job <owner/repo> <run_id>

# 获取完整日志（缓存到 ~/.gh-actions-cache/）
bash github-ops/scripts/gh-actions.sh log <owner/repo> <job_id> all

# 获取最后 500 行
bash github-ops/scripts/gh-actions.sh log <owner/repo> <job_id> 500

# 获取指定行范围（第 50-200 行）
bash github-ops/scripts/gh-actions.sh log <owner/repo> <job_id> 50:200
```

**日志缓存**: `~/.gh-actions-cache/<repo>/<job_id>.log`

### 3. 日志错误提取

```bash
# 从缓存的完整日志中自动提取错误行及其上下文
bash github-ops/scripts/gh-log-errors.sh <owner/repo> <job_id>
```

**输出格式**: 每个错误块包含 `=== ERROR #N ===` 分隔符 + 错误行前后各 5 行上下文。

### 4. 从 Issue 查找 CI Run

```bash
# 从 github-actions[bot] 评论中提取最新 Actions Run 链接
bash github-ops/scripts/gh-find-run.sh <owner/repo> <issue_number>

# JSON 格式输出（含 run_id / job_id 便于脚本消费）
bash github-ops/scripts/gh-find-run.sh <owner/repo> <issue_number> -j
```

**工作原理**: 遍历 Issue 评论，找到最新的 `github-actions[bot]` 评论，从其中提取 run URL。

### 5. 发布评论

```bash
# 从 stdin 读取正文发布
echo "评论内容" | bash github-ops/scripts/gh-comment.sh <owner/repo> <issue_number>

# 从文件读取
bash github-ops/scripts/gh-comment.sh <owner/repo> <issue_number> -f comment.txt

# 带前缀命令（如 /ai-develop-preview）
echo "分析反馈" | bash github-ops/scripts/gh-comment.sh <owner/repo> <issue_number> \
  -p "/ai-develop-preview"

# Dry-run 预览（不实际发布）
echo "评论" | bash github-ops/scripts/gh-comment.sh <owner/repo> <issue_number> -d
```

**前缀命令**: `-p "/ai-xxx"` 将命令置于评论首行，与正文以空格分隔。这会被 AI agent 解析为触发指令。

**预览确认流程**:
```
1. 脚本输出完整的评论预览（含 markdown 渲染效果提示）
2. 提示用户确认 (y/N)
3. 确认后才通过 GitHub API 发布
```

---

## Token 优先级

所有脚本使用统一认证逻辑：

1. `GH_COMMENT_TOKEN` 环境变量（优先用于评论操作）
2. `GH_TOKEN` 环境变量
3. `~/.gh-token` 文件（fallback）

```bash
export GH_TOKEN=$(cat ~/.gh-token)  # 一行启用
```

**权限要求**: Token 需对目标仓库有 `repo` 读权限（评论操作需 `repo` 写权限）。

---

## API 端点参考

| 脚本 | 主要 API |
|------|---------|
| `gh-issue.sh` | `GET /repos/{owner}/{repo}/issues/{num}` + `/comments` |
| `gh-actions.sh` | `GET /repos/{owner}/{repo}/actions/runs` + `/jobs/{id}/logs` |
| `gh-find-run.sh` | `GET /repos/{owner}/{repo}/issues/{num}/comments` |
| `gh-comment.sh` | `POST /repos/{owner}/{repo}/issues/{num}/comments` |
| `gh-log-errors.sh` | 本地文件处理（读取缓存日志） |

**通用约定**:
- 所有 API 调用基于 `api.github.com`（非 `github.com`）
- 超时设置: 连接 10s，读取 30s
- 自动重试: 网络错误重试 1 次
