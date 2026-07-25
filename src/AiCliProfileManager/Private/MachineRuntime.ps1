# Ephemeral runtime for machine-facing agent calls. The parent creates only
# deterministic configuration; the untrusted agent still runs inside Codex sandbox.

function Initialize-AiCliMachineRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$StdInText = '',
        [ValidateSet('read-only','workspace-write')][string]$Policy = 'read-only',
        [int]$MaxSteps = 20,
        [int]$MaxToolCalls = 80
    )
    $workspace = [IO.Path]::GetFullPath([string](Get-AiCliProperty $Plan 'workingDirectory'))
    if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
        throw "Machine runtime workspace does not exist: $workspace"
    }
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
    $arguments = @((Get-AiCliProperty $Plan 'argumentList') | ForEach-Object { [string]$_ })
    $effectiveStdIn = if ($null -eq $StdInText) { '' } else { [string]$StdInText }
    $runtimeConfig = Get-AiCliProperty $Plan 'machineRuntime'
    $kind = [string](Get-AiCliProperty $runtimeConfig 'kind')
    $useOuterSandbox = $true
    $runtimeFileName = [string](Get-AiCliProperty $Plan 'fileName')
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
            for ($index = 0; $index -lt $arguments.Count; $index++) {
                $candidate = [string]$arguments[$index]
                if ($candidate.EndsWith('codex.js', [StringComparison]::OrdinalIgnoreCase) -and
                    (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    $packageSource = Split-Path -Parent (Split-Path -Parent $candidate)
                    $nativePackages = @(Get-ChildItem -LiteralPath (Join-Path $packageSource 'node_modules\@openai') `
                        -Directory -Filter 'codex-win32-*' -ErrorAction SilentlyContinue | Where-Object {
                            @(Get-ChildItem -LiteralPath (Join-Path $_.FullName 'vendor') -Recurse -File `
                                -Filter 'codex.exe' -ErrorAction SilentlyContinue).Count -gt 0
                        })
                    if ($nativePackages.Count -eq 0) {
                        throw "Codex npm package is missing its Windows native runtime: $packageSource"
                    }
                    # Keep the installed package at its short canonical path.
                    # The outer sandbox grants this exact package read-only;
                    # mirroring it under a deep workspace can exceed MAX_PATH.
                    $arguments[$index] = [IO.Path]::GetFullPath($candidate)
                    $codexEntryFound = $true
                    $codexEntryIndex = $index
                    $codexPackageSource = [IO.Path]::GetFullPath($packageSource)
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
            $codexHome = Join-Path $runtimePath 'codex-home'
            New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
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

            $boundedAgentFlags = @('--disable', 'multi_agent', '--disable', 'multi_agent_v2')
            $sandboxBoundary = [string](Get-AiCliProperty $runtimeConfig 'sandboxBoundary' 'outer-codex')
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
                if ($execIndex -gt 0) {
                    $arguments[0..($execIndex - 1)]
                }
            )
            # Codex 0.145 accepts --profile for interactive/runtime commands,
            # but rejects it for app-server before initialize. Keep the
            # explicit -c provider/model overrides and disposable CODEX_HOME,
            # while removing only this runtime-only selector.
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
            $bridgeConfig = [ordered]@{
                fileName = [IO.Path]::GetFullPath($runtimeFileName)
                argumentList = @($appServerArguments)
                workingDirectory = $workspace
                sandboxBoundary = $sandboxBoundary
                sandboxPolicy = $Policy
                model = [string](Get-AiCliProperty $Plan 'model')
                minimumCliVersion = '0.145.0'
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
            $config = [ordered]@{
                '$schema' = 'https://opencode.ai/config.json'
                provider = [ordered]@{
                    aicli_ollama = [ordered]@{
                        npm = '@ai-sdk/openai-compatible'
                        name = 'AICLI local Ollama'
                        options = [ordered]@{ baseURL = $endpoint; apiKey = 'ollama' }
                        models = [ordered]@{ $model = [ordered]@{ name = $model } }
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
            ArgumentList = @($arguments)
            EnvironmentDelta = $environment
            StdInText = $effectiveStdIn
            UseOuterSandbox = $useOuterSandbox
            EventProtocol = $eventProtocol
            AdditionalReadRoots = @($additionalReadRoots)
            PrivateTaskPipeName = $privateTaskPipeName
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
        [Parameter(Mandatory)][string]$Workspace
    )
    if ([string]::IsNullOrWhiteSpace($RuntimePath) -or -not (Test-Path -LiteralPath $RuntimePath)) { return }
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
    Remove-Item -LiteralPath $resolvedRuntime -Recurse -Force
}
