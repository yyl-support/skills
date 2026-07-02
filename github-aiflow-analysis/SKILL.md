# GitHub AI Flow Analyzer

用户扔一个 GitHub 链接，自动抓取、分析、诊断、归档。专注 **Issue 分析** 和 **CI 日志诊断**。

---

## 基于第一性原理

本 Skill 的本质是对 **GitHub URL** 执行四个原子操作：

```
GitHub URL → [1] 获取数据 → [2] 模式匹配 → [3] 执行操作 → [4] 归档知识
```

| 原子操作 | 含义 | 实现 |
|---------|------|------|
| **获取数据** | 从 GitHub API 拉取 Issue/评论/日志 | `github-ops/scripts/` (数据层 skill) |
| **模式匹配** | 将症状对号入座到已知根因模式 | 见下方「失败模式匹配」 |
| **执行操作** | 按用户意图评论/提 PR | `github-ops/scripts/gh-comment.sh`, git commit + PR |
| **归档知识** | 将分析结果持久化到 Obsidian | `write` to `/Users/gorden/LLM/Obsidian/knowledgeBase/` |

**核心原则**：
- 数据获取委托 [github-ops](../github-ops/SKILL.md) skill，本 skill 不直接操作 GitHub API
- 先匹配已知模式，再推理未知根因
- 日志分析不是 grep error，而是追溯全链路（YAML → 探针 → Pod → Runner）
- 评论和 PR 操作必须经用户确认，禁止自动执行

---

## 身份约定

| 项 | 值 |
|----|-----|
| **GitHub 用户名** | `yyl-support` |
| **Git 提交邮箱** | `1275703733@qq.com` |
| **PR 提交流程** | clone → branch → commit（用上述身份）→ push → 创建 PR |

所有 git 操作必须使用：
```bash
git -c user.name="yyl-support" -c user.email="1275703733@qq.com" commit ...
```

---

## 输入识别：URL → 管线路由

拿到 GitHub URL 后，首先按以下决策树分类：

```
用户给的链接
├─ 是 Issue/PR URL？
│   ├─ 用户要求「分析」→ 管线 A：Issue 分析
│   ├─ 用户要求「找 CI」→ 管线 C：从 Issue 找 Run → 再走管线 B
│   └─ 用户要求「评论」→ 管线 D：发布评论
├─ 是 Actions Run/Job URL？
│   └─ → 管线 B：CI 日志分析
└─ 用户要求「提 PR 修复」→ 管线 E：提交修复 PR
```

**管线速查**：

| 管线 | 输入 | 产出 | 归档 |
|------|------|------|------|
| **A - Issue 分析** | Issue/PR 链接 | 正文+评论摘要 | `other/` |
| **B - CI 日志分析** | Actions Run/Job 链接 | 错误根因分析 | `error/` |
| **C - 从 Issue 找 Run** | Issue 链接 | 最新 Run 链接 | 继续走管线 B |
| **D - 发布评论** | Issue 链接 + 内容 | 评论发布 | **先预览 → 用户确认 → 再发布** |
| **E - 提交修复 PR** | 修改代码 | PR 提交 | **先展示 diff → 用户确认 → 再提交** |

---

## 数据获取（委托 github-ops）

本 Skill 不直接调用 GitHub API。所有数据获取通过 `github-ops/scripts/` 完成：

```bash
# Issue 查询
bash github-ops/scripts/gh-issue.sh get <owner/repo> <issue_number>

# CI 日志
bash github-ops/scripts/gh-actions.sh runs <owner/repo> [count]
bash github-ops/scripts/gh-actions.sh job <owner/repo> <run_id>
bash github-ops/scripts/gh-actions.sh log <owner/repo> <job_id> all

# 日志错误提取
bash github-ops/scripts/gh-log-errors.sh <owner/repo> <job_id>

# 从 Issue 找 CI Run
bash github-ops/scripts/gh-find-run.sh <owner/repo> <issue_number>
bash github-ops/scripts/gh-find-run.sh <owner/repo> <issue_number> -j

# 发布评论
echo "评论内容" | bash github-ops/scripts/gh-comment.sh <owner/repo> <issue_number> -p "/ai-xxx"
```

> 详细用法见 [github-ops SKILL.md](../github-ops/SKILL.md)

---

## 核心：失败模式匹配

分析 CI 日志时，**先把症状匹配到已知模式**，而不是从零推理。

### K8s 探针时间窗口（所有部署问题的基础）

```
progressDeadlineSeconds          ← "天花板"，Deployment 最长等待
    >  initialDelaySeconds + failureThreshold × periodSeconds   ← "探针级容忍"
    >  kubectl rollout status --timeout                        ← "客户端超时"
```

三者必须满足 `progressDeadlineSeconds > 探针容忍 > rollback timeout`，否则出现「已经挂了但还在等」。

### 已知根因模式表

| 模式 | 症状 | 根因 | 修复方向 |
|------|------|------|---------|
| **探针时序错位** | Pod 持续 CrashLoopBackOff | `initialDelaySeconds` < 实际启动时间 | 增大 `initialDelaySeconds` |
| **时间窗口冲突** | Deployment 超时但 Pod 已 Running | `progressDeadlineSeconds` 太小或被中间层截断 | 检查三者不等式关系 |
| **heredoc 转义丢失** | `unbound variable` 在 YAML 生成阶段 | `\$(...)` 反斜杠被误删，`set -u` 下崩溃 | 源文件补回 `\` 转义 |
| **Runner OOM/超时** | 47min+ 后 `Executing ... failed` | self-hosted runner 资源耗尽 | 检查 runner 内存/磁盘 |
| **artifact 配额** | 上传失败但业务逻辑通过 | Artifact storage quota hit | 清理旧 artifact 或增大配额 |
| **Vault 认证过期** | 部署段 `403 Forbidden` | userpass token 过期 | 更新 runner Vault token |
| **configmap 未更新** | 修改配置不生效 | Helm 未 reload / ArgoCD sync 未触发 | 强制 restart pod |

### 分析决策链

```
拿到错误日志
  ├─ 有 CrashLoopBackOff / ProbeError？
  │   └─ 进入「K8s 探针时间窗口」分支：比较三个参数
  ├─ 有 "unbound variable"？
  │   └─ 进入「heredoc 转义」分支：读取源文件交叉验证
  ├─ 有 "timeout" / "deadline"？
  │   └─ 进入「时间窗口冲突」分支：检查三个不等式
  ├─ 有 "artifact storage"？
  │   └─ 进入「artifact 配额」分支
  └─ 都不匹配？
      └─ 读取 references/ci-terminology.md + references/ai-flow-architecture.md 重新推理
```

---

## 知识库加载策略

分析前根据问题类型**选读** 1-3 个最相关文档，**不全部加载**：

| 文件 | 内容 | 何时读取 |
|------|------|---------|
| `references/ai-flow-architecture.md` | orchestrate.sh 引擎、三段式工作流 | 首次分析 / 架构问题 / 部署超时 |
| `references/ai-flow-commands.md` | 命令触发、五阶段生命周期 | 命令参数 / 阶段理解 |
| `references/forum-reply-robot-vault.md` | sync.sh Vault 处理链路 | forum-reply-robot 相关 |
| `references/ai-flow-integration.md` | 全组织串联视图 | 跨仓问题 / 全局视角 |
| `references/ci-terminology.md` | K8s 探针参数、CI 术语 | 参数含义 / 部署超时（**必读**） |

**硬规则**：涉及部署超时/探针问题**必须**读 `ci-terminology.md` + `ai-flow-architecture.md`。

---

## 分析诊断流程

1. **获取原始数据**：调用 github-ops 脚本获取 Issue 正文/评论或 CI 日志
2. **匹配已知模式**：对照「失败模式匹配」决策链，定位根因类型
3. **交叉验证源文件**：日志引用的脚本（preview.sh, sync.sh 等）通过 GitHub API 读取实际内容验证
4. **对照知识库**：读取相应的 references/ 文档确认架构理解
5. **输出结论**：按以下格式给出结构化结论：

### 分析输出规范

每次分析结束时，给出：
1. **错误根因**（一句话）
2. **是否与已知模式匹配**
3. **修复建议**（如有）
4. **关联知识**（references/ 文档中的相关章节）

---

## Feedback 生成

分析完成后，根据用户意图生成 feedback 内容。Feedback 是通过 Issue 评论注入给 AI agent 的上下文信息。

### Feedback 类型

| 场景 | feedback 内容 | 前缀命令 |
|------|-------------|---------|
| 首次预览有部署错误 | 详细错误根因 + 建议修复 | `/ai-develop-preview` |
| 设计已定稿仅代码修复 | 具体代码修改建议 | `/ai-develop-preview --skip-design` |
| 仅需重部署即可验证 | 部署参数修正 | `/ai-develop-preview --deploy-only` |
| 门禁失败 | 失败项 + 修复方案 | `/ai-develop-submit` |
| 全部门禁 | 整体通过情况 | `/ai-develop-submit --allgate` |

### Feedback 格式

```
<前缀命令> （独占第一行，命令后自动空格）
这一行开始是正文，描述遇到的问题、根因分析、建议的修复方向。
具体的技术细节可以作为上下文注入给 AI agent。
```

---

## 归档知识

### Issue 分析 → `other/`

路径: `/Users/gorden/LLM/Obsidian/knowledgeBase/other/{yyyy-mm-dd}-{工程名}-issue分析.md`

```markdown
# {工程名} Issue #{num} — {标题}

**链接**: {URL}  **状态**: {open/closed}  **创建者**: @{user}
**标签**: {labels}  **评论数**: {count}

## 正文
{issue body}

## 评论摘要
{逐条评论摘要，标注作者和时间}
```

### CI 日志分析 → `error/`

路径: `/Users/gorden/LLM/Obsidian/knowledgeBase/error/{yyyy-mm-dd}-{工程名}-{错误摘要}.md`

```markdown
# {工程名} — {错误摘要}

**时间**: {日志时间}  **仓库**: {owner/repo}
**Run ID**: {run_id}  **Job ID**: {job_id}  **原始链接**: {URL}

## 错误概览
| # | 类型 | 位置 | 简要描述 |

## 详细分析
### 错误 1: {错误类型}
**原始日志**: ```{关键日志片段}```
**原因分析**: {根因}
**影响范围**: {影响评估}

## 总结
{整体评估 + 修复建议}
```

---

## 执行操作

### D. 发布评论（必须审核）

**绝对禁止直接发布评论。**

1. 根据用户意图确定前缀命令（参考「Feedback 生成」表）
2. 编写评论内容，展示给用户
3. 等用户确认后，通过 github-ops 发布：

```bash
echo "评论正文..." | bash github-ops/scripts/gh-comment.sh <owner/repo> <issue_number> -p "/ai-develop-preview"
```

### E. 提交修复 PR（必须审核）

**绝对禁止未经确认直接提交 PR。**

1. 修改代码，用 `git diff` 展示变更
2. 等用户确认后，commit → push → 创建 PR

```bash
git -c user.name="yyl-support" -c user.email="1275703733@qq.com" \
  commit -m "fix: <提交信息>

<详细说明>

关联: <issue 链接>"
```

---

## 附录 A：AI Flow 关键知识速查

### 五阶段生命周期

```
[1]需求分析 → [2]开发预览 → [3]开发提交 → [4]测试发布 → [5]正式上线
```

### preview 段主循环

```
design → push_design_pr_now → dev → deploy → tester(冒烟) → 回评
```

**关键细节**：每轮都会重新跑 design agent。用户 feedback 会被注入 design agent prompt。如果 feedback 是部署 bug 修复，设计文档会被污染。后续部署修复轮次应使用 `--skip-design`。

### orchestrate.sh 核心机制

- `run_agent(agent)`: 将角色提示词 + 用户 feedback 拼成 prompt 调用 AI CLI
- `prime_branches()`: 检查已有 `issue-N-impl` 分支，增量开发
- `push_design_pr_now()`: 首次创建 `issue-N-impl-design` 分支，已有 open PR 则更新
- `commit_push_branch()`: 分支名纠偏、白名单 add、lockfile 回滚

---

## 附录 B：backlog AI Flow 命令参考

### `/ai-develop-preview` 参数

| 参数 | 行为 | 使用场景 |
|------|------|---------|
| 无参 | 正常预览：设计→开发→部署→冒烟 | 日常预览 |
| `--design` | 只更新设计文档 | 补充设计细节 |
| `--skip-design` | 设计冻结，只开发+预览 | 设计已定稿 |
| `--deploy-only` | 仅重部署，不动设计和代码 | 配置变更后验证 |
| `--pr <URL>` | 部署外部 PR 预览 | 跨仓 PR 预览 |

### 自动触发（无需命令）

| 条件 | 行为 |
|------|------|
| 打 `project:<umbrella>` 标签 | 自动触发需求分析 |
| 打 `accepted` 标签 | 自动触发开发预览 |
| 标题含 `[缺陷]` / `[任务]` | 跳过需求分析，直接开发 |
