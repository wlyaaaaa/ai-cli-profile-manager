# AI CLI Profile Manager 项目规则

## 1. 事实源与工作阶段

- 默认使用简体中文。
- 维护与发布前读取 `docs/maintainer/项目设计与实施归档.md`；它是合并后的产品范围、决策、合同与实施事实源。
- 本机 `docs/research-inputs/*.txt` 只是被 Git 排除的讨论输入，存在截断和过时信息，不能作为实现真相。
- 产品名 AI CLI Profile Manager、模块名和命令 `aicli` 应集中定义；不要把品牌字符串散落在代码里。
- 阶段由用户指令决定。产品设计完成不自动授权创建远端、发布、推送或 Release。

## 2. 产品硬边界

- 只做 Windows 11、PowerShell 7。
- 这是原生 Codex CLI / Claude Code 的 Profile、启动、代理运维、Doctor、自检和中文手册层；不做 GUI、TUI、PTY 外壳、自研 Agent 或通用聊天历史库。Codex harness 允许维护最小、root-owned、不可变分段的 app-server 恢复账本，只用于证明同 thread exact resume，不保存任务正文、隐藏推理或工具载荷。
- 不汉化或修改上游 CLI 本体；原生终端交互、上下文和会话由上游负责。AICLI 的 Codex harness 对所有当前和未来模型统一固定原生 `danger-full-access`，不得按 Profile/Provider 降权或静默改写；交互式 `start` 仍由上游 Codex 权限界面负责。
- AICLI 的 Codex harness 对所有当前和未来模型默认注册受管 `public_web_search` dynamic tool，不维护模型 allowlist；只允许固定 HTTPS RSS provider、拒绝重定向/任意 endpoint/Header/凭据，公开事件不得包含 query/result。必须保留显式 `--no-web-search`，但关闭搜索不得改变 `danger-full-access` 权限。
- 所有 Codex harness Profile 必须共用持久恢复合同：只允许 app-server `thread/resume` 复用已记录的 exact thread/session，并回读同一 workspace、Profile 指纹、model/provider、requested/effective effort 和权限身份。新 thread、身份漂移、不可验证事件/receipt、迟到终态或重放覆盖必须失败关闭；禁止把旧上下文重提到新会话冒充恢复。
- Codex 公开第三方路径只接受上游已明确支持的 Responses Provider。Qwen 云端只开放两个隔离 exact Workspace paygo Profile：`codex-qwen3-7-max-paygo` → `qwen3.7-max-2026-06-08` 与 `codex-qwen3-8-max-paygo` → `qwen3.8-max`。Qwen3.7 的通用 alias、05-20、preview、Plus、旧 Profile ID 与 native model/fallback 绕过继续退役；06-08 只能经新 exact Profile 进入。DeepSeek 只开放 exact `deepseek-v4-flash` / `DeepSeek-V4-Flash-0731` 与 `deepseek-v4-pro` / `DeepSeek-V4-Pro-0813` 两个隔离 Profile，禁止其他 V4 alias/version/reserved/fallback。不得把 Chat Completions 端点伪装成 Codex Responses。
- Claude Code 与 Open Interpreter 的公开 DeepSeek 模板只保留 `deepseek-v4-flash`；旧 Pro 验收记录不得跨当前 Profile 指纹复用。任何旧 Qwen3.7 用户 Profile、非 06-08 模型参数或生成物都必须失败关闭，不得自动迁移到新 Profile 或 Qwen3.8。
- 原生 ChatGPT/Codex 与官方 Claude Profile 是连续性基准，不附加第三方模型目录或压缩策略。第三方 Codex/Claude/OpenCode 的窗口与自动压缩仍以受管 catalog/modelMetadata 和客户端原生能力为准；未知第三方 Claude 模型不猜容量，并清除继承的窗口、提前压缩与禁压缩变量。不得关闭溢出保护。AICLI 的 `aicli.third-party-continuity.v1` 契约要求有损压缩前把最小 checkpoint 写入项目已有状态，压缩后重读项目规则、状态文档与 diff，不建立第二事实源。
- 未完成当期 Windows 11 真实验证的 Provider 不得标成 `可用`。

## 3. 安全与隔离

- 不永久写全局 Provider 环境变量，不覆盖用户基础 `config.toml`、`settings.json` 或官方登录。
- 密钥不得出现在 Git、命令参数、PowerShell 历史、日志、Doctor JSON、异常文本、导出脚本和测试快照中。
- 使用 Windows CurrentUser 范围安全存储；只把必要秘密放进目标子进程环境。禁止 `Invoke-Expression` 和字符串拼接执行用户参数。
- 自定义远程明文 HTTP 默认拒绝；受管代理只监听 `127.0.0.1`。
- 代理端口严格遵守维护者归档中的端口合同；不得杀未知占用者、修改系统端口范围/排除、防火墙或要求管理员权限来抢端口。
- 第三方代理可执行文件必须命中产品批准的固定 SHA256/可信发布者签名；发现未知新版本不授权执行。
- Live Tool Test 只能暴露隔离的单用途 nonce 工具；无法证明其他工具与私人配置已隔离时跳过并报告限制。
- Codex 只在真实 `CODEX_HOME` 写入身份可验证的受管派生 Profile；未知或用户修改文件不覆盖、不误删。
- 普通卸载不删除上游 CLI、官方登录、本地模型或用户 Profile/秘密；彻底清理必须显式选择并准确列出范围。
- 删除本地代理 OAuth 文件不等于远程撤销；输出和手册必须分别报告。

## 4. 实施与验证

- 外部 CLI、模型、端点、套餐、代理版本和参数属于动态事实；实现和发布验收时重新核对官方文档与精确上游仓库。
- Provider 定义采用无执行能力的数据 Manifest；厂商差异放适配器，不散落在通用启动逻辑。
- 本地模型是低频、按需能力，不因可用就替代原生子代理。未来换型以现有 Codex main/review Manifest 与对应 catalog 为入口；`scripts/Sync-LocalModelProfiles.ps1` 显式同步其他 main 引擎的共同模型字段，保留各引擎输出、压缩和启动参数。固定型号的兼容 Profile 独立保留；测试比较实际身份与能力，不把当前主/复核型号永久写成路由规则。上下文继续保持 262144。当前启用集合由 data/local-model-set.json 管理，日常统一运行 scripts/Sync-LocalModelConfiguration.ps1；普通增减做配置同步与必要读回，实际故障再定向验证，不机械要求全客户端 E2E。
- 面向用户的 Profile 名称以真实模型名称为主，可保留引擎和必要套餐信息；`main`、`local-default`、主用、辅助、复核等内部识别不得出现在菜单、最近/默认项、启动提示或普通列表。稳定 Profile ID、Provider、wire、模型参数和 JSON 机器字段继续保留；同一用户可见本地模型的兼容入口在菜单去重时必须记住实际选中的 ID，不能重路由。
- 所有路径通过 Windows Known Folders 计算，不硬编码本机用户名或盘符。
- 含中文常量的 `.ps1` 使用 UTF-8 BOM，并显式处理 PowerShell/外部进程编码；JSON/Markdown 默认 UTF-8 无 BOM。
- 自动测试使用 Pester，覆盖中文/空格路径、参数原样透传、秘密脱敏、子进程环境隔离、原子写入、端口竞争、代理身份和卸载恢复。
- CI 不使用真实用户密钥、不运行付费 Live Test；真实 Provider 验收只在临时空目录按矩阵人工执行。
- 阶段性任务是一次实施内部的顺序，不是反复向用户申请开工。遇到纯技术问题按最优解修订计划并记录；只有改变产品范围、公开动作或不可逆风险时才询问。

## 5. 文档与公开准备

- 用户手册正文必须符合维护者归档中的手册合同：先讲功能、命令、效果，CLI 学习篇放在后面。
- README、示例和帮助只能描述真实存在且已验证的命令。
- 公开候选内容不得包含本机绝对私人路径、密钥、OAuth 数据、原始诊断、聊天归档或未脱敏截图。
- 未经用户明确授权，不创建 GitHub 远端、不 push、不发 PR、不发布 Release。
