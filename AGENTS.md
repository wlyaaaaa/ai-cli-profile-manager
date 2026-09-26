# AICLI 项目规则

## 范围与事实源

- 只支持 Windows 11 x64、PowerShell 7；保留原生 Codex、Claude Code、Qwen Code、OpenCode 与官方 Rust Open Interpreter 的交互，不做另一套 GUI、PTY、Agent 或通用聊天历史库，不汉化上游本体。
- Provider 差异放数据 Manifest 和适配器，品牌集中定义。型号、窗口、档位和启用集合查 `data/providers`、`data/model-catalogs`、`data/local-model-set.json`，不把旧验收记录当现行身份。
- [维护契约](docs/maintainer/项目设计与实施归档.md)保留跨模块合同和本人已定取舍；[machine run](docs/user/MACHINE-RUN.md)与[Toolkit 接口](docs/maintainer/Toolkit-reliability.md)供跨库调用。研究输入和历史回执不是当前能力证明。
- 用户首页保持五项简短说明。两本完整手册及 PDF 目前是打包、帮助与测试的依赖，保留源文/PDF哈希一致；不再把贡献指南、过程记录复制成另一套规则。

## 不可偷换的产品行为

- Codex harness 所有当前和未来模型统一用原生 `danger-full-access`，不按厂商降权；交互式 `start` 的权限交给上游。默认注册 `public_web_search`，保留 `--no-web-search`；关闭搜索不改变权限。搜索只用固定 HTTPS RSS provider，不允许任意地址、重定向、凭据或公开查询正文。
- 持久恢复仅用 app-server `thread/resume` 继续同一个真实 thread/session，并核对 workspace、Profile 指纹、实际 model/provider、requested/effective effort 和权限；新会话、身份漂移、重放或损坏证据不能冒充恢复。恢复账本只存必要身份、游标与哈希，不存正文、隐藏推理或工具载荷。
- 云端 Codex 只开放上游真实支持的 Responses；本机 managed-proxy 也必须实现真实协议，不能把 Chat Completions 或另一家 Agent 接口改名冒充。exact Profile 固定模型、套餐和端点，不自动 fallback，不把退役 ID 改绑给新型号；精确允许集合与退役例外见维护契约。
- 原生 ChatGPT/Codex 和官方 Claude 是连续性基准，不附加第三方目录或压缩策略。AICLI 接入的非 OpenAI Codex 在真实最大上下文 90% 自动压缩；本地窗口保持 262144。未知 Claude 模型不猜容量，并清除继承的压缩/窗口变量。
- `aicli.third-party-continuity.v1`：有损压缩前写项目既有状态，恢复后重读规则、状态和 diff；不建立第二事实源，不关闭溢出保护。
- Gemini consumer → Codex 已由本人明确冻结，日用接入未交付；不自动安装、启用、换型实测或续作调试。仅该接入冻结，其他 Provider 与官方 Antigravity 不受影响。重开须本人明确决定及新证据，详见[冻结与恢复边界](docs/maintainer/Gemini-integration-freeze.md)。
- 本地模型按需使用，不代替原生委派策略。日常增减只走 `scripts/Sync-LocalModelConfiguration.ps1`，保留各引擎专有参数；普通同步做必要读回，实际故障再定向验证，不机械要求全客户端实跑。
- 菜单、默认项和启动提示显示真实模型名称，不出现 main、local-default、主用/复核等内部别名。兼容入口去重仍记住实际选中的稳定 ID，不暗中重路由。
- Desktop 桥沿用官方动态模型目录及官方引擎发现，未知通知和请求透传；不靠固定版本白名单阻止官方升级。机器安装、已加载进程和用户验收分别核实。

## 配置、恢复与验证

- 不永久写全局 Provider 变量，不覆盖用户基础 config/settings 或官方登录；只在真实 CODEX_HOME 维护身份可验证的派生配置，保留未知或用户改过的文件。
- 密钥使用 Windows CurrentUser 安全存储，只注入必要子进程；不进入参数、Git、日志、异常、导出或快照。禁止字符串执行用户参数。受管代理只监听 127.0.0.1；自定义远端明文 HTTP 默认拒绝。
- 端口分配遵守维护契约，不杀未知占用者、不改系统端口范围、防火墙或提权抢端口。第三方代理执行文件必须匹配已批准哈希或发布者签名。
- 普通卸载保留上游 CLI、登录、本地模型、Profile 和秘密；彻底清理另列准确范围。删除本地 OAuth 文件不代表远端撤销；模块更新不顺手替换独立登记的 Desktop 桥。
- Windows 路径用 Known Folders；中文 PowerShell 脚本用 UTF-8 BOM，Markdown/JSON 用 UTF-8 无 BOM。
- 离线验证：`pwsh -File scripts/Test-Release.ps1`、Pester 5.5+ 的 `Invoke-Pester -Path tests`；发行再跑 `scripts/Build.ps1`。覆盖参数、中文路径、隔离、原子写入、端口竞争和恢复。
- CI 不读取真实 Key，不跑付费 Live。Live Tool Test 仅开放隔离 nonce 工具，隔离不能证明就报告限制；未完成当期真实验证不能标 Provider 可用。两本 PDF 变动时由 `scripts/Build-Pdfs.py` 生成并验版，源文哈希必须匹配。
