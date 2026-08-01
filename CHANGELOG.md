# 变更日志

本项目遵循语义化版本。日期按 UTC+8 记录。

## [Unreleased]

本节描述 `0.3.3` 本地/源码目标，尚未发布 GitHub Release。未经过安装/晋升流程时不得宣称 installed runtime 已包含这些修复。

### 新增

- 新增 DeepSeek 官方 Codex public beta 模板 `codex-deepseek`：固定 `deepseek-v4-flash`、Responses、1M context、Codex CLI `0.144.0+`，默认 reasoning effort 为 `high`，支持 `low` / `high` / `max`。
- DeepSeek 模型目录使用 AICLI 受管的内容寻址副本；API Key 继续由 CurrentUser DPAPI 保存，Codex 配置只引用 `env_key`。不复制官方示例的明文 `experimental_bearer_token`，也不写入 `preferred_auth_method`。
- OpenClaw DeepSeek 导入可生成 `codex-deepseek`、`claude-deepseek`、`oi-deepseek` 三个 Profile。

### 变更

- Codex、Claude Code 与 Rust Open Interpreter 的公开 DeepSeek 模板统一收敛为 `deepseek-v4-flash`。`deepseek-v4-pro` 只保留不可选的 `reserved` 元数据，待上游正式支持 Codex Responses 后再接入。
- Qwen Code `0.21` 与 OpenCode `1.18.8` 暂不开放 DeepSeek 远程 Profile：当前 AICLI machine-only 外层沙箱断网，且没有隔离真实 Key 的远程 egress relay；不以假 Profile 代替缺失的安全执行路径。
- 2026-07-14 的 Claude/OI `deepseek-v4-pro` Live 记录仅保留为历史证据；Flash-only Profile 指纹变化后，该记录不再证明当前模板可用。

### 修正

- Codex CLI `0.145.x` 的原生 app-server `workspace-write` 改用实验协议中的命名权限：`thread/start` 与 `turn/start` 都传入 `permissions=:workspace`，并用唯一的 `runtimeWorkspaceRoots` 精确绑定请求 `cwd`。桥接器回读 `workspaceWrite`、`:workspace` 和同一根路径，并在模型轮次前执行受限写探针；根目录为空、漂移或探针失败时，不启动模型调用。
- 原生 Codex machine run 继续固定 `approvalPolicy=never`；app-server 发起任何审批或用户输入 RPC 时均失败关闭，不自动批准。
- machine child 不再继承完整父进程环境，而是从 Windows、PowerShell、Node/TLS 运行所需的小型 allowlist 重建环境，并屏蔽调试类变量。受管运行时仍可通过 `EnvironmentDelta` 显式注入本次任务所需的 Provider 或运行时变量；该显式注入是权限边界，不能被表述成“子进程永远看不到秘密”。
- 官方 Codex/Spark machine run 继续使用一次性 `CODEX_HOME` 中的 `auth.json` 副本，不要求也不注入付费 API Key；运行目录在结束时清理。
- 修复 app-server 重建时丢失原生 `--model` / `-m` 覆盖的问题。先前标成 Qwen Flash/Plus 的云端 Agent 记录实际使用了 Profile 主模型 Max，旧身份与能力结论已经撤回；付费 Qwen Agent route 保持禁用，本轮不做付费复测。

### 验收

- 通过仓库源代码入口执行的 Spark `workspace-write` 真实任务已证明工作区写权限生效；但 `code_repair` 在硬上限 `maxSteps=80` 下到达 `81/80` 并终止，确定性得分为 `2/9`。该结果属于能力验收不通过，不因写权限修复而晋升为合格代码 Agent，也不重复复测。

## [0.3.2] - 2026-07-25

### 新增

- `aicli version --json` 公开声明 `aicli.machine-event.v1` 能力。
- `aicli run` 新增可选 `--event-file <absolute-jsonl-path>`。运行期间逐行刷新安全公共事件，供上层观察器显示线程/轮次、推理活动状态、工具类型、文件编辑状态和公开最终消息。
- Codex machine run 以实测的 npm `codex-cli 0.145.0` app-server 协议为最低基线，`0.146.0-alpha.3.1` 已通过真实兼容验收；后续更新版本默认尝试，只有通过运行时协议门禁才继续，否则返回明确错误。公开 `agentMessage` 增量按短语聚合为 `output.delta`；`context.usage.updated` 直接投影一份同时完整包含 `tokenUsage.last.totalTokens / modelContextWindow` 的运行时快照，`context.compaction.completed` 投影自动压缩完成计数。最终 `run.usage` 新增 `current_context_tokens` 与 `context_window_tokens`，均不由本地猜测。
- 官方与本地 Ollama Codex machine run 使用 Codex 原生 `read-only` / `workspace-write` 沙箱；第三方 Codex 及其他适用引擎继续使用网络关闭的 Windows 外层沙箱。0.145 的 `subAgentActivity` 是只发送一次 completed 的点事件，其他受支持 item 仍严格要求 started → completed。

### 安全修正

- side-channel 使用严格 schema、单调 sequence、事件/字段白名单和有界公开文本；不写入隐藏推理正文、命令/参数、工具输入输出、文件内容、环境变量、秘密或原始 stderr。
- `maxSteps` 的 Codex 计数升级为 `distinct-non-output-thread-item-v2`：推理、计划、工具、压缩等不同非输出 item 继续占用硬行动预算；公开 `agentMessage` 增量与最终消息不再挤占执行步骤。墙钟、事件输出上限与 `maxToolCalls` 仍独立约束公开输出和工具活动。
- app-server 双向桥只在内存中处理原始通知；原生 Codex 沙箱路径直接从 stdin 接收任务，仍使用外层沙箱的路径才通过受限 ACL 的随机命名管道传递。prompt、压缩 history 和通知私有载荷不进入结果、事件文件、环境变量或临时文件。公开进度、粗粒度工具事件和最终结果可见，隐藏 reasoning 正文不公开。低于基线、必要字段缺失或结构漂移、未知通知、跨 thread/turn、非 `completed` 的成功终态、非法 item 生命周期、服务端交互请求与无法确认的进程树清理均失败关闭，不回退到 token 估算。真实复测证明 `0.145.x` 会为连续公开进度留下多个消息 orphan；兼容层只接受它们全部早于同轮次后续、已完成且有公开正文的 final `agentMessage`。更新/未知版本、缺少后续 final、final 之后的新 orphan 或任何非消息 orphan 仍明确报错。
- 事件路径在读取 stdin 和启动模型进程前完成绝对路径、扩展名、父目录和普通文件校验。事件写入失败只将观察级别标为 `degraded`，不会重跑或篡改已经完成的模型结果。
- 事件文件变量不会传入受管子进程；既有 stdout 单-envelope、沙箱、预算、超时和进程树清理语义保持兼容。

### 验收

- 覆盖未启用 side-channel 的兼容路径、公开消息短语聚合、实时 flush、公开消息不消耗行动步骤预算、sequence、敏感信息阻断、非法路径提前拒绝、写入降级回执、app-server 上下文/压缩投影、严格 scope/status/lifecycle、`0.145.x` 多条早期公开消息 orphan 窄兼容、最低版本门禁和未知通知失败关闭。

## [0.3.1] - 2026-07-24

### 新增

- 新增 `codex-spark-xhigh`：精确固定 `gpt-5.3-codex-spark` 与默认 `xhigh` 思考强度，供上层显式选择高速中档智能体；不改变任何本地 Qwen 默认路由。
- 官方 Codex machine run 支持复用现有原生登录：一次性 `CODEX_HOME` 只复制 `auth.json`，不继承用户 `config.toml`、rules、skills、sessions 或 history。

### 安全修正

- 交互式官方 Codex 仍优先使用桌面版 `codex.exe`；machine run 明确选择 npm Codex CLI，避免把桌面二进制误当成可解析 JSONL 的机器运行时。
- 官方云端 Codex machine run 使用 CLI 原生 `read-only` / `workspace-write` 沙箱，并忽略用户配置和规则；本地与第三方 Profile 继续使用网络关闭的 Windows 外层沙箱。两种边界都保留硬墙钟、step、tool-call、事件投影与进程树清理。
- Spark 额度或上游限流不会在 aicli 内自动切换模型；上层必须显式决定是否重新提交到本地 Profile，并分别保留两份回执。

### 验收

- `codex-spark-xhigh` 的只读 machine run 在合成任务上返回严格 JSON，精确回执记录目标模型、`xhigh`、硬预算、墙钟时间和线程标识。

## [0.3.0] - 2026-07-24

### 安全修正

- Codex machine run 现在逐行解析公开 JSON 事件：`max-steps` 统计不同的 ThreadItem 工作单元，`max-tool-calls` 统计命令、文件、MCP、collab 与 web 等工具项；越限立即终止完整 Windows 子进程树。
- 有界 machine run 显式关闭 Codex `multi_agent` / `multi_agent_v2`；若仍观察到 collab 事件，会计数并立即失败关闭，防止隐藏子智能体工具循环。
- 事件类型使用封闭 allowlist；未知事件、未知 item、持续 JSONL 超过墙钟或无法确认完整进程树终止时均失败关闭，不再误报 `hard`。
- machine run 只返回公开 agent message 与线程标识；reasoning、命令正文和工具输出在计数后即丢弃，不进入结果 envelope。
- 回执新增 `eventProjection=codex-public-v1`、`limitUsage` 与 `limitHit`。只有事件协议和进程树清理均有效时，Codex 的 step/tool-call 上限才标记为 `hard`。

### 验收

- 新增 collab 计数、未知事件、持续流墙钟、隐藏推理/stderr 丢弃及真实父→孙进程树终止回归。

## [0.2.1] - 2026-07-22

### 修正

- Codex machine run 不再依赖外层 Windows 沙箱转发 stdin；任务正文保存在一次性运行目录，进程参数只包含该文件路径。
- Codex 的任务正文不会出现在命令行参数、结果 envelope 或持久化配置中，运行目录仍在结束后清理。
- Codex npm 包改为从短的安装路径只读加载，避免深层工作区镜像触发 Windows `MAX_PATH`；不会因此暴露整个 npm 根目录。

### 验收

- Pester 全量回归与本机 `qwen-main-v1` Codex 沙箱调用通过；通用智能基准结果另由上层 LLM Backend Toolkit 按版本记录。

## [0.2.0] - 2026-07-22

### 新增

- Qwen Code 与 OpenCode 的本机 `qwen-main-v1` Profile。
- `aicli run`：任务正文走 stdin，结果返回单一 JSON envelope，支持墙钟、step、tool-call 和输出上限。
- Codex Windows 外层沙箱：默认禁用外网；`workspace-write` 只写指定工作区，`read-only` 使用一次性可写运行目录并把来源工作区设为只读。
- Codex/Claude/Qwen/OpenCode 的临时配置隔离，运行后清理；上层只取得结果侧元数据。

### 安全修正

- Qwen Code npm 包与 Codex npm 包在 machine run 中镜像到沙箱内，避免给整个用户 AppData 扩大读取权限。
- Claude Code 的自动授权只在强制外层沙箱内生效。
- Qwen Code/OpenCode 拒绝通过交互式入口绕过 machine sandbox。

### 验收

- 本机 Qwen3.6 35B 同题数据清洗：Codex CLI 21/21、47.343 秒、exit 0，被上层工具选为默认；其他 harness 保留为显式候选。

## [0.1.0] - 2026-07-14

首个公开版本。

### 新增

- Windows 11 / PowerShell 7 当前用户安装、PATH 垫片和原子同版本替换。
- 可恢复卸载：移除模块、命令垫片、安装器加入的用户 PATH 项和受管 PowerShell Profile 块；默认保留用户数据，彻底清理需显式选择。
- 统一 `aicli` 命令、中文帮助、严格未知参数检查和 JSON 输出入口。
- Codex 官方、千问 Responses、Ollama Profile。
- Claude 官方、DeepSeek、千问三套餐、Ollama、自定义 Anthropic Messages Profile。
- 当前官方 Rust Open Interpreter `0.0.21+` 的千问、DeepSeek 与 Ollama Profile；明确拒绝旧 Python 0.4.x。
- DPAPI CurrentUser 密钥保存、子进程 Provider 隔离、脱敏 `native` 和无秘密 `eject`。
- Doctor、显式 Live Test、Profile 指纹与 CLI 版本验证记录。
- `raine/claude-code-proxy` 与 CLIProxyAPI 可选运维入口、SHA256 批准清单、loopback 端口和进程身份检查。
- 两本 canonical 中文手册、顺序索引、隐私、安全、贡献和第三方声明。

### 安全修正

- Live 文本测试要求目标 CLI 正常退出且最终正文严格等于 `PONG`，避免提示回显假绿。
- Open Interpreter Key 不进入命令行，并从其 Shell 工具环境排除。
- 未知命令和参数返回用法错误，不再静默忽略。
- 安装器先验证候选目录，失败时恢复已有版本。

### 已知限制

- 本轮尚未完成 Claude 官方登录后的最终 Live 验收；先前 `401` 只表示当时 CLI 未登录。
- 两个 ChatGPT 第三方代理尚未完成本轮 OAuth 和端到端 Live 验收，保持可选且不标“可用”。
- 工具 Live Test 无法证明完整隔离时会跳过并显示“可用但有限制”。
- 只支持 Windows 11；不承诺 macOS、Linux 或 GUI。
