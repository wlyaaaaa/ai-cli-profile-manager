# 沙箱化 machine run

`aicli run` 是供上层 AI/程序调用原生智能体的底层入口，不是新的 Agent，也不负责选择模型或自动 fallback。

```powershell
$task | aicli run codex-ollama-main `
  --project C:\staging\job-001 `
  --stdin --json `
  --sandbox-policy workspace-write `
  --timeout-seconds 900 `
  --max-steps 30 `
  --max-tool-calls 120 `
  -- exec --json --ephemeral --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -
```

本机 Profile：

| Profile | 智能体 | 端点/模型 |
| --- | --- | --- |
| `codex-ollama-main` | Codex CLI | `127.0.0.1:32100` / `qwen-main-v1` |
| `claude-ollama-main` | Claude Code | 同上 |
| `qwen-code-ollama-main` | Qwen Code | 同上 |
| `opencode-ollama-main` | OpenCode | 同上 |

安全边界：

- 调用接口只从 stdin 接收任务正文，不把正文放入 argv；Codex 路径会把正文暂存到一次性运行目录，argv 只含文件路径，结束后统一清理。返回值是一个 JSON envelope。
- 外层 Codex Windows 沙箱是强制边界，网络关闭；内层 CLI 的自动批准不会扩大到沙箱之外。
- `workspace-write` 允许修改指定工作区。因此应传入隔离 worktree 或暂存目录，canonical raw 数据只读保留在边界外。
- `read-only` 让 CLI 在一次性运行目录写自身状态，来源工作区只读；任务结束后清理运行目录。
- 无法建立沙箱时直接失败，不切换到无沙箱执行，也不改用另一个 Profile。
- Qwen Code/OpenCode 是 machine-only；交互式 `start` 会拒绝这两个 Profile。
- Codex 的 `max-steps` 统计不同的 ThreadItem 工作单元，`max-tool-calls` 统计命令、文件、MCP、collab、web 等工具项；machine run 逐行解析公开 JSON 事件并硬执行，越限会终止完整子进程树。
- 有界 machine run 显式关闭 Codex `multi_agent` / `multi_agent_v2`，避免一次 collab 调用在事件边界后隐藏未计数的子智能体工具循环；若仍出现 collab 事件，会先计为一次工具调用，再按配置不变量失效而失败关闭。
- Codex 输出采用版本化的 `eventProjection=codex-public-v1`：只返回公开 agent message 与线程标识。reasoning、命令正文、工具输出和原始 stderr 只在内存中识别后丢弃，不进入 JSON envelope。
- JSONL 事件类型使用封闭 allowlist。未知事件、未知 item、持续输出超过墙钟或无法确认完整进程树终止时，`limitEnforcement` 会失败关闭；回执用 `limitUsage`、`limitHit`、`cleanupConfirmed` 与 `stepDefinition` 说明原因。
- 其他 CLI 只有在自身回执能证明相同硬边界时才可被上层当作有限预算 runner；`upstream` 或 `not-enforced` 不能冒充 `hard`。

产品边界：aicli 只启动和约束进程，不判断低级模型是否胜任任务。上层模型应给出确定性验收器，依据最终文件、exit code、墙钟时间和结果回执裁决；不要读取或持续监控思考流。
