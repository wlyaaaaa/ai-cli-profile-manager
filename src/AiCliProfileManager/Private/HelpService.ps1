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

功能：用 Profile 启动原生 Codex / Claude Code / Qwen Code / OpenCode / Open Interpreter，或供上层 AI 发起有界沙箱任务。

常用命令：
  $cmd setup
  $cmd profile list
  $cmd start <profile> [--project <path>] [-- <native-args...>]
  $cmd run <profile> --stdin --json --project <path> --sandbox-policy <read-only|workspace-write> -- <native-args...>
  $cmd doctor [profile]
  $cmd test <profile> --live [--level text|tool|all] [--yes]
  $cmd proxy <ccp|cliproxy> status
  $cmd native <profile>
  $cmd eject <profile>
  $cmd help setup|profile|start|run|doctor|test|proxy|update|native|eject|uninstall
  $cmd help compact|model|effort|permissions|resume|compare

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

注意：压缩不可完美还原细节；重要结论请先让模型写到文件。

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
  aicli start <profile> -- --model <id>     # 视上游 CLI 支持而定
  aicli start codex-ollama -- -m <model>

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

安全：公开项目不默认开启“完全访问/不询问”。需要时在原生 CLI 内显式设置。
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

执行后：加载历史上下文；不是新进程的“干净状态”。

生效：立即进入已有会话。

区分：
  - 新进程：重新 aicli start（可换 Profile）
  - 新会话：在同一 CLI 内开新 thread
  - 恢复会话：继续旧 thread
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
        profile   = @('查看、配置、设默认值或删除用户 Profile。','aicli profile list --available；aicli profile configure <模板 ID>；aicli profile remove <ID>','删除最后一个引用某密钥的 Profile 时，也会删除对应 DPAPI 密钥文件。')
        start     = @('在指定项目目录中启动真实上游 CLI。','aicli start <Profile ID> --project <项目路径> -- <原生参数>','Provider、模型和密钥只注入该子进程。')
        run       = @('供上层程序通过 stdin 调用一个有界智能体任务。','aicli run <Profile ID> --stdin --json --project <路径> --sandbox-policy read-only|workspace-write -- <原生参数>','外层 Codex 沙箱禁止外网并限制文件范围；只返回子进程输出和结果侧元数据，不返回环境或密钥。')
        doctor    = @('检查 CLI、Profile、端点、代理和配置冲突，不发送模型请求。','aicli doctor [Profile ID] [--json]','输出“通过 / 可用 / 可用但有限制 / 不可用”及下一步。')
        test      = @('通过目标 CLI 发送一次真实连通请求。','aicli test <Profile ID> --live --level text --yes','会消耗额度；最终正文必须严格匹配 PONG，未执行的工具测试不会冒充通过。')
        proxy     = @('安装、登录、启停和检查 ccp / CLIProxyAPI。','aicli proxy <ccp|cliproxy> status','只允许 loopback 监听；ChatGPT 通道为可选第三方方案。')
        update    = @('检查本工具和上游 CLI 版本，或显示官方更新命令。','aicli update check；aicli update guide codex','只报告与指导，不静默自动升级。')
        native    = @('查看实际可执行文件、参数、子进程环境和数据去向。','aicli native <Profile ID>','秘密字段始终脱敏。')
        eject     = @('导出不含秘密的独立启动配方。','aicli eject <Profile ID> --output <新目录>','不会导出 API Key/OAuth；运行前需自行提供密钥。')
        uninstall = @('卸载模块；默认保留用户数据。','aicli uninstall [--purge-user-data] [--yes]','purge 才删除 Profile、DPAPI 密钥和代理本地数据；不等于远程撤销 OAuth。')
    }
    $row = $rows[$Command]
    Write-Host ("# {0}`n`n功能：{1}`n`n命令：{2}`n`n效果：{3}" -f $Command,$row[0],$row[1],$row[2])
}
