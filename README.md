# AI CLI Profile Manager

面向 Windows 11 x64 的中文 PowerShell 工具：用统一 Profile 启动原生 Codex CLI、Claude Code、Qwen Code、OpenCode 和当前官方 Rust Open Interpreter，并提供 Provider 隔离、Doctor、显式 Live Test、Codex harness 与可选的第三方代理运维。

命令：`aicli`　版本：`0.3.6`（`main` 源码；source/install/runtime/live 分层回读）　许可证：MIT

它不是新的 Agent 或聊天外壳，不接管历史会话，也不汉化上游 CLI。本工具只负责“选哪条连接、怎样安全启动、出了问题如何验证”。

## 三步开始

```powershell
pwsh -File .\scripts\Install.ps1
aicli setup
aicli start codex-official
# 或：aicli start claude-official
```

目标版本已安装时，确认替换可加 `-Force`。安装后请新开 PowerShell 7，再运行 `aicli version`。

从旧版升级到 `0.3.6` 时，安装器继续先只读预检 Qwen3.7 遗留入口，再把身份与哈希闭合的旧 Profile、旧受管 Codex 文件和旧模块版本移入 `%LOCALAPPDATA%\AiCliProfileManager\retirement\qwen37-v1`。新 `codex-qwen3-7-max-paygo`、其 exact 06-08 TOML 与被引用目录会被明确保留。迁移不读取、移动或删除 SecretRef/密钥；未知或被修改的遗留物会在安装变更前阻断。

不安装的开发入口：

```powershell
pwsh -File .\bin\aicli.ps1 version
pwsh -File .\bin\aicli.ps1 doctor
```

## 当前范围

| 引擎 | 已实现的公开路径 | 验收口径 |
|------|------------------|----------|
| Codex CLI | 官方登录、精确 Qwen3.7 Max 06-08 / Qwen3.8 Max Workspace 按量、精确 DeepSeek V4 Flash 0731 / Pro 0813、本机 qwen-main/review | `0.3.6` source/static；安装与 Live 只认同提交、同指纹回执 |
| Claude Code | 官方登录、DeepSeek V4 Flash、Ollama、自定义 Anthropic Messages | Qwen3.7 Max/Plus 云模板已移除 |
| Qwen Code | 本机 Ollama `qwen-main-v1` machine run | 仅机器入口 |
| OpenCode | 本机 Ollama `qwen-main-v1` machine run | 仅机器入口 |
| Open Interpreter | 当前官方 Rust `0.0.21+`：DeepSeek V4 Flash Chat、Ollama | Qwen3.7 云模板已移除；旧 Python `0.4.x` 不支持 |
| ChatGPT → Claude | `raine/claude-code-proxy`、`CLIProxyAPI` | 可选第三方通道；本轮未完成 OAuth 与端到端 Live 验收 |

DeepSeek 当前官方 Codex/Responses 目录同时支持 `deepseek-v4-flash` 与 `deepseek-v4-pro`。AICLI 用 `codex-deepseek` 精确绑定 alias `deepseek-v4-flash` / 版本 `DeepSeek-V4-Flash-0731`，用 `codex-deepseek-v4-pro` 精确绑定 alias `deepseek-v4-pro` / 版本 `DeepSeek-V4-Pro-0813`；两者都是 1048576 context、Responses、`low/high/max`，默认 `max`，不接受模型或 fallback 覆盖。动态支持状态以 [Codex integration](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/) 与 [DeepSeek Change Log](https://api-docs.deepseek.com/updates/) 为准。

Qwen 云端使用两个互相隔离的 exact Profile：`codex-qwen3-7-max-paygo` 只固定 `qwen3.7-max-2026-06-08`，`codex-qwen3-8-max-paygo` 只固定 `qwen3.8-max`；两者都只接受北京百炼 Workspace 按量 Responses endpoint，使用 983616 context、95% 有效窗口、262144 token 自动压缩阈值，用户 `max` 映射为原生最高 `xhigh`。通用 alias、05-20、preview、Plus、通用 DashScope、Token Plan、模型覆盖和 fallback 都不进入这两个入口。

DeepSeek API Key 仍由 Windows CurrentUser DPAPI 保存，Codex 受管配置只写 `env_key` 引用；不复制官方示例中的明文 `experimental_bearer_token`，也不写入 `preferred_auth_method`。Qwen Code `0.21` 与 OpenCode `1.18.8` 虽有上游 DeepSeek 原生接入方式，但 AICLI 当前 machine-only 外层沙箱断网，且尚无把真实 Key 与远程 egress 隔离开的 relay；因此不开放这两条远程模板，也不生成看似可用的假 Profile。

Qwen3.7 只恢复上述单一 exact Codex 快照。旧 `codex-qwen-paygo` 等 Profile、Qwen3.7 Plus、其他 Max alias/snapshot、Claude/OI 路线和导入入口继续退役；旧用户 Profile 或原生 `--model` / `--fallback-model` 会失败关闭，不会自动改投新入口或 Qwen3.8。本地 `qwen-main-v1` / `qwen-review-v1` 不受影响。

2026-07-14（UTC+8）曾完成 Claude Code / Rust Open Interpreter → `deepseek-v4-pro` 的文本验收；当前 Claude Code / Open Interpreter 模板已切换为 Flash-only，旧 Profile 指纹已经失效，也不能作为本轮任何 Codex exact Profile 的当前证据。逐项状态见兼容性页。

Claude 官方路径在未登录机器上出现 `401`，通常表示需要先完成 Claude Code 自己的官方登录，不代表本工具安装失败。

## 常用命令

```text
aicli profile list --available
aicli profile configure <模板 ID>
aicli start <精确 Profile ID> --project <可信项目路径>
aicli run <Profile ID> --stdin --json --project <项目路径> [--sandbox-policy danger-full-access] [--no-web-search] [--event-file <绝对 JSONL 路径>] -- <原生参数...>
aicli doctor [Profile ID] [--json]
aicli test <Profile ID> --live [--level text|tool|all] [--yes]
aicli native <Profile ID>
aicli eject <Profile ID> [--output <新目录>]
aicli help [主题或命令]
```

`run` 是供上层 AI/程序使用的非交互入口：任务正文只从 stdin 输入，并返回 JSON envelope。所有当前和未来 Codex Profile 共用一个稳定权限合同：AICLI 固定 app-server 原生 `danger-full-access`，显式传入 `read-only` / `workspace-write` 会失败关闭；AICLI 不根据模型或 Provider 降权。每次 run 仍使用一次性 `CODEX_HOME`，清除无关父环境，并在公开任何模型输出前验证 app-server 返回的 actual model、modelProvider、CLI version 与 `dangerFullAccess` 权限身份。缺失、错配或 `model/rerouted` 均失败，不把 launch plan 冒充实际身份。非 Codex 引擎仍保留自己的 `read-only` / `workspace-write` 合同。

Codex harness 在 `thread/start` 和 `turn/start` 都选择命名权限 `permissions=:danger-full-access`；thread receipt 必须实际返回 `activePermissionProfile=:danger-full-access` 与 `sandbox.type=dangerFullAccess`。这一规则不枚举模型，因此未来 Profile 自动继承。`approvalPolicy=never` 只表示不弹审批，不把全访问伪装成沙箱。交互式 `aicli start` 仍直接进入上游 Codex CLI，由上游会话权限界面负责。

所有 Codex harness 当前及未来模型还默认获得同一个受管 `public_web_search` 动态工具；它固定访问 `https://cn.bing.com/search` 的 RSS 响应，拒绝重定向、Cookie、任意 endpoint/Header/凭据，并把结果作为不可信公共文本交给模型。Windows 受管系统代理可用于建立固定 HTTPS 连接，但不会注入默认凭据。公开事件只记录 `web_search` 生命周期、`public_web_search`、`bing-rss-v1` 与计数，不记录查询或结果正文。无需联网时显式加 `--no-web-search`；其他 Codex 权限仍保持 `danger-full-access`。

machine child 的父环境按运行时 allowlist 重建，不继承无关凭据或调试设置；受管 `EnvironmentDelta` 只显式注入本次 Profile 所需变量。官方 Codex/Spark 使用一次性 `CODEX_HOME` 中的登录 `auth.json` 副本；第三方 Provider Key 由 SecretRef 解封后只进入目标子进程环境。Qwen Code/OpenCode 不提供交互式 `start`。

除 `codex-qwen3-7-max-paygo` → exact 06-08 外，Qwen3.7 Cloud Agent route、兼容 ID 和历史 Flash/Plus 入口均已退役；历史记录只保留在变更史，不能启动、导入或作为当前证据。

本机 Codex 预置两个精确 Profile：`codex-ollama-main` → `qwen-main-v1`，`codex-ollama-review` → `qwen-review-v1`，均固定 `127.0.0.1:32100`、Responses、最高 `max` 且无 fallback。旧泛型 `codex-ollama` 已从公开目录隐藏。另有显式 opt-in 的 `codex-spark-xhigh`，精确选择 `gpt-5.3-codex-spark` 与默认 `xhigh`。所有 Profile 都不自动 fallback，上层调用者仍负责选择、额度失败后的显式重提、隔离工作区和最终验收。

上层若考虑免费本地模型或订阅内 Spark，唯一收益口径是减少边际付费 token/API 成本；简单、低风险、可验证且净节省为正时才值得委派。疑难任务、授权、高风险动作和最终判断保留给顶级模型，亲自完成不是故障。

`0.3.6` 的 source/static/install/runtime/live 必须分开报告。旧安装态、旧受管 TOML 或旧回执不是本版本证据；只有从最终提交安装并固定路径回读后才能声明 installed current。云 Live 只在现有授权与 SecretRef 下各执行一次，失败不自动重试。

已有 OpenClaw DeepSeek 配置时，可先安全预览再导入；脚本可生成 Codex Flash 0731、Codex Pro 0813、Claude Flash、OI Flash 四个 Profile。Qwen3.7 配置不会由导入器读取、复制或迁移；06-08 必须显式配置新 exact Profile：

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

4. [Codex harness / machine run](docs/user/MACHINE-RUN.md)：stdin/JSON 协议、全访问合同、运行时身份与能力限制。

根目录同时保留两本可打印手册；PDF 只在由当前 `0.3.6` Markdown 重新生成并完成视觉验收后才算 current：

- 《[AI CLI Profile Manager 使用手册（PDF）](<AI CLI Profile Manager 使用手册.pdf>)》
- 《[Codex、Claude Code 与 Open Interpreter CLI 中文手册（PDF）](<Codex、Claude Code 与 Open Interpreter CLI 中文手册.pdf>)》

## 安全与隐私摘要

- API Key 使用 Windows DPAPI CurrentUser 保存；不进入 Git、日志、`show`、`native` 或 `eject`。
- Provider 环境只注入目标子进程，不永久写全局 Provider 变量。
- Open Interpreter 云端 Key 还会从它的 Shell 工具环境中排除。
- 受管代理只允许 `127.0.0.1`，下载的 Windows artifact 必须命中批准 SHA256。
- Live Test 必须显式使用 `--live`，可能消耗额度；提示和回复正文不落盘。
- Codex 文本 Live 保持 `danger-full-access`，并把“观测到零次工具调用”作为通过条件；首个工具事件会触发终止和失败，但这不是执行前禁用，工具仍可能在事件被观测前产生本机副作用，只应在明确授权时执行。
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
