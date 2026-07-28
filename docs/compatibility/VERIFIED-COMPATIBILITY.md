# 兼容性与最终验收状态

文档日期：2026-07-24（UTC+8）
产品版本：`0.3.2`
状态原则：代码路径存在不等于 Provider 已通过；最终状态必须来自当前版本、当前 Profile 指纹和真实目标 CLI 的验收记录。

## 1. 当前实现基线

开发环境曾检测到：Windows 11、PowerShell 7.6.3、Codex CLI 0.144.3、Claude Code 2.1.207、Ollama 0.31.1。它们只是实现时的版本基线，不是所有用户机器的保证，也不代替最终发布验收。

Open Interpreter 只支持当前官方 Rust CLI `0.0.21` 或更高。输出形如 `Open Interpreter 0.4.x` 的旧 Python 产品不在支持范围。

## 2. 最终验收矩阵

本页不沿用修复前的 Live Test 成功记录。下表只记录 Live 判定、配置隔离和 Rust OI 适配器更新后的当前证据；没有新证据的路径保持“可用但有限制”或“不可用”。

| Profile / 路径 | 实现状态 | 本轮最终 Live 状态 | 发布说明 |
|----------------|----------|--------------------|----------|
| `codex-official` | 已实现 | 可用但有限制（本轮按用户要求未做 Live） | 使用上游官方登录；不得由桌面端登录状态推断 CLI 一定可用 |
| `codex-spark-xhigh` | 已实现 | 只读 machine run 文本/严格 JSON 通过（可用但有限制） | 2026-07-24（UTC+8）：npm Codex CLI → `gpt-5.3-codex-spark` / `xhigh`，合成任务 exit 0，正文严格 `{"status":"SPARK_AICLI_OK"}`；墙钟 15.603 秒，回执显示 1 step、0 tool call，墙钟/step/tool-call均为 hard。未据此宣称图片输入、所有工具或长期额度稳定。 |
| `codex-qwen-paygo` | 已实现 | 文本/只读 smoke 可用；`workspace-write` 不可用 | 2026-07-28：当前 npm Codex CLI 0.145.0 → `qwen3.7-flash` 连续 3 次、`qwen3.7-plus` 1 次严格 `PONG`，均 exit 0；远程 Provider 禁网边界与原生 `codex.exe` 进程树清理已修。随后真实任务证明两模型的文件写入均被原生沙箱策略拒绝；24 步的 4/30 及 Flash 56 步的 4/30 均为无效能力分。AICLI 现会在远程 `workspace-write` 发起 Provider 调用前失败关闭，上层 Toolkit 也已禁用两款模型的 Agent route。 |
| `codex-qwen-token-plan` | 已实现 | 可用但有限制（本轮未做 Live） | Key、端点和按量套餐分开 |
| `codex-ollama` | 已实现，公共默认 `127.0.0.1:11434` | 可用但有限制（公共默认未做 Live） | 需验证本机模型、上下文和工具能力 |
| `claude-official` | 已实现 | 不可用（本机未登录，401） | 完成 Claude CLI 官方登录后可重新验收；不等于产品安装失败 |
| `claude-deepseek` | 已实现 | 文本通过；工具层跳过（可用但有限制） | 2026-07-14（UTC+8）：Claude Code 2.1.207 → `deepseek-v4-pro`，exit 0，最终正文严格 `PONG` |
| `claude-qwen-paygo` | 已实现 | 文本通过；工具层跳过（可用但有限制） | 2026-07-14（UTC+8）：Claude Code 2.1.207 → `qwen3.7-max-2026-06-08`，exit 0，最终正文严格 `PONG` |
| `claude-qwen-coding-plan` | 已实现 | 可用但有限制（本轮未做 Live） | 套餐能力与模型候选必须匹配 |
| `claude-qwen-token-plan` | 已实现 | 可用但有限制（本轮未做 Live） | 与按量/Coding Plan 分开 |
| `claude-ollama` | 已实现，公共默认 `127.0.0.1:11434` | 可用但有限制（公共默认未做 Live） | 本机服务和模型为前置条件 |
| `claude-custom` | 已实现 | 可用但有限制（按用户端点分别验收） | 只接受 HTTPS 或 localhost HTTP 的 Anthropic Messages 兼容端点 |
| `oi-qwen-paygo` | Rust 0.0.21+ 适配已实现 | 文本通过；工具层跳过（可用但有限制） | 2026-07-14（UTC+8）：Rust OI 0.0.21 → `qwen3.7-max-2026-06-08`，exit 0，最终正文严格 `PONG` |
| `oi-deepseek` | Rust 0.0.21+ 适配已实现 | 文本通过；工具层跳过（可用但有限制） | 2026-07-14（UTC+8）：Rust OI 0.0.21 → `deepseek-v4-pro`，exit 0，最终正文严格 `PONG` |
| `oi-ollama` | Rust 0.0.21+ 适配已实现 | 可用但有限制（公共默认未做 Live） | 公共默认 `127.0.0.1:11434/v1` |
| `claude-chatgpt-ccp` | 代理运维与 Profile 已实现 | 可用但有限制（本轮未做 OAuth/端到端 Live） | 可选第三方通道，不标成完全“可用” |
| `claude-chatgpt-cliproxy` | 代理运维与 Profile 已实现 | 可用但有限制（本轮未做 OAuth/端到端 Live） | 可选第三方通道，不标成完全“可用” |

另有三条本机用户 Profile 在 2026-07-14（UTC+8）完成文本验收：Codex 0.144.3、Claude Code 2.1.207 和 Rust OI 0.0.21 均连接本机 Ollama `qwen3.6:27b`，目标 CLI exit 0 且最终正文严格等于 `PONG`。这些用户 Profile 使用非公开默认端口，因此证据只说明三套 Ollama 适配路径在该配置下通过，**不能**替代上表三个公共默认 Ollama Profile 的最终验收；三条工具层同样跳过，状态为“可用但有限制”。

2026-07-29（UTC+8）又对本机 `qwen-main-v1` 做了更新后复核：Codex CLI 0.145.0、Claude Code 2.1.220、Qwen Code 0.21.0、OpenCode 1.18.8 均已通过修复后的本地文本 smoke。此前三套非 Codex runner 共同失败的原因是外层沙箱按修改时间选中了缺少配套 helper 的另一版 Desktop `codex.exe`；当前实现固定从同一 npm Codex 包解析启动器与唯一 `codex-windows-sandbox-setup.exe`，不再跨安装来源拼装。完整任务中 Codex 的硬预算/事件协议 3/3；Claude、Qwen Code、OpenCode 仍只能报告 `upstream` 或 `not-enforced`，不能晋升为受管默认。Qwen Code 两个满分产物最终 exit 53，当前 0.21.0 将其定义为会话轮次达到上限，因此状态仍为“可用但有限制”。

## 3. 验收命令

先静态检查：

```powershell
aicli doctor <Profile ID>
aicli native <Profile ID>
```

再由有权使用该账号/Key 的维护者显式执行：

```powershell
aicli test <Profile ID> --live --level text --yes
```

只有文本通过并且要求的工具层完成时才允许显示“可用”。工具层安全隔离无法证明时必须跳过，并保持“可用但有限制”。

当前 Live Test 要求：

- 通过真实目标 CLI，不使用外部 HTTP 请求冒充。
- 进程退出码为 0。
- 最终模型正文严格等于 `PONG`，不能由提示回显刷绿。
- 临时空目录运行，禁用或隔离项目配置、私人规则和普通工具。
- 记录 CLI 版本、Provider、端点、模型、Profile 指纹和测试时间，不记录提示/回复正文或秘密。

`codex-spark-xhigh` 的 machine run 证据与桌面端“能够创建 Spark 任务”是两条不同事实：前者证明 aicli/工具包可以通过 Codex CLI 程序化调用并取得结构化回执，后者只证明 Codex 产品界面提供该模型选项。额度和限流仍是动态外部状态；aicli 不自动降级，调用方如改投本地模型必须显式重提并保留两份回执。

## 4. 当前命令事实

- Codex 思考强度使用当前构建提供的 `/reasoning`，或在 `/model` 中选择；配置层由 `model_reasoning_effort` 控制。
- Claude Code 使用 `/effort` 或 `--effort`。
- Codex 第三方 Profile 由 aicli 管理；透传 `-c`、`--config` 或 `--profile` 会被拒绝，不提供必然失败的覆盖示例。
- Open Interpreter 使用当前 Rust CLI 的 `-c` TOML 配置、`exec`、`/model` 与 `/permissions`；旧 Python 版的参数和依赖安装路径不受支持。
- 三套 CLI 的权限、思考和上下文语义不完全等价。
- 第三方模型下 Claude 结束页 `Total cost: $… (unknown models)` 不是百炼账单；美元多半偏高，真费用以阿里云控制台为准。用户正文见两本中文手册（工作区 start、升级重载、PowerShell `--%`、用量阅读）。

## 5. 模型与套餐动态事实

内置模板当前候选包括：

- 千问主模型：`qwen3.7-max-2026-06-08`；小模型候选：`qwen3.7-plus-2026-05-26`。
- DeepSeek 主模型：`deepseek-v4-pro`；小模型：`deepseek-v4-flash`。
- Ollama 公共模板只使用默认端口和公开模型名；用户必须确认本机已经存在该模型。

模型名、地域、套餐和端点属于动态事实。`0.1.0` 发布时已按官方来源和真实目标 CLI 证据核对；后续版本仍须重新核对。“模板中存在”不等于账号有权调用。

## 6. 代理供应链状态

两个代理均为第三方组件。批准清单可以记录特定版本、asset 与 SHA256，但本轮没有完成交互 OAuth 和订阅链路 Live 验收。

```powershell
aicli proxy ccp update-check
aicli proxy cliproxy update-check
```

发现上游新版本不授权执行。首次安装只接受命中随产品发布批准 SHA256、且通过安全解压和结构验证的 artifact；启动时还要通过进程身份、健康响应与 IPv4 loopback 监听验证，才会保存运行状态。`0.1.0` 不执行已安装代理的受管版本切换，`update` 会明确拒绝并保留当前版本。

## 7. 官方事实源

- Codex：[Profiles](https://learn.chatgpt.com/docs/config-file/config-advanced#profiles)、[Slash commands](https://learn.chatgpt.com/docs/developer-commands)
- Claude Code：[Commands](https://code.claude.com/docs/en/commands)、[Permissions](https://code.claude.com/docs/en/permissions)、[Model configuration](https://code.claude.com/docs/en/model-config)
- Open Interpreter：[Install](https://www.openinterpreter.com/docs/terminal/install)、[CLI Reference](https://www.openinterpreter.com/docs/terminal/cli-reference)、[Providers](https://www.openinterpreter.com/docs/terminal/providers)
- 千问百炼：[Codex](https://help.aliyun.com/zh/model-studio/codex)、[Claude Code](https://help.aliyun.com/zh/model-studio/claude-code)
- DeepSeek：[Claude Code integration](https://api-docs.deepseek.com/guides/agent_integrations/claude_code)
- Ollama：[Codex](https://docs.ollama.com/integrations/codex)、[Claude Code](https://docs.ollama.com/integrations/claude-code)
- 第三方代理：[raine/claude-code-proxy](https://github.com/raine/claude-code-proxy)、[router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
