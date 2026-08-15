# Codex harness 与 machine run

`aicli run` 是供上层 AI/程序调用原生智能体的底层入口，不是新的 Agent，也不负责选择模型或自动 fallback。

```powershell
$task | aicli run codex-ollama-main `
  --project C:\staging\job-001 `
  --stdin --json `
  --event-file C:\staging\observer\job-001.jsonl `
  --sandbox-policy danger-full-access `
  --timeout-seconds 900 `
  --max-steps 30 `
  --max-tool-calls 120 `
  -- exec --json --ephemeral --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -
```

本机 Profile：

| Profile | 智能体 | 端点/模型 |
| --- | --- | --- |
| `codex-spark-xhigh` | Codex CLI（官方登录） | OpenAI / `gpt-5.3-codex-spark` / 默认 `xhigh` |
| `codex-qwen3-7-max-paygo` | Codex CLI（百炼 Workspace） | Responses / `qwen3.7-max-2026-06-08` / requested `max` → effective `xhigh` |
| `codex-qwen3-8-max-paygo` | Codex CLI（百炼 Workspace） | Responses / `qwen3.8-max` / requested `max` → effective `xhigh` |
| `codex-deepseek` | Codex CLI | Responses / `deepseek-v4-flash` / Flash 0731 / 1M / `max` |
| `codex-deepseek-v4-pro` | Codex CLI | Responses / `deepseek-v4-pro` / Pro 0813 / 1M / `max` |
| `codex-ollama-main` | Codex CLI | `127.0.0.1:32100` / `qwen-main-v1` / 262144 / `max` |
| `codex-ollama-qwen3-8-27b` | Codex CLI | `127.0.0.1:32100` / `qwen3.8:27b` Q4_K_M / 262144 / `max` |
| `claude-ollama-main` | Claude Code | 同上；MAX/AUTO 262144（Claude Code 2.1.193+） |
| `qwen-code-ollama-main` | Qwen Code | 同上 |
| `opencode-ollama-main` | OpenCode | 同上；262144 context / 8192 output / 20000 compaction reserve |
| `opencode-ollama-qwen3-8-27b` | OpenCode | `qwen3.8:27b` Q4_K_M；262144 context/input / 32768 output / 20000 compaction reserve |

安全边界：

- 调用接口只从 stdin 接收任务正文，不把正文放入 argv、环境变量、工作区或临时任务文件。返回值是一个 JSON envelope。
- **所有当前和未来 Codex 模型一律完全访问。** AICLI 在 `thread/start` 与 `turn/start` 都选择命名权限 `permissions=:danger-full-access`；规则按 `engine=codex` 生效，不维护模型 allowlist。省略 `--sandbox-policy` 时自动选择全访问；显式传 `read-only` / `workspace-write` 会失败关闭，不能静默降权。
- `approvalPolicy=never` 表示 harness 不等待权限弹窗；它不会缩小 `danger-full-access`，也不能被描述成沙箱或只读隔离。调用方应只传可信工作区与任务，并对可能产生的全部本机副作用负责。
- 所有当前和未来 Codex harness 默认在 `thread/start.dynamicTools` 注册受管函数 `public_web_search`；无需按模型逐项登记。它只访问固定的 `https://cn.bing.com/search` RSS，拒绝重定向、Cookie、模型指定 URL/Header/Key，并将结果标为不可信公共文本。Windows 系统代理仅用于固定 HTTPS 出口且不带默认凭据。显式 `--no-web-search` 可关闭本次 run；不会改变 `danger-full-access` 权限。
- 运行时身份是独立硬门：app-server 的 `thread/start` 结果必须提供 exact actual model、modelProvider、CLI version、`activePermissionProfile=:danger-full-access` 与 `sandbox.type=dangerFullAccess`；公开回执同时必须证明 `requested_policy=danger-full-access`。缺失、错配或随后收到 `model/rerouted` 时整次 run 失败。
- `codex-deepseek` 与 `codex-deepseek-v4-pro` 分别只允许 Flash 0731 / Pro 0813 官方 alias；Qwen3.7 Max 06-08 与 Qwen3.8 Max 各自只允许自己的 Workspace paygo route。Key 由 DPAPI 解封后仅以 `env_key` 对应环境变量注入目标 Codex 子进程，不进入参数或模型目录。
- 除 `codex-qwen3-7-max-paygo` → exact 06-08 外，Qwen3.7 Max/Plus 的 Cloud Agent route、Profile、目录和导入入口均已退役；旧身份记录不能通过 native model/fallback 参数恢复。
- 本地 Ollama 的 Codex harness 同样使用全访问；LocalGpuBroker 的 lease/capability 绑定仍负责证明请求确实命中 exact 本地模型，但不再被表述为文件系统权限沙箱。
- machine child 的父环境从 Windows、PowerShell、Node/TLS 运行所需的 allowlist 重建，不继承完整父环境或调试变量。受管运行计划仍可通过 `EnvironmentDelta` 显式注入目标 Profile 必需的 Provider/运行时变量，因此调用方不得把无关变量放入该显式增量。
- 官方云端 Codex machine run 同时忽略用户配置和规则。一次性 `CODEX_HOME` 只复制现有 `auth.json`，不需要付费 API Key；不会复制 `config.toml`、rules、skills、sessions 或 history，运行后清理。
- Codex harness 本来就是全访问，因此应传入隔离 worktree 或暂存目录；canonical raw 数据和无关秘密应保留在边界外。AICLI 不自动 fallback 到另一个 Profile。
- Qwen Code/OpenCode 是 machine-only；交互式 `start` 会拒绝这两个 Profile。
- OpenCode 的 inline 配置只启用 `aicli_ollama`，主/小/压缩模型都固定为当前 exact Profile 的模型；`opencode-ollama-main` 使用 `qwen-main-v1`，`opencode-ollama-qwen3-8-27b` 使用 `qwen3.8:27b`。两者显式 `auto=true`、`prune=false`、20000 reserve、最近 4 轮/16384 token 原样保留。`agent.build.steps=maxSteps` 只是上游软收尾，`maxToolCalls` 仍未获得硬映射，不能标成 AICLI `hard`。
- OpenCode 的 XDG config/data/cache/state 位于一次性 `.aicli-runtime-*` 并在结束时清理，所以 session summary/checkpoint 不能跨 run 继承。一个 run 只做一个里程碑；先把目标、约束、改动、测试和下一步写入项目状态，再开新 run。自动压缩后重读 `AGENTS.md`、当前 `SKILL.md`、状态文件和 `git status` / `git diff`。
- Codex harness 以 npm `codex-cli 0.147.0` 为当前最低身份验证基线，由内部桥使用 app-server JSON-RPC v2 的 `thread/start`、`turn/start` 与通知流。CLI 更新后默认尝试运行，但每次仍严格验证初始化、actual identity、全访问权限、通知 allowlist、thread/turn 归属、item 生命周期、成功轮次 `status=completed` 和清理结果；必要协议缺失、结构漂移、歧义事件或清理不可靠就明确失败。
- Codex 的 `max-steps` 采用 `distinct-non-output-thread-item-v2`：统计不同的推理、计划、工具、压缩等非输出 ThreadItem；公开 `agentMessage` 增量和最终消息不占用行动步骤，避免“一边汇报”挤掉实际执行预算。`max-tool-calls` 仍统计命令、文件、MCP、collab、web 等工具项；墙钟、输出上限和事件安全门也保持独立。machine run 逐行解析桥接后的安全事件并硬执行，越限会终止桥、app-server 和全部后代进程。
- 有界 machine run 显式关闭 Codex `multi_agent` / `multi_agent_v2`，避免一次 collab 调用在事件边界后隐藏未计数的子智能体工具循环；若仍出现 collab 事件，会先计为一次工具调用，再按配置不变量失效而失败关闭。
- Codex 输出采用版本化的 `eventProjection=codex-public-v1`：公开 `agentMessage` 增量会先按短语聚合，再投影为 `output.delta`；对模型目录明确声明支持的公开 reasoning summary，`item/reasoning/summaryTextDelta` 会独立投影为有界 `reasoning.summary.delta`，不混入回答草稿。公开进度、粗粒度工具事件和最终结果可见。隐藏 reasoning 正文、命令正文、工具输入输出和原始 stderr 只在内存中识别后丢弃，不进入 JSON envelope 或事件文件。
- Codex 的 `turn.failed` 与最终非零进程退出是终态失败。顶层 `error` 和 `item.type=error` 只作为待确认错误观察：只有其后同时出现公开 final message、`turn.completed`，且进程最终退出码为 `0` 时才恢复为成功；否则失败关闭。错误正文和原始 stderr 在两种路径中都不会进入公开回执或事件文件。
- 最终 JSON envelope 的 `run.usage` 只投影上游明确提供的安全字段。Codex app-server 桥接把同一完整快照中的 `tokenUsage.total` 投影为本次 machine run 的累计 `input_tokens` / `cached_input_tokens` / `output_tokens` / `reasoning_output_tokens` / `total_tokens`；AICLI 每次 run 新建线程，因此这些累计值不会混入其他 run。累计字段缺失或无效时直接省略，绝不回退到 `tokenUsage.last` 冒充整场累计；缓存为 `0` 或缺失时也省略，因为当前链路不能据此证明缓存统计可用。`current_context_tokens` 与 `context_window_tokens` 仍只取 `last.totalTokens` 和 `modelContextWindow`，不按字符数、累计 token 或配置上限估算；必要上下文字段缺失或协议漂移时整次 run 失败关闭。缓存 Token 是输入 Token 的子集，不能再次加入总计；推理输出也保持独立，不偷算进普通输出。其他引擎原生返回的 usage 仍按其自身回执保留，AICLI 不把任何一类 usage 当作费用或账单。
- `--event-file` 是可选的机器观察 side-channel，必须是父目录已存在的绝对 `.jsonl` 路径。AICLI 会先校验并清空该普通文件，再在运行中逐行 flush `aicli.machine-event.v1`；`aicli version --json` 可用于无模型调用的能力探测。
- side-channel 只投影线程/轮次、`reasoning.activity` 活动状态、模型明确公开且有界的 `reasoning.summary.delta`、粗粒度工具类型与状态、限制/失败状态、有界公开 agent message，以及真实上下文信号。受管搜索固定投影 `tool.activity` / `item_type=web_search`、`tool_name=public_web_search`、`search_provider=bing-rss-v1`、状态与计数；查询和结果正文永不进入事件。`context.usage.updated` 只含 `current_tokens` / `context_window_tokens`；`context.compaction.completed` 只含 `status` / 单调的 `compaction_count`。压缩信号来自 app-server `contextCompaction` item，不从消息长度或历史记录推断。
- app-server 原始通知只在内存中按封闭 allowlist 识别，并逐条绑定当前 thread / turn。只有 `item/reasoning/summaryTextDelta` 的显式公开摘要会进入 `reasoning.summary.delta`；raw `item/reasoning/textDelta` 与结构未知的 `summaryPartAdded` 始终丢弃。0.145 的 `subAgentActivity` 是 completion-only 点事件，只允许首次 `item/completed`；其他受支持 item 必须按同一 ID、同一类型严格 started → completed。真实复测确认 Codex CLI 0.145 和 0.147 会在连续公开进度时留下多个 started `agentMessage`，但仍随后闭合同轮次的非空 final；因此仅允许把全部早于该 final 的消息 orphan 标记为 superseded。该兼容按严格事件形态而非版本号生效，后续保持同一结构的高版本可直接使用；没有后续公开 final、final 之后仍有 orphan，或出现 reasoning/命令/文件/工具等非消息 orphan 时仍明确失败。任务 prompt、raw reasoning、命令、工具输入输出、压缩前后 history、文件内容、环境变量、秘密和原始 stderr 都不会进入 JSON envelope 或事件文件；观察器可将有明确字段标识的 summary 显示为“公开工作思路”，但不能标注为原始思维链。
- 结束时桥接器主动终止并确认 app-server 完整进程树；若 app-server 提前退出或无法确认完整清理，会向父进程发出安全的 `cleanup.failed` 内部信号并把整次 run 判为失败，不能用成功的 bridge 退出掩盖孤儿进程。
- 最终回执通过 `machineEventProjection`、`machineEventStatus` 与 `machineEventCount` 标明观察级别。事件写入失败时状态为 `degraded`，已完成的模型结果不会被重跑；调用方也不得用失败后的自动重试制造重复副作用。
- JSONL 事件类型使用封闭 allowlist。未知事件、未知 item、持续输出超过墙钟或无法确认完整进程树终止时，`limitEnforcement` 会失败关闭；回执用 `limitUsage`、`limitHit`、`cleanupConfirmed` 与 `stepDefinition` 说明原因。
- 其他 CLI 只有在自身回执能证明相同硬边界时才可被上层当作有限预算 runner；`upstream` 或 `not-enforced` 不能冒充 `hard`。
- CLI 更新不应直接等同于受管 machine runtime 晋升。应先校验包内可执行文件与资源闭包、版本/协议、actual identity、全访问权限对象和少量 smoke，再按当前版本与 Profile 指纹重新验收。

`0.3.8` 是当前源码与安装目标，包含 exact Qwen3.7 06-08/Qwen3.8/DeepSeek/local Codex Profile、Qwen3.8-27B Codex/OpenCode Profile、MAX 映射、统一 `danger-full-access`、actual identity/no-reroute 和环境隔离。源代码验收必须明确使用仓库入口并在回执中保留来源；正式安装/晋升前，不得把 source 结果宣称为 installed 或 runtime current。

2026-07-29 的 Spark 源代码入口真实任务证明工作区写权限已生效；但 `code_repair` 在硬上限 `maxSteps=80` 下到达 `81/80` 并终止，确定性得分为 `2/9`。这属于模型/Agent 能力验收不通过，不是权限链仍然只读，也不应通过重复复测改变结论。

产品边界：aicli 只启动和约束进程，不判断低级模型是否胜任任务，也不在额度、限流或失败时自动 fallback。上层模型应给出确定性验收器，依据最终文件、exit code、墙钟时间和结果回执裁决；若显式改投本地模型，必须保留原失败回执和新的本地回执，不得把结果冒充为原模型产出。可以持续读取上述安全公共事件，但不要读取、保存或伪装隐藏思考流。

上下文边界：原生 ChatGPT + Codex 保持上游默认。DeepSeek/千问/本地 Qwen 的第三方 Codex/Claude 路径不要主动压缩；受管目录或逐模型元数据只负责声明真实窗口和保留溢出保护，不把客户端摘要变成无损或远程压缩。未知第三方 Claude 模型会清除继承的上下文控制变量，避免沿用上一模型容量。
