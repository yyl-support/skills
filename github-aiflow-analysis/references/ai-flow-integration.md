# ai-flow 如何串联整个 opensourceways 代码组织

> 分析仓库：`opensourceways/backlog`（私有）
> 关联文档：`backlog-architecture.md` + `backlog-ai-flow-commands.md` + 基础设施全系列分析

## 一、ai-flow 是什么

`ai-flow` 是 `backlog` 仓库中的 **AI 驱动的全自动软件开发流水线操作系统**。它不是传统 CI/CD，而是一个以 **GitHub Issue 为入口、AI Agent 为执行器、K8s 为运行环境** 的端到端自动化平台。

## 二、全组织串联全景图

```
                         用户创建 Issue / 打上 project:xxx 标签
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        backlog (平台类)                                  │
│                                                                         │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐     │
│  │ command-router   │───→│ resolve_service  │───→│  orchestrate.sh │     │
│  │ 监听 Issue 评论   │    │ 路由匹配服务配置  │    │ 编排 AI Agent    │     │
│  └─────────────────┘    └───────┬─────────┘    └────────┬────────┘     │
│                                 │                        │             │
│                                 ▼                        │             │
│                    ┌──────────────────────┐              │             │
│                    │  services/*.yaml     │              │             │
│                    │  (19个服务配置)       │◄─────────────┘             │
│                    │  meeting-server.yaml │                            │
│                    │  robot.yaml          │                            │
│                    │  calculator.yaml     │                            │
│                    └──────────┬───────────┘                            │
└───────────────────────────────┼────────────────────────────────────────┘
                                │
          ┌─────────────────────┼─────────────────────────┐
          │                     │                         │
          ▼                     ▼                         ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────────┐
│  infrastructure  │  │   infra-common   │  │ 各业务服务仓库             │
│  (基础设施类)     │  │  (基础设施类)     │  │                          │
│                  │  │                  │  │ ┌──────────────────────┐ │
│  service.md      │  │  kustomize/helm  │  │ │ forum-reply-robot    │ │
│  (服务档案总表)   │  │  (部署 YAML)     │  │ │ (机器人类)            │ │
│                  │  │                  │  │ └──────────────────────┘ │
│  Vault Path      │  │  部署归档子路径   │  │                          │
│  Vault Key       │  │                  │  │ ┌──────────────────────┐ │
│                  │  │                  │  │ │ meeting-server       │ │
└────────┬─────────┘  └────────┬─────────┘  │ │ (会议服务类)          │ │
         │                     │            │ └──────────────────────┘ │
         │                     │            │                          │
         ▼                     ▼            │ ┌──────────────────────┐ │
  ┌──────────────┐    ┌─────────────────┐   │ │ calculator           │ │
  │    Vault     │    │   K8s Clusters  │   │ │ (中台类)             │ │
  │  (密码保险柜) │    │                 │   │ └──────────────────────┘ │
  │              │    │  预览/测试/生产  │   │                          │
  │  DB密码      │    │  三个集群        │   │ ┌──────────────────────┐ │
  │  API Key     │    │                 │   │ │ 其他微服务...         │ │
  │  SSL 证书    │    │  PostgreSQL底座  │   │ │ (搜索/平台/中间件)    │ │
  └──────────────┘    │  Harbor/SWR镜像  │   │ └──────────────────────┘ │
                      └────────┬────────┘   └──────────────────────────┘
                               │
                               ▼
                      ┌──────────────────┐
                      │  业务服务 Pod     │
                      │  (运行时)         │
                      │                  │
                      │ forum-reply-robot│
                      │ meeting-server   │
                      │ calculator       │
                      │ ...              │
                      └────────┬─────────┘
                               │
                ┌──────────────┼──────────────┐
                │              │              │
                ▼              ▼              ▼
         ┌───────────┐  ┌───────────┐  ┌───────────┐
         │   cora    │  │int-tests  │  │  trivy    │
         │ (CLI工具)  │  │(集成测试)  │  │(安全扫描)  │
         └───────────┘  └───────────┘  └───────────┘
```

## 三、逐阶段串联流程

### 阶段 1：需求入口 — 分类 & 路由

```
用户操作：在 Issue 评论 /ai-develop-preview
         或给 Issue 打 project:forum-reply-robot 标签
         ↓
backlog/command-router.yml
  → 正则匹配 issue_comment.created 事件
  → 调用 gh workflow run 分发到下游 workflow
         ↓
backlog/scripts/resolve_service.py
  → 遍历 .ai-flow/services/*.yaml (19 个服务配置)
  → 按 Issue label → service.label 匹配
  → 输出环境变量 (REPO/ORG/UMBRELLA/CLUSTER/NAMESPACE)
  → 注入 $GITHUB_ENV 供后续步骤使用
```

**串联的代码组织**：
- `backlog/.ai-flow/services/` 目录包含了所有业务仓库的接入配置
- 每个 YAML 指向一个具体的 umbrella/service 仓库

### 阶段 2：AI Agent 编排 — 自动开发

```
orchestrate.sh (1458 行 Shell)
  → 入参来自 resolve_service.py 输出的环境变量
  → prime_branches(): 检出/创建功能分支
  → 按 PHASE (preview/submit) 编排 AI Agent
         ↓
  ┌─────────────────────────────────────────────────────┐
  │ Agent 序列 (每个 Agent 操作对应的业务仓库):          │
  │                                                     │
  │ ① design Agent  → 产出设计文档到 umbrella 仓         │
  │ ② dev Agent     → 按 design.md 修改 umbrella 仓代码  │
  │ ③ deploy        → K8s 预览部署 (见阶段 3)            │
  │ ④ tester Agent  → 冒烟测试                           │
  │ ⑤ review Agent  → 门禁检查 + 代码评审                │
  │ ⑥ 开代码 PR     → umbrella 仓创建 PR                │
  └─────────────────────────────────────────────────────┘
```

**串联的代码组织**：
- Agent 的 **角色提示词** 来自独立 spec 仓 `agent-development-specification`
- Agent 的 **操作技能** 来自 `agent-skills` 仓库
- AI CLI 工具：OpenCode / Claude Code

### 阶段 3：预览部署 — K8s + Vault + 基础设施

这是 ai-flow 与基础设施仓库**交联最密集**的阶段：

```
backlog deploy.sh
  → 探测 umbrella 仓是否有 .ai-flow/deploy/preview.sh
  → 如果有 → 完全交权给 umbrella 自己处理
  → 如果没有 → 使用默认 runtime-clone 模式

= = = 以 forum-reply-robot 为例（完全交权模式） = = =

umbrella 仓: forum-reply-robot/.ai-flow/deploy/preview.sh
  → 创建 K8s namespace
  → 确保底座 PostgreSQL (跨 Issue 复用)
  → 枚举有改动的子仓
  → 对每个子仓调用 sync.sh

sync.sh (Vault 处理核心):
  ① curl → 拉取 infrastructure/service.md
  ② 按 (REPO, "test") 匹配行 → 取出 Vault Path
  ③ userpass 登录 Vault
  ④ curl → 读 Vault Path 下的配置
  ⑤ Python 解析 JSON → 改写为预览形态:
     - DB 连接 → 指向底座 PostgreSQL
     - 域名 → .test.osinfra.cn → .preview.test.osinfra.cn
     - API Key → 使用测试环境凭证
  ⑥ kubectl create secret → 烘成 k8s Secret
  ⑦ 渲染 Deployment + Service + Ingress
  ⑧ kubectl apply + rollout status
```

**串联的代码组织**：
| 步骤 | 操作的仓库 | 说明 |
|------|-----------|------|
| 拉取 service.md | `infrastructure` 或 `infra-common` | 查服务的 Vault 路径和部署信息 |
| 登录 Vault | `infrastructure/Vault` | 取真实配置 |
| 读取配置 | Vault 中的特定 Path | DB 密码、API Key、证书等 |
| 烘 Secret | 动态生成到 K8s | 预览环境专属的配置 |
| 渲染 Deployment | `infra-common` 的 YAML 模板 | 基于 test 环境配置改写 |

### 阶段 4：门禁 & 测试

```
gates/run.sh
  → 7 项检查（Gitleaks/设计文档/漏洞扫描/安全编码/License/镜像/UT）
  → 自动修复循环 (≤ MAX_FIX_ROUNDS)
  → security-gate 预跑 (开 PR 前)

tests/run_layered.sh
  → 按语言自动探测: go test / pytest / vitest
  → 对每个改动子仓执行 UT

integration-tests (独立仓库)
  → services/meeting-server/ 的专业测试用例
  → run_all.sh 调用 meeting-server 的 API
```

**串联的代码组织**：
- 门禁在 umbrella 仓代码上运行
- `integration-tests` 是独立仓库，存放跨仓测试用例

### 阶段 5：发布上线

```
workflow-deploy-test (Phase C)
  → 构建 Docker 镜像
  → 推到华为云 SWR (Harbor)
  → 改 GitOps 仓的镜像 tag:
    infra-common 的 kustomize YAML 或 helm values.yaml
  → ArgoCD 自动检测变更 → 同步到 K8s 集群
  → 集成测试
```

## 四、核心串联机制总结

### ai-flow 作为"操作系统"的六层串联

```
Layer 1: 事件监听     command-router.yml
   │     监听 GitHub Issue 事件 (评论/标签/创建)
   │
Layer 2: 服务路由     resolve_service.py + services/*.yaml
   │     将 Issue 映射到具体的业务仓库和部署集群
   │
Layer 3: Agent 编排   orchestrate.sh (design/dev/review/tester)
   │     AI 自动完成需求→设计→开发→测试的闭环
   │
Layer 4: 基础设施集成  sync.sh + deploy.sh
   │     读取 infrastructure(service.md) → Vault → K8s → 部署
   │
Layer 5: 质量保障     gates/ + tests/ + integration-tests
   │     门禁检查 + 单元测试 + 集成测试 + 安全扫描
   │
Layer 6: 发布交付     ArgoCD + SWR + infra-common
         镜像构建 → GitOps 归档 → 自动同步 → 上线
```

### 全组织仓库依赖关系（强依赖链路）

```
backlog
 ├── .ai-flow/services/*.yaml  ──→ 注册所有业务仓库
 ├── orchestrate.sh           ──→ 操作各业务仓库代码
 ├── deploy.sh/sync.sh        ──→ 读取 infrastructure + infra-common
 └── gates/tests               ──→ 运行在业务仓库代码上
      │
      ├── infrastructure/service.md  ← 被 sync.sh 读取
      │   └── 指向 Vault Path
      │
      ├── infra-common/kustomize/*   ← 被 deploy.sh 使用
      │   └── 部署到 K8s
      │
      ├── agent-skills               ← 被 AI Agent 加载
      │   └── 提供操作技能
      │
      └── integration-tests          ← 被 tester/CI 调用
          └── 验证服务功能
```

### 一句话总结

**ai-flow 是 opensourceways 组织的"CIO（首席基础设施官）"** — 它不写业务代码，但通过 `services/*.yaml` 知道所有服务在哪、通过 `infrastructure/service.md` 知道如何部署它们、通过 Vault 拿到它们的密码、通过 AI Agent 替它们写代码，最终通过 K8s + ArgoCD 把它们送上生产环境。
