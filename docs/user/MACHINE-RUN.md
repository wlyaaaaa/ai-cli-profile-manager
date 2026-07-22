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

- 任务正文只从 stdin 读取，不进入 argv；返回一个 JSON envelope。
- 外层 Codex Windows 沙箱是强制边界，网络关闭；内层 CLI 的自动批准不会扩大到沙箱之外。
- `workspace-write` 允许修改指定工作区。因此应传入隔离 worktree 或暂存目录，canonical raw 数据只读保留在边界外。
- `read-only` 让 CLI 在一次性运行目录写自身状态，来源工作区只读；任务结束后清理运行目录。
- 无法建立沙箱时直接失败，不切换到无沙箱执行，也不改用另一个 Profile。
- Qwen Code/OpenCode 是 machine-only；交互式 `start` 会拒绝这两个 Profile。

产品边界：aicli 只启动和约束进程，不判断低级模型是否胜任任务。上层模型应给出确定性验收器，依据最终文件、exit code、墙钟时间和结果回执裁决；不要读取或持续监控思考流。
