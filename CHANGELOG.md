# 变更日志

本项目遵循语义化版本。日期按 UTC+8 记录。

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
