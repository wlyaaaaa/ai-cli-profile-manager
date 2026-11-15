# 兼容性与最终验收状态

文档日期：2026-11-15
产品版本：`0.3.19`（source/install/runtime/live 分层验收）
状态原则：代码路径存在不等于 Provider 已通过；最终状态必须来自当前版本、当前 Profile 指纹和真实目标 CLI 的验收记录。

本页严格分开 source/static/install/runtime/live。任何旧版本安装或旧 Live 回执都不能证明 `0.3.19`；最终安装提交、payload、受管 TOML/catalog 和 Live 回执必须分别固定指纹。

## 1. 当前实现基线

2026-11-15 本轮源码 Manifest 与本机加载模块均为 0.3.19；GLM-5.3 的 text 回执实际观测到 Codex CLI 0.167.0。Flash 预检没有取得 CLI 版本，不把另一条路线的运行时证据挪给它。

2026-09-17 留存的环境快照（本轮未重测这些上游版本）：Windows 11、PowerShell 7.6.4、PATH 固定解析的 npm Codex CLI 0.147.0、Claude Code 2.1.220、Qwen Code 0.21.0、OpenCode 1.18.18、Open Interpreter 0.0.21。WindowsApps 中另有不可直接版本探测的 Codex Desktop 可执行文件，不与 npm CLI 混为一谈。它们只是历史实现环境，不是所有用户机器的保证，也不代替逐 Profile Live 验收。`codex-deepseek-flash` 的最低兼容基线仍按 Codex CLI `0.144.0` 或更高处理；桌面桥每次启动动态定位当前 Codex 引擎，不固定版本目录。

Open Interpreter 只支持当前官方 Rust CLI `0.0.21` 或更高。输出形如 `Open Interpreter 0.4.x` 的旧 Python 产品不在支持范围。

## 2. 最终验收矩阵

2026-11-15 从本机 settings.json 的 verification 回读。下表列出当前源码 Manifest；记录列保留验收时的产品版本、级别、结果、退出码和北京时间。旧版本通过或失败都是历史证据，不晋升为 0.3.19 通过；没有同 ID 记录的入口写待验。即使产品版本相同，CLI、模型、端点或 Profile 指纹变化后也须重新验收。

本轮只执行两条 GLM coding-plan 的 text（文本）级验收；不调用 Qwen paygo、DeepSeek 或其他路线，不执行 agent（真实文件任务）级验收。GLM 入口已存在于 data/providers/codex-glm-5-3.json 和 codex-glm-5-3-flash.json；“验收失败”不表示“入口不存在”。

| Profile / 路径 | 当前入口 / 模型 | 本机最近验收记录 | 0.3.19 状态 |
| --- | --- | --- | --- |
| `claude-custom` | 已实现 | 无记录 | 待验 |
| `claude-official` | 已实现 | 无记录 | 待验 |
| `claude-ollama` | 已实现 / qwen3:8b | 无记录 | 待验 |
| `claude-ollama-main` | 已实现 / qwen3.8-27b:256k | 无记录 | 待验 |
| `codex-custom-responses` | 已实现（隐藏模板） | 无记录 | 待验 |
| `codex-deepseek-flash` | 已实现 / deepseek-flash | `0.3.19` / text / 通过 / exit=0 / 2026-10-28 04:52:13 | 0.3.19 text 通过记录（2026-10-28）；本轮未重测 |
| `codex-deepseek-v4-pro` | 已实现 / deepseek-v4-pro；CLI-only | `0.3.5` / text / 失败 / exit=0 / 2026-08-14 04:30:46 | 待验（旧版本失败） |
| `codex-glm-5-3` | 已实现 / glm-5.3 | `0.3.19` / text / 失败 / exit=1 / 2026-11-15 16:10:57 | text 失败（原因见下） |
| `codex-glm-5-3-flash` | 已实现 / glm-5.3-flash | `0.3.19` / text / 失败 / exit=未取得 / 2026-11-15 16:11:45 | text 失败（原因见下） |
| `codex-official` | 已实现 / gpt-6.1-sol | `0.3.12` / agent / 通过 / exit=0 / 2026-08-28 11:11:58 | 待验（旧版本通过） |
| `codex-ollama` | 已实现（隐藏模板） / qwen3:8b | `0.1.0` / text / 通过 / exit=未取得 / 2026-07-14 02:16:42 | 待验（旧版本通过） |
| `codex-ollama-main` | 已实现 / qwen3.8-27b:256k | `0.3.14` / agent / 通过 / exit=0 / 2026-09-16 00:54:59 | 待验（旧版本通过） |
| `codex-ollama-qwen3-6-35b-abliterated` | 已实现 / qwen3.6-35b-abliterated:256k | `0.3.14` / agent / 失败 / exit=1 / 2026-09-16 01:09:04 | 待验（旧版本失败） |
| `codex-ollama-qwen3-8-27b` | 已实现 / qwen3.8-27b:256k | `0.3.12` / agent / 通过 / exit=0 / 2026-08-28 11:05:14 | 待验（旧版本通过） |
| `codex-ollama-qwen3-8-27b-abliterated` | 已实现 / qwen3.8-27b-abliterated:256k | 无记录 | 待验 |
| `codex-ollama-review` | 已实现 / qwen3.6-35b:256k | `0.3.14` / agent / 通过 / exit=0 / 2026-09-16 01:01:03 | 待验（旧版本通过） |
| `codex-qwen3-7-max-paygo` | 已实现 / qwen3.7-max-2026-06-08 | `0.3.6` / text / 失败 / exit=4 / 2026-08-14 18:07:29 | 待验（旧版本失败） |
| `codex-qwen3-8-max-paygo` | 已实现 / qwen3.8-max-0902 | `0.3.15` / text / 通过 / exit=0 / 2026-09-16 10:29:56 | 待验（旧版本通过） |
| `oi-ollama` | 已实现 / qwen3-coder:30b | `0.1.0` / text / 通过 / exit=未取得 / 2026-07-14 02:41:20 | 待验（旧版本通过） |
| `opencode-ollama-main` | 已实现 / qwen3.8-27b:256k | 无记录 | 待验 |
| `opencode-ollama-qwen3-8-27b` | 已实现 / qwen3.8-27b:256k | 无记录 | 待验 |
| `qwen-code-ollama-main` | 已实现 / qwen3.8-27b:256k | 无记录 | 待验 |

### 本轮 GLM 实测

| Profile | 产品 / 级别 | AICLI 命令退出码 | 目标 CLI 退出码 / 版本 | 记录时间（北京时间） | 结论 |
| --- | --- | --- | --- | --- | --- |
| `codex-glm-5-3` | 0.3.19 / text | 4 | 1 / 0.167.0 | 2026-11-15 16:10:57 | 失败；已取得 exact `glm-5.3` / `aicli_glm_5_3` 运行时身份，观测工具数 0；验收只返回“exit=1 或最终正文不匹配”，未留存更细的上游原因，不能判断为账号、端点或模型故障 |
| `codex-glm-5-3-flash` | 0.3.19 / text | 4 | 未启动 / 未取得 | 2026-11-15 16:11:45 | 失败；启动计划预检报“需要 0.154.0+，实际 无法取得版本”；未进入模型文本调用，不能据此判断 GLM Flash 服务可用性 |

两条失败均由项目自带 live test 写入本机 verification；本轮不修产品代码。GLM-5.3 回执证明 `approval_policy=never`、`danger-full-access`、`codex-native`、`dangerFullAccess`；Flash 在预检失败，没有运行时权限证据。两条都不能标为通过。

tool（工具）档位“无法证明隔离就跳过”是有意不补的边界（2026-11-15 AI 判定：日常用不到，不再当缺口报）；text 通过仍只证明文本链路。

### 历史或用户自定义入口记录

以下是 verification 中没有对应当前源码 Manifest 的 ID，仅作历史追溯或用户配置证据，不恢复已退役入口，也不证明当前公开模板可用。

| Profile ID | 产品版本 / 级别 / 结果 | 退出码 | 记录时间（北京时间） |
| --- | --- | --- | --- |
| `claude-chatgpt-cliproxy` | `0.1.0` / text / 通过（旧版本） | 未记录 | 2026-07-14 02:25:45 |
| `claude-deepseek` | `0.1.0` / text / 通过（旧版本） | 0 | 2026-07-14 03:27:52 |
| `claude-ollama-local` | `0.1.0` / text / 通过（旧版本） | 0 | 2026-07-14 03:30:31 |
| `claude-openrouter-opus5` | `0.3.1` / text / 失败（旧版本） | 1 | 2026-07-25 08:19:37 |
| `claude-qwen-paygo` | `0.1.0` / text / 通过（旧版本） | 0 | 2026-07-14 03:27:40 |
| `codex-deepseek` | `0.3.5` / text / 失败（旧版本） | 0 | 2026-08-14 04:30:22 |
| `codex-ollama-local` | `0.1.0` / text / 通过（旧版本） | 0 | 2026-07-14 03:30:17 |
| `codex-qwen-paygo` | `0.1.0` / text / 通过（旧版本） | 0 | 2026-07-14 03:27:23 |
| `codex-qwen3-7-plus-paygo` | `0.3.3` / agent / 通过（旧版本） | 0 | 2026-08-09 04:23:25 |
| `codex-spark-xhigh` | `0.3.2` / text / 通过（旧版本） | 0 | 2026-07-25 22:02:46 |
| `oi-deepseek` | `0.1.0` / text / 通过（旧版本） | 0 | 2026-07-14 03:28:33 |
| `oi-ollama-local` | `0.1.0` / text / 通过（旧版本） | 0 | 2026-07-14 03:30:45 |
| `oi-qwen-paygo` | `0.1.0` / text / 通过（旧版本） | 0 | 2026-07-14 03:28:04 |

`codex-spark-xhigh` 已退役；历史 text 通过不表示现在仍能启动。旧 `codex-deepseek`、`claude-deepseek`、`oi-deepseek` 与 `deepseek-v4-flash` 已退役，不继承为当前 DeepSeek Flash 证据。Qwen Code / OpenCode 的本地模型入口不能代表已开放这两个引擎的 DeepSeek 云端路径。

历史 Agent 回执中的模型可能已被当前 Manifest 替换（例如 Ollama 的旧运行标签、`qwen-main-v1`）；版本或模型不同的通过记录均不复用。Claude 官方入口没有本机 verification 记录，本轮待验，不沿用旧文中“401 未登录”作为当前结论。

## 3. 验收命令

先静态检查：

```powershell
aicli doctor <Profile ID>
aicli native <Profile ID>
```

再由有权使用该账号/Key 的维护者显式执行：

```powershell
aicli test <Profile ID> --live --level text --yes
aicli test <Codex Profile ID> --live --level agent --yes --json
```

只有文本通过并且要求的工具层完成时才允许显示“可用”。Codex harness 固定 `danger-full-access`；Live 只发送要求严格返回 `PONG` 的文本任务，并要求最终观测到的工具调用数为 0。首个工具事件会触发终止并判失败，但不是执行前工具禁用，可能已经产生副作用，也不缩小全访问权限；权限事实仍必须进入回执。

当前 Live Test 要求：

- 通过真实目标 CLI，不使用外部 HTTP 请求冒充。
- 进程退出码为 0。
- 最终模型正文严格等于 `PONG`，不能由提示回显刷绿。
- 临时空目录运行，但 Codex harness 仍按统一合同拥有 `danger-full-access`；不得把空目录冒充权限隔离。
- Codex 回执记录实际 CLI 路径/版本、Provider、端点、actual 模型/Provider、`approval_policy=never`、`requested_policy=danger-full-access`、`native` 边界、`sandbox_type=dangerFullAccess`、permission profile、零工具使用、Profile 指纹和测试时间；不记录提示/回复正文或秘密。
- Agent 回执必须另行证明同一 exact thread 的可恢复执行、至少一次真实工具活动、完整进程树清理与独立 verifier 通过；`all` 不隐式包含 Agent 测试。
- Codex machine run 默认提供受管 `public_web_search`；回执记录 `enabled/provider/searches/eventEvidence`，事件仅记录 `web_search` 生命周期和计数，不含 query/result。2026-08-13 源码入口已由本地 `qwen-main-v1` 真实完成一次搜索并返回 `SEARCH_DONE`；该次未启用 event-file，不能冒充安装态或 durable GUI JSONL acceptance。

`0.3.10` 起的安装器会只读预检 Qwen3.7 遗留入口；只有能用 marker/body/state/hash 和模块 Manifest 身份证明由 AICLI 管理的旧文件才会移入可恢复 quarantine。新 06-08 exact Profile、受管 TOML/state 与被引用目录会保留。未知/篡改/reparse 项会阻断安装且不会被删除；SecretRef 与密钥不参与迁移。

`0.3.12` 复用 `0.3.11` 的可恢复 Codex run：`thread/start ephemeral=false`、`thread/resume`、同 thread/session 和全部身份回读、进程丢失/配额暂停恢复、append-only 分段 hash 链、最多 3 次瞬态 exact-resume 与累计 token 差分计费证据都有确定性测试；新增显式 Agent fixture/verifier，并已由上述本地 Qwen3.8-27B 安装版真实 Agent Live 闭合 source/install/runtime/live 四层证据。该次没有发生中断，因此只证明正常 Agent 路径；中断恢复仍引用 `0.3.11` 的同线程定向 kill→resume Live 与本版本确定性回归，不能把 resume_count=0 写成一次恢复。旧 `0.3.10` ephemeral 会话未登记持久 run 身份，不得伪造为可恢复。

`codex-spark-xhigh` 退役前的 machine run 与当时的桌面端验收分开。历史证据有三层：旧只读 smoke 证明文本链路，2026-07-29 的写任务证明源码权限修复生效，而同一任务的 `81/80` 与 `2/9` 证明能力验收不通过。旧回执不表示现在仍能启动；调用方必须显式选择现行 Profile。

## 4. 当前命令事实

- Codex 思考强度使用当前构建提供的 `/reasoning`，或在 `/model` 中选择；配置层由 `model_reasoning_effort` 控制。
- Claude Code 使用 `/effort` 或 `--effort`。
- Codex 第三方 Profile 由 aicli 管理；透传 `-c`、`--config` 或 `--profile` 会被拒绝，不提供必然失败的覆盖示例。
- Open Interpreter 使用当前 Rust CLI 的 `-c` TOML 配置、`exec`、`/model` 与 `/permissions`；旧 Python 版的参数和依赖安装路径不受支持。
- 三套 CLI 的权限、思考和上下文语义不完全等价。
- 第三方模型下 Claude 结束页 `Total cost: $… (unknown models)` 不是百炼账单；美元多半偏高，真费用以阿里云控制台为准。用户正文见两本中文手册（工作区 start、升级重载、PowerShell `--%`、用量阅读）。

## 5. 模型与套餐动态事实

内置模板当前候选包括：

- GLM 当前有两个 exact Codex 模板：`codex-glm-5-3` → `glm-5.3`、`codex-glm-5-3-flash` → `glm-5.3-flash`；均为智谱 coding-plan、中国区 `https://open.bigmodel.cn/api/v1`、Responses、1M、low/high/max、默认 max、无 fallback。模板存在与真实验收状态分开，见第 2 节。

- Qwen 云端只保留两个隔离 exact Codex Profile：`codex-qwen3-7-max-paygo` → `qwen3.7-max-2026-06-08` 与 `codex-qwen3-8-max-paygo` → `qwen3.8-max-0902`，requested `max` 均映射 effective `xhigh`。其他 Qwen3.7 Max/Plus、Qwen3.8 可变 alias/preview、兼容 ID、目录与导入入口继续退役；旧用户 Profile/原生模型参数失败关闭。
- DeepSeek Codex 当前以 `codex-deepseek-flash` → `deepseek-flash` 为主入口，Responses、1M、默认 `max`，Desktop 不写死版本；`codex-deepseek-v4-pro` → `deepseek-v4-pro` 仅保留 CLI-only。Claude Code 与 Open Interpreter 不再公开 DeepSeek 模板，旧 V4 Flash 身份失败关闭。
- Ollama 公共模板只使用默认端口和公开模型名；用户必须确认本机已经存在该模型。

模型名、地域、套餐和端点属于动态事实。`0.1.0` 发布时已按官方来源和真实目标 CLI 证据核对；后续版本仍须重新核对。“模板中存在”不等于账号有权调用。

## 6. 官方事实源

- Codex：[Profiles](https://learn.chatgpt.com/docs/config-file/config-advanced#profiles)、[Slash commands](https://learn.chatgpt.com/docs/developer-commands)
- Claude Code：[Commands](https://code.claude.com/docs/en/commands)、[Permissions](https://code.claude.com/docs/en/permissions)、[Model configuration](https://code.claude.com/docs/en/model-config)
- Open Interpreter：[Install](https://www.openinterpreter.com/docs/terminal/install)、[CLI Reference](https://www.openinterpreter.com/docs/terminal/cli-reference)、[Providers](https://www.openinterpreter.com/docs/terminal/providers)
- 千问百炼：[Codex](https://help.aliyun.com/zh/model-studio/codex)、[Claude Code](https://help.aliyun.com/zh/model-studio/claude-code)
- DeepSeek：[Codex integration](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/)、[Responses API](https://api-docs.deepseek.com/guides/responses_api/)、[Claude Code integration](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/)、[Change Log](https://api-docs.deepseek.com/updates)
- Ollama：[Codex](https://docs.ollama.com/integrations/codex)、[Claude Code](https://docs.ollama.com/integrations/claude-code)
