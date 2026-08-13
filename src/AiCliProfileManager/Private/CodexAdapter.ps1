# Codex CLI adapter: official + Responses providers via managed profile files in real CODEX_HOME.

function Get-AiCliCodexReservedArgs {
    return @('--profile', '-p', '-c', '--config', '--oss', '--local-provider')
}

function Assert-AiCliCodexNativeArgs {
    param([string[]]$NativeArgList)
    $reserved = Get-AiCliCodexReservedArgs
    for ($i = 0; $i -lt @($NativeArgList).Count; $i++) {
        $a = $NativeArgList[$i]
        foreach ($r in $reserved) {
            $shortAttached = $r.Length -eq 2 -and $r.StartsWith('-') -and
                $a.Length -gt 2 -and $a.StartsWith($r, [StringComparison]::Ordinal)
            if ($a -eq $r -or $a.StartsWith("$r=") -or $shortAttached) {
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

function Get-AiCliCodexAutoCompactConfiguration {
    param([Parameter(Mandatory)]$MergedProfile)
    $rawLimit = Get-AiCliProperty $MergedProfile 'codexAutoCompactTokenLimit'
    if ($null -eq $rawLimit) { return $null }
    if ($rawLimit -isnot [byte] -and $rawLimit -isnot [int16] -and
        $rawLimit -isnot [int32] -and $rawLimit -isnot [int64]) {
        throw 'Codex 自动压缩阈值必须是整数。'
    }
    $limit = [long]$rawLimit
    if ($limit -lt 32768 -or $limit -gt 4194304) {
        throw "Codex 自动压缩阈值超出允许范围: $limit"
    }
    $scope = [string](Get-AiCliProperty $MergedProfile 'codexAutoCompactTokenLimitScope')
    if ([string]::IsNullOrWhiteSpace($scope)) { $scope = 'total' }
    if ($scope -notin @('total','body_after_prefix')) {
        throw "Codex 自动压缩计数范围无效: $scope"
    }
    return [pscustomobject]@{ Limit = $limit; Scope = $scope }
}

function Add-AiCliCodexProviderOverrides {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$ArgumentList,
        [Parameter(Mandatory)]$MergedProfile,
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][string]$EnvironmentKey,
        [string]$Model,
        [string]$ModelCatalogPath
    )
    $null = Assert-AiCliSafeIdentifier -Id $ProviderId -Kind 'Codex Provider ID'
    $endpoint = [string](Get-AiCliProperty $MergedProfile 'endpoint')
    if ([bool](Get-AiCliProperty $MergedProfile 'workspaceBaseUrlRequired' $false)) {
        $endpoint = Resolve-AiCliQwenWorkspaceResponsesEndpoint -Endpoint $endpoint
    }
    Assert-AiCliEndpointSafe -Url $endpoint
    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = [string](Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary')
    }
    $null = Assert-AiCliModelId -Model $Model
    $name = [string](Get-AiCliProperty $MergedProfile 'displayName')
    $localGpuBrokerSession = Get-AiCliLocalGpuBrokerSessionConfiguration `
        -MergedProfile $MergedProfile
    $autoCompact = Get-AiCliCodexAutoCompactConfiguration -MergedProfile $MergedProfile
    $shellExcludes = @(
        $EnvironmentKey,
        'OPENAI_API_KEY',
        'CODEX_API_KEY',
        'DASHSCOPE_API_KEY',
        'QWEN_API_KEY'
    )
    if ($localGpuBrokerSession) {
        $shellExcludes += Get-AiCliLocalGpuBrokerShellExcludes
    }
    $shellExcludeToml = '[' + (@(
        $shellExcludes | ForEach-Object { ConvertTo-AiCliTomlString ([string]$_) }
    ) -join ',') + ']'
    $overrides = @(
        ('model=' + (ConvertTo-AiCliTomlString $Model))
        ('model_provider=' + (ConvertTo-AiCliTomlString $ProviderId))
        ("model_providers.$ProviderId.name=" + (ConvertTo-AiCliTomlString $name))
        ("model_providers.$ProviderId.base_url=" + (ConvertTo-AiCliTomlString $endpoint))
        ("model_providers.$ProviderId.env_key=" + (ConvertTo-AiCliTomlString $EnvironmentKey))
        "model_providers.$ProviderId.wire_api=`"responses`""
        'shell_environment_policy.ignore_default_excludes=false'
        "shell_environment_policy.exclude=$shellExcludeToml"
    )
    if ($localGpuBrokerSession) {
        $overrides += (
            "model_providers.$ProviderId.env_http_headers=" +
            '{"X-LocalGpuBroker-Lease-Id"="AICLI_LOCAL_GPU_BROKER_LEASE_ID",' +
            '"X-LocalGpuBroker-Capability"="AICLI_LOCAL_GPU_BROKER_CAPABILITY"}'
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($ModelCatalogPath)) {
        $fullCatalogPath = [IO.Path]::GetFullPath($ModelCatalogPath)
        $overrides += 'model_catalog_json=' + (ConvertTo-AiCliTomlString $fullCatalogPath)
    }
    if ($autoCompact) {
        $overrides += "model_auto_compact_token_limit=$($autoCompact.Limit)"
        $overrides += 'model_auto_compact_token_limit_scope=' + (ConvertTo-AiCliTomlString $autoCompact.Scope)
    }
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
        [string]$EnvKeyName = 'OPENAI_API_KEY',
        [string]$ModelCatalogPath
    )
    $providerId = Get-AiCliProperty $MergedProfile 'codexProviderId'
    if (-not $providerId) { $providerId = 'aicli_' + ((Get-AiCliProperty $MergedProfile 'id') -replace '-', '_') }
    if ($script:AiCliCodexReservedProviderIds -contains $providerId) {
        throw "Codex provider id 保留: $providerId"
    }
    $name = Get-AiCliProperty $MergedProfile 'displayName'
    $base = Get-AiCliProperty $MergedProfile 'endpoint'
    if ([bool](Get-AiCliProperty $MergedProfile 'workspaceBaseUrlRequired' $false)) {
        $base = Resolve-AiCliQwenWorkspaceResponsesEndpoint -Endpoint ([string]$base)
    }
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
    $catalogToml = if ([string]::IsNullOrWhiteSpace($ModelCatalogPath)) {
        $null
    } else {
        ConvertTo-AiCliTomlString ([IO.Path]::GetFullPath($ModelCatalogPath))
    }
    $catalogLine = if ($catalogToml) { "model_catalog_json = $catalogToml`n" } else { '' }
    $autoCompact = Get-AiCliCodexAutoCompactConfiguration -MergedProfile $MergedProfile
    $autoCompactLines = if ($autoCompact) {
        "model_auto_compact_token_limit = $($autoCompact.Limit)`n" +
            "model_auto_compact_token_limit_scope = $(ConvertTo-AiCliTomlString $autoCompact.Scope)`n"
    } else { '' }
    $localGpuBrokerSession = Get-AiCliLocalGpuBrokerSessionConfiguration `
        -MergedProfile $MergedProfile
    $providerHeaderLine = if ($localGpuBrokerSession) {
        'env_http_headers = { "X-LocalGpuBroker-Lease-Id" = "AICLI_LOCAL_GPU_BROKER_LEASE_ID", ' +
            '"X-LocalGpuBroker-Capability" = "AICLI_LOCAL_GPU_BROKER_CAPABILITY" }' + "`n"
    } else { '' }
    $shellExcludes = @(
        $EnvKeyName,
        'OPENAI_API_KEY',
        'CODEX_API_KEY',
        'DASHSCOPE_API_KEY',
        'QWEN_API_KEY'
    )
    if ($localGpuBrokerSession) {
        $shellExcludes += Get-AiCliLocalGpuBrokerShellExcludes
    }
    $shellExcludeToml = @(
        $shellExcludes | ForEach-Object { ConvertTo-AiCliTomlString ([string]$_) }
    ) -join ', '

    $body = @"
model = $modelToml
model_provider = $providerToml
$catalogLine$autoCompactLines

[model_providers.$providerId]
name = $nameToml
base_url = $baseToml
env_key = $envToml
wire_api = "responses"
$providerHeaderLine

[shell_environment_policy]
ignore_default_excludes = false
exclude = [$shellExcludeToml]
"@
    return $body.Trim() + "`n"
}

function Publish-AiCliCodexModelCatalog {
    param([Parameter(Mandatory)]$MergedProfile)

    $catalogName = [string](Get-AiCliProperty $MergedProfile 'codexModelCatalog')
    if ([string]::IsNullOrWhiteSpace($catalogName)) { return $null }
    if ($catalogName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}\.json$' -or
        [IO.Path]::GetFileName($catalogName) -ne $catalogName) {
        throw "Codex model catalog 名称非法: $catalogName"
    }

    $sourcePath = Get-AiCliDataPath -Relative (Join-Path 'model-catalogs' $catalogName)
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Codex model catalog 不存在: $catalogName"
    }
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Codex model catalog 源文件不能是重解析点: $catalogName"
    }
    $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
    try {
        $utf8Strict = [Text.UTF8Encoding]::new($false, $true)
        $catalog = $utf8Strict.GetString($sourceBytes) | ConvertFrom-Json -Depth 100
    } catch {
        throw "Codex model catalog JSON 无效: $catalogName"
    }
    if (@($catalog.models).Count -eq 0) {
        throw "Codex model catalog 为空: $catalogName"
    }
    $autoCompact = Get-AiCliCodexAutoCompactConfiguration -MergedProfile $MergedProfile
    if ($autoCompact) {
        foreach ($catalogModel in @($catalog.models)) {
            $catalogLimit = Get-AiCliProperty $catalogModel 'auto_compact_token_limit'
            if ($null -eq $catalogLimit -or [long]$catalogLimit -ne $autoCompact.Limit) {
                throw "Codex model catalog 自动压缩阈值与 Profile 不一致: $catalogName"
            }
        }
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $sourceHash = [Convert]::ToHexString($sha.ComputeHash($sourceBytes)).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    $catalogRoot = Join-Path (Get-AiCliCodexHome) 'aicli-model-catalogs'
    if (Test-Path -LiteralPath $catalogRoot) {
        $rootItem = Get-Item -LiteralPath $catalogRoot -Force
        if (-not $rootItem.PSIsContainer -or
            ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Codex model catalog 目录不能是重解析点: $catalogRoot"
        }
    } else {
        New-Item -ItemType Directory -Path $catalogRoot -Force | Out-Null
    }
    $stem = [IO.Path]::GetFileNameWithoutExtension($catalogName)
    $destination = Join-Path $catalogRoot ("{0}-{1}.json" -f $stem, $sourceHash.Substring(0, 12))
    if (Test-Path -LiteralPath $destination) {
        $destinationItem = Get-Item -LiteralPath $destination -Force
        if ($destinationItem.PSIsContainer -or
            ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Codex model catalog 目标必须是普通文件: $destination"
        }
        $destinationBytes = [IO.File]::ReadAllBytes($destination)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $existingHash = [Convert]::ToHexString($sha.ComputeHash($destinationBytes)).ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
        if ($existingHash -ne $sourceHash) {
            throw "Codex model catalog 内容寻址冲突: $destination"
        }
        return [IO.Path]::GetFullPath($destination)
    }

    $tempPath = Join-Path $catalogRoot ('.aicli-catalog-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($tempPath, $sourceBytes)
        $rootItem = Get-Item -LiteralPath $catalogRoot -Force
        if (-not $rootItem.PSIsContainer -or
            ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Codex model catalog 目录在发布期间发生变化: $catalogRoot"
        }
        [IO.File]::Move($tempPath, $destination, $false)
        $destinationItem = Get-Item -LiteralPath $destination -Force
        if ($destinationItem.PSIsContainer -or
            ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Codex model catalog 发布结果不是普通文件: $destination"
        }
        $publishedBytes = [IO.File]::ReadAllBytes($destination)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $publishedHash = [Convert]::ToHexString($sha.ComputeHash($publishedBytes)).ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
        if ($publishedHash -ne $sourceHash) {
            throw "Codex model catalog 发布后哈希不一致: $destination"
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
    return [IO.Path]::GetFullPath($destination)
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
    $allowed = @(
        Get-AiCliProperty $MergedProfile 'effortLevels' |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if ($allowed.Count -eq 0) { $allowed = @(Get-AiCliCodexEffortLevels) }
    if ($allowed -notcontains $e) {
        throw "Codex 思考等级无效: $e。可选: $($allowed -join ', ')"
    }
    return $e
}

function Resolve-AiCliCodexEffectiveEffort {
    param(
        [Parameter(Mandatory)]$MergedProfile,
        [Parameter(Mandatory)][string]$RequestedEffort
    )
    $effortMap = Get-AiCliProperty $MergedProfile 'effortMap'
    $effective = [string](Get-AiCliProperty $effortMap $RequestedEffort)
    if ([string]::IsNullOrWhiteSpace($effective)) { return $RequestedEffort }
    return $effective
}

function Resolve-AiCliCodexModel {
    param($MergedProfile, [string[]]$NativeArgs)
    if (-not [bool](Get-AiCliProperty $MergedProfile 'flexible' $true) -or
        (Get-AiCliLocalGpuBrokerSessionConfiguration -MergedProfile $MergedProfile)) {
        foreach ($argument in @($NativeArgs)) {
            if ([string]$argument -eq '--fallback-model' -or
                ([string]$argument).StartsWith('--fallback-model=', [StringComparison]::Ordinal)) {
                throw 'Codex fallback models are disabled; the selected Profile route is exact.'
            }
        }
    }
    $overrides = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt @($NativeArgs).Count; $index++) {
        $argument = [string]$NativeArgs[$index]
        if ($argument -in @('--model', '-m')) {
            if ($index + 1 -ge @($NativeArgs).Count) {
                throw "Codex 参数 $argument 缺少模型值。"
            }
            $index++
            $value = [string]$NativeArgs[$index]
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "Codex 参数 $argument 缺少模型值。"
            }
            [void]$overrides.Add($value)
        } elseif ($argument.StartsWith('--model=', [StringComparison]::Ordinal)) {
            $value = $argument.Substring(8)
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw 'Codex 参数 --model 缺少模型值。'
            }
            [void]$overrides.Add($value)
        } elseif ($argument.Length -gt 2 -and $argument.StartsWith('-m', [StringComparison]::Ordinal)) {
            $value = $argument.Substring(2)
            if ($value.StartsWith('=')) { $value = $value.Substring(1) }
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw 'Codex 参数 -m 缺少模型值。'
            }
            [void]$overrides.Add($value)
        }
    }
    $distinct = @($overrides | Select-Object -Unique)
    if ($distinct.Count -gt 1) {
        throw "Codex 原生参数包含冲突的模型覆盖: $($distinct -join ', ')"
    }
    $model = if ($distinct.Count -eq 1) {
        [string]$distinct[0]
    } else {
        [string](Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary')
    }
    if (-not [string]::IsNullOrWhiteSpace($model)) {
        $null = Assert-AiCliModelId -Model $model
    }
    $catalogName = [string](Get-AiCliProperty $MergedProfile 'codexModelCatalog')
    if ($catalogName) {
        $models = Get-AiCliProperty $MergedProfile 'models'
        $allowed = @((Get-AiCliProperty $models 'candidates') | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($allowed -notcontains $model) {
            throw "Codex 模型当前目录未启用: $model。可选: $($allowed -join ', ')"
        }
    }
    return $model
}

function Resolve-AiCliCodexLaunchExecutable {
    param(
        [Parameter(Mandatory)]$MergedProfile,
        [switch]$MachineRun
    )
    $provider = Get-AiCliProperty $MergedProfile 'provider'
    $id = Get-AiCliProperty $MergedProfile 'id'
    # Interactive official sessions may use the Desktop launcher. Machine runs
    # require the npm entry because the disposable runtime and event parser
    # bind to the exact codex.js package rather than the private Desktop tree.
    $preferDesktop = -not $MachineRun -and ($provider -eq 'openai' -or $id -eq 'codex-official')
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
        } elseif (-not $MachineRun) {
            $resolved = Resolve-AiCliLaunchExecutable -Name 'codex'
        }
    }
    if (-not $resolved) {
        if ($MachineRun) {
            throw 'Codex machine run 需要 npm Codex CLI（npm i -g @openai/codex）；桌面 codex.exe 仅保留给交互启动。'
        }
        throw '未找到 codex。请安装 Codex CLI（npm i -g @openai/codex）或 Codex 桌面版。'
    }
    return $resolved
}

function Build-AiCliCodexLaunchPlan {
    param(
        $MergedProfile,
        [string]$ProjectPath,
        [string[]]$NativeArgs = @(),
        [switch]$MachineRun
    )
    Assert-AiCliCodexNativeArgs -NativeArgList $NativeArgs
    $provider = Get-AiCliProperty $MergedProfile 'provider'
    $id = Get-AiCliProperty $MergedProfile 'id'
    $resolved = Resolve-AiCliCodexLaunchExecutable -MergedProfile $MergedProfile -MachineRun:$MachineRun
    Assert-AiCliProfileMinimumCliVersion -MergedProfile $MergedProfile -Resolved $resolved
    $envDelta = @{}
    $removeEnv = @()
    $cliArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($resolved.PrefixArgs)) { $cliArgs.Add([string]$p) | Out-Null }
    $configFiles = @()
    $authSourceFile = $null
    $sandboxBoundary = 'outer-codex'
    $workspaceWriteValidated = $true
    $localGpuBrokerSession = $null
    $notes = @()
    $requestedEffort = Resolve-AiCliCodexEffort -MergedProfile $MergedProfile -NativeArgs $NativeArgs
    $effort = Resolve-AiCliCodexEffectiveEffort -MergedProfile $MergedProfile -RequestedEffort $requestedEffort
    $model = Resolve-AiCliCodexModel -MergedProfile $MergedProfile -NativeArgs $NativeArgs

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
        $notes += "默认模型 $model；思考等级 $requestedEffort（有效档位 $effort）。"
        if ($id -eq 'codex-spark-xhigh') {
            $notes += '该 Profile 精确固定 gpt-5.3-codex-spark / xhigh；文本型、Codex CLI/桌面可用，API 与图像输入不属于此路径。'
        } else {
            $notes += '可用模型例: gpt-5.6-sol / gpt-5.6-terra / gpt-5.6-luna（以账号可用为准）。'
        }
        $notes += "启动器: $($resolved.Kind) → $($resolved.FileName)"
        if ($MachineRun) {
            $authCandidate = Join-Path (Get-AiCliCodexHome) 'auth.json'
            if (-not (Test-Path -LiteralPath $authCandidate -PathType Leaf)) {
                throw 'Codex 官方 machine run 缺少 auth.json；请先通过 Codex CLI 或桌面版完成官方登录。'
            }
            $authSourceFile = [IO.Path]::GetFullPath($authCandidate)
            $sandboxBoundary = 'codex-native'
            $notes += '机器入口仅复制 auth.json 到一次性 CODEX_HOME；不复制配置、规则、skills、sessions 或历史。'
            $notes += '模型传输由官方 Codex CLI 联网；模型生成的命令仍由 Codex 原生沙箱限制。'
        }
    }
    elseif ($provider -eq 'ollama' -or $id -eq 'codex-ollama') {
        $localGpuBrokerSession = Get-AiCliLocalGpuBrokerSessionConfiguration `
            -MergedProfile $MergedProfile
        if ($MachineRun) {
            # The local gateway does not require the official-cloud sandbox
            # contract. Keep the complete bridge/app-server tree inside the
            # Windows outer sandbox and tell app-server that enforcement is
            # external, so approvalPolicy=never cannot turn an already-bounded
            # workspace command into an interactive approval request.
            $sandboxBoundary = 'outer-codex'
        }
        $endpoint = Get-AiCliProperty $MergedProfile 'endpoint'
        if (-not $endpoint) { $endpoint = 'http://127.0.0.1:11434/v1' }
        if (-not $model) { $model = 'qwen3:8b' }
        $providerId = Get-AiCliProperty $MergedProfile 'codexProviderId'
        if (-not $providerId) { $providerId = 'aicli_' + ($id -replace '-', '_') }
        $merged2 = [ordered]@{
            id             = $id
            displayName    = Get-AiCliProperty $MergedProfile 'displayName'
            endpoint       = $endpoint
            codexProviderId= $providerId
            models         = [ordered]@{ primary = $model }
            compatibility  = Get-AiCliProperty $MergedProfile 'compatibility'
        }
        $modelCatalogPath = Publish-AiCliCodexModelCatalog -MergedProfile $MergedProfile
        $toml = New-AiCliCodexProviderToml -MergedProfile $merged2 `
            -EnvKeyName 'AICLI_CODEX_PROVIDER_KEY' -ModelCatalogPath $modelCatalogPath
        $written = Write-AiCliCodexManagedProfile -MergedProfile $merged2 -TomlBody $toml
        $cliArgs.Add('--profile') | Out-Null
        $cliArgs.Add($written.CliProfileName) | Out-Null
        $configFiles += $written.FilePath
        foreach ($v in $script:AiCliCodexProviderVars) { $removeEnv += $v }
        $removeEnv += @('OPENAI_BASE_URL')
        $envDelta['AICLI_CODEX_PROVIDER_KEY'] = 'ollama'
        $envDelta['NO_PROXY'] = '127.0.0.1,localhost,::1'
        $envDelta['no_proxy'] = '127.0.0.1,localhost,::1'
        $cliArgs.Add('-c') | Out-Null
        $cliArgs.Add("model_reasoning_effort=`"$effort`"") | Out-Null
        Add-AiCliCodexProviderOverrides -ArgumentList $cliArgs -MergedProfile $merged2 `
            -ProviderId $providerId -EnvironmentKey 'AICLI_CODEX_PROVIDER_KEY' `
            -ModelCatalogPath $modelCatalogPath
        if ($modelCatalogPath) { $configFiles += $modelCatalogPath }
        $notes += "本机 Ollama 兼容网关: $endpoint"
        $notes += "模型: $model；wire_api=responses；思考等级 $requestedEffort（有效档位 $effort）"
        $notes += '公开模板使用 Ollama 默认 11434；其他本机网关请配置独立用户 Profile。'
    }
    else {
        # Scrub parent hijacks so only profile provider base_url is used
        foreach ($v in $script:AiCliCodexProviderVars) { $removeEnv += $v }
        $removeEnv += @('OPENAI_BASE_URL')
        if ($MachineRun) {
            # The Codex process must retain network access to reach the remote
            # Responses provider. Codex native sandboxing still constrains
            # model-generated commands and can deny their network access.
            $sandboxBoundary = 'codex-native'
            # Live Qwen Cloud tasks on 2026-07-28 proved that Codex 0.145
            # accepted the turn but rejected every workspace write. Fail before
            # provider invocation until that contract is independently fixed
            # and re-accepted.
            $workspaceWriteValidated = $false
        }
        $providerId = Get-AiCliProperty $MergedProfile 'codexProviderId'
        if (-not $providerId) { $providerId = 'aicli_' + ($id -replace '-', '_') }
        $modelCatalogPath = Publish-AiCliCodexModelCatalog -MergedProfile $MergedProfile
        $toml = New-AiCliCodexProviderToml -MergedProfile $MergedProfile `
            -EnvKeyName 'AICLI_CODEX_PROVIDER_KEY' -ModelCatalogPath $modelCatalogPath
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
        Add-AiCliCodexProviderOverrides -ArgumentList $cliArgs -MergedProfile $MergedProfile `
            -ProviderId $providerId -EnvironmentKey 'AICLI_CODEX_PROVIDER_KEY' -Model $model `
            -ModelCatalogPath $modelCatalogPath
        if ($modelCatalogPath) { $configFiles += $modelCatalogPath }
        $notes += "派生 Profile 文件: $($written.FilePath)"
        $notes += "wire_api = responses；思考等级 $requestedEffort（有效档位 $effort）。"
        $notes += '已清除父终端 OPENAI_BASE_URL/KEY，避免污染第三方 Profile。'
    }

    foreach ($a in $NativeArgs) { $cliArgs.Add($a) | Out-Null }

    return [pscustomobject]@{
        engine            = 'codex'
        profileId         = $id
        profileFingerprint = [string](Get-AiCliProperty $MergedProfile 'profileFingerprint')
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
        effort            = $requestedEffort
        effectiveEffort   = $effort
        model             = $model
        modelProvider     = $(if ($provider -eq 'openai' -or $id -eq 'codex-official') { 'openai' } else { $providerId })
        endpoint          = $(if ($provider -eq 'openai' -or $id -eq 'codex-official') { $null } else { [string](Get-AiCliProperty $MergedProfile 'endpoint') })
        wire              = 'responses'
        machineRuntime    = [ordered]@{
            kind = 'codex'
            configFiles = @($configFiles)
            authSourceFile = $authSourceFile
            sandboxBoundary = $sandboxBoundary
            workspaceWriteValidated = $workspaceWriteValidated
            localGpuBrokerSession = $localGpuBrokerSession
        }
    }
}
