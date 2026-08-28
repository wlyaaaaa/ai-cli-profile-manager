# Update check/guide — no silent upgrades of upstream CLIs.

function Get-AiCliInstallChannel {
    param([Parameter(Mandatory)]$Resolved)
    $kind = [string](Get-AiCliProperty $Resolved 'Kind')
    $parts = @(
        [string](Get-AiCliProperty $Resolved 'FileName')
    ) + @(
        (Get-AiCliProperty $Resolved 'PrefixArgs') |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ }
    )
    $joined = $parts -join "`n"

    if ($kind -match '^npm-' -or $joined -match '(?i)(\\|/)npm(\\|/)|node_modules') {
        return 'npm'
    }
    if ($kind -eq 'desktop-codex' -or $joined -match '(?i)\\OpenAI\\Codex\\') {
        return 'desktop'
    }
    if ($joined -match '(?i)WindowsApps|WinGet') { return 'winget' }
    if ($joined -match '(?i)(\\|/)scoop(\\|/)') { return 'scoop' }
    if ($joined -match '(?i)\.local\\bin(\\|$)') { return 'native-installer' }
    return 'unknown'
}

function Get-AiCliResolvedInstallSource {
    param(
        [Parameter(Mandatory)]$Resolved,
        [string]$Source,
        [string]$RuntimeRole = $null,
        [string]$PackageEntry = $null
    )
    $evidence = Get-AiCliResolvedCliVersionEvidence -Resolved $Resolved
    $resolvedSource = if ($Source) { $Source } else { Get-AiCliInstallChannel -Resolved $Resolved }
    $path = if ($evidence) {
        [string](Get-AiCliProperty $evidence 'FileName')
    } else {
        [string](Get-AiCliProperty $Resolved 'FileName')
    }
    $version = if ($evidence) {
        [string](Get-AiCliProperty $evidence 'Version')
    } else {
        'unknown'
    }
    $info = [ordered]@{
        found       = $true
        path        = $path
        source      = $resolvedSource
        runtimeKind = [string](Get-AiCliProperty $Resolved 'Kind')
        version     = $version
    }
    $prefixArgs = @((Get-AiCliProperty $Resolved 'PrefixArgs') |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { [string]$_ })
    if ($prefixArgs.Count -gt 0) { $info['launcherArgs'] = $prefixArgs }
    if ($RuntimeRole) { $info['runtimeRole'] = $RuntimeRole }
    if ($PackageEntry) { $info['packageEntry'] = $PackageEntry }
    if (-not $evidence) {
        $info['note'] = '已定位同一启动入口，但无法取得该入口的版本。'
    }
    return $info
}

function Get-AiCliCodexUpdateInstallSource {
    try {
        # `aicli test`/machine harness uses the npm package's matching native
        # executable. Do not let a newer Desktop executable and PATH npm shim
        # become one fabricated source/version record.
        $resolved = Resolve-AiCliLaunchExecutable -Name 'codex' -PreferNpmCodex
    } catch {
        $resolved = $null
    }
    if (-not $resolved) { return [ordered]@{ found = $false; source = 'missing'; version = 'n/a' } }

    if ([string](Get-AiCliProperty $resolved 'Kind') -eq 'npm-node') {
        $entries = @((Get-AiCliProperty $resolved 'PrefixArgs') |
            Where-Object { [string]$_ -match 'codex\.js$' } |
            Select-Object -First 2)
        if ($entries.Count -ne 1) {
            return [ordered]@{
                found = $true; path = [string](Get-AiCliProperty $resolved 'FileName')
                source = 'npm'; runtimeKind = 'npm-node'; runtimeRole = 'aicli-codex-harness'
                version = 'unknown'; note = 'Codex npm 入口无法唯一解析为受管原生运行时。'
            }
        }
        try {
            $native = Resolve-AiCliCodexNativeRuntimeFromEntry -EntryPath ([string]$entries[0])
            $runtime = [pscustomobject]@{
                FileName = [string](Get-AiCliProperty $native 'NativeExecutable')
                PrefixArgs = @()
                Kind = 'npm-native'
            }
            return (Get-AiCliResolvedInstallSource -Resolved $runtime `
                -Source 'npm' -RuntimeRole 'aicli-codex-harness' -PackageEntry ([string]$entries[0]))
        } catch {
            return [ordered]@{
                found = $true; path = [string](Get-AiCliProperty $resolved 'FileName')
                source = 'npm'; runtimeKind = 'npm-node'; runtimeRole = 'aicli-codex-harness'
                version = 'unknown'; note = 'Codex npm 入口无法解析为匹配的原生运行时。'
            }
        }
    }

    return (Get-AiCliResolvedInstallSource -Resolved $resolved `
        -RuntimeRole 'interactive-codex')
}

function Get-AiCliInstallSource {
    param([ValidateSet('codex','claude','ollama','interpreter','ccp','cliproxy','self')][string]$Component)
    switch ($Component) {
        'codex' { return (Get-AiCliCodexUpdateInstallSource) }
        'claude' {
            $resolved = Resolve-AiCliLaunchExecutable -Name 'claude'
            if (-not $resolved) { return [ordered]@{ found = $false; source = 'missing'; version = 'n/a' } }
            return (Get-AiCliResolvedInstallSource -Resolved $resolved)
        }
        'ollama' {
            $resolved = Resolve-AiCliLaunchExecutable -Name 'ollama'
            if (-not $resolved) { return [ordered]@{ found = $false; source = 'missing'; version = 'n/a' } }
            return (Get-AiCliResolvedInstallSource -Resolved $resolved `
                -Source 'ollama-installer')
        }
        'interpreter' {
            try { $resolved = Resolve-AiCliInterpreterExecutable } catch {
                return [ordered]@{
                    found = $false
                    source = 'unsupported-or-missing'
                    version = 'n/a'
                    note = '当前 Open Interpreter 入口不可用或不受支持。'
                }
            }
            if (-not $resolved) { return [ordered]@{ found = $false; source = 'missing'; version = 'n/a' } }
            # The resolver already obtains Version from this exact supported
            # executable; do not invoke a second, potentially different path.
            return [ordered]@{
                found = $true
                path = [string](Get-AiCliProperty $resolved 'FileName')
                source = [string](Get-AiCliProperty $resolved 'Kind')
                runtimeKind = [string](Get-AiCliProperty $resolved 'Kind')
                family = [string](Get-AiCliProperty $resolved 'Family')
                version = "interpreter $([string](Get-AiCliProperty $resolved 'Version'))"
            }
        }
        'ccp' { return [ordered]@{ found = [bool](Get-AiCliProxyExecutable 'ccp'); source = 'aicli-managed'; path = (Get-AiCliProxyExecutable 'ccp'); version = 'n/a' } }
        'cliproxy' { return [ordered]@{ found = [bool](Get-AiCliProxyExecutable 'cliproxy'); source = 'aicli-managed'; path = (Get-AiCliProxyExecutable 'cliproxy'); version = 'n/a' } }
        'self' { return [ordered]@{ found = $true; source = 'local-module'; version = (Get-AiCliVersion); note = '使用 GitHub Release ZIP + Install.ps1 更新；本命令只读检查。' } }
    }
}

function Get-AiCliOfficialStableMetadata {
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Source
    )
    $spec = switch ("$Component|$Source") {
        'codex|npm' { [ordered]@{ url = 'https://registry.npmjs.org/@openai%2fcodex/latest'; property = 'version' }; break }
        'claude|npm' { [ordered]@{ url = 'https://registry.npmjs.org/@anthropic-ai%2fclaude-code/latest'; property = 'version' }; break }
        'ollama|ollama-installer' { [ordered]@{ url = 'https://api.github.com/repos/ollama/ollama/releases/latest'; property = 'tag_name' }; break }
        'interpreter|official-rust' { [ordered]@{ url = 'https://api.github.com/repos/openinterpreter/openinterpreter/releases/latest'; property = 'tag_name' }; break }
        'self|local-module' { [ordered]@{ url = 'https://api.github.com/repos/wlyaaaaa/ai-cli-profile-manager/releases/latest'; property = 'tag_name' }; break }
        default { $null }
    }
    if (-not $spec) {
        return [ordered]@{ state = 'unknown'; note = '此安装渠道暂无固定官方稳定版元数据，不能判定是否最新。' }
    }
    try {
        $response = Invoke-RestMethod -Method Get -Uri ([string]$spec.url) -TimeoutSec 5 `
            -MaximumRedirection 0 -Headers @{ Accept = 'application/json'; 'User-Agent' = ((Get-AiCliBrand).ModuleName + '-update-check') } `
            -ErrorAction Stop
        $isPrerelease = ([string](Get-AiCliProperty $response 'prerelease' $false) -ieq 'true')
        $isDraft = ([string](Get-AiCliProperty $response 'draft' $false) -ieq 'true')
        if ($isPrerelease -or $isDraft) {
            return [ordered]@{
                state = 'unknown'; metadataUrl = [string]$spec.url
                note = '官方元数据是草稿或预发行，不能作为稳定版更新依据。'
            }
        }
        $candidate = [string](Get-AiCliProperty $response ([string]$spec.property))
        if ($Component -eq 'interpreter') {
            # The repository also contains historical Python releases. Only a
            # current Rust-tagged release with an x64 Windows package can guide
            # this Windows-only Rust CLI; otherwise leave the result unknown.
            $windowsAssets = @((Get-AiCliProperty $response 'assets' @()) | Where-Object {
                [string](Get-AiCliProperty $_ 'name') -match
                    '^open-interpreter-package-x86_64-pc-windows-msvc\.(tar\.gz|tar\.zst)$'
            })
            if ($candidate -notmatch '^rust-v\d+\.\d+\.\d+$' -or $windowsAssets.Count -eq 0) {
                return [ordered]@{
                    state = 'unknown'; metadataUrl = [string]$spec.url
                    note = '官方元数据无法证明当前 Rust Windows x64 发行物，不能判定是否最新。'
                }
            }
        }
        $semantic = Get-AiCliSemanticVersionEvidence -Text $candidate
        if (-not $semantic -or [bool](Get-AiCliProperty $semantic 'IsPrerelease' $false)) {
            return [ordered]@{
                state = 'unknown'; metadataUrl = [string]$spec.url
                note = '官方元数据未给出可比较的稳定版语义版本。'
            }
        }
        return [ordered]@{
            state = 'available'; metadataUrl = [string]$spec.url
            latestVersion = [string](Get-AiCliProperty $semantic 'Text')
        }
    } catch {
        return [ordered]@{
            state = 'unknown'; metadataUrl = [string]$spec.url
            note = '无法读取固定官方稳定版元数据，不能判定是否最新。'
        }
    }
}

function Add-AiCliUpdateAvailability {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Info)
    if (-not [bool](Get-AiCliProperty $Info 'found' $false)) {
        $Info['updateState'] = 'not-installed'
        $Info['updateAvailable'] = $null
        return $Info
    }

    $metadata = Get-AiCliOfficialStableMetadata `
        -Component ([string](Get-AiCliProperty $Info 'component')) `
        -Source ([string](Get-AiCliProperty $Info 'source'))
    $metadataUrl = Get-AiCliProperty $metadata 'metadataUrl'
    if ($metadataUrl) { $Info['metadataUrl'] = [string]$metadataUrl }
    if ([string](Get-AiCliProperty $metadata 'state') -ne 'available') {
        $Info['updateState'] = 'unknown'
        $Info['updateAvailable'] = $null
        $Info['updateNote'] = [string](Get-AiCliProperty $metadata 'note')
        return $Info
    }

    $latest = [string](Get-AiCliProperty $metadata 'latestVersion')
    $Info['latestVersion'] = $latest
    $current = Get-AiCliSemanticVersionEvidence -Text ([string](Get-AiCliProperty $Info 'version'))
    if (-not $current) {
        $Info['updateState'] = 'unknown'
        $Info['updateAvailable'] = $null
        $Info['updateNote'] = '当前入口未返回可比较的语义版本，不能判定是否最新。'
        return $Info
    }
    if ([bool](Get-AiCliProperty $current 'IsPrerelease' $false)) {
        $Info['updateState'] = 'channel-different'
        $Info['updateAvailable'] = $null
        $Info['updateNote'] = '当前为预发行版本；稳定版元数据不能证明该预发行渠道是否最新。'
        return $Info
    }

    $latestSemantic = Get-AiCliSemanticVersionEvidence -Text $latest
    if (-not $latestSemantic -or [bool](Get-AiCliProperty $latestSemantic 'IsPrerelease' $false)) {
        $Info['updateState'] = 'unknown'
        $Info['updateAvailable'] = $null
        $Info['updateNote'] = '官方元数据稳定版版本不可比较。'
        return $Info
    }
    if ($current.Version -lt $latestSemantic.Version) {
        $Info['updateState'] = 'update-available'
        $Info['updateAvailable'] = $true
        return $Info
    }
    if ($current.Version -eq $latestSemantic.Version) {
        $Info['updateState'] = 'current'
        $Info['updateAvailable'] = $false
        return $Info
    }

    $Info['updateState'] = 'channel-different'
    $Info['updateAvailable'] = $null
    $Info['updateNote'] = '当前稳定版高于固定官方元数据；不能将其冒充为已确认最新。'
    return $Info
}

function Invoke-AiCliUpdateCheck {
    param(
        [string]$Component,
        [switch]$Json
    )
    $components = if ($Component) { @($Component) } else { @('codex','claude','ollama','interpreter','ccp','cliproxy','self') }
    $items = @()
    $overall = '通过'
    foreach ($c in $components) {
        $info = Get-AiCliInstallSource -Component $c
        if ($info -isnot [System.Collections.IDictionary]) {
            throw 'Install source must return a map.'
        }
        $info['component'] = $c
        if (-not (Test-AiCliMapContains -Map $info -Key 'version')) { $info['version'] = 'n/a' }
        $info = Add-AiCliUpdateAvailability -Info $info
        $state = [string](Get-AiCliProperty $info 'updateState')
        if ($state -in @('unknown','channel-different','update-available')) {
            $overall = '可用但有限制'
        }
        $items += $info
    }
    $result = New-AiCliResult -Command 'update check' -OverallStatus $overall -Extra @{ components = $items }
    if ($Json) { Write-AiCliJson $result }
    else {
        foreach ($i in $items) {
            $comp = Get-AiCliProperty $i 'component'
            $found = Get-AiCliProperty $i 'found'
            $source = Get-AiCliProperty $i 'source'
            $ver = Get-AiCliProperty $i 'version' 'n/a'
            $latest = Get-AiCliProperty $i 'latestVersion' 'unknown'
            $state = Get-AiCliProperty $i 'updateState'
            $role = Get-AiCliProperty $i 'runtimeRole'
            $path = Get-AiCliProperty $i 'path'
            Write-Host ("[{0}] found={1} source={2} version={3} latest={4} state={5}" -f $comp, $found, $source, $ver, $latest, $state)
            if ($role) { Write-Host ("      target={0}" -f $role) }
            if ($path) { Write-Host ("      path={0}" -f $path) }
            $note = Get-AiCliProperty $i 'updateNote'
            if (-not $note) { $note = Get-AiCliProperty $i 'note' }
            if ($note) { Write-Host ("      note={0}" -f $note) }
        }
        Write-Host '本命令只读检查，不会自动升级。'
    }
    return (Get-AiCliExitCodeFromStatus $overall)
}

function Invoke-AiCliUpdateGuide {
    param([string]$Component = 'codex')
    $info = Get-AiCliInstallSource -Component $Component
    $source = [string](Get-AiCliProperty $info 'source')
    Write-Host ("=== 更新指引: {0} ===" -f $Component)
    Write-Host ("当前: found={0} source={1} version={2}" -f $info.found, $source, $info.version)
    switch ($Component) {
        'codex' {
            switch ($source) {
                'npm' {
                    Write-Host '同一 npm 渠道更新：'
                    Write-Host '  npm install -g @openai/codex@latest'
                }
                'winget' { Write-Host '同一 WinGet 渠道更新：winget upgrade OpenAI.Codex' }
                'desktop' { Write-Host '当前为 Codex Desktop 渠道；请在 Desktop 应用内检查更新，不要用 npm 覆盖。' }
                default { Write-Host '当前来源不明确；请先确认安装渠道，勿用 npm/WinGet/桌面版交叉覆盖。' }
            }
            Write-Host '验证: aicli update check codex；然后: aicli doctor <profile>'
        }
        'claude' {
            switch ($source) {
                'npm' { Write-Host '同一 npm 渠道更新：npm install -g @anthropic-ai/claude-code@latest' }
                'winget' { Write-Host '同一 WinGet 渠道更新：winget upgrade Anthropic.ClaudeCode' }
                'native-installer' { Write-Host '同一官方安装器渠道更新：在 Claude Code 内使用官方更新，或重新运行官方 install.ps1。' }
                default { Write-Host '当前来源不明确；请先确认安装渠道，勿用 npm/WinGet/安装器交叉覆盖。' }
            }
            Write-Host '验证: aicli update check claude'
        }
        'ollama' {
            Write-Host '使用 Ollama 官方 Windows 安装器/应用更新。'
            Write-Host 'https://ollama.com/download'
        }
        'interpreter' {
            Write-Host '当前官方 Rust 版支持内置更新：'
            Write-Host '  interpreter update'
            Write-Host '验证: aicli update check interpreter'
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
