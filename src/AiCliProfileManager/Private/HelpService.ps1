# Chinese help topics: function → command → effect first.

function Show-AiCliHelp {
    param([string]$Topic)
    if ([string]::IsNullOrWhiteSpace($Topic)) {
        Show-AiCliHelpRoot
        return
    }
    switch -Regex ($Topic.ToLowerInvariant()) {
        '^(compact)$' { Show-AiCliHelpCompact }
        '^(model)$' { Show-AiCliHelpModel }
        '^(effort|think)' { Show-AiCliHelpEffort }
        '^(perm)' { Show-AiCliHelpPermissions }
        '^(resume|session)' { Show-AiCliHelpResume }
        '^(compare)$' { Show-AiCliHelpCompare }
        '^(setup|profile|start|run|doctor|test|proxy|update|native|eject|uninstall)$' { Show-AiCliHelpCommand -Command $Topic.ToLowerInvariant() }
        default {
            throw "未知帮助主题: $Topic"
        }
    }
}

function Show-AiCliHelpRoot {
    $cmd = Get-AiCliCommandName
    $name = Get-AiCliProductName
    Write-Host @"
$name — 命令帮助

功能：用 Profile 启动原生 Codex / Claude Code / Qwen Code / OpenCode / Open Interpreter，或供上层 AI 发起受硬预算监管的任务；Codex harness 始终是完全访问。

常用命令：
  $cmd setup
  $cmd profile list
  $cmd start <profile> [--project <path>] [-- <native-args...>]
  $cmd run start <profile> --stdin --json --project <path> [--background] [--no-web-search]
  $cmd run status|abort <run-id> --json
  $cmd run resume <run-id> --json [--background]
  $cmd doctor [profile]
  $cmd test <profile> --live [--level text|tool|agent|all] [--yes]
  $cmd proxy <ccp|cliproxy> status
  $cmd native <profile>
  $cmd eject <profile>
  $cmd help setup|profile|start|run|doctor|test|proxy|update|native|eject|uninstall
  $cmd help compact|model|effort|permissions|resume|compare

精确第三方 Codex 一键入口：
  $cmd start codex-qwen3-7-max-paygo --project <trusted-workspace>
  $cmd start codex-qwen3-8-max-paygo --project <trusted-workspace>
  $cmd start codex-glm-5-3 --project <trusted-workspace>
  $cmd start codex-glm-5-3-flash --project <trusted-workspace>
  $cmd start codex-deepseek-flash --project <trusted-workspace>
  $cmd start codex-ollama-main --project <trusted-workspace>
  $cmd start codex-ollama-qwen3-8-27b --project <trusted-workspace>
  $cmd start codex-ollama-review --project <trusted-workspace>

使用 $cmd profile list --available 查看 exact model 与默认 max；云 Profile 首次使用前只需配置一次 SecretRef。
所有当前及未来 Codex harness 调用固定为原生 danger-full-access，并默认提供受管 public_web_search；显式较低权限会失败关闭，--no-web-search 只关闭搜索。

详细手册见 docs/user/。
"@
}

function Show-AiCliHelpCompact {
    Write-Host @'
# 压缩上下文

功能：减少当前会话占用的上下文，腾出空间继续对话。

命令（会话内，英文原样）：
  Codex:   /compact
  Claude:  /compact

执行后：总结并压缩历史；不会删除磁盘上的全部会话记录（取决于上游实现）。

生效：当前会话立即。

注意：压缩不可完美还原细节。原生 ChatGPT + Codex 保持上游默认；DeepSeek、千问及本地模型的第三方 CLI 路由不要为了省上下文主动 compact。

建议：一个会话只做一个内聚里程碑。确需压缩前先把目标与验收、约束/授权/owner、规则与关键文件、改动和脏改动归属、决定、测试/Live 缺口、阻塞与下一步写入项目已有状态文档；压缩后把摘要当线索，重读项目规则（AGENTS.md/CLAUDE.md）、状态文档和 git diff/status。不要建立第二事实源。

对照：二者都有 compact，语义相近但实现不等价。
'@
}

function Show-AiCliHelpModel {
    Write-Host @'
# 切换模型

功能：更换当前会话使用的模型。

命令：
  Codex:   /model
  Claude:  /model

或在启动时：
  aicli start codex-official -- --model <id>  # 仅 flexible Profile

第三方 exact Codex Profile（Qwen / DeepSeek / 本地 main/review）由 Profile 固定模型；
不接受 --model、-m 或 --fallback-model。请选择另一个精确 Profile。

执行后：后续请求使用新模型；已产生的历史仍占用上下文。

生效：通常下一请求。

更多：各 Provider 可用模型以官方文档与 Profile 候选为准。
'@
}

function Show-AiCliHelpEffort {
    Write-Host @'
# 思考等级 / effort

功能：调节模型思考深度（延迟与质量权衡）。

命令：
  Codex:   /reasoning（或在 /model 中调整）/ 配置 model_reasoning_effort
  Claude:  /effort   或相关思考设置

执行后：影响后续推理强度；不同厂商语义不完全等价，aicli 不会伪装成“完全相同”。

对受管第三方 Codex Profile，用户看到的 max 始终表示该模型当前支持的最高思考档：
  - Qwen3.7 Max 06-08: max → 原生 xhigh
  - Qwen3.8 Max: max → 原生 xhigh
  - DeepSeek Flash / V4 Pro: max → 原生 max
  - 本地 qwen-main/review: max → 目录最高档 max

启动计划会解析、固定并记录 requested/effective effort；它们是发出的计划值，不冒充供应商回读。只有取得独立证明时 attested effort 才会有值。

生效：通常下一请求。

示例（透传上游参数，需 Profile 支持）：
  aicli start claude-official -- --effort high
'@
}

function Show-AiCliHelpPermissions {
    Write-Host @'
# 权限与审批

功能：控制 CLI 执行命令/改文件前是否询问你。

命令：
  Codex:   /permissions  以及 approval_policy / sandbox 配置
  Claude:  /permissions
  Claude 会话内：Shift+Tab 循环 manual → acceptEdits → plan
  启动时：aicli start <claude-profile> -- --permission-mode acceptEdits

执行后：改变工具调用审批行为。

生效：当前会话或按上游说明。

Claude 底栏「manual mode on」= 官方默认档，不是故障。
千问等第三方模型下 auto 模式通常不可用；bypass 须启动时带
  --permission-mode bypassPermissions --dangerously-skip-permissions
PowerShell 防吞参数：pwsh -File bin\aicli.ps1 --% start … -- --permission-mode …

安全：交互式 `aicli start` 不替用户改写原生权限；面向上层程序的 `aicli run`
对所有当前及未来 Codex 模型固定使用 `danger-full-access` 与 `approvalPolicy=never`，默认注册固定 HTTPS RSS 的受管 `public_web_search`，
显式较低权限会失败关闭。该合同不按模型白名单分支，新增 Codex 模型自动继承。
专文：docs/user/CLAUDE-PERMISSIONS-AND-QWEN.md
'@
}

function Show-AiCliHelpResume {
    Write-Host @'
# 恢复会话

功能：回到之前的对话线程。

命令：
  Codex:   codex resume   或会话内恢复命令（见官方）
  Claude:  claude -c / --continue  或 /resume
  AICLI harness:
    aicli run start <profile> --stdin --json --project <path> --background
    aicli run status <run-id> --json
    aicli run resume <run-id> --json [--background]
    aicli run abort <run-id> --json

执行后：加载历史上下文；不是新进程的“干净状态”。

生效：立即进入已有会话。

区分：
  - 新进程：重新 aicli start（可换 Profile）
  - 新会话：在同一 CLI 内开新 thread
  - 恢复会话：继续旧 thread

AICLI harness 只在 app-server 回读同一 thread/session、工作区、Profile 指纹、
模型、Provider、effort 与全访问权限后 exact resume。进程退出、瞬态上游错误或
重启后证据不足会返回 resume_supported=false 与原因；禁止把旧上下文塞入新
thread 冒充恢复。默认最多自动恢复 3 次，额度暂停不消耗该次数。
'@
}

function Show-AiCliHelpCompare {
    Write-Host @'
# Codex vs Claude Code 常用对照

| 任务     | Codex              | Claude Code        |
|----------|--------------------|--------------------|
| 压缩     | /compact           | /compact           |
| 模型     | /model             | /model             |
| 思考     | /reasoning         | /effort            |
| 权限     | /permissions       | /permissions       |
| 非交互   | codex exec ...     | claude -p ...      |
| 配置主档 | ~/.codex/config.toml | ~/.claude/settings.json |
| Profile  | --profile name + name.config.toml | 多为环境变量 / settings |

不要假设命令参数与思考语义完全一致。
'@
}

function Show-AiCliHelpCommand {
    param([Parameter(Mandatory)][string]$Command)
    $rows = [ordered]@{
        setup     = @('首次引导与本机体检。','aicli setup','显示环境状态并选择要配置的 Profile。')
        profile   = @('查看、配置、设默认值或删除用户 Profile。','aicli profile list --available；aicli profile configure <模板 ID> [--reuse-existing-secret | --reuse-secret-from <Profile ID>]；aicli profile remove <ID>','秘密复用只允许同一凭据域且不读取明文；删除最后一个引用某密钥的 Profile 时，也会删除对应 DPAPI 密钥文件。')
        start     = @('在指定项目目录中启动真实上游 CLI。','aicli start <精确 Profile ID> --project <项目路径>','第三方 Profile 封闭 Provider、模型、Responses、max 映射和 SecretRef；用户无需拼底层参数。')
        run       = @('供上层程序通过 stdin 调用可恢复、受墙钟/步数/工具/输出预算监管的任务；预算不等于权限沙箱。','aicli run start <Profile ID> --stdin --json --project <路径> [--background]；aicli run status|resume|abort <run-id> --json','所有当前及未来 Codex harness Profile 固定使用原生 danger-full-access，并默认提供受管 public_web_search。每个 run 绑定持久 thread/session 与工作区/Profile/模型/Provider/effort；恢复身份变化、证据链损坏或新 thread 都失败关闭。后台控制器可供 benchmark 轮询，瞬态错误最多自动 exact-resume 3 次。')
        doctor    = @('检查 CLI、Profile、端点、代理和配置冲突，不发送模型请求。','aicli doctor [Profile ID] [--json]','输出“通过 / 可用 / 可用但有限制 / 不可用”及下一步。')
        test      = @('通过目标 CLI 发送真实连通或 Agent 能力请求。','aicli test <Profile ID> --live --level agent --yes --json','agent 会在隔离目录运行可恢复的非平凡文件任务，并由独立 verifier 验收；真实请求可能消耗额度。')
        proxy     = @('安装、登录、启停和检查 ccp / CLIProxyAPI。','aicli proxy <ccp|cliproxy> status','只允许 loopback 监听；ChatGPT 通道为可选第三方方案。')
        update    = @('检查本工具和上游 CLI 版本，或显示官方更新命令。','aicli update check；aicli update guide codex','只报告与指导，不静默自动升级。')
        native    = @('查看实际可执行文件、参数、子进程环境和数据去向。','aicli native <Profile ID>','秘密字段始终脱敏。')
        eject     = @('导出不含秘密的独立启动配方。','aicli eject <Profile ID> --output <新目录>','不会导出 API Key/OAuth；运行前需自行提供密钥。')
        uninstall = @('卸载模块；默认保留用户数据。','aicli uninstall [--purge-user-data] [--yes]','purge 才删除 Profile、DPAPI 密钥和代理本地数据；不等于远程撤销 OAuth。')
    }
    $row = $rows[$Command]
    Write-Host ("# {0}`n`n功能：{1}`n`n命令：{2}`n`n效果：{3}" -f $Command,$row[0],$row[1],$row[2])
}
