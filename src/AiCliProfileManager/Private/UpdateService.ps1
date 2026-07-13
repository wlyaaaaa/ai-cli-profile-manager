# Update check/guide — no silent upgrades of upstream CLIs.

function Get-AiCliInstallSource {
    param([ValidateSet('codex','claude','ollama','interpreter','ccp','cliproxy','self')][string]$Component)
    switch ($Component) {
        'codex' {
            $p = Find-AiCliCommandPath 'codex'
            if (-not $p) { return [ordered]@{ found = $false } }
            $src = 'unknown'
            if ($p -match 'npm') { $src = 'npm' }
            elseif ($p -match 'WinGet|WindowsApps') { $src = 'winget' }
            elseif ($p -match 'scoop') { $src = 'scoop' }
            $ver = try { (& codex --version 2>&1 | Out-String).Trim() } catch { 'unknown' }
            return [ordered]@{ found = $true; path = $p; source = $src; version = $ver }
        }
        'claude' {
            $p = Find-AiCliCommandPath 'claude'
            if (-not $p) { return [ordered]@{ found = $false } }
            $src = 'unknown'
            if ($p -match '\.local\\bin') { $src = 'native-installer' }
            elseif ($p -match 'npm') { $src = 'npm' }
            elseif ($p -match 'WinGet|WindowsApps') { $src = 'winget' }
            $ver = try { (& claude --version 2>&1 | Out-String).Trim() } catch { 'unknown' }
            return [ordered]@{ found = $true; path = $p; source = $src; version = $ver }
        }
        'ollama' {
            $p = Find-AiCliCommandPath 'ollama'
            if (-not $p) { return [ordered]@{ found = $false } }
            $ver = try { (& ollama --version 2>&1 | Out-String).Trim() } catch { 'unknown' }
            return [ordered]@{ found = $true; path = $p; source = 'ollama-installer'; version = $ver }
        }
        'interpreter' {
            $r = $null
            try { $r = Resolve-AiCliInterpreterExecutable } catch {
                return [ordered]@{
                    found = $false
                    source = 'unsupported-or-missing'
                    version = 'n/a'
                    note = Protect-AiCliSecretText $_.Exception.Message
                }
            }
            if (-not $r) { return [ordered]@{ found = $false; source = 'missing'; version = 'n/a' } }
            return [ordered]@{
                found = $true
                path = $r.FileName
                source = $r.Kind
                family = $r.Family
                version = "interpreter $($r.Version)"
            }
        }
        'ccp' { return [ordered]@{ found = [bool](Get-AiCliProxyExecutable 'ccp'); source = 'aicli-managed'; path = (Get-AiCliProxyExecutable 'ccp') } }
        'cliproxy' { return [ordered]@{ found = [bool](Get-AiCliProxyExecutable 'cliproxy'); source = 'aicli-managed'; path = (Get-AiCliProxyExecutable 'cliproxy') } }
        'self' { return [ordered]@{ found = $true; source = 'local-module'; version = (Get-AiCliVersion); note = '使用 GitHub Release ZIP + Install.ps1 更新；本命令只读检查' } }
    }
}

function Invoke-AiCliUpdateCheck {
    param(
        [string]$Component,
        [switch]$Json
    )
    $components = if ($Component) { @($Component) } else { @('codex','claude','ollama','interpreter','ccp','cliproxy','self') }
    $items = @()
    foreach ($c in $components) {
        $info = Get-AiCliInstallSource -Component $c
        if ($info -is [System.Collections.IDictionary]) {
            $info['component'] = $c
            if (-not (Test-AiCliMapContains -Map $info -Key 'version')) { $info['version'] = 'n/a' }
        } else {
            $info | Add-Member -NotePropertyName component -NotePropertyValue $c -Force
            if (-not $info.PSObject.Properties['version']) {
                $info | Add-Member -NotePropertyName version -NotePropertyValue 'n/a' -Force
            }
        }
        $items += $info
    }
    $result = New-AiCliResult -Command 'update check' -OverallStatus '通过' -Extra @{ components = $items }
    if ($Json) { Write-AiCliJson $result }
    else {
        foreach ($i in $items) {
            $comp = Get-AiCliProperty $i 'component'
            $found = Get-AiCliProperty $i 'found'
            $source = Get-AiCliProperty $i 'source'
            $ver = Get-AiCliProperty $i 'version' 'n/a'
            $path = Get-AiCliProperty $i 'path'
            Write-Host ("[{0}] found={1} source={2} version={3}" -f $comp, $found, $source, $ver)
            if ($path) { Write-Host ("      path={0}" -f $path) }
        }
        Write-Host '本命令只读检查，不会自动升级。'
    }
    return (Get-AiCliExitCode Success)
}

function Invoke-AiCliUpdateGuide {
    param([string]$Component = 'codex')
    $info = Get-AiCliInstallSource -Component $Component
    Write-Host ("=== 更新指引: {0} ===" -f $Component)
    Write-Host ("当前: found={0} source={1} version={2}" -f $info.found, $info.source, $info.version)
    switch ($Component) {
        'codex' {
            Write-Host '识别来源后使用同一渠道：'
            Write-Host '  npm:    npm install -g @openai/codex@latest'
            Write-Host '  winget: winget upgrade OpenAI.Codex  # 若包名不同请 winget search codex'
            Write-Host '验证: codex --version'
            Write-Host '然后: aicli doctor'
        }
        'claude' {
            Write-Host '原生安装器优先（不要混用 npm 覆盖）：'
            Write-Host '  在 Claude Code 内使用官方更新，或重新运行官方 install.ps1'
            Write-Host '  irm https://claude.ai/install.ps1 | iex'
            Write-Host '  winget 安装的用 winget upgrade'
            Write-Host '验证: claude --version'
        }
        'ollama' {
            Write-Host '使用 Ollama 官方 Windows 安装器/应用更新。'
            Write-Host 'https://ollama.com/download'
        }
        'interpreter' {
            Write-Host '当前官方 Rust 版支持内置更新：'
            Write-Host '  interpreter update'
            Write-Host '未安装时使用官方 PowerShell 安装器：'
            Write-Host '  irm https://www.openinterpreter.com/install.ps1 | iex'
            Write-Host '验证: interpreter --version（必须显示 interpreter 0.0.21 或更高）'
        }
        'ccp' {
            Write-Host '受管代理显式更新：aicli proxy ccp update-check'
            Write-Host '仅当 approved-windows-artifacts.json 含 SHA256 时: aicli proxy ccp install'
        }
        'cliproxy' {
            Write-Host '受管代理显式更新：aicli proxy cliproxy update-check'
            Write-Host '仅当有批准 SHA256 时安装。'
        }
        'self' {
            Write-Host '本工具不静默自更新。请下载最新 Release ZIP，再运行 scripts\Install.ps1。'
            Write-Host 'https://github.com/wlyaaaaa/ai-cli-profile-manager/releases/latest'
            Write-Host "当前版本: $(Get-AiCliVersion)"
        }
    }
    return (Get-AiCliExitCode Success)
}
