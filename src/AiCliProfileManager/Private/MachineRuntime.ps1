# Ephemeral runtime for machine-facing agent calls. The parent creates only
# deterministic configuration. Public Codex harness calls deliberately use
# native danger-full-access; other engines retain their explicit sandbox policy.

function Resolve-AiCliCodexNativeRuntimeFromEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EntryPath)
    $entry = [IO.Path]::GetFullPath($EntryPath)
    if (-not $entry.EndsWith('codex.js', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $entry -PathType Leaf)) {
        throw "Codex npm entry is invalid: $entry"
    }
    $packageSource = Split-Path -Parent (Split-Path -Parent $entry)
    $nativePackages = @(
        Get-ChildItem -LiteralPath (Join-Path $packageSource 'node_modules\@openai') `
            -Directory -Filter 'codex-win32-*' -ErrorAction SilentlyContinue |
            Where-Object {
                @(Get-ChildItem -LiteralPath (Join-Path $_.FullName 'vendor') `
                    -Recurse -File -Filter 'codex.exe' -ErrorAction SilentlyContinue).Count -gt 0
            }
    )
    if ($nativePackages.Count -eq 0) {
        throw "Codex npm package is missing its Windows native runtime: $packageSource"
    }
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $preferredPackage = @($nativePackages | Where-Object { $_.Name -eq "codex-win32-$architecture" })
    $selectedPackage = if ($preferredPackage.Count -eq 1) {
        $preferredPackage[0]
    } elseif ($nativePackages.Count -eq 1) {
        $nativePackages[0]
    } else {
        throw "Codex npm package has no unambiguous native runtime for $architecture."
    }
    $nativeExecutables = @(
        Get-ChildItem -LiteralPath (Join-Path $selectedPackage.FullName 'vendor') `
            -Recurse -File -Filter 'codex.exe' -ErrorAction SilentlyContinue
    )
    if ($nativeExecutables.Count -ne 1) {
        throw "Codex npm package has no unambiguous native executable: $($selectedPackage.FullName)"
    }
    return [pscustomobject]@{
        EntryPath = $entry
        PackageRoot = [IO.Path]::GetFullPath($packageSource)
        NativeExecutable = [IO.Path]::GetFullPath($nativeExecutables[0].FullName)
    }
}

function Set-AiCliIsolatedInterpreterHome {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Root
    )
    $base = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $base -PathType Container)) {
        throw "Interpreter home root does not exist: $base"
    }
    $isolatedInterpreterHome = Join-Path $base 'interpreter-home'
    New-Item -ItemType Directory -Path $isolatedInterpreterHome -Force | Out-Null
    # Rust OI 0.0.21 and 0.0.40 use INTERPRETER_HOME. Bind CODEX_HOME to the
    # same disposable directory too, so shared legacy Codex code cannot reach
    # an inherited user home during a bounded Live or machine run.
    $Environment['INTERPRETER_HOME'] = $isolatedInterpreterHome
    $Environment['CODEX_HOME'] = $isolatedInterpreterHome
    return $isolatedInterpreterHome
}

function Initialize-AiCliMachineRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$StdInText = '',
        [ValidateSet('danger-full-access','read-only','workspace-write')][string]$Policy = 'read-only',
        [int]$MaxSteps = 20,
        [int]$MaxToolCalls = 80,
        [switch]$DisableWebSearch,
        [object]$RecoveryContext = $null
    )
    $workspace = [IO.Path]::GetFullPath([string](Get-AiCliProperty $Plan 'workingDirectory'))
    if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
        throw "Machine runtime workspace does not exist: $workspace"
    }
    $runtimeConfig = Get-AiCliProperty $Plan 'machineRuntime'
    $kind = [string](Get-AiCliProperty $runtimeConfig 'kind')
    $base = if ($Policy -eq 'workspace-write') { $workspace } else { [IO.Path]::GetTempPath() }
    $runtimePath = Join-Path $base ('.aicli-runtime-' + [guid]::NewGuid().ToString('N'))
    $tmpPath = Join-Path $runtimePath 'tmp'
    New-Item -ItemType Directory -Path $tmpPath -Force | Out-Null

    $environment = @{}
    $planEnvironment = Get-AiCliProperty $Plan 'environmentDelta'
    if ($planEnvironment) {
        foreach ($key in $planEnvironment.Keys) { $environment[$key] = $planEnvironment[$key] }
    }
    $environment['TEMP'] = $tmpPath
    $environment['TMP'] = $tmpPath
    if ([string](Get-AiCliProperty $Plan 'engine') -eq 'interpreter') {
        $null = Set-AiCliIsolatedInterpreterHome -Environment $environment -Root $runtimePath
    }
    $arguments = @((Get-AiCliProperty $Plan 'argumentList') | ForEach-Object { [string]$_ })
    $effectiveStdIn = if ($null -eq $StdInText) { '' } else { [string]$StdInText }
    $useOuterSandbox = $true
    $runtimeFileName = [string](Get-AiCliProperty $Plan 'fileName')
    $runtimeTargetFileName = $runtimeFileName
    $eventProtocol = $null
    $additionalReadRoots = @()
    $privateTaskPipeName = $null
    try {
        if ($kind -eq 'qwen-code') {
            for ($index = 0; $index -lt $arguments.Count; $index++) {
                $candidate = [string]$arguments[$index]
                if ($candidate.EndsWith('cli-entry.js', [StringComparison]::OrdinalIgnoreCase) -and
                    (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    $packageSource = Split-Path -Parent $candidate
                    $packageMirror = Join-Path $runtimePath 'qwen-package'
                    New-AiCliPackageMirror -Source $packageSource -Destination $packageMirror
                    $arguments[$index] = Join-Path $packageMirror 'cli-entry.js'
                    break
                }
            }
            $endpoint = ([string](Get-AiCliProperty $runtimeConfig 'endpoint')).TrimEnd('/')
            $model = [string](Get-AiCliProperty $runtimeConfig 'model')
            $settings = [ordered]@{
                env = [ordered]@{ AICLI_QWEN_LOCAL_KEY = 'ollama' }
                modelProviders = [ordered]@{
                    openai = @([ordered]@{
                        id = $model
                        name = $model
                        envKey = 'AICLI_QWEN_LOCAL_KEY'
                        baseUrl = $endpoint
                        generationConfig = [ordered]@{
                            maxRetries = 0
                            contextWindowSize = 262144
                        }
                    })
                }
                security = [ordered]@{ auth = [ordered]@{ selectedType = 'openai' } }
                model = [ordered]@{
                    name = $model
                    maxSessionTurns = $MaxSteps
                    maxToolCalls = $MaxToolCalls
                }
                tools = [ordered]@{ approvalMode = 'yolo' }
            }
            Write-AiCliJsonFile -Path (Join-Path $runtimePath 'settings.json') -Value $settings
            $environment['QWEN_HOME'] = $runtimePath
            $environment['AICLI_QWEN_LOCAL_KEY'] = 'ollama'
            $environment['OPENAI_API_KEY'] = 'ollama'
            $environment['OPENAI_BASE_URL'] = $endpoint
            $environment['QWEN_CODE_DISABLE_AUTO_UPDATE'] = 'true'
            $environment['QWEN_CODE_SUPPRESS_YOLO_WARNING'] = '1'
            $arguments += @('--max-session-turns', [string]$MaxSteps, '--max-tool-calls', [string]$MaxToolCalls)
        }
        elseif ($kind -eq 'codex') {
            $codexEntryFound = $false
            $codexEntryIndex = -1
            $codexPackageSource = $null
            $codexNativeExecutable = $null
            for ($index = 0; $index -lt $arguments.Count; $index++) {
                $candidate = [string]$arguments[$index]
                if ($candidate.EndsWith('codex.js', [StringComparison]::OrdinalIgnoreCase) -and
                    (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    $nativeRuntime = Resolve-AiCliCodexNativeRuntimeFromEntry -EntryPath $candidate
                    # Keep the installed package at its short canonical path.
                    # The outer sandbox grants this exact package read-only;
                    # mirroring it under a deep workspace can exceed MAX_PATH.
                    $arguments[$index] = $nativeRuntime.EntryPath
                    $codexEntryFound = $true
                    $codexEntryIndex = $index
                    $codexPackageSource = $nativeRuntime.PackageRoot
                    $codexNativeExecutable = $nativeRuntime.NativeExecutable
                    break
                }
            }
            if (-not $codexEntryFound) { throw 'Codex machine runtime could not locate codex.js.' }
            $execIndex = [Array]::IndexOf([string[]]$arguments, 'exec')
            if ($execIndex -lt 0) {
                $execIndex = [Array]::IndexOf([string[]]$arguments, 'e')
            }
            if ($execIndex -le $codexEntryIndex -or
                $arguments -notcontains '--json' -or
                $arguments[-1] -ne '-') {
                throw 'Codex machine run requires native arguments: exec --json ... -'
            }
            $codexHome = if ($null -ne $RecoveryContext) {
                $recoveryRunId = [string](
                    Get-AiCliProperty $RecoveryContext 'runId'
                )
                $requestedHome = [string](
                    Get-AiCliProperty $RecoveryContext 'durableCodexHome'
                )
                $expectedHome = Join-Path (
                    Get-AiCliRecoverableRunRoot -RunId $recoveryRunId
                ) 'codex-home'
                if ([string]::IsNullOrWhiteSpace($requestedHome) -or
                    -not [IO.Path]::GetFullPath($requestedHome).Equals(
                        [IO.Path]::GetFullPath($expectedHome),
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                    throw 'Recoverable Codex home is outside the bound run root.'
                }
                $homeItem = Get-Item -LiteralPath $expectedHome -Force `
                    -ErrorAction Stop
                if (-not $homeItem.PSIsContainer -or
                    ($homeItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'Recoverable Codex home must be an ordinary directory.'
                }
                [IO.Path]::GetFullPath($expectedHome)
            } else {
                Join-Path $runtimePath 'codex-home'
            }
            if (-not (Test-Path -LiteralPath $codexHome -PathType Container)) {
                New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
            }
            foreach ($configFile in @((Get-AiCliProperty $runtimeConfig 'configFiles'))) {
                if (-not [string]::IsNullOrWhiteSpace([string]$configFile) -and
                    (Test-Path -LiteralPath ([string]$configFile) -PathType Leaf)) {
                    Copy-Item -LiteralPath ([string]$configFile) -Destination (Join-Path $codexHome (Split-Path -Leaf ([string]$configFile))) -Force
                }
            }
            $authSourceFile = [string](Get-AiCliProperty $runtimeConfig 'authSourceFile')
            if (-not [string]::IsNullOrWhiteSpace($authSourceFile)) {
                if ((Split-Path -Leaf $authSourceFile) -ne 'auth.json' -or
                    -not (Test-Path -LiteralPath $authSourceFile -PathType Leaf)) {
                    throw 'Codex machine runtime auth source must be an existing auth.json file.'
                }
                Copy-Item -LiteralPath $authSourceFile -Destination (Join-Path $codexHome 'auth.json') -Force
            }
            $environment['CODEX_HOME'] = $codexHome
            # The Node launcher normally supplies these bindings before it
            # starts the native executable. Machine runs launch codex.exe
            # directly so the exact npm package, command runner, and Windows
            # sandbox helper remain one versioned closure.
            $environment['CODEX_MANAGED_PACKAGE_ROOT'] = $codexPackageSource
            $environment['CODEX_MANAGED_BY_NPM'] = '1'

            $boundedAgentFlags = @('--disable', 'multi_agent', '--disable', 'multi_agent_v2')
            $sandboxBoundary = if ($Policy -eq 'danger-full-access') {
                'codex-native'
            } else {
                [string](Get-AiCliProperty $runtimeConfig 'sandboxBoundary' 'outer-codex')
            }
            if ($sandboxBoundary -notin @('outer-codex', 'codex-native')) {
                throw "Unsupported Codex machine sandbox boundary: $sandboxBoundary"
            }
            if ($sandboxBoundary -eq 'codex-native') {
                $useOuterSandbox = $false
            } else {
                # `codex sandbox windows` does not forward its own stdin to the
                # sandboxed command. An ACL-restricted named pipe carries the
                # private task into the trusted bridge without argv, env-value,
                # workspace, or temporary-file persistence.
                $privateTaskPipeName = 'aicli-' + [guid]::NewGuid().ToString('N')
            }

            $globalArguments = @(
                if ($execIndex -gt ($codexEntryIndex + 1)) {
                    $arguments[($codexEntryIndex + 1)..($execIndex - 1)]
                }
            )
            # Codex 0.145 accepts --profile for interactive/runtime commands,
            # but rejects it for app-server before initialize. Keep the
            # explicit -c provider/model overrides and isolated CODEX_HOME,
            # while removing only this runtime-only selector. Recovery runs
            # bind that home to one durable run; one-shot captures still clean it.
            $appServerGlobalArguments = [System.Collections.Generic.List[string]]::new()
            for ($index = 0; $index -lt $globalArguments.Count; $index++) {
                if ([string]$globalArguments[$index] -eq '--profile') {
                    if ($index + 1 -ge $globalArguments.Count) {
                        throw 'Codex machine run profile selector is missing its value.'
                    }
                    $index++
                    continue
                }
                [void]$appServerGlobalArguments.Add(
                    [string]$globalArguments[$index]
                )
            }
            $appServerArguments = @($appServerGlobalArguments.ToArray()) + $boundedAgentFlags +
                @('app-server', '--stdio')
            # Launch the package's native executable directly. Keeping node.exe
            # as the app-server root creates a short-lived wrapper race: after
            # a fast turn the wrapper can exit before the bridge can kill and
            # confirm the complete process tree.
            $runtimeFileName = $codexNativeExecutable
            $runtimeTargetFileName = $codexNativeExecutable
            $bridgePath = Join-Path (
                Split-Path -Parent $PSScriptRoot
            ) 'Support\CodexAppServerBridge.ps1'
            if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
                throw 'Codex app-server bridge is missing from the installed module.'
            }
            $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue |
                Select-Object -First 1).Source
            if (-not $pwsh) {
                throw 'PowerShell 7 is required for the Codex app-server bridge.'
            }
            $bridgeConfigPath = Join-Path $runtimePath 'codex-app-server-bridge.json'
            $localGpuBrokerConfiguration = Get-AiCliProperty `
                $runtimeConfig 'localGpuBrokerSession'
            $expectedProviderForIdentity = [string](Get-AiCliProperty $Plan 'modelProvider')
            # The public Codex harness is always danger-full-access and every
            # current/future model on that route must attest actual identity.
            # Legacy lower-level sandbox probes retain their narrower fixtures.
            $requireRuntimeIdentity = $Policy -eq 'danger-full-access' -or
                $null -ne $localGpuBrokerConfiguration -or
                $expectedProviderForIdentity -cmatch '^aicli_deepseek(?:_|$)'
            $expectedModel = [string](Get-AiCliProperty $Plan 'model')
            $expectedModelProvider = [string](
                Get-AiCliProperty $Plan 'modelProvider'
            )
            if ($requireRuntimeIdentity -and (
                $expectedModel -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,127}$' -or
                $expectedModelProvider -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
            )) {
                throw 'Codex machine runtime identity expectation is invalid.'
            }
            $bridgeConfig = [ordered]@{
                fileName = [IO.Path]::GetFullPath($runtimeFileName)
                argumentList = @($appServerArguments)
                workingDirectory = $workspace
                sandboxBoundary = $sandboxBoundary
                sandboxPolicy = $Policy
                model = [string](Get-AiCliProperty $Plan 'model')
                minimumCliVersion = if ($requireRuntimeIdentity) {
                    '0.147.0'
                } else {
                    '0.145.0'
                }
                webSearchEnabled = (
                    $Policy -eq 'danger-full-access' -and -not $DisableWebSearch
                )
            }
            if ($null -ne $RecoveryContext) {
                foreach ($name in @(
                    'runId','mode','threadId','sessionId','workspaceHash',
                    'profileFingerprint','requestedEffort','effectiveEffort'
                )) {
                    $bridgeConfig[$name] = Get-AiCliProperty `
                        $RecoveryContext $name
                }
                $bridgeConfig['durableSession'] = $true
            }
            if ($requireRuntimeIdentity) {
                $bridgeConfig['expectedModel'] = $expectedModel
                $bridgeConfig['expectedModelProvider'] = $expectedModelProvider
                $bridgeConfig['requireRuntimeIdentity'] = $true
            }
            Write-AiCliJsonFile -Path $bridgeConfigPath -Value $bridgeConfig
            $runtimeFileName = $pwsh
            $arguments = @(
                '-NoProfile',
                '-File',
                [IO.Path]::GetFullPath($bridgePath),
                '-ConfigPath',
                [IO.Path]::GetFullPath($bridgeConfigPath)
            )
            $eventProtocol = 'codex-app-server'
            $additionalReadRoots = @(
                [IO.Path]::GetFullPath((Split-Path -Parent ([string](
                    Get-AiCliProperty $bridgeConfig 'fileName'
                )))),
                $codexPackageSource
            )
        }
        elseif ($kind -eq 'claude') {
            $claudeConfig = Join-Path $runtimePath 'claude-config'
            New-Item -ItemType Directory -Path $claudeConfig -Force | Out-Null
            $environment['CLAUDE_CONFIG_DIR'] = $claudeConfig
            # The host is protected by the mandatory outer Codex sandbox. Let
            # Claude operate autonomously inside that boundary without prompts.
            $environment['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'] = '0'
            $environment['DISABLE_AUTOUPDATER'] = '1'
            if ($arguments -notcontains '--max-turns') {
                $arguments += @('--max-turns', [string]$MaxSteps)
            }
        }
        elseif ($kind -eq 'opencode') {
            $endpoint = ([string](Get-AiCliProperty $runtimeConfig 'endpoint')).TrimEnd('/')
            $model = [string](Get-AiCliProperty $runtimeConfig 'model')
            $modelMetadata = Get-AiCliProperty $runtimeConfig 'modelMetadata'
            if ($null -eq $modelMetadata) {
                throw "OpenCode model metadata is missing: $model"
            }
            $contextWindow = [int](Get-AiCliProperty $modelMetadata 'contextWindowTokens')
            $inputWindow = [int](Get-AiCliProperty $modelMetadata 'inputWindowTokens')
            $outputWindow = [int](Get-AiCliProperty $modelMetadata 'outputWindowTokens')
            $compactionReserve = [int](Get-AiCliProperty $modelMetadata 'compactionReserveTokens')
            $preserveRecent = [int](Get-AiCliProperty $modelMetadata 'preserveRecentTokens')
            $tailTurns = [int](Get-AiCliProperty $modelMetadata 'tailTurns')
            $modelRef = "aicli_ollama/$model"
            $config = [ordered]@{
                '$schema' = 'https://opencode.ai/config.json'
                model = $modelRef
                small_model = $modelRef
                default_agent = 'build'
                enabled_providers = @('aicli_ollama')
                share = 'disabled'
                compaction = [ordered]@{
                    auto = $true
                    prune = $false
                    tail_turns = $tailTurns
                    preserve_recent_tokens = $preserveRecent
                    reserved = $compactionReserve
                }
                agent = [ordered]@{
                    build = [ordered]@{ steps = $MaxSteps }
                    compaction = [ordered]@{ model = $modelRef }
                }
                provider = [ordered]@{
                    aicli_ollama = [ordered]@{
                        npm = '@ai-sdk/openai-compatible'
                        name = 'AICLI local Ollama'
                        options = [ordered]@{ baseURL = $endpoint; apiKey = 'ollama' }
                        models = [ordered]@{
                            $model = [ordered]@{
                                name = $model
                                limit = [ordered]@{
                                    context = $contextWindow
                                    input = $inputWindow
                                    output = $outputWindow
                                }
                            }
                        }
                    }
                }
            }
            $environment['OPENCODE_CONFIG_CONTENT'] = ($config | ConvertTo-Json -Depth 20 -Compress)
            $environment['OPENCODE_DISABLE_AUTOUPDATE'] = 'true'
            $environment['OPENCODE_CONFIG_DIR'] = (Join-Path $runtimePath 'config\opencode')
            $environment['XDG_CONFIG_HOME'] = (Join-Path $runtimePath 'config')
            $environment['XDG_DATA_HOME'] = (Join-Path $runtimePath 'data')
            $environment['XDG_CACHE_HOME'] = (Join-Path $runtimePath 'cache')
            $environment['XDG_STATE_HOME'] = (Join-Path $runtimePath 'state')
            foreach ($directory in @('config\opencode','data','cache','state')) {
                New-Item -ItemType Directory -Path (Join-Path $runtimePath $directory) -Force | Out-Null
            }
            $taskPath = Join-Path $runtimePath 'task.md'
            [IO.File]::WriteAllText($taskPath, $effectiveStdIn, [Text.UTF8Encoding]::new($false))
            $arguments += @('Complete the attached task inside the current workspace. Return only the final result.', '--file', $taskPath)
            $effectiveStdIn = ''
        }
        return [pscustomobject]@{
            RuntimePath = $runtimePath
            FileName = $runtimeFileName
            TargetFileName = $runtimeTargetFileName
            ArgumentList = @($arguments)
            EnvironmentDelta = $environment
            StdInText = $effectiveStdIn
            UseOuterSandbox = $useOuterSandbox
            EventProtocol = $eventProtocol
            AdditionalReadRoots = @($additionalReadRoots)
            PrivateTaskPipeName = $privateTaskPipeName
            WebSearchEnabled = (
                $kind -eq 'codex' -and
                $Policy -eq 'danger-full-access' -and
                -not $DisableWebSearch
            )
            DurableSession = $null -ne $RecoveryContext
            CodexHome = if ($kind -eq 'codex') {
                [string]$environment['CODEX_HOME']
            } else { $null }
        }
    } catch {
        Remove-AiCliMachineRuntime -RuntimePath $runtimePath -Workspace $workspace
        throw
    }
}

function New-AiCliPackageMirror {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($directory in Get-ChildItem -LiteralPath $sourceRoot -Directory -Recurse -Force) {
        $relative = $directory.FullName.Substring($sourceRoot.Length).TrimStart('\')
        New-Item -ItemType Directory -Path (Join-Path $Destination $relative) -Force | Out-Null
    }
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        try {
            New-Item -ItemType HardLink -Path $target -Target $file.FullName -ErrorAction Stop | Out-Null
        } catch {
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }
    }
}

function Remove-AiCliMachineRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$Workspace,
        [ValidateRange(0,30000)][int]$WaitForReleaseMs = 0,
        [switch]$PassThru
    )
    if ([string]::IsNullOrWhiteSpace($RuntimePath) -or -not (Test-Path -LiteralPath $RuntimePath)) {
        $result = [pscustomobject]@{
            Removed = $true; Reason = 'already-absent'; Attempts = 0; WaitedMs = 0
        }
        if ($PassThru) { return $result }
        return
    }
    $resolvedRuntime = [IO.Path]::GetFullPath($RuntimePath).TrimEnd('\')
    $leaf = Split-Path -Leaf $resolvedRuntime
    if (-not $leaf.StartsWith('.aicli-runtime-', [StringComparison]::Ordinal)) {
        throw "Refusing to remove a non-runtime path: $resolvedRuntime"
    }
    $workspaceRoot = [IO.Path]::GetFullPath($Workspace).TrimEnd('\') + '\'
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $allowed = $resolvedRuntime.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedRuntime.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)
    if (-not $allowed) { throw "Refusing to remove runtime outside the workspace or temp root: $resolvedRuntime" }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $attempts = 0
    $lastException = $null
    do {
        $attempts++
        try {
            Remove-Item -LiteralPath $resolvedRuntime -Recurse -Force -ErrorAction Stop
        } catch {
            $lastException = $_.Exception
        }
        if (-not (Test-Path -LiteralPath $resolvedRuntime)) {
            $stopwatch.Stop()
            $result = [pscustomobject]@{
                Removed = $true; Reason = 'removed'; Attempts = $attempts
                WaitedMs = [int]$stopwatch.ElapsedMilliseconds
            }
            if ($PassThru) { return $result }
            return
        }
        $remainingMs = $WaitForReleaseMs - [int]$stopwatch.ElapsedMilliseconds
        if ($remainingMs -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Min(100, $remainingMs))
        }
    } while ($remainingMs -gt 0)
    $stopwatch.Stop()
    $reason = if ($lastException -is [IO.IOException]) {
        'runtime-directory-busy'
    } elseif ($lastException -is [UnauthorizedAccessException]) {
        'runtime-directory-access-denied'
    } else {
        'runtime-directory-remove-failed'
    }
    $result = [pscustomobject]@{
        Removed = $false; Reason = $reason; Attempts = $attempts
        WaitedMs = [int]$stopwatch.ElapsedMilliseconds
        RuntimeId = $leaf; RuntimePath = $resolvedRuntime
    }
    if ($PassThru) { return $result }
    if ($lastException) { throw $lastException }
    throw "Failed to remove runtime directory: $resolvedRuntime"
}
