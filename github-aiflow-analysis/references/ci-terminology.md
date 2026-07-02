# backlog CI 流水线术语解释

---

## 一、Kubernetes Deployment 探针与超时参数

这些参数位于 sync.sh 生成的 Kubernetes Deployment YAML 中，控制 Pod 的生命周期判定。

### 1. readinessProbe（就绪探针）

Kubernetes 用来判断 Pod 是否准备好接收流量的健康检查机制。只有探针通过的 Pod 才会被加入 Service 的负载均衡。

探针类型：
- **tcpSocket**: 仅检查端口是否可连接（TCP 三次握手成功即通过）。不关心应用层逻辑。
- **httpGet**: 向指定路径发 HTTP GET 请求，状态码 2xx/3xx 才算通过。可检查应用层健康。

### 2. readinessProbe.initialDelaySeconds

```
readinessProbe:
  initialDelaySeconds: 30   # 容器启动后等 30 秒再开始探针
```

**含义**：容器启动后，等待多少秒才开始第一次健康检查。

**为什么重要**：容器启动 ≠ 应用就绪。Python Flask 监听端口往往很快（几秒），但后台初始化（如 LightRAG 数据加载、数据库连接池建立）可能需要数分钟甚至数十分钟。如果 initialDelaySeconds 太短，探针会在应用还没准备好时就判定失败。

**典型值**：
- 轻量服务：5-30s
- 有重型初始化：300-600s
- #621/#785 的 forum-reply-robot（LightRAG 全量数据初始化）：原配置 5400s (90min)

### 3. readinessProbe.periodSeconds

```
readinessProbe:
  periodSeconds: 10   # 每 10 秒检查一次
```

**含义**：探针的执行间隔。每隔 N 秒执行一次健康检查。

### 4. readinessProbe.failureThreshold

```
readinessProbe:
  failureThreshold: 30   # 连续失败 30 次后标记为 Unready
```

**含义**：探针连续失败多少次后，Pod 被标记为 Not Ready。

**计算最大容忍时间**：
```
最大容忍时间 = initialDelaySeconds + (failureThreshold × periodSeconds)
```

例如：`initialDelaySeconds: 30, failureThreshold: 30, periodSeconds: 10`
→ 最大容忍 = 30 + 30×10 = 330 秒 ≈ 5.5 分钟

其中 `initialDelaySeconds` 部分是"必等"，`failureThreshold × periodSeconds` 是"追加容忍"。

**超时保护原则**（来自 #621 需求正文）：
> 在与外部 API 交互的全流程中，考虑网络和模型时延影响，都设置 300s 的超时保护

### 5. readinessProbe.timeoutSeconds

```
readinessProbe:
  timeoutSeconds: 5   # 单次探针最多等 5 秒
```

**含义**：单次探针的超时时间。如果探针在此时限内没有响应，算作一次失败。

### 6. progressDeadlineSeconds

```
spec:
  progressDeadlineSeconds: 7200   # Deployment 2 小时内必须 progressing
```

**含义**：Kubernetes 等待 Deployment 取得进展的最长时间。如果在此时间内 Deployment 没有任何进展（如 Pod 一直 CrashLoopBackOff 无法创建出新 Pod），Deployment 会被标记为 "Timed out"。

**与探针的关系**：
```
progressDeadlineSeconds 是"天花板"
initialDelaySeconds + failureThreshold × periodSeconds 是"探针级容忍"
kubectl rollout status --timeout 是"命令行级超时"
```

**约束**：`progressDeadlineSeconds` 必须大于 `initialDelaySeconds + failureThreshold × periodSeconds`，否则 Deployment 可能在 Pod 还没做完健康检查之前就被判超时。

### 7. 三者的时间窗口匹配

这是 B3 规则中强调的常见根因——三个超时必须协调：

```
progressDeadlineSeconds (K8s 平台层)
    > initialDelaySeconds + failureThreshold × periodSeconds (容器层)
        > kubectl rollout status --timeout (CI 命令行层)
```

**反例（#621 的 bug）**：
```
progressDeadlineSeconds: 7200
initialDelaySeconds: 30           ← 太小！
failureThreshold: 60
periodSeconds: 10
→ 容器在 ~630 秒后就被判死 → 持续 CrashLoopBackOff
→ progressDeadlineSeconds 很大但 Pod 一直不 progressing → 无意义等待
→ kubectl rollout status 阻塞 → CI runner 46 分钟后超时崩溃
```

---

## 二、Pod 状态

### CrashLoopBackOff

Pod 的状态。表示容器启动后立即崩溃退出，Kubernetes 不断重启它，但每次重启后依然崩溃。

**常见原因**：
- 应用启动时 import 失败（如 #621 的 `from src.ForumBot.evaluation_timer import EvaluationTimer` 在依赖缺失时崩溃）
- 配置文件缺失（如 vault secrets 未挂载）
- 端口冲突
- OOM（内存不足被杀）

**现象**：`kubectl get pods` 显示 `RESTARTS` 数字持续增长，STATUS 为 `CrashLoopBackOff`。

---

## 三、Shell / CI 相关

### heredoc 变量转义

`cat <<YAML` 称为 heredoc（here document），用于在 bash 脚本中生成多行文本。在 backlog 的 sync.sh 中，heredoc 用于生成 Kubernetes Deployment YAML。

**关键坑**：heredoc 中的 `$变量` 和 `$(命令)` 默认会被 bash 展开。

```bash
# sync.sh 中的 heredoc 片段（简化）
cat <<YAML
containers:
- args:
  - |
    TOK="\$(cat /run/secrets/clone/token 2>/dev/null || true)"
    git clone --depth 1 --branch "\$BRANCH" \
      "https://x-access-token:\${TOK}@\${REPO_HOSTPATH}" /tmp/app
YAML
```

- `\$(...)` — 反斜杠转义，让 `$()` 作为**字面量**写入 YAML，由容器运行时执行
- `\$BRANCH` / `\${TOK}` — 同上，保留为容器内变量
- 如果去掉反斜杠写成 `$(...)` 或 `${TOK}`，bash 在生成 YAML 时就会展开，此时外层变量未定义 → `unbound variable` 错误

**这是 #621 部署失败的直接根因**：AI Agent 误删了反斜杠。

### `set -u` / unbound variable

```bash
set -u   # 引用未定义变量时立即报错退出
```

**含义**：bash 严格模式的一部分。如果脚本中引用了从未赋值的变量，立即报错并退出。

**为什么在 CI 中重要**：不加 `set -u`，`${UNDEFINED_VAR}` 会静默展开为空字符串，bug 很难发现。加上后，任何拼写错误或未初始化的变量都会立即暴露。

---

## 四、GitHub Actions 相关

### Artifact storage quota

GitHub Actions 的制品（artifact）有存储上限。超过配额后，`actions/upload-artifact@v4` 会报错：

```
Failed to CreateArtifact: Artifact storage quota has been hit.
```

配额每 6-12 小时重置一次。清理方法：仓库 Settings → Actions → Artifacts → 删除过期制品。

**这是 #784 的根因**：需求分析本身的业务逻辑成功，但最后的上传 artifact 步骤因配额满了而失败。

### Executing the custom container implementation failed

```
##[error] Executing the custom container implementation failed.
Please contact your self hosted runner administrator.
```

Self-hosted runner 的通用错误。表示运行 job 的容器意外崩溃。常见原因：
1. 容器 OOM
2. 步骤执行超时（runner 层超时）
3. 磁盘/存储配额耗尽
4. 容器内进程被 kill

---

## 五、参数配置速查

| 参数 | 含义 | #621 原值 | #785 推荐值 |
|------|------|-----------|------------|
| `readinessProbe.initialDelaySeconds` | 容器启动后等待 N 秒再开始探针 | 5400 (原) → 30 (被改坏) | **600** |
| `readinessProbe.periodSeconds` | 探针间隔 | 10 | 10 |
| `readinessProbe.failureThreshold` | 连续失败 N 次标记 Unready | 30→60 (被改大) | **30** |
| `readinessProbe.timeoutSeconds` | 单次探针超时 | (无→5) | 5 |
| `progressDeadlineSeconds` | Deployment 总进展时限 | 7200 | **3600** |
| `RELEASE_ARGOCD_TIMEOUT_MIN` | ArgoCD 同步超时 | 8 | 8 |

### 推荐配置下的时间窗口

```
探针级别: initialDelaySeconds(600) + failureThreshold(30) × periodSeconds(10) = 900s (15min)
平台级别: progressDeadlineSeconds(3600) = 60min
CI级别: kubectl rollout status --timeout ≈ 不影响（走脚本内置逻辑）

关系: 60min > 15min ✓  时间窗口匹配
```
