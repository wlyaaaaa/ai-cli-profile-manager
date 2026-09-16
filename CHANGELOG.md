# 变更日志

本项目遵循语义化版本。日期按 UTC+8 记录。

## [Unreleased]

### 新增

- `codex-qwen3-8-max-paygo` 现精确固定 `qwen3.8-max-0902`；Codex Desktop 在启动时保留原生 OpenAI 动态目录，并把已配置的 0902 云端模型与本地模型合并到同一选择器。云端密钥通过 command-backed auth 按需读取受管加密副本，不写入基础配置或全局环境变量。
- 新增 `codex-glm-5-3` 与 `codex-glm-5-3-flash` 两个中国区 exact Responses Profile。两者固定 `https://open.bigmodel.cn/api/v1`、1M 上下文、`low/high/max` 和单模型目录；Codex Desktop 从 Password Center 的 GLM 凭据副本按需认证，并继续保留 OpenAI 原生动态目录。

### 修复

- Codex Desktop 官方模型发现只接受带 `etag`、`fetched_at` 和客户端版本的原生在线缓存，并做三次有界刷新；`debug models` 即使内部静默退回 bundled（内置）目录，其输出也不再进入桌面菜单。在线缓存不可验证时交还原生 Codex。
- `update check` 现在把实际启动入口与版本绑定，并只读比较对应渠道的官方稳定版元数据；无法确认、预发行或存在更新时如实报告，不再把本地版本清单当成“已是最新”。Codex harness 与 Desktop 运行时分开识别。
- Open Interpreter 的 Live 与一次性 machine run 使用独立临时 home，隔离继承的 `INTERPRETER_HOME` / `CODEX_HOME`；交互式启动仍保留用户原有配置。
- 恢复非 Codex Profile 的公开 `run` / `run start` 一次性入口，明确不支持 exact resume，避免误入仅适用于 Codex 的持久恢复流程。
- 机器调用会有界等待临时目录句柄释放；仍无法清理时保留原始超时、退出结果和可定位的残留信息，未确认清理不标记成功。
- 安装切换使用同一模块父目录内的原子目录重命名；文件占用时保留完整旧安装，避免部分移动造成半套安装。
- 退役预检现在与运行时一致地优先现有 `CODEX_HOME`。历史 managed state 只有在其直连 Junction、祖先链和唯一完整绝对目标均闭合到已验证真实 home 时才可与真实路径等价；旧记录路径只用于 Junction 元数据比对，退役产物的扫描、移动和存在性检查始终使用真实路径，显式或越界链接继续失败关闭。
- 发布 smoke 保持离线，并验证无法联网确认更新时的 Limited / exit 3 语义；真实最新版本和模型能力仍单独验收。

## [0.3.12] - 2026-08-15

### 新增

- 新增显式 `aicli test <Profile> --live --level agent --yes --json`。它在全新临时目录运行确定性的非平凡文件任务，并由独立 verifier 验收实际产物；不能用模型自述、提示回显或普通连通性冒充 Agent 能力通过。
- Agent 验收直接复用 `0.3.11` 的 root-owned 可恢复 run：瞬态中断最多自动 exact-resume 3 次，恢复前后必须保持同一 thread/session、workspace、Profile 指纹、model/provider、requested/effective effort 与完全访问权限。

### 可靠性与审计

- 第三方 Codex/Claude/OpenCode 启动计划现在附带项目自有 `aicli.third-party-continuity.v1` 契约：窗口/自动压缩仍来自现有受管 metadata/catalog，压缩前要求把最小 checkpoint 写入项目已有状态，压缩后从项目规则、状态与工作树恢复；原生 ChatGPT + Codex 基线不变。
- 验收回执绑定实际模型、Provider、CLI 版本、`danger-full-access` 权限、工具活动、进程树清理、恢复次数、任务合同哈希与 verifier 哈希/结果；提示、回复正文、工具载荷、endpoint 与秘密不进入回执。
- 修复 Agent Live 刚通过后被错误标记为“目标 CLI 版本已变化”：app-server 的裸 `0.147.0` 与 `codex --version` 的 `codex-cli 0.147.0` 现在按完整 SemVer 等价比较；不同 prerelease/build 仍会失败关闭。
- `all` 保持既有 text+tool 语义，Agent 验收只在显式选择 `agent` 时运行，避免升级后意外发起较长或有副作用的模型任务。

## [0.3.11] - 2026-08-15

### 新增

- `aicli run` 为所有当前和未来 Codex harness Profile 增加 root-owned 可恢复运行：每个 run 持久化 exact thread/session、workspace、Profile 指纹、model/provider、requested/effective effort、协议、attempt 与事件游标；任务正文、隐藏推理和工具载荷不落盘。
- 新增稳定机器控制面：`run start`、`run resume`、`run status`、`run abort`；`start/resume --background` 通过仅当前用户可连接的命名管道交付首次任务并立即返回 run id，供 benchmark/observer 后台轮询。
- 后台控制器使用隐藏的独立进程句柄；即使 GUI 或脚本正在捕获 stdout/stderr，命名管道交付任务后也会立即返回，不再等待控制器终态。
- app-server 恢复改用真实 `thread/resume`。只有返回同一 thread/session 且工作区、Profile、模型、Provider、effort、CLI 与五项完全访问权限身份都一致时才继续；任何新 thread、reroute、身份漂移或证据不足均失败关闭。

### 可靠性与审计

- 事件与 receipt 按 attempt 追加为不可变分段，使用单调 sequence、文件 SHA256、segmentHash、stateHash 与前向 journal hash 链；重启后只从已关闭的事件 writer 对账，孤儿/重复/迟到终态或重放覆盖都会失效。
- 运行时身份事件先做 exact-secret 脱敏，再仅恢复已经由 harness 验证的封闭公开身份字段；本地兼容 Key 与 Provider 名子串碰撞时不会误伤 exact Provider，自由文本仍保持脱敏。拒绝的中断身份也会先闭合分段游标与不可变 receipt，保留准确失败原因而不制造证据链矛盾。
- `thread/resume` 在请求前预绑定已经持久化并验证的旧 thread/session，因此 Codex 0.147 先于响应发送的 thread 状态通知仍能按 exact scope 验证；响应若返回新 thread/session 继续立即拒绝。父层身份门在子进程写出公开终态后失败时，也会闭合该事件段并保留结构化错误码，不再把原始失败降成笼统的证据链错误。
- UTC 创建、额度暂停和 controller 启动时间在 JSON 往返后保持原始时区/精度，`status` 不再把活进程误判为中断，wall/quota 时间也不再错误归零。每个能返回 verified capture receipt 的 attempt 另保存无 lease/capability 的 broker 终态摘要；控制器被直接杀死的段仍诚实标为 cleanup 未确认，由后续成功 reacquire 与 broker 自身 owner-exit 合同分别举证。
- broker 终态摘要在全回执秘密清洗前完成严格验证，清洗后只恢复不含 lease/capability 的封闭公开字段；本地兼容 Key 与公开 broker schema 子串碰撞时不再把已成功、已释放的 attempt 误判为 `broker_terminal_receipt_invalid`。
- 瞬态上游错误、进程退出和 app-server stream 断开最多自动 exact-resume 3 次；额度暂停来自公开 `codexErrorInfo` 的结构化分类，不消耗恢复次数，也不依赖或公开厂商错误文本。硬预算、取消、身份错误和结构性协议错误不重试。
- 回执分开记录首次/恢复 active time、额度等待、重复 continuation 字节、各 attempt usage 与 wall time；重复输入不冒充模型有效工作或费用证据。控制器丢失时无法回读的 active duration 显式标为 partial，不用 0 或 wall time 伪造。无法证明旧版/旧 ephemeral thread 可恢复时明确返回 `resumeSupported=false`，不得把 partial 与新 workspace attempt 合并。

## [0.3.10] - 2026-08-15

### 修复

- 修复 Codex 0.147 app-server 在本地 Responses 路线中对同一个尚未完成 item 重发 `item/started` 时，AICLI 误报 `codex_appserver.item_started_duplicate` 并提前终止的问题。
- 兼容只接受同 thread/turn、同 item id/type、仍为 `started` 且生命周期投影一致的幂等重发；载荷补充不重复计步或计工具。类型或生命周期变化、completed 后重发、未知状态和未闭合终态继续失败关闭。
- 本机 Qwen3.8-27B 命令工具 canary 已证明 exact model/provider/MAX/Responses/完全访问身份、单次工具调用、正常终态与 LocalGpuBroker 清理均闭合；正式能力样本仍使用新工作区独立执行。

## [0.3.9] - 2026-08-15

### 修复

- Qwen3.8-27B 的 Codex/OpenCode Profile 改为同一个内容固定的本机运行标签 `aicli-qwen3.8-27b-256k:2026-08-14`；它复用官方 `qwen3.8:27b` Q4_K_M 模型/视觉权重，只增加 `num_ctx 262144` 参数层，避免目录写 256K、Ollama 实际却按 32K 加载。
- 新增 `scripts/Setup-Qwen38-27B256K.ps1`：经 LocalGpuBroker 公共端点校验官方基础 digest、创建确定性 256K 镜像并回读参数/digest；可安全备份并注册 OpenCode Desktop 的 `Qwen3.8 27B MAX (256K)` 条目，不更改用户当前选择。
- Codex 仍固定 Responses、`max`、单候选、no-fallback；OpenCode 固定同一模型权重与 262144 context/input、32768 output。

## [0.3.8] - 2026-08-15

### 新增

- 新增本机 `Qwen/Qwen3.8-27B` 的两个 exact harness Profile：`codex-ollama-qwen3-8-27b` 与 `opencode-ollama-qwen3-8-27b`，统一固定官方 Ollama `qwen3.8:27b` Q4_K_M 标签、LocalGpuBroker `127.0.0.1:32100` 和原生 262144 context。
- Codex 路线固定 Responses、单候选、默认/有效 `max`、受管单模型目录和 no-fallback；OpenCode 路线固定同一模型、一次性 pure 配置、262144 input/context 与 32768 output。
- 帮助、公开 Profile 列表、发行 smoke、确定性目录生成器及聚焦回归同步覆盖新入口；既有 `qwen-main-v1` / `qwen-review-v1` 身份保持不变。

### 运行时

- 官方 `qwen3.8:27b` 要求 Ollama 0.32.12+；本机验收使用稳定版 0.32.13。1M YaRN 属扩展模式且可能损害短上下文质量，不作为 32GB GPU 的默认合同。

## [0.3.7] - 2026-08-14

### 修复

- 修复本地 Qwen 经 Codex app-server 已完成推理、工具和最终输出后，仍因较早公开 `agentMessage` 保持 `started` 而报 `codex_appserver.item_unfinished` / exit 74 的终态兼容问题。
- supersession 兼容由 CLI 版本白名单改为严格的生命周期形态判定：只有全部未完成项都是早于同轮次后续、已完成且有非空正文 final 的 `agentMessage` 时才闭合；非消息项、无 final、final 之后的新消息或结构漂移仍失败关闭。该合同已锁定 Codex 0.145、0.147 和模拟高版本，后续保持同一事件结构的版本无需追加版本号。
- exact Profile、Provider、Responses wire、最高 effort、`:danger-full-access`、actual identity、SecretRef 与 no-fallback 合同不变。

## [0.3.6] - 2026-08-14

### 新增

- 新增唯一 Qwen3.7 Max Codex 入口 `codex-qwen3-7-max-paygo`，精确固定 `qwen3.7-max-2026-06-08`、北京百炼 Workspace 按量 Responses、单候选、无 fallback、983616/95% 窗口与 262144 自动压缩阈值。
- 用户可继续选择统一 `max`，启动计划、受管 TOML 与回执按供应商当前最高档发出 effective `xhigh`；SecretRef 只经 `AICLI_CODEX_PROVIDER_KEY` 注入。
- 同一北京 Workspace endpoint 可通过 `--reuse-secret-from codex-qwen3-8-max-paygo` 复用既有不透明 SecretRef；endpoint 不同即失败关闭，不读取或复制秘密值。
- 新增 clean commit 专用的 `Install-ExactCodexProfileFast.ps1`：只跑 exact Profile 聚焦门禁、发行 smoke、原子安装和固定入口回读；PDF/ZIP、全量回归与付费 Live 留在正式发布车道。Qwen Workspace 同域复用还会盲复用 endpoint，不再重复询问 Workspace URL。

### 安全与兼容

- `qwen3.7-max` 通用 alias、05-20、preview、Qwen3.7 Plus、旧 Profile ID、Claude/OI/导入路线与 native model/fallback 绕过继续退役。06-08 只允许经新 exact Profile 进入。
- 升级退役迁移能识别并保留新 exact 用户 Profile、受管 Codex TOML/state 与仍被引用的内容寻址目录，同时继续隔离可验证的旧入口。
- source/static/install/runtime/live 继续分层；旧 0.3.5 回执不能证明 0.3.6 Live。

## [0.3.5] - 2026-08-13

### 新增

- 所有当前及未来 Codex harness 默认通过 app-server `thread/start.dynamicTools` 注册受管 `public_web_search`，并提供显式 `--no-web-search`；固定 HTTPS RSS provider、拒绝重定向/任意 endpoint/Header/凭据，事件与回执只记录生命周期/provider/次数，不记录 query/result。真实本地 `qwen-main-v1` 已打通 dynamicTools → `item/tool/call` → managed search → 完成回执。
- DeepSeek Codex 提供两个可发现的一键 exact Profile：`codex-deepseek` 固定 `deepseek-v4-flash` / `DeepSeek-V4-Flash-0731`，`codex-deepseek-v4-pro` 固定 `deepseek-v4-pro` / `DeepSeek-V4-Pro-0813`。两者均使用官方 Responses wire、隔离单模型目录和用户 `max`。
- `profile configure` 支持在同一凭据域内用 `--reuse-existing-secret` 或 `--reuse-secret-from <Profile ID>` 复用现有 SecretRef；不读取或复制明文，保存失败也不会删除被其他 Profile 共用的密钥。
- 安装器新增幂等退役迁移：只把 marker/body/state/hash 闭合的 Qwen3.7 用户 Profile、Codex TOML/目录和旧模块版本移入可恢复 quarantine；未知、篡改或 reparse 项在任何变更前失败关闭，SecretRef 和密钥始终保留。

### 变更

- 永久退役 Qwen3.7 Max/Plus 全家族及其 Codex、Claude Code、Open Interpreter Profile、目录、生成器分支和 OpenClaw 导入入口。旧用户 Profile、native `--model` / `--fallback-model` 与未知别名均失败关闭，不自动映射到 Qwen3.8。
- 所有当前和未来 Codex harness 模型统一使用原生 `danger-full-access` 与 `approvalPolicy=never`；该不变量按 `engine=codex` 生效，不维护模型 allowlist。显式请求 `read-only` / `workspace-write` 会在模型调用前失败关闭。
- Codex harness 必须回读实际 model、modelProvider 和 `dangerFullAccess` 权限身份，并拒绝任何 `model/rerouted` 通知。请求/计划值不再冒充运行时 actual。
- 所有 Codex 文本 Live 统一走同一 app-server harness，要求最终观测到 `toolCalls=0` 并持久化五项运行时权限证据。首个工具事件会触发终止和失败，但不是执行前工具禁用，也不把 `danger-full-access` 降权或冒充沙箱。
- DeepSeek 官方目录以 2026-08-13 Codex setup artifact 的双模型条目为基线；AICLI 仅把目录默认 reasoning 从官方 `high` 明确覆盖为产品最高档 `max`，其余能力字段与官方条目绑定。

### 验收边界

- source、static、install、runtime 和 live 分层记录；只允许每个付费 DeepSeek exact Profile 一次最小 Live，失败不自动重试。Qwen3.8、本地 main/review 的旧回执不冒充 `0.3.5` 当前 Live。

### 修正

- Codex 文本 Live 现在按公开 run receipt 的 lower-camel schema 读取 `runtimeIdentity` / `exitCode` / `stdout`，并从未截断的安全 JSONL 最终 `item.completed/agent_message` 提取完整正文后逐字比较 `PONG`；附加行、首尾空白与截断回执均失败关闭，不再把 JSONL 整体误当纯文本，也不再因旧 child-capture 字段名把真实运行身份判空。
- whole-receipt 秘密擦除后会恢复已在同一调用中严格验证的封闭公开 runtime identity 与 launch identity。兼容 key 与公开 Provider ID 存在子串重合时，不再把已验证的 `aicli_ollama_main` 误改成脱敏占位符；秘密值和 stdout/stderr 仍保持精确擦除。
- Codex Live 计划未显式提供 `versionArgumentList` 时会正确回退到 `--version`，不再把 PowerShell 的 `$null` 管道结果误计为一个空参数；新生成的 Live 回执因此能持久绑定实际 CLI 路径与版本并通过后续 currentness 回读。

## [0.3.4] - 2026-08-13

本节仅记录已安装候选的历史事实：该版本引入 Qwen3.8 Max、DeepSeek Flash/Pro 和本地 main/review 的 exact Codex Profile，但仍保留了后续在 `0.3.5` 退役的 Qwen3.7 入口，也未包含本版的通用全访问 harness 与升级隔离。不得把 `0.3.4` 安装态或 Live 回执解释为 `0.3.5` 当前证据。

## [0.3.3] - 2026-08-03

本节保留 `0.3.3` 的历史候选事实；本机当时只从目标提交的干净快照安装并完成 DeepSeek 静态验收，未发布 GitHub Release，也未执行当时 Flash Live/API 请求。不得把这项旧证据解释成当前发行或 Provider 能力通过。

### 新增

- 新增 DeepSeek 官方 Codex public beta 模板 `codex-deepseek`：固定 `deepseek-v4-flash`、Responses、1M context、Codex CLI `0.144.0+`，默认 reasoning effort 为 `high`，支持 `low` / `high` / `max`。
- 新增千问 Codex 受管 `qwen3.7-codex.json`：六个现有候选固定 983616/95% 窗口、非空 Codex 基础指令和受限 effort，避免未知模型 272K 回退。
- 新增本地 `qwen-main-v1-codex.json`：Codex、Claude Code 与 OpenCode 对同一免费本地模型统一使用 262144 context，不再分别回退为未知容量。
- 新增 Claude/OpenCode 的逐模型 `modelMetadata`，模型窗口变化会进入 Profile 指纹并使旧验收失效。
- DeepSeek 模型目录使用 AICLI 受管的内容寻址副本；API Key 继续由 CurrentUser DPAPI 保存，Codex 配置只引用 `env_key`。不复制官方示例的明文 `experimental_bearer_token`，也不写入 `preferred_auth_method`。
- OpenClaw DeepSeek 导入可生成 `codex-deepseek`、`claude-deepseek`、`oi-deepseek` 三个 Profile。

### 变更

- Codex、Claude Code 与 Rust Open Interpreter 的公开 DeepSeek 模板统一收敛为 `deepseek-v4-flash`。`deepseek-v4-pro` 只保留不可选的 `reserved` 元数据，待上游正式支持 Codex Responses 后再接入。
- DeepSeek/千问/本地 Qwen Claude Profile 仅在命中已知最终模型时设置真实 MAX/AUTO 窗口；原生 Claude 与原生 ChatGPT + Codex 不变。未知第三方模型不猜容量，并清除父进程遗留的窗口、提前压缩和禁压缩变量。
- 本地 OpenCode 固定主/小/压缩模型与唯一 local provider，使用 262144 context、8192 output、20000 reserve、4 轮/16384 token 保留并关闭 tool-output pruning；checkpoint 仍是一次性。
- Qwen Code `0.21` 与 OpenCode `1.18.8` 暂不开放 DeepSeek 远程 Profile：当前 AICLI machine-only 外层沙箱断网，且没有隔离真实 Key 的远程 egress relay；不以假 Profile 代替缺失的安全执行路径。
- 2026-07-14 的 Claude/OI `deepseek-v4-pro` Live 记录仅保留为历史证据；Flash-only Profile 指纹变化后，该记录不再证明当前模板可用。

### 修正

- Codex app-server 的运行累计 Token 现在取同一快照中的 `tokenUsage.total`，包括输入、缓存输入、输出、推理输出与上游总计；当前上下文仍只取 `tokenUsage.last.totalTokens`。桥接不再把最近一次调用误标为整场累计，也不会在累计字段缺失时回退到 `last`；无法证明缓存统计可用的零值会省略。
- PDF 构建优先复用本机已有的 Playwright 与已安装 Edge，避免 Edge 命令行打印受既有浏览器单例影响而无限等待；仍保留有界超时的 Edge CLI 后备路径。两本 canonical Markdown 会写入源 SHA256，并在生成后做文本与逐页渲染验收。
- Codex CLI `0.145.x` 的原生 app-server `workspace-write` 改用实验协议中的命名权限：`thread/start` 与 `turn/start` 都传入 `permissions=:workspace`，并用唯一的 `runtimeWorkspaceRoots` 精确绑定请求 `cwd`。桥接器回读 `workspaceWrite`、`:workspace` 和同一根路径，并在模型轮次前执行受限写探针；根目录为空、漂移或探针失败时，不启动模型调用。
- 原生 Codex machine run 继续固定 `approvalPolicy=never`；app-server 发起任何审批或用户输入 RPC 时均失败关闭，不自动批准。
- machine child 不再继承完整父进程环境，而是从 Windows、PowerShell、Node/TLS 运行所需的小型 allowlist 重建环境，并屏蔽调试类变量。受管运行时仍可通过 `EnvironmentDelta` 显式注入本次任务所需的 Provider 或运行时变量；该显式注入是权限边界，不能被表述成“子进程永远看不到秘密”。
- 官方 Codex/Spark machine run 继续使用一次性 `CODEX_HOME` 中的 `auth.json` 副本，不要求也不注入付费 API Key；运行目录在结束时清理。
- 修复 app-server 重建时丢失原生 `--model` / `-m` 覆盖的问题。先前标成 Qwen Flash/Plus 的云端 Agent 记录实际使用了 Profile 主模型 Max，旧身份与能力结论已经撤回；付费 Qwen Agent route 保持禁用，本轮不做付费复测。

### 验收

- 2026-08-03（UTC+8）从提交 `32dad74` 的干净快照事务安装 `0.3.3`，安装 payload 与快照逐文件 SHA256 一致，23 个 Manifest 可回读。Codex `debug models` 对 DeepSeek Flash、本地 Qwen 与云千问目录分别唯一命中 `1000000`、`262144`、`983616`；Claude 已知/未知模型窗口策略及 OpenCode 262144/8192/20000/16384/4、`prune=false` 均由安装态静态解析确认。Pester 200/200、release smoke 与两本 PDF 的源哈希/文本/全页渲染验收通过；未调用模型或 Provider API。
- 通过仓库源代码入口执行的 Spark `workspace-write` 真实任务已证明工作区写权限生效；但 `code_repair` 在硬上限 `maxSteps=80` 下到达 `81/80` 并终止，确定性得分为 `2/9`。该结果属于能力验收不通过，不因写权限修复而晋升为合格代码 Agent，也不重复复测。

## [0.3.2] - 2026-07-25

### 新增

- `aicli version --json` 公开声明 `aicli.machine-event.v1` 能力。
- `aicli run` 新增可选 `--event-file <absolute-jsonl-path>`。运行期间逐行刷新安全公共事件，供上层观察器显示线程/轮次、推理活动状态、工具类型、文件编辑状态和公开最终消息。
- Codex machine run 以实测的 npm `codex-cli 0.145.0` app-server 协议为最低基线，`0.146.0-alpha.3.1` 已通过真实兼容验收；后续更新版本默认尝试，只有通过运行时协议门禁才继续，否则返回明确错误。公开 `agentMessage` 增量按短语聚合为 `output.delta`；`context.usage.updated` 直接投影一份同时完整包含 `tokenUsage.last.totalTokens / modelContextWindow` 的运行时快照，`context.compaction.completed` 投影自动压缩完成计数。最终 `run.usage` 新增 `current_context_tokens` 与 `context_window_tokens`，均不由本地猜测。
- 官方与本地 Ollama Codex machine run 使用 Codex 原生 `read-only` / `workspace-write` 沙箱；第三方 Codex 及其他适用引擎继续使用网络关闭的 Windows 外层沙箱。0.145 的 `subAgentActivity` 是只发送一次 completed 的点事件，其他受支持 item 仍严格要求 started → completed。

### 安全修正

- side-channel 使用严格 schema、单调 sequence、事件/字段白名单和有界公开文本；不写入隐藏推理正文、命令/参数、工具输入输出、文件内容、环境变量、秘密或原始 stderr。
- `maxSteps` 的 Codex 计数升级为 `distinct-non-output-thread-item-v2`：推理、计划、工具、压缩等不同非输出 item 继续占用硬行动预算；公开 `agentMessage` 增量与最终消息不再挤占执行步骤。墙钟、事件输出上限与 `maxToolCalls` 仍独立约束公开输出和工具活动。
- app-server 双向桥只在内存中处理原始通知；原生 Codex 沙箱路径直接从 stdin 接收任务，仍使用外层沙箱的路径才通过受限 ACL 的随机命名管道传递。prompt、压缩 history 和通知私有载荷不进入结果、事件文件、环境变量或临时文件。公开进度、粗粒度工具事件和最终结果可见，隐藏 reasoning 正文不公开。低于基线、必要字段缺失或结构漂移、未知通知、跨 thread/turn、非 `completed` 的成功终态、非法 item 生命周期、服务端交互请求与无法确认的进程树清理均失败关闭，不回退到 token 估算。真实复测证明 `0.145.x` 会为连续公开进度留下多个消息 orphan；兼容层只接受它们全部早于同轮次后续、已完成且有公开正文的 final `agentMessage`。更新/未知版本、缺少后续 final、final 之后的新 orphan 或任何非消息 orphan 仍明确报错。
- 事件路径在读取 stdin 和启动模型进程前完成绝对路径、扩展名、父目录和普通文件校验。事件写入失败只将观察级别标为 `degraded`，不会重跑或篡改已经完成的模型结果。
- 事件文件变量不会传入受管子进程；既有 stdout 单-envelope、沙箱、预算、超时和进程树清理语义保持兼容。

### 验收

- 覆盖未启用 side-channel 的兼容路径、公开消息短语聚合、实时 flush、公开消息不消耗行动步骤预算、sequence、敏感信息阻断、非法路径提前拒绝、写入降级回执、app-server 上下文/压缩投影、严格 scope/status/lifecycle、`0.145.x` 多条早期公开消息 orphan 窄兼容、最低版本门禁和未知通知失败关闭。

## [0.3.1] - 2026-07-24

### 新增

- 新增 `codex-spark-xhigh`：精确固定 `gpt-5.3-codex-spark` 与默认 `xhigh` 思考强度，供上层显式选择高速中档智能体；不改变任何本地 Qwen 默认路由。
- 官方 Codex machine run 支持复用现有原生登录：一次性 `CODEX_HOME` 只复制 `auth.json`，不继承用户 `config.toml`、rules、skills、sessions 或 history。

### 安全修正

- 交互式官方 Codex 仍优先使用桌面版 `codex.exe`；machine run 明确选择 npm Codex CLI，避免把桌面二进制误当成可解析 JSONL 的机器运行时。
- 官方云端 Codex machine run 使用 CLI 原生 `read-only` / `workspace-write` 沙箱，并忽略用户配置和规则；本地与第三方 Profile 继续使用网络关闭的 Windows 外层沙箱。两种边界都保留硬墙钟、step、tool-call、事件投影与进程树清理。
- Spark 额度或上游限流不会在 aicli 内自动切换模型；上层必须显式决定是否重新提交到本地 Profile，并分别保留两份回执。

### 验收

- `codex-spark-xhigh` 的只读 machine run 在合成任务上返回严格 JSON，精确回执记录目标模型、`xhigh`、硬预算、墙钟时间和线程标识。

## [0.3.0] - 2026-07-24

### 安全修正

- Codex machine run 现在逐行解析公开 JSON 事件：`max-steps` 统计不同的 ThreadItem 工作单元，`max-tool-calls` 统计命令、文件、MCP、collab 与 web 等工具项；越限立即终止完整 Windows 子进程树。
- 有界 machine run 显式关闭 Codex `multi_agent` / `multi_agent_v2`；若仍观察到 collab 事件，会计数并立即失败关闭，防止隐藏子智能体工具循环。
- 事件类型使用封闭 allowlist；未知事件、未知 item、持续 JSONL 超过墙钟或无法确认完整进程树终止时均失败关闭，不再误报 `hard`。
- machine run 只返回公开 agent message 与线程标识；reasoning、命令正文和工具输出在计数后即丢弃，不进入结果 envelope。
- 回执新增 `eventProjection=codex-public-v1`、`limitUsage` 与 `limitHit`。只有事件协议和进程树清理均有效时，Codex 的 step/tool-call 上限才标记为 `hard`。

### 验收

- 新增 collab 计数、未知事件、持续流墙钟、隐藏推理/stderr 丢弃及真实父→孙进程树终止回归。

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
