# 沙箱化 machine run

`aicli run` 是供上层 AI/程序调用原生智能体的底层入口，不是新的 Agent，也不负责选择模型或自动 fallback。

```powershell
$task | aicli run codex-ollama-main `
  --project C:\staging\job-001 `
  --stdin --json `
  --event-file C:\staging\observer\job-001.jsonl `
  --sandbox-policy workspace-write `
  --timeout-seconds 900 `
  --max-steps 30 `
  --max-tool-calls 120 `
  -- exec --json --ephemeral --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -
```

本机 Profile：

| Profile | 智能体 | 端点/模型 |
| --- | --- | --- |
| `codex-spark-xhigh` | Codex CLI（官方登录） | OpenAI / `gpt-5.3-codex-spark` / 默认 `xhigh` |
| `codex-ollama-main` | Codex CLI | `127.0.0.1:32100` / `qwen-main-v1` |
| `claude-ollama-main` | Claude Code | 同上 |
| `qwen-code-ollama-main` | Qwen Code | 同上 |
| `opencode-ollama-main` | OpenCode | 同上 |

安全边界：

- 调用接口只从 stdin 接收任务正文，不把正文放入 argv。Codex 原生沙箱路径由可信内部桥直接从 stdin 驱动 app-server；仍使用外层沙箱的路径因沙箱不转发 stdin，父进程才通过带随机名称且只授权父进程身份与隔离沙箱身份的命名管道，把正文交给沙箱内桥接器。任务正文不写入参数、环境变量、工作区或临时文件。返回值是一个 JSON envelope。
- 官方 Codex machine run 使用 Codex CLI 原生命令沙箱：`read-only` 或 `workspace-write` 由 aicli 在 `turn/start` 显式传入。
- 远程第三方 Responses Provider 需要模型传输联网。当前 Qwen Cloud 只验收到文本/只读 smoke；真实任务中 `workspace-write` 被原生沙箱策略拒绝，因此 AICLI 会在 Provider 调用前失败关闭，不能作为可写 Agent 使用。
- 本地 Ollama Codex 及其他适用本地引擎使用强制 Windows 外层沙箱，网络关闭；内层 CLI 的自动批准不会扩大到沙箱之外。Codex app-server 由 npm 包内的原生 `codex.exe` 直接承载，避免短生命周期 Node 启动器破坏进程树清理确认。
- 官方云端 Codex machine run 同时忽略用户配置和规则。一次性 `CODEX_HOME` 只复制现有 `auth.json`；不会复制 `config.toml`、rules、skills、sessions 或 history。
- `workspace-write` 允许修改指定工作区。因此应传入隔离 worktree 或暂存目录，canonical raw 数据只读保留在边界外。
- `read-only` 让 CLI 在一次性运行目录写自身状态，来源工作区只读；任务结束后清理运行目录。
- 无法建立对应沙箱时直接失败，不切换到无沙箱执行，也不改用另一个 Profile。
- Qwen Code/OpenCode 是 machine-only；交互式 `start` 会拒绝这两个 Profile。
- Codex machine run 以已实测的 npm `codex-cli 0.145.0` 为最低协议基线，由内部桥使用 app-server JSON-RPC v2 的 `thread/start`、`turn/start` 与通知流；`0.146.0-alpha.3.1` 已通过同一真实兼容验收。CLI 更新后默认尝试运行，但每次仍严格验证初始化、必要字段、通知 allowlist、thread/turn 归属、item 生命周期、成功轮次 `status=completed` 和清理结果；兼容则直接工作，必要协议缺失、结构漂移、歧义事件或清理不可靠就返回明确错误。低于基线的版本直接拒绝，不回退到估算值或旧式解析。
- Codex 的 `max-steps` 采用 `distinct-non-output-thread-item-v2`：统计不同的推理、计划、工具、压缩等非输出 ThreadItem；公开 `agentMessage` 增量和最终消息不占用行动步骤，避免“一边汇报”挤掉实际执行预算。`max-tool-calls` 仍统计命令、文件、MCP、collab、web 等工具项；墙钟、输出上限和事件安全门也保持独立。machine run 逐行解析桥接后的安全事件并硬执行，越限会终止桥、app-server 和全部后代进程。
- 有界 machine run 显式关闭 Codex `multi_agent` / `multi_agent_v2`，避免一次 collab 调用在事件边界后隐藏未计数的子智能体工具循环；若仍出现 collab 事件，会先计为一次工具调用，再按配置不变量失效而失败关闭。
- Codex 输出采用版本化的 `eventProjection=codex-public-v1`：公开 `agentMessage` 增量会先按短语聚合，再投影为 `output.delta`；公开进度、粗粒度工具事件和最终结果可见。隐藏 reasoning 正文、命令正文、工具输入输出和原始 stderr 只在内存中识别后丢弃，不进入 JSON envelope 或事件文件。
- Codex 的 `turn.failed` 与最终非零进程退出是终态失败。顶层 `error` 和 `item.type=error` 只作为待确认错误观察：只有其后同时出现公开 final message、`turn.completed`，且进程最终退出码为 `0` 时才恢复为成功；否则失败关闭。错误正文和原始 stderr 在两种路径中都不会进入公开回执或事件文件。
- 最终 JSON envelope 的 `run.usage` 只允许五个非负整数：`input_tokens`、`cached_input_tokens`、`output_tokens`、`current_context_tokens`、`context_window_tokens`。后两项只取 Codex app-server 的 `thread/tokenUsage/updated.params.tokenUsage.last.totalTokens` 与同一完整快照中的 `modelContextWindow`，不是按字符数、累计 token 或配置上限自行估算；Codex app-server 成功轮次必须至少收到一份同时包含这两个必要字段的有效运行时快照，字段缺失或协议结构漂移都会令整次 run 明确失败。前三项中缺失或无效的可选字段会省略，其他字段一律丢弃。该对象只是上游 token 回执，不是 aicli 计算的费用或账单。
- `--event-file` 是可选的机器观察 side-channel，必须是父目录已存在的绝对 `.jsonl` 路径。AICLI 会先校验并清空该普通文件，再在运行中逐行 flush `aicli.machine-event.v1`；`aicli version --json` 可用于无模型调用的能力探测。
- side-channel 只投影线程/轮次、`reasoning.activity` 活动状态、粗粒度工具类型与状态、限制/失败状态、有界公开 agent message，以及真实上下文信号。`context.usage.updated` 只含 `current_tokens` / `context_window_tokens`；`context.compaction.completed` 只含 `status` / 单调的 `compaction_count`。压缩信号来自 app-server `contextCompaction` item，不从消息长度或历史记录推断。
- app-server 原始通知只在内存中按封闭 allowlist 识别，并逐条绑定当前 thread / turn。0.145 的 `subAgentActivity` 是 completion-only 点事件，只允许首次 `item/completed`；其他受支持 item 必须按同一 ID、同一类型严格 started → completed。真实复测确认 Codex CLI `0.145.x` 会在连续公开进度时留下多个 started `agentMessage`，但仍随后闭合同轮次的非空 final；因此仅允许把全部早于该 final 的消息 orphan 标记为 superseded。更新/未知版本、没有后续公开 final、final 之后仍有 orphan，或出现 reasoning/命令/文件/工具等非消息 orphan 时仍明确失败。任务 prompt、reasoning、命令、工具输入输出、压缩前后 history、文件内容、环境变量、秘密和原始 stderr 都不会进入 JSON envelope 或事件文件；因此观察器应把它显示为“公开工作摘要”，不能标注为原始思维链。
- 结束时桥接器主动终止并确认 app-server 完整进程树；若 app-server 提前退出或无法确认完整清理，会向父进程发出安全的 `cleanup.failed` 内部信号并把整次 run 判为失败，不能用成功的 bridge 退出掩盖孤儿进程。
- 最终回执通过 `machineEventProjection`、`machineEventStatus` 与 `machineEventCount` 标明观察级别。事件写入失败时状态为 `degraded`，已完成的模型结果不会被重跑；调用方也不得用失败后的自动重试制造重复副作用。
- JSONL 事件类型使用封闭 allowlist。未知事件、未知 item、持续输出超过墙钟或无法确认完整进程树终止时，`limitEnforcement` 会失败关闭；回执用 `limitUsage`、`limitHit`、`cleanupConfirmed` 与 `stepDefinition` 说明原因。
- 其他 CLI 只有在自身回执能证明相同硬边界时才可被上层当作有限预算 runner；`upstream` 或 `not-enforced` 不能冒充 `hard`。

产品边界：aicli 只启动和约束进程，不判断低级模型是否胜任任务，也不在额度、限流或失败时自动 fallback。上层模型应给出确定性验收器，依据最终文件、exit code、墙钟时间和结果回执裁决；若显式改投本地模型，必须保留原失败回执和新的本地回执，不得把结果冒充为原模型产出。可以持续读取上述安全公共事件，但不要读取、保存或伪装隐藏思考流。
