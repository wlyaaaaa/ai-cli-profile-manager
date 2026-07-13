# Codex CLI adapter: official + Responses providers via managed profile files in real CODEX_HOME.

function Get-AiCliCodexReservedArgs {
    return @('--profile', '-c', '--config')
}

function Assert-AiCliCodexNativeArgs {
    param([string[]]$NativeArgList)
    $reserved = Get-AiCliCodexReservedArgs
    for ($i = 0; $i -lt @($NativeArgList).Count; $i++) {
        $a = $NativeArgList[$i]
        foreach ($r in $reserved) {
            if ($a -eq $r -or $a.StartsWith("$r=")) {
                throw "参数 $a 与 aicli 启动计划冲突。请使用 aicli native / aicli eject 查看原生配置，不要通过 -- 覆盖 --profile 或 Provider 配置入口。"
            }
        }
    }
}

function Get-AiCliManagedProfileMarker {
    param([string]$ProfileSafeId, [string]$ContentHash)
    return @"
# aicli-managed=true
# aicli-profile-id=$ProfileSafeId
# aicli-content-hash=$ContentHash
# aicli-do-not-edit-unless-you-accept-unmanaged
"@
}

function Get-AiCliSafeProfileFileId {
    param([string]$Id)
    $safe = ($Id -replace '[^a-zA-Z0-9_-]', '-').ToLowerInvariant()
    if ($safe.Length -gt 40) {
        # Preserve a readable prefix but bind the filename to the full ID so
        # two legal 64-character IDs with the same first 40 chars cannot collide.
        $suffix = (Get-AiCliContentHash -Text $Id).Substring(0, 8)
        $safe = $safe.Substring(0, 31) + '-' + $suffix
    }
    return "aicli-$safe"
}

function Get-AiCliContentHash {
    param([string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function ConvertTo-AiCliTomlString {
    param([AllowEmptyString()][string]$Value)
    return ($Value | ConvertTo-Json -Compress)
}

function Add-AiCliCodexProviderOverrides {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$ArgumentList,
        [Parameter(Mandatory)]$MergedProfile,
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][string]$EnvironmentKey
    )
    $null = Assert-AiCliSafeIdentifier -Id $ProviderId -Kind 'Codex Provider ID'
    $endpoint = [string](Get-AiCliProperty $MergedProfile 'endpoint')
    Assert-AiCliEndpointSafe -Url $endpoint
    $model = [string](Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary')
    $null = Assert-AiCliModelId -Model $model
    $name = [string](Get-AiCliProperty $MergedProfile 'displayName')
    $overrides = @(
        ('model=' + (ConvertTo-AiCliTomlString $model))
        ('model_provider=' + (ConvertTo-AiCliTomlString $ProviderId))
        ("model_providers.$ProviderId.name=" + (ConvertTo-AiCliTomlString $name))
        ("model_providers.$ProviderId.base_url=" + (ConvertTo-AiCliTomlString $endpoint))
        ("model_providers.$ProviderId.env_key=" + (ConvertTo-AiCliTomlString $EnvironmentKey))
        "model_providers.$ProviderId.wire_api=`"responses`""
        'shell_environment_policy.ignore_default_excludes=false'
        "shell_environment_policy.exclude=[`"$EnvironmentKey`",`"OPENAI_API_KEY`",`"CODEX_API_KEY`"]"
    )
    foreach ($override in $overrides) {
        [void]$ArgumentList.Add('-c')
        [void]$ArgumentList.Add($override)
    }
}

function Get-AiCliCodexManagedStatePath {
    $paths = Initialize-AiCliDirectories
    return (Join-Path $paths.StateDir 'codex-managed-profiles.json')
}

function Get-AiCliCodexManagedState {
    return (Read-AiCliJsonFile -Path (Get-AiCliCodexManagedStatePath) -Default ([ordered]@{}))
}

function Save-AiCliCodexManagedState {
    param($State)
    Write-AiCliJsonFile -Path (Get-AiCliCodexManagedStatePath) -Value $State
}

function New-AiCliCodexProviderToml {
    param(
        $MergedProfile,
        [string]$EnvKeyName = 'OPENAI_API_KEY'
    )
    $providerId = Get-AiCliProperty $MergedProfile 'codexProviderId'
    if (-not $providerId) { $providerId = 'aicli_' + ((Get-AiCliProperty $MergedProfile 'id') -replace '-', '_') }
    if ($script:AiCliCodexReservedProviderIds -contains $providerId) {
        throw "Codex provider id 保留: $providerId"
    }
    $name = Get-AiCliProperty $MergedProfile 'displayName'
    $base = Get-AiCliProperty $MergedProfile 'endpoint'
    $model = Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary'
    if (-not $model) { $model = 'gpt-5.4' }

    $null = Assert-AiCliSafeIdentifier -Id $providerId -Kind 'Codex Provider ID'
    Assert-AiCliEndpointSafe -Url $base
    $null = Assert-AiCliModelId -Model $model
    $modelToml = ConvertTo-AiCliTomlString $model
    $providerToml = ConvertTo-AiCliTomlString $providerId
    $nameToml = ConvertTo-AiCliTomlString $name
    $baseToml = ConvertTo-AiCliTomlString $base
    $envToml = ConvertTo-AiCliTomlString $EnvKeyName

    $body = @"
model = $modelToml
model_provider = $providerToml

[model_providers.$providerId]
name = $nameToml
base_url = $baseToml
env_key = $envToml
wire_api = "responses"

[shell_environment_policy]
ignore_default_excludes = false
exclude = ["$EnvKeyName", "OPENAI_API_KEY", "CODEX_API_KEY"]
"@
    return $body.Trim() + "`n"
}

function Write-AiCliCodexManagedProfile {
    param(
        $MergedProfile,
        [string]$TomlBody
    )
    $home = Get-AiCliCodexHome
    if (-not (Test-Path -LiteralPath $home)) {
        New-Item -ItemType Directory -Force -Path $home | Out-Null
    }
    $safeId = Get-AiCliSafeProfileFileId -Id (Get-AiCliProperty $MergedProfile 'id')
    $hash = Get-AiCliContentHash -Text $TomlBody
    $marker = Get-AiCliManagedProfileMarker -ProfileSafeId $safeId -ContentHash $hash
    $content = $marker + "`n" + $TomlBody
    $fileName = "$safeId.config.toml"
    $path = Join-Path $home $fileName

    $state = Get-AiCliCodexManagedState
    if (Test-Path -LiteralPath $path) {
        $existing = Get-Content -LiteralPath $path -Raw -Encoding utf8
        $isManaged = $existing -match 'aicli-managed=true'
        $oldHash = $null
        if ($existing -match 'aicli-content-hash=([a-f0-9]+)') { $oldHash = $Matches[1] }
        $recorded = $null
        if ($state -is [System.Collections.IDictionary] -and $state.Contains($safeId)) {
            $recorded = Get-AiCliProperty $state[$safeId] 'contentHash'
        }
        $actualBodyHash = $null
        $bodyStart = [regex]::Match($existing, '(?m)^# aicli-do-not-edit-unless-you-accept-unmanaged\r?\n')
        if ($bodyStart.Success) {
            $actualBody = $existing.Substring($bodyStart.Index + $bodyStart.Length)
            $actualBodyHash = Get-AiCliContentHash -Text $actualBody
        }
        if (-not $isManaged) {
            # conflict: unknown file — pick new id
            $safeId = "$safeId-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $fileName = "$safeId.config.toml"
            $path = Join-Path $home $fileName
            $marker = Get-AiCliManagedProfileMarker -ProfileSafeId $safeId -ContentHash $hash
            $content = $marker + "`n" + $TomlBody
        } elseif (-not $oldHash -or -not $actualBodyHash -or $actualBodyHash -ne $oldHash -or ($recorded -and $recorded -ne $oldHash)) {
            # user modified managed file — do not overwrite; new id
            Write-AiCliWarn "检测到用户修改过的派生 Profile，将写入新文件而不覆盖。"
            $safeId = "$safeId-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $fileName = "$safeId.config.toml"
            $path = Join-Path $home $fileName
            $marker = Get-AiCliManagedProfileMarker -ProfileSafeId $safeId -ContentHash $hash
            $content = $marker + "`n" + $TomlBody
        }
    }

    $tmp = "$path.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $content, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $path -Force

    if ($state -isnot [System.Collections.IDictionary]) { $state = [ordered]@{} }
    $state[$safeId] = [ordered]@{
        profileId    = Get-AiCliProperty $MergedProfile 'id'
        fileName     = $fileName
        fullPath     = $path
        contentHash  = $hash
        updatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-AiCliCodexManagedState -State $state

    # CLI profile name is filename without .config.toml
    $cliProfileName = $safeId
    return [pscustomobject]@{
        CliProfileName = $cliProfileName
        FilePath       = $path
        ContentHash    = $hash
    }
}

function Get-AiCliCodexEffortLevels {
    # Desktop 2026-07: low medium high xhigh ultra max
    return @('low', 'medium', 'high', 'xhigh', 'ultra', 'max')
}

function Resolve-AiCliCodexEffort {
    param($MergedProfile, [string[]]$NativeArgs)
    # Native -c model_reasoning_effort=... wins if user passed it; otherwise profile preference
    foreach ($a in $NativeArgs) {
        if ($a -match 'model_reasoning_effort\s*=\s*"?([a-zA-Z0-9_]+)"?') { return $Matches[1] }
    }
    $prefs = Get-AiCliProperty $MergedProfile 'preferences'
    $e = Get-AiCliProperty $prefs 'effort'
    if (-not $e) { $e = Get-AiCliProperty $MergedProfile 'defaultEffort' }
    if (-not $e) { $e = 'high' }
    $allowed = Get-AiCliCodexEffortLevels
    if ($allowed -notcontains $e) {
        throw "Codex 思考等级无效: $e。可选: $($allowed -join ', ')"
    }
    return $e
}

function Resolve-AiCliCodexLaunchExecutable {
    param([Parameter(Mandatory)]$MergedProfile)
    $provider = Get-AiCliProperty $MergedProfile 'provider'
    $id = Get-AiCliProperty $MergedProfile 'id'
    # Desktop codex.exe can hang on third-party --profile exec; prefer npm node for non-official
    $preferDesktop = ($provider -eq 'openai' -or $id -eq 'codex-official')
    $resolved = $null
    if ($preferDesktop) {
        $resolved = Resolve-AiCliLaunchExecutable -Name 'codex'
    } else {
        # force npm/node path
        $npmJs = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\bin\codex.js'
        $node = (Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $node) { $node = Find-AiCliCommandPath -Name 'node' }
        if ($node -and (Test-Path -LiteralPath $npmJs)) {
            $resolved = [pscustomobject]@{ FileName = $node; PrefixArgs = @($npmJs); Kind = 'npm-node' }
        } else {
            $resolved = Resolve-AiCliLaunchExecutable -Name 'codex'
        }
    }
    if (-not $resolved) {
        throw '未找到 codex。请安装 Codex CLI（npm i -g @openai/codex）或 Codex 桌面版。'
    }
    return $resolved
}

function Build-AiCliCodexLaunchPlan {
    param(
        $MergedProfile,
        [string]$ProjectPath,
        [string[]]$NativeArgs = @()
    )
    Assert-AiCliCodexNativeArgs -NativeArgList $NativeArgs
    $provider = Get-AiCliProperty $MergedProfile 'provider'
    $id = Get-AiCliProperty $MergedProfile 'id'
    $resolved = Resolve-AiCliCodexLaunchExecutable -MergedProfile $MergedProfile
    $envDelta = @{}
    $removeEnv = @()
    $cliArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($resolved.PrefixArgs)) { $cliArgs.Add([string]$p) | Out-Null }
    $configFiles = @()
    $notes = @()
    $effort = Resolve-AiCliCodexEffort -MergedProfile $MergedProfile -NativeArgs $NativeArgs
    $models = Get-AiCliProperty $MergedProfile 'models'
    $model = Get-AiCliProperty $models 'primary'

    if ($provider -eq 'openai' -or $id -eq 'codex-official') {
        foreach ($v in $script:AiCliCodexProviderVars) { $removeEnv += $v }
        $removeEnv += @('OPENAI_BASE_URL')
        if (-not $model) { $model = 'gpt-5.6-sol' }
        $cliArgs.Add('-c') | Out-Null
        $cliArgs.Add("model=`"$model`"") | Out-Null
        $cliArgs.Add('-c') | Out-Null
        $cliArgs.Add("model_reasoning_effort=`"$effort`"") | Out-Null
        $cliArgs.Add('-c') | Out-Null
        $cliArgs.Add('model_provider="openai"') | Out-Null
        $notes += '使用官方 ChatGPT 登录与真实 CODEX_HOME，不生成派生配置。'
        $notes += "默认模型 $model；思考等级 $effort（low/medium/high/xhigh/ultra/max）。"
        $notes += '可用模型例: gpt-5.6-sol / gpt-5.6-terra / gpt-5.6-luna（以账号可用为准）。'
        $notes += "启动器: $($resolved.Kind) → $($resolved.FileName)"
    }
    elseif ($provider -eq 'ollama' -or $id -eq 'codex-ollama') {
        $endpoint = Get-AiCliProperty $MergedProfile 'endpoint'
        if (-not $endpoint) { $endpoint = 'http://127.0.0.1:11434/v1' }
        if (-not $model) { $model = 'qwen3:8b' }
        $merged2 = [ordered]@{
            id             = $id
            displayName    = Get-AiCliProperty $MergedProfile 'displayName'
            endpoint       = $endpoint
            codexProviderId= 'aicli_ollama_local'
            models         = [ordered]@{ primary = $model }
        }
        $toml = New-AiCliCodexProviderToml -MergedProfile $merged2 -EnvKeyName 'AICLI_CODEX_PROVIDER_KEY'
        $written = Write-AiCliCodexManagedProfile -MergedProfile $merged2 -TomlBody $toml
        $cliArgs.Add('--profile') | Out-Null
        $cliArgs.Add($written.CliProfileName) | Out-Null
        $configFiles += $written.FilePath
        foreach ($v in $script:AiCliCodexProviderVars) { $removeEnv += $v }
        $removeEnv += @('OPENAI_BASE_URL')
        $envDelta['AICLI_CODEX_PROVIDER_KEY'] = 'ollama'
        Add-AiCliCodexProviderOverrides -ArgumentList $cliArgs -MergedProfile $merged2 -ProviderId 'aicli_ollama_local' -EnvironmentKey 'AICLI_CODEX_PROVIDER_KEY'
        $notes += "本机 Ollama 兼容网关: $endpoint"
        $notes += "模型: $model；wire_api=responses"
        $notes += '公开模板使用 Ollama 默认 11434；其他本机网关请配置独立用户 Profile。'
    }
    else {
        # Scrub parent hijacks so only profile provider base_url is used
        foreach ($v in $script:AiCliCodexProviderVars) { $removeEnv += $v }
        $removeEnv += @('OPENAI_BASE_URL')
        $providerId = Get-AiCliProperty $MergedProfile 'codexProviderId'
        if (-not $providerId) { $providerId = 'aicli_' + ($id -replace '-', '_') }
        $toml = New-AiCliCodexProviderToml -MergedProfile $MergedProfile -EnvKeyName 'AICLI_CODEX_PROVIDER_KEY'
        $written = Write-AiCliCodexManagedProfile -MergedProfile $MergedProfile -TomlBody $toml
        $cliArgs.Add('--profile') | Out-Null
        $cliArgs.Add($written.CliProfileName) | Out-Null
        $configFiles += $written.FilePath
        if ((Get-AiCliProperty $MergedProfile 'secretConfigured') -or (Get-AiCliProperty $MergedProfile 'secretRef')) {
            $secret = Get-AiCliSecret -SecretId (Get-AiCliProperty $MergedProfile 'secretRef')
            $envDelta['AICLI_CODEX_PROVIDER_KEY'] = $secret
        } else {
            throw "Profile $id 需要 API Key。请运行: aicli profile configure $id"
        }
        $cliArgs.Add('-c') | Out-Null
        $cliArgs.Add("model_reasoning_effort=`"$effort`"") | Out-Null
        Add-AiCliCodexProviderOverrides -ArgumentList $cliArgs -MergedProfile $MergedProfile -ProviderId $providerId -EnvironmentKey 'AICLI_CODEX_PROVIDER_KEY'
        $notes += "派生 Profile 文件: $($written.FilePath)"
        $notes += "wire_api = responses；思考等级 $effort（上游若不支持会忽略或报错）。"
        $notes += '已清除父终端 OPENAI_BASE_URL/KEY，避免污染第三方 Profile。'
    }

    foreach ($a in $NativeArgs) { $cliArgs.Add($a) | Out-Null }

    return [pscustomobject]@{
        engine            = 'codex'
        profileId         = $id
        fileName          = [string](Get-AiCliProperty $resolved 'FileName')
        argumentList      = @($cliArgs.ToArray())
        versionArgumentList = @((Get-AiCliProperty $resolved 'PrefixArgs') | ForEach-Object { [string]$_ }) + @('--version')
        launcherKind      = [string](Get-AiCliProperty $resolved 'Kind')
        workingDirectory  = $ProjectPath
        environmentDelta  = $envDelta
        removeEnvironment = @($removeEnv)
        configFiles       = @($configFiles)
        notes             = @($notes)
        proxyRef          = $null
        effort            = $effort
        model             = $model
    }
}
