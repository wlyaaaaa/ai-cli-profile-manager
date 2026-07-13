# AI CLI Profile Manager 项目规则

## 1. 事实源与工作阶段

- 默认使用简体中文。
- 维护与发布前读取 `docs/maintainer/项目设计与实施归档.md`；它是合并后的产品范围、决策、合同与实施事实源。
- 本机 `docs/research-inputs/*.txt` 只是被 Git 排除的讨论输入，存在截断和过时信息，不能作为实现真相。
- 产品名 AI CLI Profile Manager、模块名和命令 `aicli` 应集中定义；不要把品牌字符串散落在代码里。
- 阶段由用户指令决定。产品设计完成不自动授权创建远端、发布、推送或 Release。

## 2. 产品硬边界

- 只做 Windows 11、PowerShell 7。
- 这是原生 Codex CLI / Claude Code 的 Profile、启动、代理运维、Doctor、自检和中文手册层；不做 GUI、TUI、PTY 外壳、自研 Agent、会话历史或协议转换器。
- 不汉化或修改上游 CLI 本体；原生终端交互、权限、上下文和会话由上游负责。
- Codex 首版只做官方、Ollama、千问 Responses；不得加入 DeepSeek 或纯 Chat Completions 直连。
- Claude Code 首版只做产品设计列出的官方、DeepSeek、千问、Ollama、双代理和 Anthropic Messages 自定义档。
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
