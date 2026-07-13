# AI CLI Profile Manager 使用手册

适用版本：`0.1.0`
适用系统：Windows 11 x64、PowerShell 7
命令入口：`aicli`

AI CLI Profile Manager 是原生 Codex CLI、Claude Code 与 Open Interpreter 的启动和运维层。它负责保存 Profile、隔离 Provider 环境、管理可选代理、体检和连通测试；聊天界面、历史会话、工具执行和上游账号仍由各 CLI 自己负责。

> 本手册是产品操作的唯一事实源。三套上游 CLI 的会话内命令见《[Codex、Claude Code 与 Open Interpreter CLI 中文手册](<./Codex、Claude Code 与 Open Interpreter CLI 中文手册.md>)》。

## 1. 五分钟开始

### 1.1 安装前提

- Windows 11 x64。
- PowerShell 7，命令为 `pwsh`。
- 至少安装一个目标 CLI：Codex、Claude Code 或当前官方 Rust Open Interpreter。
- 使用云端 API 的 Profile 需要对应 Provider 的 Key；官方订阅 Profile 使用上游自己的登录。

### 1.2 安装本工具

从 [GitHub Releases](https://github.com/wlyaaaaa/ai-cli-profile-manager/releases/latest) 下载同一版本的 ZIP 和 `.sha256.json`。下面的命令会先核对发布清单，再解除这个已核对 ZIP 的 Internet 阻止标记；不需要也不应该全局放宽 ExecutionPolicy：

```powershell
$version = '0.1.0'
$base = "https://github.com/wlyaaaaa/ai-cli-profile-manager/releases/download/v$version"
$download = Join-Path $HOME "Downloads\ai-cli-profile-manager-$version"
New-Item -ItemType Directory -Force -Path $download | Out-Null

$zip = Join-Path $download "ai-cli-profile-manager-$version-win-x64.zip"
$hashJson = Join-Path $download "ai-cli-profile-manager-$version.sha256.json"
Invoke-WebRequest "$base/$(Split-Path $zip -Leaf)" -OutFile $zip
Invoke-WebRequest "$base/$(Split-Path $hashJson -Leaf)" -OutFile $hashJson

$expected = (Get-Content -LiteralPath $hashJson -Raw | ConvertFrom-Json).sha256
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw 'SHA256 不匹配，拒绝安装。' }

Unblock-File -LiteralPath $zip
$extract = Join-Path $download 'package'
Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
Set-Location $extract
pwsh -File .\scripts\Install.ps1
```

如果已经手动下载并核对文件，从解压后的目录执行安装器即可：

```powershell
pwsh -File .\scripts\Install.ps1
```

目标版本已经存在时，安装器默认拒绝覆盖。确认替换同一版本时使用：

```powershell
pwsh -File .\scripts\Install.ps1 -Force
```

安装器会：

1. 把模块安装到当前用户的 PowerShell 模块目录，不要求管理员权限。
2. 创建 `%LOCALAPPDATA%\aicli\bin\aicli.cmd` 与 `aicli.ps1` 垫片，并尝试加入用户 `PATH`。
3. 尝试在当前用户 PowerShell 7 配置中加入模块自动导入块。
4. 先验证临时候选版本，再替换目标版本；失败时恢复原版本。

新开一个 PowerShell 7 窗口后验证：

```powershell
Get-Command aicli
aicli version
```

当前窗口还找不到 `aicli` 时：

```powershell
$env:Path = "$env:LOCALAPPDATA\aicli\bin;$env:Path"
Import-Module AiCliProfileManager
aicli version
```

开发者也可以不安装，直接在仓库根目录运行：

```powershell
pwsh -File .\bin\aicli.ps1 version
pwsh -File .\bin\aicli.ps1 doctor
```

### 1.3 第一次设置

```powershell
aicli setup
```

`setup` 会检查 Windows、PowerShell、目标 CLI、Profile、Ollama 和可选代理，并让你选择要配置的方向。静态检查不会让模型生成内容；配置第三方云端 Profile 时才会要求无回显输入 API Key。

### 1.4 开始第一段对话

在项目根目录运行：

```powershell
aicli start codex-official
# 或
aicli start claude-official
```

也可以显式指定含空格或中文的目录：

```powershell
aicli start codex-official --project "C:\Work\Demo App"
aicli start claude-official --project "D:\项目\演示"
```

命令会立即启动一个新的原生 CLI 进程。父终端的 Provider 环境变量不会被永久修改。

### 1.5 工作区日常用法（千问写代码）

多数日常工程任务可以在**项目根目录**直接启动已配置好的千问 + Claude Code：

```powershell
cd E:\你的项目
# 例：cd C:\Work\my-project

aicli start claude-qwen-paygo
```

说明：

- 工作目录默认是**当前 shell 目录**；Claude 欢迎页左下角路径应与项目一致。不 `cd` 时用 `--project "路径"`。
- 首次弹出 **Detected a custom API key** 时：走千问/百炼应选 **Yes**。界面上的 “No (recommended)” 是针对官方 claude.ai 订阅路径，不是本 Profile 的推荐。
- 同千问三条引擎只按任务选（不按「熟哪个 CLI」）：

| 任务 | 优先 Profile |
|------|----------------|
| 写代码、改仓库、工程对话 | `claude-qwen-paygo` |
| 本机执行脚本/操作环境 | `oi-qwen-paygo`（需已装 Open Interpreter） |
| Codex / Responses 工作流 | `codex-qwen-paygo` |
| 拿不准 | `claude-qwen-paygo` |

### 1.6 安装或升级 aicli 之后必须用新会话

`Install.ps1 -Force` 或手动覆盖模块目录后，**已经打开的 PowerShell 窗口仍可能加载旧模块**。会出现「别人已修好、你这边还在报 `engine` / 旧行为」的假象。

任选其一：

```powershell
# 推荐：关掉终端，新开 pwsh 再运行 aicli
# 或在当前窗口强制重载：
Remove-Module AiCliProfileManager -Force -ErrorAction SilentlyContinue
Import-Module AiCliProfileManager -Force
aicli version
```

## 2. 先理解三个对象

| 对象 | 保存什么 | 是否包含秘密 |
|------|----------|--------------|
| Provider 模板 | 随产品发布的引擎、端点、模型和能力声明 | 否 |
| 用户 Profile | 选择的模板、地域、模型、项目偏好和秘密引用 | 只保存引用 |
| 启动计划 | 本次可执行文件、工作目录、参数和子进程环境 | 运行时短暂持有必要秘密 |

`aicli start` 每次根据模板和用户 Profile 重新生成启动计划，因此更新或重新安装上游 CLI 后，不需要把 Key 写进全局环境变量。Profile 切换只对**新进程**生效，不能在已经打开的会话中途热切换 Provider。

## 3. Profile 管理

### 3.1 命令总览

```powershell
aicli profile list
aicli profile list --available
aicli profile list --available --json
aicli profile show claude-qwen-paygo
aicli profile configure claude-qwen-paygo
aicli profile configure claude-qwen-paygo --id qwen-work
aicli profile set-default codex-official
aicli profile remove qwen-work
```

| 命令 | 作用 | 生效时间 |
|------|------|----------|
| `profile list` | 显示可直接启动或已经配置的 Profile | 立即 |
| `profile list --available` | 显示全部公开模板和当前状态 | 立即 |
| `profile show` | 脱敏显示 Provider、端点、模型、密钥是否存在和数据去向 | 立即 |
| `profile configure` | 保存用户 Profile；需要时无回显录入 Key并用 DPAPI 加密 | 下次启动 |
| `profile set-default` | 设置无参数入口优先使用的 Profile | 下次无参数运行 |
| `profile remove` | 删除用户实例；不删除内置模板 | 立即 |

删除型命令会先确认。使用 `--yes` 可跳过交互确认。删除最后一个引用某密钥的用户 Profile 时，也会删除本工具保存的对应 DPAPI 密钥文件；不会删除上游官方登录。

### 3.2 首版公开 Profile

| 引擎 | 场景 | Profile |
|------|------|---------|
| Codex | ChatGPT/OpenAI 官方登录 | `codex-official` |
| Codex | 千问按量 Responses | `codex-qwen-paygo` |
| Codex | 千问 Token Plan Responses | `codex-qwen-token-plan` |
| Codex | 本机 Ollama | `codex-ollama` |
| Claude Code | Claude 官方登录 | `claude-official` |
| Claude Code | DeepSeek | `claude-deepseek` |
| Claude Code | 千问按量、Coding Plan、Token Plan | `claude-qwen-paygo`、`claude-qwen-coding-plan`、`claude-qwen-token-plan` |
| Claude Code | 本机 Ollama | `claude-ollama` |
| Claude Code | 自定义 Anthropic Messages 兼容端点 | `claude-custom` |
| Claude Code | ChatGPT 第三方本地代理 | `claude-chatgpt-ccp`、`claude-chatgpt-cliproxy` |
| Open Interpreter | 千问 Responses | `oi-qwen-paygo` |
| Open Interpreter | DeepSeek Chat | `oi-deepseek` |
| Open Interpreter | 本机 Ollama | `oi-ollama` |

Codex 首版不提供 DeepSeek、千问 Coding Plan 或纯 Chat Completions 直连。千问按量、Token Plan 与 Coding Plan 的 Key、端点和能力不同，不能混用。

Ollama 公共模板使用默认地址 `127.0.0.1:11434`，不再包含某台机器的私有端口或模型别名。使用前先确认服务和模板所列模型实际存在：

```powershell
ollama list
aicli doctor codex-ollama
```

### 3.3 配置第三方 API

以千问和 DeepSeek 为例：

```powershell
aicli profile configure claude-qwen-paygo
aicli profile configure codex-qwen-paygo
aicli profile configure claude-deepseek
aicli profile configure oi-deepseek
```

配置过程中会先显示引擎、Provider、套餐和数据去向，再无回显读取 Key。秘密使用 Windows DPAPI CurrentUser 保存，不写入 Git、日志、`profile show`、`native` 或 `eject`。

### 3.4 启动、查看与导出

```powershell
aicli start claude-deepseek --project "C:\Work\Project"
aicli native claude-deepseek
aicli eject claude-deepseek --output .\export-claude-deepseek
```

- `start` 启动真实上游 CLI。
- `native` 脱敏显示可执行文件、配置、环境差异和数据去向，不执行模型请求。
- `eject` 导出不含 Key/OAuth 的独立配方；目标目录已存在时应换一个新目录。

原生参数必须放在双横线之后：

```powershell
aicli start claude-official -- --effort high
aicli start claude-qwen-paygo -- --permission-mode acceptEdits
aicli start codex-ollama -- -m qwen3:8b
```

与本工具启动计划冲突的 Provider、认证、`--profile`、`--settings` 或 `-c` 覆盖会被拒绝。不要用透传参数绕过 Profile 的安全边界。

### 3.5 从 OpenClaw 安全导入（可选）

如果 OpenClaw 已经保存了千问或 DeepSeek 配置，可以用发行包里的导入脚本减少重复录入。它默认只预览，不修改 Profile，也不显示 Key：

```powershell
pwsh -File .\scripts\Import-FromOpenClaw.ps1
```

配置文件不在默认的 `%USERPROFILE%\.openclaw\openclaw.json` 时，显式指定路径：

```powershell
pwsh -File .\scripts\Import-FromOpenClaw.ps1 -OpenClawJson "D:\配置\openclaw.json"
```

确认预览内容后再导入：

```powershell
pwsh -File .\scripts\Import-FromOpenClaw.ps1 -Apply
```

已有同名 Profile 时默认跳过；只有明确要替换时才使用：

```powershell
pwsh -File .\scripts\Import-FromOpenClaw.ps1 -Apply -Force
```

脚本只接受能由 HTTPS 主机名证明身份的配置：千问必须指向阿里云百炼域名，DeepSeek 必须指向 `api.deepseek.com`。未知/OpenAI Base URL 会被拒绝，避免把某家的 Key 误送到另一家。导入的 Key 立即使用 Windows CurrentUser DPAPI 保存；输出、Profile JSON 和日志中都不出现明文。导入后运行 `aicli doctor <Profile ID>`，需要真实连通证据时再显式执行 Live Test。

## 4. Doctor 与 Live Test

### 4.1 Doctor：静态检查，不生成模型内容

```powershell
aicli doctor
aicli doctor claude-qwen-paygo
aicli doctor claude-qwen-paygo --json
```

Doctor 检查 CLI、Profile、秘密引用、端点、有效配置层、代理、端口和本机服务。它不发送模型生成请求，不应消耗模型额度。

| 状态 | 含义 |
|------|------|
| `通过` | 单个检查项成功 |
| `可用` | 要求的真实验证和必要能力均有当前证据 |
| `可用但有限制` | 静态就绪但未完成全部 Live Test，或存在已知限制 |
| `不可用` | 关键依赖、配置或测试失败 |

找不到可选 CLI 不应否定其他引擎；请按 check ID 和“下一步”处理目标 Profile 的问题。

### 4.2 Live Test：真实请求，可能消耗额度

```powershell
aicli test claude-deepseek --live --level text
aicli test claude-deepseek --live --level text --yes
aicli test claude-deepseek --live --level all --yes --json
```

`--live` 必须显式给出；没有 `--yes` 时会再次确认。文本测试在随机临时空目录中运行，禁用或隔离私人配置和工具，通过目标 CLI 发出最小请求，并要求正常退出且最终模型正文严格等于 `PONG`。提示和回复正文不写日志。

| 层级 | 含义 |
|------|------|
| `text` | 验证目标 CLI、Provider、模型和最小文本链路 |
| `tool` | 只验证隔离的单用途 nonce 工具链 |
| `all` | 依次验证两层 |

无法证明工具隔离时，工具层会跳过并显示“可用但有限制”，不会冒充完整文件或 Shell 编程能力已经通过。

当前哪些 Profile 已完成文本验收、哪些仍待验收，以《[兼容性与最终验收状态](../compatibility/VERIFIED-COMPATIBILITY.md)》为准；成功记录也不能跨模型、端点或公开默认配置外推。

## 5. 当前官方 Rust Open Interpreter

本工具只支持当前官方 Rust Open Interpreter `0.0.21` 或更高版本，不支持旧 Python `open-interpreter 0.4.x`。

### 5.1 安装和验证

```powershell
irm https://www.openinterpreter.com/install.ps1 | iex
interpreter --version
aicli doctor
```

版本输出必须类似 `interpreter 0.0.21` 或更高。若检测到 `Open Interpreter 0.4.x`，Doctor 会把它识别为不受支持的旧 Python 版本，并给出当前官方安装命令。

### 5.2 配置和启动

```powershell
aicli profile configure oi-qwen-paygo
aicli start oi-qwen-paygo

aicli profile configure oi-deepseek
aicli start oi-deepseek

aicli start oi-ollama
```

aicli 通过 Rust CLI 的临时 `-c` 配置层写入 Provider、模型、`base_url` 和 `wire_api`。云端 Key 只进入目标子进程环境变量，且明确从 OI Shell 工具环境中排除；不会放进命令行参数。默认不启用跳过审批、跳过沙箱或旧版 `auto_run` 参数。

Open Interpreter 仍具备本机代码执行能力。只在信任的项目目录和 Provider 中使用，并在 OI 自己的 `/permissions` 中确认权限。

官方资料：[安装](https://www.openinterpreter.com/docs/terminal/install)、[快速开始](https://www.openinterpreter.com/docs/terminal/quickstart)、[配置](https://www.openinterpreter.com/docs/terminal/config)、[Provider](https://www.openinterpreter.com/docs/terminal/providers)。

## 6. Claude Code 权限与第三方模型

aicli 默认不替用户设置 Claude permission mode。底栏 `manual mode on` 是 Claude Code 的默认权限档，不是启动失败。

会话内按 `Shift+Tab` 通常在以下模式间循环：

```text
manual → acceptEdits → plan
```

查看工具规则：

```text
/permissions
```

启动时指定更松的日常写代码模式：

```powershell
aicli start claude-qwen-paygo -- --permission-mode acceptEdits
```

完全绕过权限只适合外部已经隔离、没有不可信网络或文件的环境：

```powershell
aicli start claude-qwen-paygo -- --permission-mode bypassPermissions --dangerously-skip-permissions
```

PowerShell 有时会吞掉参数分隔用的 `--`，导致 `--permission-mode` 等并未传给 Claude。需要透传时优先：

```powershell
pwsh -NoProfile -File $env:LOCALAPPDATA\aicli\bin\aicli.ps1 --% start claude-qwen-paygo -- --permission-mode acceptEdits
# 或开发仓库：
pwsh -NoProfile -File <安装目录>\bin\aicli.ps1 --% start claude-qwen-paygo -- --permission-mode acceptEdits
```

`bypassPermissions` 必须在新进程启动时启用。第三方模型通常不满足 Claude `auto` 模式的模型或账号条件；这不是 aicli 的故障。

Claude 官方登录与 `ANTHROPIC_API_KEY` 同时存在时，上游可能显示双认证或 connectors disabled 提示。使用第三方 API Profile 时以该 Profile 显示的数据去向为准；使用 `claude-official` 时，先运行 Doctor 检查会抢占官方路径的设置层。

第三方模型（如千问）下，Claude 会话结束页的 **Total cost: $… (costs may be inaccurate due to usage of unknown models)** **不是** 阿里云百炼账单。token 量级可能接近真实调用；美元金额多半按 Claude 内置未知模型单价估算，**往往偏高**。真费用以百炼「模型监控 / 账单」为准（调用后约一小时可查）。详见《CLI 中文手册》用量说明。

## 7. ChatGPT 双代理（可选）

两个通道都是第三方本地代理，不是 OpenAI 或 Anthropic 官方功能，也不自动串联或故障转移。

| ID | 上游 | 角色 | 首选端口 |
|----|------|------|----------|
| `ccp` | `raine/claude-code-proxy` | Claude Code 到 ChatGPT 的专用转换器 | `43197` |
| `cliproxy` | `router-for-me/CLIProxyAPI` | 多协议备用通道 | `43198` |

`0.1.0` 未完成两个代理的交互 OAuth 和端到端 Live Test；它们只能标为“可用但有限制”，不能由安装成功推断为订阅链路可用。

完整流程：

```powershell
aicli proxy ccp install
aicli proxy ccp configure --auto-port
aicli proxy ccp login
# 无法打开本机浏览器时：
aicli proxy ccp login device
aicli proxy ccp start
aicli proxy ccp status
aicli start claude-chatgpt-ccp
```

将 `ccp` 换成 `cliproxy` 可使用另一通道。CLIProxyAPI 登录还可显式选择 `codex`、`claude` 或 `device`：

```powershell
aicli proxy cliproxy login codex
aicli proxy cliproxy login device
```

安全边界：

- 下载的 Windows artifact 必须命中产品批准的精确 SHA256，否则拒绝安装或更新。
- 受管代理只允许监听 `127.0.0.1`；发现 wildcard、局域网或公网监听会停止本次受管进程。
- 首选端口不可用时在受控候选池中重试，不杀未知占用进程。
- 本工具不读取 OAuth token 正文。
- `logout --purge-local-auth` 只删除本项目隔离的本地认证目录，不等于远程撤销授权。

退出与停止：

```powershell
aicli proxy ccp stop
aicli proxy ccp logout
aicli proxy ccp logout --purge-local-auth --yes
```

远程授权请另外在对应账号的安全或已授权应用页面确认撤销。

## 8. 更新与修复

### 8.1 只读检查

```powershell
aicli update check
aicli update check codex --json
aicli update guide codex
aicli update guide claude
aicli update guide ollama
aicli update guide interpreter
aicli update guide self
```

`update check` 和 `update guide` 只检查来源、版本并打印同渠道指引，不静默升级 Codex、Claude Code、Ollama 或本工具。识别来源后，应继续使用原安装渠道，避免 npm、WinGet 和原生安装器互相覆盖。

Open Interpreter Rust 可按上游支持使用：

```powershell
interpreter update
interpreter --version
```

受管代理版本检查：

```powershell
aicli proxy ccp update-check
```

`0.1.0` 只对未安装代理执行经过固定 SHA256 的首次 `install`。对已经安装的代理，`update` 会明确拒绝且不会替换当前版本；先用 `update-check` 查看批准状态，等待后续具备运行健康回滚的版本再做受管升级。

### 8.2 通用修复顺序

1. `aicli update check` 确认实际来源和版本。
2. 使用同一渠道更新目标 CLI。
3. 运行目标 CLI 的 `--version`。
4. 运行 `aicli doctor <Profile ID>`。
5. 静态通过后，再按需运行显式 Live Test。

## 9. 卸载、恢复与数据

### 9.1 普通卸载

```powershell
aicli uninstall
# 非交互确认
aicli uninstall --yes
```

普通卸载会停止本工具识别的受管代理，并完整移除当前用户模块、`%LOCALAPPDATA%\aicli\bin` 命令垫片、安装器加入的用户 `PATH` 项，以及带产品标记的 PowerShell Profile 自动导入块；不需要再手动清理这些安装集成。

普通卸载默认保留用户 Profile、DPAPI 密钥、代理本地数据和导出物，便于以后重装恢复。它不会卸载 Codex、Claude Code、Open Interpreter、Ollama、本地模型，也不会删除上游官方登录。

### 9.2 彻底清理本工具数据

先处理代理登录：

```powershell
aicli proxy ccp logout
aicli proxy cliproxy logout
```

然后：

```powershell
aicli uninstall --purge-user-data --yes
```

`--purge-user-data` 删除本工具的 Profile、DPAPI 密钥、日志、缓存、代理二进制和代理本地认证目录。它不代表远程 OAuth 已撤销。

### 9.3 数据位置与去向

| 内容 | 默认位置 |
|------|----------|
| Profile、书签和非秘密设置 | `%APPDATA%\AiCliProfileManager` |
| DPAPI 密文、代理、状态、缓存和日志 | `%LOCALAPPDATA%\AiCliProfileManager` |
| 命令垫片 | `%LOCALAPPDATA%\aicli\bin` |

工具自身默认无遥测。使用某个 Profile 时，提示、项目上下文和相关数据会发送到 `profile show` 显示的 Provider 或本地代理；Ollama 在本机处理，Open Interpreter 还可能在本机执行代码。Live Test 会联系目标 Provider，并可能消耗额度，但不保存提示或回复正文。

## 10. 按症状排障

### 找不到 `aicli`

```powershell
$env:Path = "$env:LOCALAPPDATA\aicli\bin;$env:Path"
Import-Module AiCliProfileManager
aicli version
```

仍失败时，新开 PowerShell 7，再用安装包中的 `scripts\Install.ps1 -Force` 修复。

### 升级后行为仍像旧版 / 报奇怪的 `engine` 属性错误

当前窗口可能仍在用内存中的旧模块：

```powershell
Remove-Module AiCliProfileManager -Force -ErrorAction SilentlyContinue
Import-Module AiCliProfileManager -Force
Get-Module AiCliProfileManager | Format-List Path, Version
aicli version
```

或直接关闭终端重开。判断是否装到预期路径：

```powershell
Get-Command aicli | Format-List *
```

### 透传给 Claude 的参数像没生效

确认参数写在 `--` 之后；在 PowerShell 中优先使用 `--%`（见上文 §6）。也可用：

```powershell
& aicli @('start','claude-qwen-paygo','--','--permission-mode','acceptEdits')
```

### 找不到目标 CLI

```powershell
aicli doctor
codex --version
claude --version
interpreter --version
ollama --version
```

只安装你需要的上游 CLI；Open Interpreter 缺失不会影响 Codex 或 Claude Profile。

### Open Interpreter 显示旧 Python 0.4.x

旧版不受支持。使用当前官方安装器：

```powershell
irm https://www.openinterpreter.com/install.ps1 | iex
interpreter --version
```

确认输出以小写 `interpreter` 开头且版本不低于 `0.0.21`。

### Claude 官方返回 401

这通常表示当前机器的 Claude Code 尚未完成官方登录，不等于 aicli 安装失败。先直接运行 `claude` 完成上游登录，再执行：

```powershell
aicli doctor claude-official
aicli start claude-official
```

### 官方 Claude 意外走第三方 API

用户、项目或本地 `settings.json` 以及父终端变量可能含 `ANTHROPIC_API_KEY` 或 `ANTHROPIC_BASE_URL`：

```powershell
aicli doctor claude-official
aicli native claude-official
```

Doctor 只报告冲突文件和字段名，不展示值。不要让 aicli 自动改写你的上游设置文件。

### 千问 401、模型或套餐错误

按量、Token Plan 与 Coding Plan 的 Key、地域和端点互不通用：

```powershell
aicli profile show claude-qwen-paygo
aicli profile configure claude-qwen-paygo
aicli doctor claude-qwen-paygo
```

### Ollama 无法连接或模型不存在

```powershell
ollama list
aicli doctor codex-ollama
```

公共模板使用 `127.0.0.1:11434`。确认 Ollama 正在监听且目标模型已拉取；不要把别人的端口或私有模型别名照搬到公开配置。

### 代理安装被拒绝

批准清单没有目标 Windows artifact 的精确 SHA256。先运行：

```powershell
aicli proxy ccp update-check
```

发现上游版本不等于已经批准执行。普通用户不应自行绕过摘要校验。

### Live Test 失败

先运行 Doctor，确认登录、Key、模型、端点和代理状态。Live Test 的失败或跳过必须保持真实状态，不能用“CLI 能打开”代替连通证据。

## 11. 完整命令索引

```text
aicli
aicli setup
aicli version
aicli help [主题或命令]

aicli profile list [--available] [--json]
aicli profile show <Profile ID> [--json]
aicli profile configure <模板 ID> [--id <新 Profile ID>]
aicli profile set-default <Profile ID>
aicli profile remove <Profile ID> [--yes]

aicli start <Profile ID> [--project <项目路径>] [-- <原生参数...>]
aicli native <Profile ID>
aicli eject <Profile ID> [--output <新目录>]

aicli doctor [Profile ID] [--json]
aicli test <Profile ID> --live [--level text|tool|all] [--yes] [--json]

aicli proxy <ccp|cliproxy> install
aicli proxy ccp login [codex|device]
aicli proxy cliproxy login [codex|claude|device]
aicli proxy <ccp|cliproxy> logout [--purge-local-auth] [--yes]
aicli proxy <ccp|cliproxy> configure [--port <端口>|--auto-port]
aicli proxy <ccp|cliproxy> start
aicli proxy <ccp|cliproxy> stop
aicli proxy <ccp|cliproxy> status [--json]
aicli proxy <ccp|cliproxy> update-check
aicli proxy <ccp|cliproxy> update
aicli proxy <ccp|cliproxy> native

aicli update check [codex|claude|ollama|interpreter|ccp|cliproxy|self] [--json]
aicli update guide [codex|claude|ollama|interpreter|ccp|cliproxy|self]
aicli uninstall [--purge-user-data] [--yes]
```

说明：`0.1.0` 保留 `proxy ... update` 命令用于安全拒绝已安装实例；它不是可用的受管升级通道。未安装时请使用 `install`。

退出码：`0` 成功、`2` 用法错误、`3` 可用但有限制、`4` 不可用、`5` 内部错误、`6` 用户取消。

## 12. 获取帮助

```powershell
aicli help
aicli help profile
aicli help doctor
aicli help permissions
aicli help compare
```

- CLI 会话操作：《[Codex、Claude Code 与 Open Interpreter CLI 中文手册](<./Codex、Claude Code 与 Open Interpreter CLI 中文手册.md>)》
- 当前兼容性状态：《[兼容性与最终验收状态](../compatibility/VERIFIED-COMPATIBILITY.md)》
- 安全问题：根目录 `SECURITY.md`
- 隐私说明：根目录 `PRIVACY.md`
