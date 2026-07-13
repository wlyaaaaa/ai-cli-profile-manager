# Current Open Interpreter adapter (Rust 0.0.21+). The legacy Python 0.4.x CLI is unsupported.

function Get-AiCliInterpreterMinimumVersion {
    return [version]'0.0.21'
}

function Get-AiCliInterpreterPreferredPath {
    $localAppData = Get-AiCliKnownFolder LocalAppData
    if ([string]::IsNullOrWhiteSpace([string]$localAppData)) {
        $localAppData = $env:LOCALAPPDATA
    }
    return (Join-Path $localAppData 'Programs\Open Interpreter\bin\interpreter.exe')
}

function Get-AiCliInterpreterVersionInfo {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$PrefixArgs = @()
    )

    $raw = ''
    $exitCode = -1
    try {
        $raw = (& $FileName @PrefixArgs '--version' 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    } catch {
        $raw = $_.Exception.Message
    }

    $family = 'unknown'
    $versionText = $null
    if ($raw -match '(?im)^\s*interpreter\s+(\d+\.\d+\.\d+)') {
        $family = 'rust'
        $versionText = $Matches[1]
    } elseif ($raw -match '(?im)^\s*Open Interpreter\s+(\d+\.\d+\.\d+)') {
        $family = 'legacy-python'
        $versionText = $Matches[1]
    }

    $supported = $false
    if ($family -eq 'rust' -and $versionText) {
        try {
            $supported = ([version]$versionText -ge (Get-AiCliInterpreterMinimumVersion))
        } catch {}
    }

    return [pscustomobject]@{
        Family    = $family
        Version   = $versionText
        Supported = $supported -and ($exitCode -eq 0)
        ExitCode  = $exitCode
        Raw        = $raw
    }
}

function Resolve-AiCliInterpreterExecutable {
    $candidates = [System.Collections.Generic.List[object]]::new()
    $preferred = Get-AiCliInterpreterPreferredPath
    if (Test-Path -LiteralPath $preferred) {
        $candidates.Add([pscustomobject]@{
            FileName = $preferred
            PrefixArgs = @()
            Kind = 'official-rust'
        }) | Out-Null
    }

    $pathResolved = Resolve-AiCliLaunchExecutable -Name 'interpreter'
    if ($pathResolved) {
        $pathFile = [string](Get-AiCliProperty $pathResolved 'FileName')
        if (-not ($candidates | Where-Object { $_.FileName -eq $pathFile })) {
            $candidates.Add($pathResolved) | Out-Null
        }
    }

    $legacy = $null
    $unsupported = $null
    foreach ($candidate in $candidates) {
        $file = [string](Get-AiCliProperty $candidate 'FileName')
        $prefix = @((Get-AiCliProperty $candidate 'PrefixArgs') | ForEach-Object { $_ })
        $versionInfo = Get-AiCliInterpreterVersionInfo -FileName $file -PrefixArgs $prefix
        if ($versionInfo.Family -eq 'rust' -and $versionInfo.Supported) {
            return [pscustomobject]@{
                FileName   = $file
                PrefixArgs = $prefix
                Kind       = $(if ($file -eq $preferred) { 'official-rust' } else { 'rust-path' })
                Family     = 'rust'
                Version    = $versionInfo.Version
            }
        }
        if ($versionInfo.Family -eq 'legacy-python') {
            $legacy = $versionInfo
        } elseif ($versionInfo.Family -eq 'rust') {
            $unsupported = $versionInfo
        }
    }

    if ($legacy) {
        throw "Detected unsupported legacy Python Open Interpreter $($legacy.Version). Install the current Rust CLI with: irm https://www.openinterpreter.com/install.ps1 | iex"
    }
    if ($unsupported) {
        throw "Open Interpreter Rust $($unsupported.Version) is too old. Required: $((Get-AiCliInterpreterMinimumVersion).ToString())+"
    }
    return $null
}

function Get-AiCliInterpreterReservedArgs {
    return @(
        '-c', '--config', '-m', '--model', '--oss', '--local-provider', '-p', '--profile',
        '--remote', '--remote-auth-token-env',
        '--dangerously-bypass-approvals-and-sandbox', '--yolo',
        '--auto_run', '--auto-run', '-y',
        '--api_base', '--api-base', '-ab', '--api_key', '--api-key', '-ak',
        '--offline', '--disable_telemetry'
    )
}

function Assert-AiCliInterpreterNativeArgs {
    param([string[]]$NativeArgList)
    $reserved = Get-AiCliInterpreterReservedArgs
    foreach ($arg in @($NativeArgList)) {
        $value = [string]$arg
        foreach ($reservedArg in $reserved) {
            if ($value -eq $reservedArg -or $value.StartsWith("$reservedArg=")) {
                throw "Parameter $value conflicts with the managed Open Interpreter provider or safety configuration."
            }
        }
    }
}

function ConvertTo-AiCliInterpreterTomlString {
    param([AllowEmptyString()][string]$Value)
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $escaped + '"'
}

function Get-AiCliInterpreterProviderId {
    param($MergedProfile)
    $providerId = Get-AiCliProperty $MergedProfile 'interpreterProviderId'
    if ([string]::IsNullOrWhiteSpace([string]$providerId)) {
        $provider = [string](Get-AiCliProperty $MergedProfile 'provider')
        $providerId = 'aicli_' + ($provider -replace '[^a-zA-Z0-9_-]', '_').ToLowerInvariant()
    }
    if ($providerId -notmatch '^[a-zA-Z0-9_-]+$') {
        throw "Invalid Open Interpreter provider id: $providerId"
    }
    return [string]$providerId
}

function Get-AiCliInterpreterWireApi {
    param($MergedProfile)
    $wireApi = [string](Get-AiCliProperty $MergedProfile 'wireApi')
    if ([string]::IsNullOrWhiteSpace($wireApi)) {
        switch ([string](Get-AiCliProperty $MergedProfile 'provider')) {
            'deepseek' { $wireApi = 'chat' }
            'qwen' { $wireApi = 'responses' }
            'ollama' { $wireApi = 'responses' }
        }
    }
    if ($wireApi -notin @('responses', 'chat')) {
        throw "Open Interpreter wireApi must be responses or chat; received: $wireApi"
    }
    return $wireApi
}

function Add-AiCliInterpreterConfigArg {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$ArgumentList,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$TomlValue
    )
    $ArgumentList.Add('-c') | Out-Null
    $ArgumentList.Add("$Key=$TomlValue") | Out-Null
}

function Build-AiCliInterpreterLaunchPlan {
    param(
        $MergedProfile,
        [string]$ProjectPath,
        [string[]]$NativeArgs = @()
    )
    Assert-AiCliInterpreterNativeArgs -NativeArgList $NativeArgs

    $resolved = Resolve-AiCliInterpreterExecutable
    if (-not $resolved) {
        throw 'Open Interpreter Rust 0.0.21+ was not found. Install it with: irm https://www.openinterpreter.com/install.ps1 | iex'
    }

    $id = [string](Get-AiCliProperty $MergedProfile 'id')
    $provider = [string](Get-AiCliProperty $MergedProfile 'provider')
    $providerId = Get-AiCliInterpreterProviderId -MergedProfile $MergedProfile
    $wireApi = Get-AiCliInterpreterWireApi -MergedProfile $MergedProfile
    $endpoint = [string](Get-AiCliProperty $MergedProfile 'endpoint')
    if ([string]::IsNullOrWhiteSpace($endpoint)) { throw "Profile $id is missing endpoint" }
    Assert-AiCliEndpointSafe -Url $endpoint | Out-Null

    $models = Get-AiCliProperty $MergedProfile 'models'
    $model = [string](Get-AiCliProperty $models 'primary')
    if ([string]::IsNullOrWhiteSpace($model)) { throw "Profile $id is missing models.primary" }
    $null = Assert-AiCliModelId -Model $model

    $envDelta = @{}
    $removeEnv = [System.Collections.Generic.List[string]]::new()
    $providerVars = @(
        $script:AiCliCodexProviderVars + $script:AiCliClaudeProviderVars + @(
            'AICLI_OI_PROVIDER_KEY', 'OPENAI_API_BASE', 'DEEPSEEK_API_KEY', 'DASHSCOPE_API_KEY',
            'ALIBABA_CODING_PLAN_API_KEY', 'OLLAMA_API_KEY', 'INTERPRETER_CLI'
        )
    )
    foreach ($name in $providerVars) {
        if ($removeEnv -notcontains $name) { $removeEnv.Add([string]$name) | Out-Null }
    }

    $requiresSecret = [bool](Get-AiCliProperty $MergedProfile 'requiresSecret' $false)
    if ($requiresSecret) {
        $secretRef = Get-AiCliProperty $MergedProfile 'secretRef'
        if ([string]::IsNullOrWhiteSpace([string]$secretRef)) {
            $templateId = Get-AiCliProperty $MergedProfile 'templateId'
            if (-not $templateId) { $templateId = $id }
            throw "Profile $id requires an API key. Run: aicli profile configure $templateId"
        }
        $envDelta['AICLI_OI_PROVIDER_KEY'] = Get-AiCliSecret -SecretId $secretRef
    }

    $configArgs = [System.Collections.Generic.List[string]]::new()
    Add-AiCliInterpreterConfigArg -ArgumentList $configArgs -Key 'model_provider' -TomlValue (ConvertTo-AiCliInterpreterTomlString $providerId)
    Add-AiCliInterpreterConfigArg -ArgumentList $configArgs -Key 'model' -TomlValue (ConvertTo-AiCliInterpreterTomlString $model)
    Add-AiCliInterpreterConfigArg -ArgumentList $configArgs -Key "model_providers.$providerId.name" -TomlValue (ConvertTo-AiCliInterpreterTomlString ([string](Get-AiCliProperty $MergedProfile 'displayName')))
    Add-AiCliInterpreterConfigArg -ArgumentList $configArgs -Key "model_providers.$providerId.base_url" -TomlValue (ConvertTo-AiCliInterpreterTomlString $endpoint)
    Add-AiCliInterpreterConfigArg -ArgumentList $configArgs -Key "model_providers.$providerId.wire_api" -TomlValue (ConvertTo-AiCliInterpreterTomlString $wireApi)
    if ($requiresSecret) {
        Add-AiCliInterpreterConfigArg -ArgumentList $configArgs -Key "model_providers.$providerId.env_key" -TomlValue (ConvertTo-AiCliInterpreterTomlString 'AICLI_OI_PROVIDER_KEY')
    }
    Add-AiCliInterpreterConfigArg -ArgumentList $configArgs -Key 'shell_environment_policy.exclude' -TomlValue '["AICLI_OI_PROVIDER_KEY"]'
    Add-AiCliInterpreterConfigArg -ArgumentList $configArgs -Key 'shell_environment_policy.ignore_default_excludes' -TomlValue 'false'

    $prefixArgs = @((Get-AiCliProperty $resolved 'PrefixArgs') | ForEach-Object { $_ })
    $interactiveArgs = @($prefixArgs) + @($configArgs.ToArray()) + @($NativeArgs)
    $nonInteractiveArgs = @($prefixArgs) + @('exec', '--skip-git-repo-check', '--ephemeral') + @($configArgs.ToArray())

    $notes = @(
        "Open Interpreter Rust $($resolved.Version) -> $provider"
        "base_url: $endpoint"
        "model: $model; wire_api: $wireApi"
        'API key is injected only as AICLI_OI_PROVIDER_KEY in the child process environment.'
        'The shell tool explicitly excludes AICLI_OI_PROVIDER_KEY; no auto-run or sandbox bypass is enabled.'
        "launcher: $($resolved.Kind) -> $($resolved.FileName)"
    )
    $destination = Get-AiCliProperty $MergedProfile 'dataDestination'
    if ($destination) { $notes += "Data destination: $destination" }

    return [pscustomobject]@{
        engine                     = 'interpreter'
        profileId                  = $id
        fileName                   = [string](Get-AiCliProperty $resolved 'FileName')
        argumentList               = @($interactiveArgs)
        versionArgumentList        = @((Get-AiCliProperty $resolved 'PrefixArgs') | ForEach-Object { [string]$_ }) + @('--version')
        launcherKind               = [string](Get-AiCliProperty $resolved 'Kind')
        nonInteractiveArgumentList = @($nonInteractiveArgs)
        workingDirectory           = $ProjectPath
        environmentDelta           = $envDelta
        removeEnvironment          = @($removeEnv.ToArray())
        configFiles                = @()
        notes                      = @($notes)
        proxyRef                   = $null
        effort                     = $null
        model                      = $model
        wireApi                    = $wireApi
        interpreterVersion         = [string]$resolved.Version
    }
}
