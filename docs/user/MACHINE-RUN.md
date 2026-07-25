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

- 调用接口只从 stdin 接收任务正文，不把正文放入 argv；Codex 路径会把正文暂存到一次性运行目录，argv 只含文件路径，结束后统一清理。返回值是一个 JSON envelope。
- 本地与第三方 Profile 使用强制 Windows 外层沙箱，网络关闭；内层 CLI 的自动批准不会扩大到沙箱之外。
- 官方云端 Codex machine run 需要连接模型服务，因此改用 Codex CLI 原生沙箱：`read-only` 或 `workspace-write` 仍由 aicli 显式传入，同时忽略用户配置和规则。一次性 `CODEX_HOME` 只复制现有 `auth.json`；不会复制 `config.toml`、rules、skills、sessions 或 history。
- `workspace-write` 允许修改指定工作区。因此应传入隔离 worktree 或暂存目录，canonical raw 数据只读保留在边界外。
- `read-only` 让 CLI 在一次性运行目录写自身状态，来源工作区只读；任务结束后清理运行目录。
- 无法建立对应沙箱时直接失败，不切换到无沙箱执行，也不改用另一个 Profile。
- Qwen Code/OpenCode 是 machine-only；交互式 `start` 会拒绝这两个 Profile。
- Codex 的 `max-steps` 统计不同的 ThreadItem 工作单元，`max-tool-calls` 统计命令、文件、MCP、collab、web 等工具项；machine run 逐行解析公开 JSON 事件并硬执行，越限会终止完整子进程树。
- 有界 machine run 显式关闭 Codex `multi_agent` / `multi_agent_v2`，避免一次 collab 调用在事件边界后隐藏未计数的子智能体工具循环；若仍出现 collab 事件，会先计为一次工具调用，再按配置不变量失效而失败关闭。
- Codex 输出采用版本化的 `eventProjection=codex-public-v1`：只返回公开 agent message 与线程标识。reasoning、命令正文、工具输出和原始 stderr 只在内存中识别后丢弃，不进入 JSON envelope。
- Codex 的 `turn.failed` 与最终非零进程退出是终态失败。顶层 `error` 和 `item.type=error` 只作为待确认错误观察：只有其后同时出现公开 final message、`turn.completed`，且进程最终退出码为 `0` 时才恢复为成功；否则失败关闭。错误正文和原始 stderr 在两种路径中都不会进入公开回执或事件文件。
- 成功解析 `turn.completed.usage` 时，最终 JSON envelope 的 `run.usage` 只允许非负整数 `input_tokens`、`cached_input_tokens`、`output_tokens`；缺失或无效字段会省略，其他字段一律丢弃。该对象只是上游 token 回执，不是 aicli 计算的费用或账单。
- `--event-file` 是可选的机器观察 side-channel，必须是父目录已存在的绝对 `.jsonl` 路径。AICLI 会先校验并清空该普通文件，再在运行中逐行 flush `aicli.machine-event.v1`；`aicli version --json` 可用于无模型调用的能力探测。
- side-channel 只投影线程/轮次、`reasoning.activity` 活动状态、粗粒度工具类型与状态、限制/失败状态和有界公开 agent message。它不包含隐藏推理正文、命令文本或参数、工具输入输出、文件内容、环境变量、秘密或原始 stderr；因此观察器应把它显示为“公开工作摘要”，不能标注为原始思维链。
- 最终回执通过 `machineEventProjection`、`machineEventStatus` 与 `machineEventCount` 标明观察级别。事件写入失败时状态为 `degraded`，已完成的模型结果不会被重跑；调用方也不得用失败后的自动重试制造重复副作用。
- JSONL 事件类型使用封闭 allowlist。未知事件、未知 item、持续输出超过墙钟或无法确认完整进程树终止时，`limitEnforcement` 会失败关闭；回执用 `limitUsage`、`limitHit`、`cleanupConfirmed` 与 `stepDefinition` 说明原因。
- 其他 CLI 只有在自身回执能证明相同硬边界时才可被上层当作有限预算 runner；`upstream` 或 `not-enforced` 不能冒充 `hard`。

产品边界：aicli 只启动和约束进程，不判断低级模型是否胜任任务，也不在额度、限流或失败时自动 fallback。上层模型应给出确定性验收器，依据最终文件、exit code、墙钟时间和结果回执裁决；若显式改投本地模型，必须保留原失败回执和新的本地回执，不得把结果冒充为原模型产出。可以持续读取上述安全公共事件，但不要读取、保存或伪装隐藏思考流。
