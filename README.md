# AI CLI Profile Manager

面向 Windows 11 x64 的中文 PowerShell 工具：用统一 Profile 启动原生 Codex CLI、Claude Code、Qwen Code、OpenCode 和当前官方 Rust Open Interpreter，并提供 Provider 隔离、Doctor、显式 Live Test、沙箱化 machine run 与可选的第三方代理运维。

命令：`aicli`　版本：`0.3.3`（本地/源码目标，未发布 Release）　许可证：MIT

它不是新的 Agent 或聊天外壳，不接管历史会话，也不汉化上游 CLI。本工具只负责“选哪条连接、怎样安全启动、出了问题如何验证”。

## 三步开始

```powershell
pwsh -File .\scripts\Install.ps1
aicli setup
aicli start codex-official
# 或：aicli start claude-official
```

目标版本已安装时，确认替换可加 `-Force`。安装后请新开 PowerShell 7，再运行 `aicli version`。

不安装的开发入口：

```powershell
pwsh -File .\bin\aicli.ps1 version
pwsh -File .\bin\aicli.ps1 doctor
```

## 当前范围

| 引擎 | 已实现的公开路径 | 验收口径 |
|------|------------------|----------|
| Codex CLI | 官方登录、DeepSeek V4 Flash Responses、千问 Responses 按量/Token Plan、本机 Ollama | DeepSeek 路径为 public beta；当前真实 Live 前状态为“可用但有限制” |
| Claude Code | 官方登录、DeepSeek V4 Flash、千问三套餐、Ollama、自定义 Anthropic Messages | 同上 |
| Qwen Code | 本机 Ollama `qwen-main-v1` machine run | 仅机器入口；必须经过外层沙箱 |
| OpenCode | 本机 Ollama `qwen-main-v1` machine run | 仅机器入口；必须经过外层沙箱 |
| Open Interpreter | 当前官方 Rust `0.0.21+`：千问 Responses、DeepSeek V4 Flash Chat、Ollama | 旧 Python `0.4.x` 明确不支持；最终 Live 状态见兼容性页 |
| ChatGPT → Claude | `raine/claude-code-proxy`、`CLIProxyAPI` | 可选第三方通道；本轮未完成 OAuth 与端到端 Live 验收 |

DeepSeek 在 2026-07-31 开放 [Codex public beta](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/) 与 [Responses API](https://api-docs.deepseek.com/guides/responses_api/)：AICLI 新增 `codex-deepseek`，固定 `deepseek-v4-flash`、Responses、1M context，要求 Codex CLI `0.144.0+`，默认 reasoning effort 为 `high`，可选 `low` / `high` / `max`。`deepseek-v4-pro` 仅作为未来扩展的不可选 `reserved` 项；官方尚未支持前不生成 Pro Profile，也不允许模型覆盖选中它。千问 Coding Plan 与纯 Chat Completions 直连仍不属于 Codex 路径。动态支持状态以 [DeepSeek Change Log](https://api-docs.deepseek.com/updates) 为准。

DeepSeek API Key 仍由 Windows CurrentUser DPAPI 保存，Codex 受管配置只写 `env_key` 引用；不复制官方示例中的明文 `experimental_bearer_token`，也不写入 `preferred_auth_method`。Qwen Code `0.21` 与 OpenCode `1.18.8` 虽有上游 DeepSeek 原生接入方式，但 AICLI 当前 machine-only 外层沙箱断网，且尚无把真实 Key 与远程 egress 隔离开的 relay；因此不开放这两条远程模板，也不生成看似可用的假 Profile。

2026-07-14（UTC+8）曾完成 Claude Code / Rust Open Interpreter → `deepseek-v4-pro` 的文本验收；当前公开模板已切换为 Flash-only，旧 Profile 指纹已经失效，不能作为 `deepseek-v4-flash` 或 `codex-deepseek` 的当前证据。逐项状态见兼容性页。

Claude 官方路径在未登录机器上出现 `401`，通常表示需要先完成 Claude Code 自己的官方登录，不代表本工具安装失败。

## 常用命令

```text
aicli profile list --available
aicli profile configure <模板 ID>
aicli start <Profile ID> [--project <项目路径>] [-- <原生参数...>]
aicli run <Profile ID> --stdin --json --project <项目路径> --sandbox-policy read-only|workspace-write [--event-file <绝对 JSONL 路径>] -- <原生参数...>
aicli doctor [Profile ID] [--json]
aicli test <Profile ID> --live [--level text|tool|all] [--yes]
aicli native <Profile ID>
aicli eject <Profile ID> [--output <新目录>]
aicli help [主题或命令]
```

`run` 是供上层 AI/程序使用的非交互入口：调用接口只从 stdin 接收任务正文，不把正文写入 argv、环境变量、工作区或临时文件，并返回一个 JSON envelope。Codex machine run 以当前实装并已验收的 npm `codex-cli 0.145.0` app-server 协议为基线；CLI 更新后默认尝试运行，并用严格的字段、通知、thread/turn、item 生命周期、成功轮次 `completed` 状态和清理门禁判断兼容性，不兼容时明确失败。只有已验证的 `0.145.x` 允许一种窄兼容：一个或多个未完成的公开进度 `agentMessage` 必须全部早于同轮次、已完成且有公开正文的最终 `agentMessage`；更新/未知版本、缺少后续 final、final 之后的新 orphan，或任何非消息 orphan 都不会套用该例外。可选的 `--event-file` 会持续追加 `aicli.machine-event.v1` 公共事件：公开 `agentMessage` 增量按短语聚合为 `output.delta`，进度、粗粒度工具事件和最终结果可见；隐藏推理正文、命令/参数、工具输入输出、压缩 history、文件内容和原始 stderr 不公开。`maxSteps` 只统计不同的非输出 ThreadItem，公开进度与最终消息不会挤占行动预算；墙钟、输出上限和工具调用上限仍是独立硬门。上下文事件只投影 app-server 实际报告的“当前上下文 / 模型上下文上限”与自动压缩完成计数，不做本地 token 或上下文估算。

官方 Codex 的原生 `workspace-write` 在 Codex CLI `0.145.x` 中必须同时使用 `permissions=:workspace` 与唯一的 `runtimeWorkspaceRoots`，且该根必须精确等于请求 `cwd`；AICLI 会在 `thread/start` 和 `turn/start` 传入同一绑定，回读有效权限并在模型调用前执行写探针。空根、根漂移或探针失败都会提前失败。`approvalPolicy` 固定为 `never`，任何审批/用户输入 RPC 均失败关闭。本地 Ollama Codex 及其他适用本地引擎仍使用网络关闭的 Windows 外层沙箱。

machine child 的父环境按运行时 allowlist 重建，不再继承无关凭据或调试设置；受管 `EnvironmentDelta` 仍可显式注入本次 Profile 所需变量。官方 Codex/Spark 使用一次性 `CODEX_HOME` 中的登录 `auth.json` 副本，不使用付费 API Key，也不继承用户配置、规则、技能或历史。Qwen Code/OpenCode 不提供绕过边界的交互式 `start`。

远程 Qwen Cloud Agent route 当前禁用且不做付费复测。2026-07-28 以前标成 Flash/Plus 的 Codex Agent 记录因 bridge 丢失模型覆盖，实际调用了 Profile 主模型 Max；这些旧身份与能力结论已撤回，不能作为 Flash/Plus 证据。

本机预置本地 Profile：`codex-ollama-main`、`claude-ollama-main`、`qwen-code-ollama-main`、`opencode-ollama-main`，都固定访问 `127.0.0.1:32100` 的 `qwen-main-v1`。另有显式 opt-in 的 `codex-spark-xhigh`，精确选择 `gpt-5.3-codex-spark` 与默认 `xhigh`。2026-07-29 的源代码入口真实任务已经证明 Spark 的工作区写权限生效，但 `code_repair` 在硬上限 `80` 步下到达 `81/80`，确定性得分仅 `2/9`；因此当前能力验收不通过，不登记为合格代码 Agent，也不为改变结果重复复测。所有 Profile 都不自动 fallback，上层调用者仍负责选择、额度失败后的显式重提、隔离工作区和最终验收。

`0.3.3` 是当前本地/源码目标，包含 DeepSeek Flash-only 与尚未发布的 machine-run 修复；它不是 GitHub Release。维护者用仓库源代码入口验收时必须明确记录该入口；在执行正式安装/候选晋升前，不得把 source 验收写成 installed runtime 已更新。

已有 OpenClaw 千问/DeepSeek 配置时，可先安全预览再导入；DeepSeek 可生成 `codex-deepseek`、`claude-deepseek`、`oi-deepseek` 三个 Flash-only Profile，默认不会写入，详见主手册：

```powershell
pwsh -File .\scripts\Import-FromOpenClaw.ps1
pwsh -File .\scripts\Import-FromOpenClaw.ps1 -Apply
```

## 中文手册

1. 《[AI CLI Profile Manager 使用手册](<docs/user/AI CLI Profile Manager 使用手册.md>)》
   安装、Profile、Doctor/Live、Open Interpreter、代理、更新、卸载、隐私和排障。

2. 《[Codex、Claude Code 与 Open Interpreter CLI 中文手册](<docs/user/Codex、Claude Code 与 Open Interpreter CLI 中文手册.md>)》
   三套原生 CLI 的常用命令与中文解释；学习篇位于最后。

3. [文档顺序索引](docs/user/README.md) · [兼容性与最终验收状态](docs/compatibility/VERIFIED-COMPATIBILITY.md)

4. [沙箱化 machine run](docs/user/MACHINE-RUN.md)：供上层 AI 调用本地或官方 Codex 智能体的 stdin/JSON 协议、权限边界与能力限制。

根目录同时保留两本可打印手册；`0.3.3` PDF 已从对应 Markdown 重新生成，并完成 15 页 / 8 页逐页渲染视觉验收：

- 《[AI CLI Profile Manager 使用手册（PDF）](<AI CLI Profile Manager 使用手册.pdf>)》
- 《[Codex、Claude Code 与 Open Interpreter CLI 中文手册（PDF）](<Codex、Claude Code 与 Open Interpreter CLI 中文手册.pdf>)》

## 安全与隐私摘要

- API Key 使用 Windows DPAPI CurrentUser 保存；不进入 Git、日志、`show`、`native` 或 `eject`。
- Provider 环境只注入目标子进程，不永久写全局 Provider 变量。
- Open Interpreter 云端 Key 还会从它的 Shell 工具环境中排除。
- 受管代理只允许 `127.0.0.1`，下载的 Windows artifact 必须命中批准 SHA256。
- Live Test 必须显式使用 `--live`，可能消耗额度；提示和回复正文不落盘。
- `aicli uninstall` 会移除模块、命令垫片、安装器加入的用户 `PATH` 项和受管 PowerShell Profile 块；默认保留用户数据，彻底清理由 `--purge-user-data` 显式选择。

完整说明：[PRIVACY.md](PRIVACY.md) · [SECURITY.md](SECURITY.md) · [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

## 从源码参与开发

以下命令只适用于完整源码仓库；面向普通用户的 Release ZIP 不包含测试与构建脚本。

```powershell
pwsh -File .\scripts\Test-Release.ps1
pwsh -File .\scripts\Build.ps1
```

贡献规则见 [CONTRIBUTING.md](https://github.com/wlyaaaaa/ai-cli-profile-manager/blob/main/CONTRIBUTING.md)，版本变化见 [CHANGELOG.md](CHANGELOG.md)。维护者设计与实施史见 [项目设计与实施归档](https://github.com/wlyaaaaa/ai-cli-profile-manager/blob/main/docs/maintainer/%E9%A1%B9%E7%9B%AE%E8%AE%BE%E8%AE%A1%E4%B8%8E%E5%AE%9E%E6%96%BD%E5%BD%92%E6%A1%A3.md)。

本项目与 OpenAI、Anthropic、阿里云、DeepSeek、Ollama、Open Interpreter 及两个第三方代理作者均无官方隶属关系。
