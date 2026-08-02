# 兼容性与最终验收状态

文档日期：2026-08-03（UTC+8）
产品版本：`0.3.3`（本机已安装并完成静态验收，未发布 Release）
状态原则：代码路径存在不等于 Provider 已通过；最终状态必须来自当前版本、当前 Profile 指纹和真实目标 CLI 的验收记录。

当前仓库包含尚未发布为 GitHub Release 的 DeepSeek 与 machine-run 变更；本机已从提交 `32dad74` 的干净快照安装 `0.3.3`，安装 payload 与快照逐文件 SHA256 一致。下文明确标注为“源代码入口”或“本机 installed”的证据都不得解释成 GitHub Release 已发布，也不得跨 Profile 指纹复用旧 Live 记录。

## 1. 当前实现基线

开发环境当前检测到：Windows 11、PowerShell 7.6.4、Codex CLI 0.146.0-alpha.9.2、Claude Code 2.1.220、Qwen Code 0.21.0、OpenCode 1.18.8、Open Interpreter 0.0.21。它们只是当前实现环境，不是所有用户机器的保证，也不代替逐 Profile Live 验收。`codex-deepseek` 的上游最低要求为 Codex CLI `0.144.0`。

Open Interpreter 只支持当前官方 Rust CLI `0.0.21` 或更高。输出形如 `Open Interpreter 0.4.x` 的旧 Python 产品不在支持范围。

## 2. 最终验收矩阵

本页不沿用修复前的 Live Test 成功记录。下表只记录 Live 判定、配置隔离和 Rust OI 适配器更新后的当前证据；没有新证据的路径保持“可用但有限制”或“不可用”。

| Profile / 路径 | 实现状态 | 本轮最终 Live 状态 | 发布说明 |
|----------------|----------|--------------------|----------|
| `codex-official` | 已实现 | 可用但有限制（本轮按用户要求未做 Live） | 使用上游官方登录；不得由桌面端登录状态推断 CLI 一定可用 |
| `codex-deepseek` | `0.3.3` 已在本机安装；DeepSeek Codex public beta | 可用但有限制（静态验收通过，尚未做当前 Flash Live） | 固定 `deepseek-v4-flash`、Responses、十进制 1M context、默认 `high`，支持 `low` / `high` / `max`；`deepseek-v4-pro` 仅 reserved 且不可选。2026-08-03（UTC+8）已验证 Profile 脱敏、Codex CLI 最低版本、受管 TOML、`env_key`、内容寻址模型目录及 Codex `debug models` 唯一命中 `1000000`；未调用 DeepSeek API。Key 由 DPAPI 保存，Codex 配置只引用 `env_key`。machine route 当前仅 `read-only`；`workspace-write` 在请求前失败关闭。 |
| `codex-spark-xhigh` | 已实现；workspace 修复仅在未发布源码 | 能力验收不通过 | 2026-07-24 的只读严格 JSON smoke 仍只证明文本链路。2026-07-29 使用仓库源代码入口和 `gpt-5.3-codex-spark` / `xhigh` 的真实 `workspace-write` 任务已证明命名权限与工作区写入生效；但 `code_repair` 在硬上限 `maxSteps=80` 下达到 `81/80` 后终止，确定性得分 `2/9`。本轮停止复测，不把权限修复等同于代码 Agent 能力通过。官方 Spark 使用临时 `CODEX_HOME` / `auth.json` 副本，不走付费 API Key。 |
| `codex-qwen-paygo` | 模型绑定与受管目录修复已在本机 installed；付费 route 禁用 | 不可用（不做付费 Live 复验） | 旧 Flash/Plus 记录实际落到 Profile 主模型 Max，身份声明已撤回。当前 installed payload 保留默认 `qwen3.7-max-2026-06-08`，六个候选共用非空基础指令的 983616/95% model catalog，并同时绑定 Provider override、machine plan、`thread/start` 和回执；不含错误的 `ultra`。Codex 本地解析唯一命中 983616，静态修复不构成付费 Live。 |
| `codex-qwen-token-plan` | 已实现；受管目录修复已在本机 installed | 可用但有限制（本轮未做 Live） | 与按量共用 983616/95% 目录，但 Key、端点和套餐分开；默认模型未改变 |
| `codex-ollama` | 已实现，公共默认 `127.0.0.1:11434` | 可用但有限制（公共默认未做 Live） | 本机 `codex-ollama-main` 使用内容寻址的 `qwen-main-v1` 262144/95% 目录；当前 Codex `debug models` 静态回读唯一命中，未执行新模型 Live |
| `claude-official` | 已实现 | 不可用（本机未登录，401） | 完成 Claude CLI 官方登录后可重新验收；不等于产品安装失败 |
| `claude-deepseek` | Flash-only 模板与上下文修复已在本机 installed | 可用但有限制（尚未做当前 Flash Live） | 2.1.193+ 按 `deepseek-v4-flash` 注入 MAX/AUTO=`1000000`；不设置提前压缩覆盖或禁压缩变量。安装态静态回读确认已知模型注入 1M，未知模型清除 MAX/AUTO、提前压缩与两个禁压缩变量。2026-07-14 的 Pro 记录属于旧指纹，不能证明当前 Flash。 |
| `claude-qwen-paygo` | 已实现；逐模型上下文修复已在本机 installed | 文本通过；工具层跳过（可用但有限制） | 已知模型按最终 `--model` 注入 1M；未知模型不猜。2026-07-14（UTC+8）Claude Code 2.1.207 → Max 的 `PONG` 记录早于当前指纹，只保留历史。 |
| `claude-qwen-coding-plan` | 已实现 | 可用但有限制（本轮未做 Live） | 套餐能力与模型候选必须匹配 |
| `claude-qwen-token-plan` | 已实现 | 可用但有限制（本轮未做 Live） | 与按量/Coding Plan 分开 |
| `claude-ollama` | 已实现，公共默认 `127.0.0.1:11434` | 可用但有限制（公共默认未做 Live） | 本机 `claude-ollama-main` 在 2.1.193+ 为 `qwen-main-v1` 注入 MAX/AUTO=`262144`；本机服务和模型仍是前置条件 |
| `claude-custom` | 已实现 | 可用但有限制（按用户端点分别验收） | 只接受 HTTPS 或 localhost HTTP 的 Anthropic Messages 兼容端点 |
| `oi-qwen-paygo` | Rust 0.0.21+ 适配已实现 | 文本通过；工具层跳过（可用但有限制） | 2026-07-14（UTC+8）：Rust OI 0.0.21 → `qwen3.7-max-2026-06-08`，exit 0，最终正文严格 `PONG` |
| `oi-deepseek` | Rust 0.0.21+ Flash-only 模板已实现 | 可用但有限制（尚未做当前 Flash Live） | 2026-07-14 的 `deepseek-v4-pro` 文本通过记录属于旧 Profile 指纹；不能作为当前 `deepseek-v4-flash` 证据。 |
| `oi-ollama` | Rust 0.0.21+ 适配已实现 | 可用但有限制（公共默认未做 Live） | 公共默认 `127.0.0.1:11434/v1` |
| `claude-chatgpt-ccp` | 代理运维与 Profile 已实现 | 可用但有限制（本轮未做 OAuth/端到端 Live） | 可选第三方通道，不标成完全“可用” |
| `claude-chatgpt-cliproxy` | 代理运维与 Profile 已实现 | 可用但有限制（本轮未做 OAuth/端到端 Live） | 可选第三方通道，不标成完全“可用” |

另有三条本机用户 Profile 在 2026-07-14（UTC+8）完成文本验收：Codex 0.144.3、Claude Code 2.1.207 和 Rust OI 0.0.21 均连接本机 Ollama `qwen3.6:27b`，目标 CLI exit 0 且最终正文严格等于 `PONG`。这些用户 Profile 使用非公开默认端口，因此证据只说明三套 Ollama 适配路径在该配置下通过，**不能**替代上表三个公共默认 Ollama Profile 的最终验收；三条工具层同样跳过，状态为“可用但有限制”。

2026-07-29（UTC+8）又对本机 `qwen-main-v1` 做了更新后复核：Codex CLI 0.145.0、Claude Code 2.1.220、Qwen Code 0.21.0、OpenCode 1.18.8 均已通过修复后的本地文本 smoke。2026-08-03 的 installed payload 进一步补齐 OpenCode 262144/8192 limit、20000 reserved、最近 4 轮/16384 token、`prune=false` 与本地 compaction model；真实 `opencode debug config --pure` 已成功解析这些一次性设置，修复 context=0 导致自动压缩失效。这些仍是静态/runtime-config 证据，不是新模型 Live。完整任务中 Codex 的硬预算/事件协议 3/3；Claude、Qwen Code、OpenCode 仍只能报告 `upstream` 或 `not-enforced`，不能晋升为受管默认。

Qwen Code 0.21.0 与 OpenCode 1.18.8 的上游原生能力不能自动变成 AICLI 公开 DeepSeek 路径。当前这两套 runner 仅允许 machine-only 禁网沙箱；若直接接远程 DeepSeek，真实 Key 会进入可执行 Shell 的子进程环境，同时缺少受控远程 egress relay。边界未补齐前状态为“不可用（未开放）”，不创建假 Profile。

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

`codex-spark-xhigh` 的 machine run 证据与桌面端“能够创建 Spark 任务”是两条不同事实。当前证据进一步拆成三层：旧只读 smoke 证明文本链路，2026-07-29 的写任务证明源码权限修复生效，而同一任务的 `81/80` 与 `2/9` 证明能力验收不通过。额度和限流仍是动态外部状态；aicli 不自动降级，调用方如改投本地模型必须显式重提并保留两份回执。

## 4. 当前命令事实

- Codex 思考强度使用当前构建提供的 `/reasoning`，或在 `/model` 中选择；配置层由 `model_reasoning_effort` 控制。
- Claude Code 使用 `/effort` 或 `--effort`。
- Codex 第三方 Profile 由 aicli 管理；透传 `-c`、`--config` 或 `--profile` 会被拒绝，不提供必然失败的覆盖示例。
- Open Interpreter 使用当前 Rust CLI 的 `-c` TOML 配置、`exec`、`/model` 与 `/permissions`；旧 Python 版的参数和依赖安装路径不受支持。
- 三套 CLI 的权限、思考和上下文语义不完全等价。
- 第三方模型下 Claude 结束页 `Total cost: $… (unknown models)` 不是百炼账单；美元多半偏高，真费用以阿里云控制台为准。用户正文见两本中文手册（工作区 start、升级重载、PowerShell `--%`、用量阅读）。

## 5. 模型与套餐动态事实

内置模板当前候选包括：

- 千问模板仍可能声明 `qwen3.7-max-2026-06-08` 与其他候选模型，但付费 Qwen Agent route 当前禁用；Flash/Plus 旧记录的模型身份已撤回，模板存在不代表已验收或允许默认调用。
- DeepSeek 当前公开模板唯一可选模型：`deepseek-v4-flash`。Codex 使用 Responses public beta、1M context、默认 `high`；`deepseek-v4-pro` 只保留 `reserved` 元数据，官方支持前不可选。
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
- DeepSeek：[Codex integration](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/)、[Responses API](https://api-docs.deepseek.com/guides/responses_api/)、[Claude Code integration](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/)、[Change Log](https://api-docs.deepseek.com/updates)
- Ollama：[Codex](https://docs.ollama.com/integrations/codex)、[Claude Code](https://docs.ollama.com/integrations/claude-code)
- 第三方代理：[raine/claude-code-proxy](https://github.com/raine/claude-code-proxy)、[router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
