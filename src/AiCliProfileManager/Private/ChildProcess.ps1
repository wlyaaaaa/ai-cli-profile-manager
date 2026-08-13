# ProcessStartInfo-based child launch: ArgumentList array, child-only env, no IEX.

function Get-AiCliExactSecretRepresentations {
    [CmdletBinding()]
    param([string[]]$SecretValues = @())

    $representations = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($secretValue in @($SecretValues)) {
        $secret = [string]$secretValue
        if ([string]::IsNullOrEmpty($secret)) { continue }
        $utf8Bytes = [Text.Encoding]::UTF8.GetBytes($secret)
        $utf8Base64 = [Convert]::ToBase64String($utf8Bytes)
        foreach ($representation in @(
            $secret,
            $utf8Base64,
            $utf8Base64.Replace('+', '-').Replace('/', '_'),
            $utf8Base64.TrimEnd('=').Replace('+', '-').Replace('/', '_'),
            [Convert]::ToHexString($utf8Bytes).ToLowerInvariant(),
            [Convert]::ToHexString($utf8Bytes),
            [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($secret))
        )) {
            if (-not [string]::IsNullOrEmpty([string]$representation)) {
                [void]$representations.Add([string]$representation)
            }
        }
    }
    return @($representations | Sort-Object Length -Descending)
}

function Protect-AiCliExactSecretValues {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [string[]]$SecretValues = @()
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $safe = $Text
    foreach ($representation in @(Get-AiCliExactSecretRepresentations `
        -SecretValues $SecretValues)) {
        $safe = $safe.Replace([string]$representation, '***REDACTED***')
    }
    return $safe
}

function New-AiCliProcessStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $null,
        [hashtable]$EnvironmentDelta = @{},
        [string[]]$RemoveEnvironment = @(),
        [switch]$RedirectStreams
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.UseShellExecute = $false
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    # Copy parent environment
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        try { $psi.Environment[$entry.Key] = [string]$entry.Value } catch {}
    }
    foreach ($name in $RemoveEnvironment) {
        if ($psi.Environment.ContainsKey($name)) {
            [void]$psi.Environment.Remove($name)
        }
    }
    foreach ($k in $EnvironmentDelta.Keys) {
        if ($null -eq $EnvironmentDelta[$k]) {
            if ($psi.Environment.ContainsKey($k)) { [void]$psi.Environment.Remove($k) }
        } else {
            $psi.Environment[$k] = [string]$EnvironmentDelta[$k]
        }
    }

    foreach ($a in $ArgumentList) {
        [void]$psi.ArgumentList.Add([string]$a)
    }

    if ($RedirectStreams) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
    } else {
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false
        $psi.RedirectStandardInput = $false
    }
    return $psi
}

function Start-AiCliChildProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$StartInfo,
        [switch]$Wait,
        [string]$SessionNote = $null
    )
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $StartInfo
    $started = $proc.Start()
    if (-not $started) { throw '无法启动子进程' }

    Register-AiCliActiveSession -Process $proc -Note $SessionNote

    if ($Wait) {
        try {
            $proc.WaitForExit()
            return $proc.ExitCode
        } finally {
            Unregister-AiCliActiveSession -ProcessId $proc.Id
            $proc.Dispose()
        }
    }
    return $proc
}

function ConvertTo-AiCliSandboxedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$Workspace,
        [ValidateSet('read-only','workspace-write')][string]$Policy = 'read-only',
        [string[]]$AdditionalReadRoots = @()
    )
    $workspacePath = [IO.Path]::GetFullPath($Workspace)
    if (-not (Test-Path -LiteralPath $workspacePath -PathType Container)) {
        throw "Sandbox workspace 不存在: $workspacePath"
    }
    # The sandbox binary and codex-resources directory are one atomic runtime.
    # Do not let an independently updated Desktop binary win by PATH/mtime:
    # the npm launcher supplies CODEX_MANAGED_PACKAGE_ROOT to its matching
    # native binary, which is how the setup helper is resolved.
    $codex = Resolve-AiCliLaunchExecutable -Name 'codex' -PreferNpmCodex
    if (-not $codex -or (Get-AiCliProperty $codex 'Kind') -ne 'npm-node') {
        throw 'Codex CLI npm sandbox runtime 不可用；machine run 拒绝切换到未绑定资源目录的 Codex。'
    }
    $sandboxHelper = [string](
        Get-AiCliProperty $codex 'SandboxHelperPath'
    )
    if (
        [string]::IsNullOrWhiteSpace($sandboxHelper) -or
        -not (Test-Path -LiteralPath $sandboxHelper -PathType Leaf)
    ) {
        throw 'Codex CLI npm sandbox runtime 缺少唯一匹配的 codex-windows-sandbox-setup.exe。'
    }
    $args = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @((Get-AiCliProperty $codex 'PrefixArgs') | ForEach-Object { $_ })) {
        [void]$args.Add([string]$arg)
    }
    $permissionProfile = if ($Policy -eq 'workspace-write') { ':workspace' } else { ':read-only' }
    foreach ($arg in @('sandbox', '-P', $permissionProfile, '-C', $workspacePath)) {
        [void]$args.Add([string]$arg)
    }
    $readRoots = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($FileName) + @($ArgumentList)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            if ([IO.Path]::IsPathRooted([string]$candidate) -and (Test-Path -LiteralPath ([string]$candidate) -PathType Leaf)) {
                $parent = [IO.Path]::GetFullPath((Split-Path -Parent ([string]$candidate)))
                if (-not $parent.StartsWith($workspacePath, [StringComparison]::OrdinalIgnoreCase) -and
                    -not $readRoots.Contains($parent)) {
                    $readRoots.Add($parent) | Out-Null
                }
                $codexPackageMarker = '\node_modules\@openai\codex\'
                $codexPackageIndex = $parent.IndexOf($codexPackageMarker, [StringComparison]::OrdinalIgnoreCase)
                if ($codexPackageIndex -gt 0) {
                    $packageRoot = $parent.Substring(0, $codexPackageIndex + $codexPackageMarker.Length - 1)
                    if (-not $readRoots.Contains($packageRoot)) { $readRoots.Add($packageRoot) | Out-Null }
                } else {
                    $nodeModulesMarker = '\node_modules\'
                    $markerIndex = $parent.IndexOf($nodeModulesMarker, [StringComparison]::OrdinalIgnoreCase)
                    if ($markerIndex -gt 0) {
                        $packageRoot = $parent.Substring(0, $markerIndex)
                        if (-not $readRoots.Contains($packageRoot)) { $readRoots.Add($packageRoot) | Out-Null }
                    }
                }
            }
        } catch {}
    }
    foreach ($candidate in @($AdditionalReadRoots)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            $root = [IO.Path]::GetFullPath([string]$candidate).TrimEnd('\')
            if ((Test-Path -LiteralPath $root -PathType Container) -and
                -not $root.StartsWith($workspacePath, [StringComparison]::OrdinalIgnoreCase) -and
                -not $readRoots.Contains($root)) {
                $readRoots.Add($root) | Out-Null
            }
        } catch {}
    }
    foreach ($root in $readRoots) {
        [void]$args.Add('--sandbox-state-readable-root')
        [void]$args.Add($root)
    }
    foreach ($arg in @('--sandbox-state-disable-network', '--', $FileName)) {
        [void]$args.Add([string]$arg)
    }
    foreach ($arg in $ArgumentList) { [void]$args.Add([string]$arg) }
    return [pscustomobject]@{
        FileName = [string](Get-AiCliProperty $codex 'FileName')
        ArgumentList = @($args.ToArray())
    }
}

function New-AiCliReadOnlyLauncher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$TargetFileName,
        [string[]]$TargetArgumentList = @()
    )
    $launcher = Join-Path $RuntimeRoot 'read-only-launcher.ps1'
    $escapedWorkingDirectory = ([IO.Path]::GetFullPath($WorkingDirectory)).Replace("'", "''")
    $escapedTarget = ([IO.Path]::GetFullPath($TargetFileName)).Replace("'", "''")
    $argumentJson = ConvertTo-Json -InputObject @($TargetArgumentList) -Compress
    $argumentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argumentJson))
    $body = @"
`$ErrorActionPreference = 'Stop'
`$argumentJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$argumentBase64'))
`$NativeArgs = @(`$argumentJson | ConvertFrom-Json)
Set-Location -LiteralPath '$escapedWorkingDirectory'
& '$escapedTarget' @NativeArgs
exit `$LASTEXITCODE
"@
    [IO.File]::WriteAllText($launcher, $body, [Text.UTF8Encoding]::new($false))
    return $launcher
}

function Stop-AiCliProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [ValidateSet('cancelled', 'timeout')][string]$Reason = 'cancelled'
    )

    $hookProperty = $Process.PSObject.Properties['AiCliBeforeProcessTreeStop']
    $beforeStopFailed = $false
    if ($hookProperty) {
        $hook = $hookProperty.Value
        if ($hook -and -not [bool]$hook.Invoked) {
            $hook.Invoked = $true
            $hook.Reason = $Reason
            try {
                & $hook.Action $Reason $Process
            } catch {
                $hook.Error = $_.Exception.GetType().FullName
                $beforeStopFailed = $true
            }
        }
    }

    try {
        if ($Process.HasExited) {
            # Once the root is gone, Windows no longer gives us a reliable tree
            # handle. Descendants may still own redirected pipes, so fail closed.
            return [pscustomobject]@{
                Attempted = $true
                Confirmed = $false
                Method = 'root-exited-before-tree-stop'
            }
        }
    } catch {}

    try {
        $Process.Kill($true)
        if ($Process.WaitForExit(5000)) {
            if ($beforeStopFailed) {
                return [pscustomobject]@{
                    Attempted = $true
                    Confirmed = $false
                    Method = 'before-stop-hook-failed'
                }
            }
            return [pscustomobject]@{ Attempted = $true; Confirmed = $true; Method = 'dotnet-kill-tree' }
        }
    } catch {}

    if ($IsWindows) {
        try {
            $taskkill = Get-Command taskkill.exe -ErrorAction Stop | Select-Object -First 1
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $taskkill.Source
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            foreach ($argument in @('/PID', [string]$Process.Id, '/T', '/F')) {
                [void]$psi.ArgumentList.Add($argument)
            }
            $killer = [System.Diagnostics.Process]::new()
            $killer.StartInfo = $psi
            [void]$killer.Start()
            [void]$killer.StandardOutput.ReadToEnd()
            [void]$killer.StandardError.ReadToEnd()
            $killer.WaitForExit()
            $taskkillExitCode = $killer.ExitCode
            $killer.Dispose()
            if ($taskkillExitCode -eq 0 -and $Process.WaitForExit(5000)) {
                if ($beforeStopFailed) {
                    return [pscustomobject]@{
                        Attempted = $true
                        Confirmed = $false
                        Method = 'before-stop-hook-failed'
                    }
                }
                return [pscustomobject]@{ Attempted = $true; Confirmed = $true; Method = 'taskkill-tree' }
            }
        } catch {}
    }

    try {
        if (-not $Process.HasExited) { $Process.Kill() }
        [void]$Process.WaitForExit(5000)
    } catch {}
    return [pscustomobject]@{
        Attempted = $true
        Confirmed = $false
        Method = if ($beforeStopFailed) { 'before-stop-hook-failed' } else { 'unconfirmed' }
    }
}

function Resolve-AiCliMachineEventFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not [IO.Path]::IsPathRooted($Path)) {
        throw 'Machine event file 必须是绝对路径。'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($full) -ine '.jsonl') {
        throw 'Machine event file 必须使用 .jsonl 扩展名。'
    }
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw 'Machine event file 的父目录必须已经存在。'
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $item.Length -ne 0) {
            throw 'Machine event file 必须是新的或空的普通文件。'
        }
    } else {
        [IO.File]::WriteAllBytes($full, [byte[]]::new(0))
    }
    return $full
}

function Test-AiCliPathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath($Root)
    )
    $relative = [IO.Path]::GetRelativePath($fullRoot, $fullPath)
    return (
        -not [IO.Path]::IsPathRooted($relative) -and
        $relative -ne '..' -and
        -not $relative.StartsWith(
            "..$([IO.Path]::DirectorySeparatorChar)",
            [StringComparison]::Ordinal
        ) -and
        -not $relative.StartsWith(
            "..$([IO.Path]::AltDirectorySeparatorChar)",
            [StringComparison]::Ordinal
        )
    )
}

function Get-AiCliPublicThreadId {
    param([object]$Value)

    $text = [string]$Value
    if ($text -match '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') {
        return $text.ToLowerInvariant()
    }
    return ''
}

function ConvertTo-AiCliSafeUsage {
    param([object]$Usage)

    $safe = [ordered]@{}
    if ($null -eq $Usage) { return $safe }

    foreach ($name in @(
        'input_tokens',
        'cached_input_tokens',
        'output_tokens',
        'reasoning_output_tokens',
        'total_tokens',
        'current_context_tokens',
        'context_window_tokens'
    )) {
        $value = Get-AiCliProperty $Usage $name
        if ($null -eq $value) { continue }
        $isInteger = (
            $value -is [sbyte] -or
            $value -is [byte] -or
            $value -is [int16] -or
            $value -is [uint16] -or
            $value -is [int32] -or
            $value -is [uint32] -or
            $value -is [int64] -or
            $value -is [uint64]
        )
        if (-not $isInteger) { continue }
        try {
            if ([decimal]$value -lt 0 -or [decimal]$value -gt [long]::MaxValue) {
                continue
            }
            $safe[$name] = [long]$value
        } catch {}
    }
    return $safe
}

function ConvertTo-AiCliBoundedInteger {
    param(
        [object]$Value,
        [long]$Minimum,
        [long]$Maximum
    )

    $isInteger = (
        $Value -is [sbyte] -or
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    )
    if (-not $isInteger) { return $null }
    try {
        if (
            [decimal]$Value -lt [decimal]$Minimum -or
            [decimal]$Value -gt [decimal]$Maximum
        ) {
            return $null
        }
        return [long]$Value
    } catch {
        return $null
    }
}

function Merge-AiCliSafeRunUsage {
    param(
        [object]$TurnUsage,
        [object]$ContextUsage
    )

    $safe = [ordered]@{}
    $turn = ConvertTo-AiCliSafeUsage $TurnUsage
    foreach ($name in @(
        'input_tokens',
        'cached_input_tokens',
        'output_tokens',
        'reasoning_output_tokens',
        'total_tokens'
    )) {
        if ($turn.Contains($name)) { $safe[$name] = $turn[$name] }
    }
    $context = ConvertTo-AiCliSafeUsage $ContextUsage
    foreach ($name in @('current_context_tokens','context_window_tokens')) {
        if ($context.Contains($name)) { $safe[$name] = $context[$name] }
    }
    return $safe
}

function Write-AiCliMachineEvent {
    param(
        [Parameter(Mandatory)][IO.FileStream]$Stream,
        [Parameter(Mandatory)][ref]$Sequence,
        [Parameter(Mandatory)][string]$Kind,
        [hashtable]$Data = @{},
        [string[]]$SecretValues = @()
    )

    $nextSequence = [int]$Sequence.Value + 1
    $value = [ordered]@{
        schema = 'aicli.machine-event.v1'
        sequence = $nextSequence
        occurred_utc = (Get-Date).ToUniversalTime().ToString('o')
        kind = $Kind
    }
    foreach ($key in $Data.Keys) {
        $value[[string]$key] = $Data[$key]
    }
    try {
        $json = Protect-AiCliExactSecretValues `
            -Text ($value | ConvertTo-Json -Depth 10 -Compress) `
            -SecretValues $SecretValues
        $encoded = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
        $Stream.Write($encoded, 0, $encoded.Length)
        $Stream.Flush()
        $Sequence.Value = $nextSequence
        return $true
    } catch {
        return $false
    }
}

function Copy-AiCliMachineParentEnvironment {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.ProcessStartInfo]$StartInfo
    )

    # Machine children may execute tools and make provider requests. Rebuild
    # their inherited environment from a small runtime allowlist so unrelated
    # credentials and parent-only configuration cannot reach Codex/Node logs.
    $allowedNames = @(
        'ALLUSERSPROFILE',
        'APPDATA',
        'CommonProgramFiles',
        'CommonProgramFiles(x86)',
        'CommonProgramW6432',
        'ComSpec',
        'DOTNET_ROOT',
        'DOTNET_ROOT(x86)',
        'HOMEDRIVE',
        'HOMEPATH',
        'LANG',
        'LC_ALL',
        'LC_CTYPE',
        'LOCALAPPDATA',
        'NODE_EXTRA_CA_CERTS',
        'NUMBER_OF_PROCESSORS',
        'OS',
        'Path',
        'PATHEXT',
        'PROCESSOR_ARCHITECTURE',
        'PROCESSOR_ARCHITEW6432',
        'ProgramData',
        'ProgramFiles',
        'ProgramFiles(x86)',
        'ProgramW6432',
        'PSModulePath',
        'SSL_CERT_DIR',
        'SSL_CERT_FILE',
        'SystemDrive',
        'SystemRoot',
        'TEMP',
        'TMP',
        'USERPROFILE',
        'windir'
    )
    $blockedDebugNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in @(
        'CODEX_LOG',
        'CODEX_LOG_LEVEL',
        'NODE_DEBUG',
        'NODE_DEBUG_NATIVE',
        'NODE_OPTIONS',
        'RUST_BACKTRACE',
        'RUST_LIB_BACKTRACE',
        'RUST_LOG',
        'RUST_LOG_STYLE'
    )) {
        [void]$blockedDebugNames.Add($name)
    }

    $StartInfo.Environment.Clear()
    foreach ($name in $allowedNames) {
        if ($blockedDebugNames.Contains($name)) { continue }
        $value = [Environment]::GetEnvironmentVariable(
            $name,
            [EnvironmentVariableTarget]::Process
        )
        if ($null -ne $value) {
            $StartInfo.Environment[$name] = $value
        }
    }
}

function Invoke-AiCliChildCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [hashtable]$EnvironmentDelta = @{},
        [string[]]$RemoveEnvironment = @(),
        [string]$WorkingDirectory = $null,
        [int]$TimeoutMs = 120000,
        [int]$MaxCaptureChars = 1000000,
        [string]$SandboxWorkspace = $null,
        [ValidateSet('read-only','workspace-write')][string]$SandboxPolicy = 'read-only',
        [switch]$CloseStdIn,
        [string]$StdInText = $null,
        [ValidateSet('none','codex-jsonl','codex-app-server')][string]$EventProtocol = 'none',
        [int]$MaxSteps = 20,
        [int]$MaxToolCalls = 80,
        [switch]$EnforceStepLimit,
        [switch]$EnforceToolCallLimit,
        [switch]$WatchdogOnly,
        [string]$MachineEventFile = $null,
        [string]$WritableWorkspace = $null,
        [string]$PrivateTaskPipeName = $null,
        [string[]]$AdditionalSandboxReadRoots = @(),
        [scriptblock]$BeforeProcessTreeStop = $null,
        $AuthorityMachineEvent = $null,
        [string[]]$SecretValues = @(),
        [switch]$RequireRuntimeIdentity,
        [string]$ExpectedRuntimeModel = '',
        [string]$ExpectedRuntimeModelProvider = ''
    )
    $enforceStepLimitEffective = if ($PSBoundParameters.ContainsKey('EnforceStepLimit')) {
        [bool]$EnforceStepLimit
    } else {
        $true
    }
    $enforceToolCallLimitEffective = if ($PSBoundParameters.ContainsKey('EnforceToolCallLimit')) {
        [bool]$EnforceToolCallLimit
    } else {
        $true
    }
    if ($WatchdogOnly) {
        $enforceStepLimitEffective = $false
        $enforceToolCallLimitEffective = $false
    }
    $isCodexEventProtocol = $EventProtocol -in @('codex-jsonl','codex-app-server')
    if ($RequireRuntimeIdentity -and (
        -not $isCodexEventProtocol -or
        $ExpectedRuntimeModel -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,127}$' -or
        $ExpectedRuntimeModelProvider -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
    )) {
        throw 'Required Codex runtime identity has no valid trusted expectation.'
    }
    $privateTaskPipeRequested = -not [string]::IsNullOrWhiteSpace($PrivateTaskPipeName)
    if ($privateTaskPipeRequested) {
        if ($EventProtocol -ne 'codex-app-server' -or
            $PrivateTaskPipeName -notmatch '^aicli-[a-f0-9]{32}$' -or
            [string]::IsNullOrWhiteSpace($StdInText)) {
            throw 'Private task pipe requires a non-empty Codex app-server task and a valid generated name.'
        }
    }
    $machineEventRequested = -not [string]::IsNullOrWhiteSpace($MachineEventFile)
    $resolvedMachineEventFile = if ($machineEventRequested -and $isCodexEventProtocol) {
        Resolve-AiCliMachineEventFile -Path $MachineEventFile
    } else {
        $null
    }
    $effectiveWritableWorkspace = if ($WritableWorkspace) {
        $WritableWorkspace
    } elseif ($SandboxPolicy -eq 'workspace-write') {
        $SandboxWorkspace
    } else {
        $null
    }
    if (
        $resolvedMachineEventFile -and
        $SandboxPolicy -eq 'workspace-write' -and
        $effectiveWritableWorkspace -and
        (Test-AiCliPathWithinRoot -Path $resolvedMachineEventFile -Root $effectiveWritableWorkspace)
    ) {
        throw 'Machine event file 不能位于子智能体可写 workspace 内。'
    }
    $machineEventProjection = if ($resolvedMachineEventFile) {
        'aicli.machine-event.v1'
    } else {
        'disabled'
    }
    $machineEventStatus = if ($resolvedMachineEventFile) {
        'ok'
    } elseif ($machineEventRequested) {
        'unsupported'
    } else {
        'disabled'
    }
    if ($null -ne $AuthorityMachineEvent) {
        if (-not $resolvedMachineEventFile) {
            throw 'Authority machine event requires the persistent Codex machine-event channel.'
        }
        $null = Assert-AiCliLocalGpuBrokerBindingObservation `
            -Observation $AuthorityMachineEvent
    }
    $machineEventSequence = 0
    $machineEventStream = $null
    $machineTerminalEventWritten = $false
    # Redirect to temp files — avoids pipe-buffer deadlock when CLI dumps large logs (e.g. models list)
    $outFile = Join-Path ([IO.Path]::GetTempPath()) ("aicli-out-" + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ("aicli-err-" + [guid]::NewGuid().ToString('N') + '.txt')
    $effectiveFileName = $FileName
    $effectiveArgs = @($ArgumentList)
    if (-not [string]::IsNullOrWhiteSpace($SandboxWorkspace)) {
        $additionalReadRoots = @(
            @('TEMP','TMP','CODEX_HOME','QWEN_HOME','OPENCODE_CONFIG_DIR','XDG_CONFIG_HOME','XDG_DATA_HOME','XDG_CACHE_HOME','XDG_STATE_HOME') |
                ForEach-Object { if ($EnvironmentDelta.ContainsKey($_)) { [string]$EnvironmentDelta[$_] } }
        ) + @($AdditionalSandboxReadRoots)
        $sandboxRoot = $SandboxWorkspace
        $sandboxMode = $SandboxPolicy
        if ($SandboxPolicy -eq 'read-only') {
            $runtimeTemp = [string]$EnvironmentDelta['TEMP']
            if ([string]::IsNullOrWhiteSpace($runtimeTemp)) {
                throw 'Read-only machine run requires an isolated runtime TEMP directory.'
            }
            $runtimeRoot = [IO.Path]::GetFullPath((Split-Path -Parent $runtimeTemp))
            $launcher = New-AiCliReadOnlyLauncher -RuntimeRoot $runtimeRoot `
                -WorkingDirectory $SandboxWorkspace -TargetFileName $FileName -TargetArgumentList $ArgumentList
            $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if (-not $pwsh) { throw 'PowerShell 7 is required for read-only machine runs.' }
            $additionalReadRoots += @($SandboxWorkspace, (Split-Path -Parent ([IO.Path]::GetFullPath($FileName))))
            foreach ($candidate in @($ArgumentList)) {
                if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
                try {
                    if ([IO.Path]::IsPathRooted([string]$candidate) -and
                        (Test-Path -LiteralPath ([string]$candidate) -PathType Leaf)) {
                        $additionalReadRoots += (Split-Path -Parent ([IO.Path]::GetFullPath([string]$candidate)))
                    }
                } catch {}
            }
            $effectiveFileName = $pwsh
            $effectiveArgs = @('-NoProfile','-File',$launcher)
            $sandboxRoot = $runtimeRoot
            # The disposable runtime is writable; the caller workspace is added
            # only as a readable root, so the untrusted child cannot modify it.
            $sandboxMode = 'workspace-write'
        }
        $wrapped = ConvertTo-AiCliSandboxedCommand -FileName $effectiveFileName -ArgumentList $effectiveArgs `
            -Workspace $sandboxRoot -Policy $sandboxMode -AdditionalReadRoots $additionalReadRoots
        $effectiveFileName = $wrapped.FileName
        $effectiveArgs = @($wrapped.ArgumentList)
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $effectiveFileName
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding = $utf8NoBom
    $psi.StandardOutputEncoding = $utf8NoBom
    $psi.StandardErrorEncoding = $utf8NoBom
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $isMachineChildCapture = -not [string]::IsNullOrWhiteSpace(
        $WritableWorkspace
    )
    if ($isMachineChildCapture) {
        Copy-AiCliMachineParentEnvironment -StartInfo $psi
    } else {
        foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
            try { $psi.Environment[$entry.Key] = [string]$entry.Value } catch {}
        }
    }
    foreach ($name in $RemoveEnvironment) {
        if ($psi.Environment.ContainsKey($name)) { [void]$psi.Environment.Remove($name) }
    }
    if ($psi.Environment.ContainsKey('AICLI_MACHINE_EVENT_FILE')) {
        [void]$psi.Environment.Remove('AICLI_MACHINE_EVENT_FILE')
    }
    if ($psi.Environment.ContainsKey('AICLI_CODEX_BRIDGE_TASK_PIPE')) {
        [void]$psi.Environment.Remove('AICLI_CODEX_BRIDGE_TASK_PIPE')
    }
    if ($EnvironmentDelta) {
        foreach ($k in $EnvironmentDelta.Keys) {
            if ($null -eq $EnvironmentDelta[$k]) {
                if ($psi.Environment.ContainsKey($k)) { [void]$psi.Environment.Remove($k) }
            } else {
                $psi.Environment[$k] = [string]$EnvironmentDelta[$k]
            }
        }
    }
    if ($privateTaskPipeRequested) {
        $psi.Environment['AICLI_CODEX_BRIDGE_TASK_PIPE'] = $PrivateTaskPipeName
    }
    foreach ($a in $effectiveArgs) { [void]$psi.ArgumentList.Add([string]$a) }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    if ($BeforeProcessTreeStop) {
        $proc | Add-Member -NotePropertyName AiCliBeforeProcessTreeStop `
            -NotePropertyValue ([pscustomobject]@{
                Invoked = $false
                Reason = $null
                Error = $null
                Action = $BeforeProcessTreeStop
            })
    }
    $processStarted = $false
    $privateTaskPipe = $null
    $privateTaskWriter = $null
    if ($privateTaskPipeRequested) {
        $pipeOptions = [IO.Pipes.PipeOptions]::Asynchronous
        $pipeSecurity = [IO.Pipes.PipeSecurity]::new()
        $pipeSecurity.SetAccessRuleProtection($true, $false)
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $pipeSecurity.AddAccessRule([IO.Pipes.PipeAccessRule]::new(
            $currentSid,
            [IO.Pipes.PipeAccessRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        ))
        if (-not [string]::IsNullOrWhiteSpace($SandboxWorkspace)) {
            try {
                $sandboxAccount = [Security.Principal.NTAccount]::new(
                    "$env:USERDOMAIN\CodexSandboxOffline"
                )
                $sandboxSid = $sandboxAccount.Translate(
                    [Security.Principal.SecurityIdentifier]
                )
                $pipeSecurity.AddAccessRule([IO.Pipes.PipeAccessRule]::new(
                    $sandboxSid,
                    [IO.Pipes.PipeAccessRights]::ReadWrite,
                    [Security.AccessControl.AccessControlType]::Allow
                ))
            } catch {
                throw 'Codex offline sandbox identity is unavailable for private task transport.'
            }
        }
        $privateTaskPipe = [IO.Pipes.NamedPipeServerStreamAcl]::Create(
            $PrivateTaskPipeName,
            [IO.Pipes.PipeDirection]::Out,
            1,
            [IO.Pipes.PipeTransmissionMode]::Byte,
            $pipeOptions,
            4096,
            4096,
            $pipeSecurity,
            [IO.HandleInheritability]::None,
            [IO.Pipes.PipeAccessRights]0
        )
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stepCount = 0
    $toolCallCount = 0
    $eventsSeen = 0
    $limitHit = $null
    $protocolValid = $true
    $protocolError = ''
    $protocolErrorCode = ''
    $outputTruncated = $false
    $safeStdOut = [Text.StringBuilder]::new()
    $seenSteps = @{}
    $seenTools = @{}
    $stdoutTask = $null
    $stderrTask = $null
    $upstreamFailed = $false
    $terminalUpstreamFailed = $false
    $recoverableUpstreamErrorSeen = $false
    $lastRecoverableErrorEvent = 0
    $lastCompletedTurnEvent = 0
    $lastFinalMessageEvent = 0
    $safeTurnUsage = [ordered]@{}
    $safeContextUsage = [ordered]@{}
    $runtimeIdentity = $null
    $compactionCount = 0
    $upstreamFailureSummary = 'Codex reported an upstream failure.'
    $termination = [pscustomobject]@{ Attempted = $false; Confirmed = $true; Method = 'none' }
    $knownEventTypes = @(
        'thread.started',
        'runtime.identity',
        'turn.started',
        'turn.completed',
        'turn.failed',
        'item.started',
        'item.updated',
        'item.completed',
        'context.usage.updated',
        'bridge.failed',
        'cleanup.failed',
        'error'
    )
    $knownBridgeErrorCodes = @(
        'codex_appserver.setup_failed',
        'codex_appserver.initialize_failed',
        'codex_appserver.initialize_rejected',
        'codex_appserver.thread_start_failed',
        'codex_appserver.thread_start_rejected',
        'codex_appserver.turn_start_failed',
        'codex_appserver.turn_start_rejected',
        'codex_appserver.turn_stream_failed',
        'codex_appserver.stream_closed',
        'codex_appserver.protocol_line_invalid',
        'codex_appserver.response_id_invalid',
        'codex_appserver.response_after_turn_unexpected',
        'codex_appserver.version_unsupported',
        'codex_appserver.workspace_write_unavailable',
        'codex_appserver.runtime_identity_missing',
        'codex_appserver.runtime_identity_mismatch',
        'codex_appserver.notification_unknown',
        'codex_appserver.notification_scope_invalid',
        'codex_appserver.turn_status_invalid',
        'codex_appserver.context_usage_incomplete',
        'codex_appserver.item_lifecycle_invalid',
        'codex_appserver.item_identity_invalid',
        'codex_appserver.item_started_duplicate',
        'codex_appserver.item_started_unexpected',
        'codex_appserver.item_completed_without_start',
        'codex_appserver.item_type_changed',
        'codex_appserver.item_completed_duplicate',
        'codex_appserver.item_unfinished',
        'codex_appserver.command_status_invalid',
        'codex_appserver.command_metric_invalid',
        'codex_appserver.server_request_unsupported',
        'codex_appserver.cleanup_unconfirmed',
        'codex_appserver.failure_code_invalid'
    )
    $knownItemTypes = @(
        'user_message',
        'hook_prompt',
        'agent_message',
        'reasoning',
        'command_execution',
        'file_change',
        'mcp_tool_call',
        'collab_tool_call',
        'sub_agent_activity',
        'web_search',
        'todo_list',
        'image_view',
        'sleep',
        'image_generation',
        'entered_review_mode',
        'exited_review_mode',
        'context_compaction',
        'error',
        # Accepted compatibility tool events remain conservatively charged.
        'tool_call',
        'dynamic_tool_call',
        'computer_use'
    )
    $toolItemTypes = @(
        'command_execution',
        'file_change',
        'mcp_tool_call',
        'collab_tool_call',
        'sub_agent_activity',
        'tool_call',
        'dynamic_tool_call',
        'web_search',
        'computer_use',
        'image_view',
        'sleep',
        'image_generation'
    )
    try {
        if ($resolvedMachineEventFile) {
            $machineEventStream = [IO.FileStream]::new(
                $resolvedMachineEventFile,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Write,
                [IO.FileShare]::Read
            )
            $machineEventStream.SetLength(0)
            $machineEventStream.Position = 0
        }
        if ($null -ne $AuthorityMachineEvent -and -not (
            Write-AiCliMachineEvent -Stream $machineEventStream `
                -Sequence ([ref]$machineEventSequence) `
                -Kind 'local-gpu-broker.binding' `
                -Data @{ binding_observation = $AuthorityMachineEvent } `
                -SecretValues $SecretValues
        )) {
            throw 'LocalGpuBroker authority binding observation could not be persisted.'
        }
        [void]$proc.Start()
        $processStarted = $true
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        try {
            if ($privateTaskPipeRequested) {
                $proc.StandardInput.Close()
                $connectTask = $privateTaskPipe.WaitForConnectionAsync()
                while (-not $connectTask.IsCompleted) {
                    $remainingPipeMs = $TimeoutMs - [int]$stopwatch.ElapsedMilliseconds
                    if ($remainingPipeMs -le 0) {
                        $termination = Stop-AiCliProcessTree -Process $proc -Reason timeout
                        throw [System.TimeoutException]::new(
                            "Private task pipe timed out (${TimeoutMs}ms): $FileName"
                        )
                    }
                    if ($proc.HasExited) {
                        $termination = Stop-AiCliProcessTree -Process $proc
                        throw 'Codex bridge exited before connecting to its private task pipe.'
                    }
                    [void]$connectTask.Wait([Math]::Min(50, $remainingPipeMs))
                }
                [void]$connectTask.GetAwaiter().GetResult()
                $privateTaskWriter = [IO.StreamWriter]::new(
                    $privateTaskPipe,
                    [Text.UTF8Encoding]::new($false),
                    4096,
                    $true
                )
                $writeTask = $privateTaskWriter.WriteAsync($StdInText)
                while (-not $writeTask.IsCompleted) {
                    $remainingPipeMs = $TimeoutMs - [int]$stopwatch.ElapsedMilliseconds
                    if ($remainingPipeMs -le 0) {
                        $termination = Stop-AiCliProcessTree -Process $proc -Reason timeout
                        throw [System.TimeoutException]::new(
                            "Private task pipe timed out (${TimeoutMs}ms): $FileName"
                        )
                    }
                    [void]$writeTask.Wait([Math]::Min(50, $remainingPipeMs))
                }
                [void]$writeTask.GetAwaiter().GetResult()
                $privateTaskWriter.Flush()
                $privateTaskWriter.Dispose()
                $privateTaskWriter = $null
                $privateTaskPipe.Dispose()
                $privateTaskPipe = $null
            } elseif (-not [string]::IsNullOrEmpty($StdInText)) {
                $proc.StandardInput.Write($StdInText)
                if (-not $StdInText.EndsWith("`n")) {
                    $proc.StandardInput.WriteLine()
                }
                $proc.StandardInput.Close()
            } else {
                $proc.StandardInput.Close()
            }
        } catch {
            if ($privateTaskPipeRequested) {
                if (-not $termination.Attempted) {
                    $termination = Stop-AiCliProcessTree -Process $proc
                }
                throw
            }
        }

        if ($isCodexEventProtocol) {
            while ($true) {
                if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMs) {
                    $termination = Stop-AiCliProcessTree -Process $proc -Reason timeout
                    throw [System.TimeoutException]::new("子进程超时 (${TimeoutMs}ms): $FileName")
                }
                $readTask = $proc.StandardOutput.ReadLineAsync()
                while (-not $readTask.IsCompleted) {
                    $remainingReadMs = $TimeoutMs - [int]$stopwatch.ElapsedMilliseconds
                    if ($remainingReadMs -le 0) {
                        $termination = Stop-AiCliProcessTree -Process $proc -Reason timeout
                        throw [System.TimeoutException]::new("子进程超时 (${TimeoutMs}ms): $FileName")
                    }
                    [void]$readTask.Wait([Math]::Min(50, $remainingReadMs))
                }
                $line = $readTask.GetAwaiter().GetResult()
                if ($null -eq $line) { break }
                if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
                $eventsSeen++

                try {
                    $event = $line | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
                } catch {
                    $protocolValid = $false
                    $protocolError = 'Codex emitted a non-JSON event line.'
                    $termination = Stop-AiCliProcessTree -Process $proc
                    if (-not $termination.Confirmed) {
                        $protocolError += ' Process-tree cleanup could not be confirmed.'
                    }
                    break
                }
                $eventType = [string](Get-AiCliProperty $event 'type')
                $item = Get-AiCliProperty $event 'item'
                $itemType = if ($item) { [string](Get-AiCliProperty $item 'type') } else { '' }
                if ($eventType -notin $knownEventTypes) {
                    $protocolValid = $false
                    $protocolError = "Codex emitted an unknown event type: $eventType."
                    $termination = Stop-AiCliProcessTree -Process $proc
                    if (-not $termination.Confirmed) {
                        $protocolError += ' Process-tree cleanup could not be confirmed.'
                    }
                    break
                }
                if ($eventType -eq 'bridge.failed') {
                    $bridgeErrorCode = [string](
                        Get-AiCliProperty $event 'error_code'
                    )
                    $bridgeFailureItemType = [string](
                        Get-AiCliProperty $event 'item_type'
                    )
                    if ($bridgeFailureItemType -notin $knownItemTypes) {
                        $bridgeFailureItemType = ''
                    }
                    if ($bridgeErrorCode -notin $knownBridgeErrorCodes) {
                        $bridgeErrorCode = 'codex_appserver.failure_code_invalid'
                    }
                    $protocolValid = $false
                    if ([string]::IsNullOrWhiteSpace($protocolErrorCode)) {
                        $protocolErrorCode = $bridgeErrorCode
                        $protocolError = (
                            'Codex app-server protocol validation failed (' +
                            $bridgeErrorCode +
                            ').'
                        )
                    }
                }
                if ($RequireRuntimeIdentity -and $protocolValid -and
                    $null -eq $runtimeIdentity -and
                    $eventType -notin @('runtime.identity', 'bridge.failed')) {
                    $protocolValid = $false
                    $protocolErrorCode = 'codex_appserver.runtime_identity_missing'
                    $protocolError = 'Codex app-server runtime identity is missing.'
                    $termination = Stop-AiCliProcessTree -Process $proc
                    break
                }
                if ($eventType -eq 'runtime.identity') {
                    $identityModel = [string](Get-AiCliProperty $event 'model')
                    $identityProvider = [string](Get-AiCliProperty $event 'model_provider')
                    $identityCliVersion = [string](Get-AiCliProperty $event 'cli_version')
                    $identityPermission = Get-AiCliProperty $event 'permission'
                    if ($null -ne $runtimeIdentity -or
                        $identityModel -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,127}$' -or
                        $identityProvider -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or
                        ($RequireRuntimeIdentity -and (
                            $identityModel -cne $ExpectedRuntimeModel -or
                            $identityProvider -cne $ExpectedRuntimeModelProvider
                        )) -or
                        [string](Get-AiCliProperty $identityPermission 'approval_policy') -ne 'never' -or
                        [string](Get-AiCliProperty $identityPermission 'requested_policy') -notin @('read-only','workspace-write') -or
                        [string](Get-AiCliProperty $identityPermission 'sandbox_boundary') -notin @('outer-codex','codex-native') -or
                        [string](Get-AiCliProperty $identityPermission 'sandbox_type') -notin @('readOnly','workspaceWrite','externalSandbox')) {
                        $protocolValid = $false
                        $protocolErrorCode = 'codex_appserver.runtime_identity_mismatch'
                        $protocolError = 'Codex app-server runtime identity is invalid.'
                        $termination = Stop-AiCliProcessTree -Process $proc
                        break
                    }
                    $runtimeIdentity = [ordered]@{
                        model = $identityModel
                        model_provider = $identityProvider
                        cli_version = $identityCliVersion
                        permission = [ordered]@{
                            approval_policy = 'never'
                            requested_policy = [string](Get-AiCliProperty $identityPermission 'requested_policy')
                            sandbox_boundary = [string](Get-AiCliProperty $identityPermission 'sandbox_boundary')
                            sandbox_type = [string](Get-AiCliProperty $identityPermission 'sandbox_type')
                            permission_profile = [string](Get-AiCliProperty $identityPermission 'permission_profile')
                        }
                    }
                }
                if ($eventType -eq 'cleanup.failed') {
                    $protocolValid = $false
                    if ([string]::IsNullOrWhiteSpace($protocolErrorCode)) {
                        $protocolErrorCode = 'codex_appserver.cleanup_unconfirmed'
                        $protocolError = (
                            'Codex app-server process-tree cleanup could not be confirmed.'
                        )
                    }
                    $termination = Stop-AiCliProcessTree -Process $proc
                    if (-not $termination.Confirmed) {
                        $protocolError += ' Parent process-tree cleanup could not be confirmed.'
                    }
                    break
                }
                $isItemEvent = $eventType -in @('item.started','item.updated','item.completed')
                if ($isItemEvent) {
                    if (-not $item -or $itemType -notin $knownItemTypes) {
                        $protocolValid = $false
                        $protocolError = if ([string]::IsNullOrWhiteSpace($itemType)) {
                            'Codex emitted an item event without a known item type.'
                        } else {
                            "Codex emitted an unknown item type: $itemType."
                        }
                        $termination = Stop-AiCliProcessTree -Process $proc
                        if (-not $termination.Confirmed) {
                            $protocolError += ' Process-tree cleanup could not be confirmed.'
                        }
                        break
                    }
                    $itemId = [string](Get-AiCliProperty $item 'id')
                    if ([string]::IsNullOrWhiteSpace($itemId)) {
                        $protocolValid = $false
                        $protocolError = "Codex emitted $itemType without the required item id."
                        $termination = Stop-AiCliProcessTree -Process $proc
                        if (-not $termination.Confirmed) {
                            $protocolError += ' Process-tree cleanup could not be confirmed.'
                        }
                        break
                    }
                    $stepKey = if ($itemType -eq 'sub_agent_activity') {
                        "point:$itemId"
                    } else {
                        "item:$itemId"
                    }
                    # Public agent messages are observable output, not execution
                    # actions. Counting them against maxSteps makes the requested
                    # progress stream consume the budget needed to finish work.
                    if (
                        $itemType -ne 'agent_message' -and
                        -not $seenSteps.ContainsKey($stepKey)
                    ) {
                        $seenSteps[$stepKey] = $true
                        $stepCount++
                    }
                    if ($itemType -in $toolItemTypes -and -not $seenTools.ContainsKey($stepKey)) {
                        $seenTools[$stepKey] = $true
                        $toolCallCount++
                    }
                    if ($itemType -eq 'collab_tool_call') {
                        $protocolValid = $false
                        $protocolError = 'Codex emitted a collab call although multi-agent is disabled.'
                        $termination = Stop-AiCliProcessTree -Process $proc
                        if (-not $termination.Confirmed) {
                            $protocolError += ' Process-tree cleanup could not be confirmed.'
                        }
                        break
                    }
                }

                $isTerminalUpstreamFailureEvent = $eventType -eq 'turn.failed'
                $isRecoverableUpstreamErrorEvent = (
                    $eventType -eq 'error' -or
                    ($isItemEvent -and $itemType -eq 'error')
                )
                if ($isTerminalUpstreamFailureEvent) {
                    $terminalUpstreamFailed = $true
                } elseif ($isRecoverableUpstreamErrorEvent) {
                    $recoverableUpstreamErrorSeen = $true
                    $lastRecoverableErrorEvent = $eventsSeen
                }
                if ($eventType -eq 'turn.completed') {
                    $lastCompletedTurnEvent = $eventsSeen
                    $completedUsage = ConvertTo-AiCliSafeUsage (
                        Get-AiCliProperty $event 'usage'
                    )
                    $safeTurnUsage = [ordered]@{}
                    foreach ($name in @(
                        'input_tokens',
                        'cached_input_tokens',
                        'output_tokens',
                        'reasoning_output_tokens',
                        'total_tokens'
                    )) {
                        if ($completedUsage.Contains($name)) {
                            $safeTurnUsage[$name] = $completedUsage[$name]
                        }
                    }
                    foreach ($name in @('current_context_tokens','context_window_tokens')) {
                        if ($completedUsage.Contains($name)) {
                            $safeContextUsage[$name] = $completedUsage[$name]
                        }
                    }
                } elseif ($eventType -eq 'context.usage.updated') {
                    $contextUpdate = ConvertTo-AiCliSafeUsage (
                        Get-AiCliProperty $event 'usage'
                    )
                    foreach ($name in @('current_context_tokens','context_window_tokens')) {
                        if ($contextUpdate.Contains($name)) {
                            $safeContextUsage[$name] = $contextUpdate[$name]
                        }
                    }
                } elseif ($eventType -eq 'item.completed' -and $itemType -eq 'agent_message') {
                    $lastFinalMessageEvent = $eventsSeen
                }

                # Only pass through the public thread identifier and public agent
                # messages. Commands, tool results, and reasoning items are counted
                # in memory where needed, then discarded rather than persisted.
                $safeEvent = $null
                if ($eventType -eq 'thread.started') {
                    $publicThreadId = Get-AiCliPublicThreadId (
                        Get-AiCliProperty $event 'thread_id'
                    )
                    $safeEvent = [ordered]@{
                        type = 'thread.started'
                        thread_id = $publicThreadId
                    }
                }
                elseif ($eventType -eq 'item.completed' -and $itemType -eq 'agent_message') {
                    $safeEvent = [ordered]@{
                        type = 'item.completed'
                        item = [ordered]@{
                            type = 'agent_message'
                            text = Protect-AiCliExactSecretValues `
                                -Text ([string](Get-AiCliProperty $item 'text')) `
                                -SecretValues $SecretValues
                        }
                    }
                }
                if ($safeEvent -and -not $terminalUpstreamFailed) {
                    $safeLine = $safeEvent | ConvertTo-Json -Depth 10 -Compress
                    $separatorLength = if ($safeStdOut.Length -gt 0) { 1 } else { 0 }
                    if ($MaxCaptureChars -le 0 -or
                        ($safeStdOut.Length + $separatorLength + $safeLine.Length) -le $MaxCaptureChars) {
                        if ($safeStdOut.Length -gt 0) { [void]$safeStdOut.Append("`n") }
                        [void]$safeStdOut.Append($safeLine)
                    } else {
                        $outputTruncated = $true
                    }
                }

                if ($machineEventStatus -eq 'ok' -and -not $machineTerminalEventWritten) {
                    $machineEvent = $null
                    if ($eventType -eq 'thread.started') {
                        $machineEvent = @{
                            Kind = 'thread.started'
                            Data = @{
                                thread_id = $publicThreadId
                            }
                        }
                    } elseif ($eventType -eq 'runtime.identity') {
                        $machineEvent = @{
                            Kind = 'runtime.identity'
                            Data = @{
                                model = $runtimeIdentity.model
                                provider_id = $runtimeIdentity.model_provider
                                cli_version = $runtimeIdentity.cli_version
                                approval_policy = $runtimeIdentity.permission.approval_policy
                                sandbox_policy = $runtimeIdentity.permission.requested_policy
                                sandbox_boundary = $runtimeIdentity.permission.sandbox_boundary
                                sandbox_type = $runtimeIdentity.permission.sandbox_type
                            }
                        }
                    } elseif ($eventType -eq 'bridge.failed') {
                        $failureData = @{
                            status = 'failed'
                            error_category = 'protocol_or_process_failure'
                            error_code = $protocolErrorCode
                            steps = $stepCount
                            tool_calls = $toolCallCount
                            events_seen = $eventsSeen
                        }
                        if (-not [string]::IsNullOrWhiteSpace($bridgeFailureItemType)) {
                            $failureData['item_type'] = $bridgeFailureItemType
                        }
                        $machineEvent = @{
                            Kind = 'run.failed'
                            Data = $failureData
                        }
                    } elseif ($isTerminalUpstreamFailureEvent) {
                        $machineEvent = @{
                            Kind = 'run.failed'
                            Data = @{
                                status = 'failed'
                                error_category = 'upstream_error'
                                steps = $stepCount
                                tool_calls = $toolCallCount
                                events_seen = $eventsSeen
                            }
                        }
                    } elseif ($eventType -in @('turn.started','turn.completed')) {
                        $turnData = @{
                            status = $eventType.Substring(5)
                            steps = $stepCount
                            tool_calls = $toolCallCount
                            events_seen = $eventsSeen
                        }
                        if ($eventType -eq 'turn.completed') {
                            $turnData['usage'] = $safeTurnUsage
                        }
                        $machineEvent = @{
                            Kind = $eventType
                            Data = $turnData
                        }
                    } elseif ($eventType -eq 'context.usage.updated') {
                        if (
                            $contextUpdate.Contains('current_context_tokens') -and
                            $contextUpdate.Contains('context_window_tokens')
                        ) {
                            $machineEvent = @{
                                Kind = 'context.usage.updated'
                                Data = @{
                                    current_tokens = $contextUpdate['current_context_tokens']
                                    context_window_tokens = $contextUpdate['context_window_tokens']
                                }
                            }
                        }
                    } elseif (
                        $eventType -eq 'item.completed' -and
                        $itemType -eq 'context_compaction'
                    ) {
                        $compactionCount++
                        $machineEvent = @{
                            Kind = 'context.compaction.completed'
                            Data = @{
                                status = 'completed'
                                compaction_count = $compactionCount
                            }
                        }
                    } elseif ($isItemEvent -and $itemType -eq 'reasoning') {
                        $machineEvent = @{
                            Kind = 'reasoning.activity'
                            Data = @{
                                status = $eventType.Substring(5)
                                item_type = 'reasoning'
                                steps = $stepCount
                                tool_calls = $toolCallCount
                                events_seen = $eventsSeen
                            }
                        }
                    } elseif ($isItemEvent -and $itemType -in $toolItemTypes) {
                        $toolData = [ordered]@{
                            status = $eventType.Substring(5)
                            item_type = $itemType
                            steps = $stepCount
                            tool_calls = $toolCallCount
                            events_seen = $eventsSeen
                        }
                        if ($itemType -eq 'command_execution') {
                            $commandStatus = Get-AiCliProperty $item 'command_status'
                            if (
                                $commandStatus -is [string] -and
                                $commandStatus -in @(
                                    'in_progress',
                                    'succeeded',
                                    'failed',
                                    'declined'
                                )
                            ) {
                                $toolData['command_status'] = $commandStatus
                            }
                            $exitCode = ConvertTo-AiCliBoundedInteger `
                                -Value (Get-AiCliProperty $item 'exit_code') `
                                -Minimum ([int]::MinValue) `
                                -Maximum ([int]::MaxValue)
                            if ($null -ne $exitCode) {
                                $toolData['exit_code'] = [int]$exitCode
                            }
                            $durationMs = ConvertTo-AiCliBoundedInteger `
                                -Value (Get-AiCliProperty $item 'duration_ms') `
                                -Minimum 0 `
                                -Maximum ([long]::MaxValue)
                            if ($null -ne $durationMs) {
                                $toolData['duration_ms'] = $durationMs
                            }
                        }
                        $machineEvent = @{
                            Kind = 'tool.activity'
                            Data = $toolData
                        }
                    } elseif ($isItemEvent -and $itemType -eq 'todo_list') {
                        $machineEvent = @{
                            Kind = 'planning.activity'
                            Data = @{
                                status = $eventType.Substring(5)
                                item_type = 'todo_list'
                                steps = $stepCount
                                tool_calls = $toolCallCount
                                events_seen = $eventsSeen
                            }
                        }
                    } elseif (
                        $eventType -eq 'item.updated' -and
                        $itemType -eq 'agent_message'
                    ) {
                        $publicText = Protect-AiCliExactSecretValues `
                            -Text ([string](Get-AiCliProperty $item 'text')) `
                            -SecretValues $SecretValues
                        if ($publicText.Length -gt 2000) {
                            $publicText = $publicText.Substring(0, 2000)
                        }
                        if (-not [string]::IsNullOrEmpty($publicText)) {
                            $machineEvent = @{
                                Kind = 'output.delta'
                                Data = @{
                                    status = 'updated'
                                    item_type = 'agent_message'
                                    public_text = $publicText
                                    steps = $stepCount
                                    tool_calls = $toolCallCount
                                    events_seen = $eventsSeen
                                }
                            }
                        }
                    } elseif (
                        $eventType -eq 'item.completed' -and
                        $itemType -eq 'agent_message'
                    ) {
                        $publicText = Protect-AiCliExactSecretValues `
                            -Text ([string](Get-AiCliProperty $item 'text')) `
                            -SecretValues $SecretValues
                        if ($publicText.Length -gt 8000) {
                            $publicText = $publicText.Substring(0, 8000)
                        }
                        $machineEvent = @{
                            Kind = 'output.completed'
                            Data = @{
                                status = 'completed'
                                item_type = 'agent_message'
                                public_text = $publicText
                                steps = $stepCount
                                tool_calls = $toolCallCount
                                events_seen = $eventsSeen
                            }
                        }
                    }
                    if ($machineEvent -and -not (
                        Write-AiCliMachineEvent -Stream $machineEventStream `
                            -Sequence ([ref]$machineEventSequence) `
                            -Kind $machineEvent.Kind -Data $machineEvent.Data `
                            -SecretValues $SecretValues
                    )) {
                        $machineEventStatus = 'degraded'
                    } elseif ($machineEvent -and $machineEvent.Kind -in @('run.failed','limit.hit')) {
                        $machineTerminalEventWritten = $true
                    }
                }

                if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMs) {
                    $termination = Stop-AiCliProcessTree -Process $proc -Reason timeout
                    throw [System.TimeoutException]::new("子进程超时 (${TimeoutMs}ms): $FileName")
                } elseif ($enforceStepLimitEffective -and $stepCount -gt $MaxSteps) {
                    $limitHit = 'maxSteps'
                }
                elseif ($enforceToolCallLimitEffective -and $toolCallCount -gt $MaxToolCalls) {
                    $limitHit = 'maxToolCalls'
                }
                if ($limitHit) {
                    if ($machineEventStatus -eq 'ok' -and -not $machineTerminalEventWritten) {
                        if (-not (
                            Write-AiCliMachineEvent -Stream $machineEventStream `
                                -Sequence ([ref]$machineEventSequence) -Kind 'limit.hit' `
                                -Data @{
                                    status = 'blocked'
                                    limit = $limitHit
                                    steps = $stepCount
                                    tool_calls = $toolCallCount
                                    events_seen = $eventsSeen
                                } -SecretValues $SecretValues
                        )) {
                            $machineEventStatus = 'degraded'
                        } else {
                            $machineTerminalEventWritten = $true
                        }
                    }
                    $termination = Stop-AiCliProcessTree -Process $proc
                    if (-not $termination.Confirmed) {
                        $protocolValid = $false
                        $protocolError = 'Process-tree cleanup could not be confirmed after a hard-limit stop.'
                    }
                    break
                }
            }
            if (-not $proc.HasExited) {
                $remainingMs = $TimeoutMs - [int]$stopwatch.ElapsedMilliseconds
                if ($remainingMs -le 0 -or -not $proc.WaitForExit($remainingMs)) {
                    $termination = Stop-AiCliProcessTree -Process $proc -Reason timeout
                    throw [System.TimeoutException]::new("子进程超时 (${TimeoutMs}ms): $FileName")
                }
            }
            $proc.WaitForExit()
            $stdout = $safeStdOut.ToString()
        } else {
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            if (-not $proc.WaitForExit($TimeoutMs)) {
                $termination = Stop-AiCliProcessTree -Process $proc -Reason timeout
                throw [System.TimeoutException]::new("子进程超时 (${TimeoutMs}ms): $FileName")
            }
            $proc.WaitForExit()
            $stdout = $stdoutTask.GetAwaiter().GetResult()
        }
        $recoverableUpstreamErrorResolved = (
            $recoverableUpstreamErrorSeen -and
            $proc.ExitCode -eq 0 -and
            $lastCompletedTurnEvent -gt $lastRecoverableErrorEvent -and
            $lastFinalMessageEvent -gt $lastRecoverableErrorEvent
        )
        $upstreamFailed = (
            $terminalUpstreamFailed -or
            ($recoverableUpstreamErrorSeen -and -not $recoverableUpstreamErrorResolved)
        )
        $stderr = if ($isCodexEventProtocol) {
            [void]$stderrTask.GetAwaiter().GetResult()
            if ($upstreamFailed) {
                $upstreamFailureSummary
            } elseif ($proc.ExitCode -ne 0) {
                'Codex process failed without a public error event.'
            } else {
                ''
            }
        } else {
            $stderrTask.GetAwaiter().GetResult()
        }
        $stdout = Protect-AiCliExactSecretValues `
            -Text $stdout -SecretValues $SecretValues
        $stderr = Protect-AiCliExactSecretValues `
            -Text $stderr -SecretValues $SecretValues
        if ($isCodexEventProtocol -and $RequireRuntimeIdentity -and
            $protocolValid -and $null -eq $runtimeIdentity) {
            $protocolValid = $false
            $protocolErrorCode = 'codex_appserver.runtime_identity_missing'
            $protocolError = 'Codex app-server runtime identity is missing.'
        }
        if ($isCodexEventProtocol -and $proc.ExitCode -eq 0 -and $eventsSeen -eq 0) {
            $protocolValid = $false
            $protocolError = 'Codex returned success without any countable JSON events.'
        }
        if ($EventProtocol -eq 'none' -and $MaxCaptureChars -gt 0 -and $stdout.Length -gt $MaxCaptureChars) {
            $stdout = $stdout.Substring(0, $MaxCaptureChars)
            $outputTruncated = $true
        }
        if ($MaxCaptureChars -gt 0 -and $stderr.Length -gt $MaxCaptureChars) {
            $stderr = $stderr.Substring(0, $MaxCaptureChars)
            $outputTruncated = $true
        }
        $exitCode = if ($limitHit) {
            75
        } elseif (-not $protocolValid) {
            74
        } elseif ($upstreamFailed -and $proc.ExitCode -eq 0) {
            1
        } else {
            $proc.ExitCode
        }
        if ($limitHit) {
            $stderr = "Agent exceeded the configured hard limit: $limitHit."
        } elseif (-not $protocolValid) {
            $stderr = Protect-AiCliExactSecretValues `
                -Text $protocolError -SecretValues $SecretValues
        }
        if (
            $machineEventStatus -eq 'ok' -and
            $null -ne $machineEventStream -and
            $exitCode -ne 0 -and
            -not $machineTerminalEventWritten
        ) {
            $terminalKind = if ($limitHit) { 'limit.hit' } else { 'run.failed' }
            $terminalData = @{
                status = $(if ($limitHit) { 'blocked' } else { 'failed' })
                steps = $stepCount
                tool_calls = $toolCallCount
                events_seen = $eventsSeen
            }
            if ($limitHit) {
                $terminalData['limit'] = $limitHit
            } else {
                $terminalData['error_category'] = if ($upstreamFailed) {
                    'upstream_error'
                } else {
                    'protocol_or_process_failure'
                }
                if (-not [string]::IsNullOrWhiteSpace($protocolErrorCode)) {
                    $terminalData['error_code'] = $protocolErrorCode
                }
            }
            if (-not (
                Write-AiCliMachineEvent -Stream $machineEventStream `
                    -Sequence ([ref]$machineEventSequence) `
                    -Kind $terminalKind -Data $terminalData `
                    -SecretValues $SecretValues
            )) {
                $machineEventStatus = 'degraded'
            } else {
                $machineTerminalEventWritten = $true
            }
        }
        $limitsHard = (
            $isCodexEventProtocol -and
            $protocolValid -and
            (-not $termination.Attempted -or $termination.Confirmed)
        )
        return [pscustomobject]@{
            ExitCode = $exitCode
            StdOut   = $stdout
            StdErr   = $stderr
            ErrorCode = if ([string]::IsNullOrWhiteSpace($protocolErrorCode)) {
                $null
            } else {
                $protocolErrorCode
            }
            TimedOut = $false
            DurationMs = [int]$stopwatch.ElapsedMilliseconds
            OutputTruncated = $outputTruncated
            StepCount = $stepCount
            ToolCallCount = $toolCallCount
            EventsSeen = $eventsSeen
            EventProtocol = $EventProtocol
            LimitHit = $limitHit
            LimitsHard = $limitsHard
            CleanupConfirmed = [bool]$termination.Confirmed
            CleanupMethod = [string]$termination.Method
            MachineEventProjection = $machineEventProjection
            MachineEventStatus = $machineEventStatus
            MachineEventCount = $machineEventSequence
            Usage = Merge-AiCliSafeRunUsage -TurnUsage $safeTurnUsage `
                -ContextUsage $safeContextUsage
            RuntimeIdentity = $runtimeIdentity
        }
    } catch [System.TimeoutException] {
        if (-not $termination.Attempted -or -not $termination.Confirmed) {
            $retriedTermination = Stop-AiCliProcessTree -Process $proc -Reason timeout
            if ($retriedTermination.Confirmed -or -not $termination.Attempted) {
                $termination = $retriedTermination
            }
        }

        $stdout = if ($isCodexEventProtocol) {
            $safeStdOut.ToString()
        } elseif ($stdoutTask) {
            try {
                if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.GetAwaiter().GetResult() } else { '' }
            } catch { '' }
        } else {
            ''
        }
        $stderr = if ($stderrTask) {
            try {
                if ($stderrTask.Wait(5000)) { [string]$stderrTask.GetAwaiter().GetResult() } else { '' }
            } catch { '' }
        } else {
            ''
        }
        $stdout = Protect-AiCliExactSecretValues `
            -Text $stdout -SecretValues $SecretValues
        $stderr = Protect-AiCliExactSecretValues `
            -Text $stderr -SecretValues $SecretValues
        if ($EventProtocol -eq 'none' -and $MaxCaptureChars -gt 0 -and $stdout.Length -gt $MaxCaptureChars) {
            $stdout = $stdout.Substring(0, $MaxCaptureChars)
            $outputTruncated = $true
        }
        if ($MaxCaptureChars -gt 0 -and $stderr.Length -gt $MaxCaptureChars) {
            $stderr = $stderr.Substring(0, $MaxCaptureChars)
            $outputTruncated = $true
        }
        if (
            $machineEventStatus -eq 'ok' -and
            $null -ne $machineEventStream -and
            -not $machineTerminalEventWritten
        ) {
            if (-not (
                Write-AiCliMachineEvent -Stream $machineEventStream `
                    -Sequence ([ref]$machineEventSequence) -Kind 'limit.hit' `
                    -Data @{
                        status = 'blocked'
                        limit = 'timeout'
                        steps = $stepCount
                        tool_calls = $toolCallCount
                        events_seen = $eventsSeen
                    } -SecretValues $SecretValues
            )) {
                $machineEventStatus = 'degraded'
            } else {
                $machineTerminalEventWritten = $true
            }
        }
        return [pscustomobject]@{
            ExitCode = (Get-AiCliExitCode Unavailable)
            StdOut = $stdout
            StdErr = 'Child process exceeded the configured wall timeout.'
            ErrorCode = $null
            TimedOut = $true
            DurationMs = [int]$stopwatch.ElapsedMilliseconds
            OutputTruncated = $outputTruncated
            StepCount = $stepCount
            ToolCallCount = $toolCallCount
            EventsSeen = $eventsSeen
            EventProtocol = $EventProtocol
            LimitHit = 'timeout'
            LimitsHard = (
                $isCodexEventProtocol -and
                $protocolValid -and
                [bool]$termination.Confirmed
            )
            CleanupConfirmed = [bool]$termination.Confirmed
            CleanupMethod = [string]$termination.Method
            MachineEventProjection = $machineEventProjection
            MachineEventStatus = $machineEventStatus
            MachineEventCount = $machineEventSequence
            Usage = Merge-AiCliSafeRunUsage -TurnUsage $safeTurnUsage `
                -ContextUsage $safeContextUsage
            RuntimeIdentity = $runtimeIdentity
        }
    } catch {
        if ($processStarted -and -not $termination.Attempted) {
            $termination = Stop-AiCliProcessTree -Process $proc -Reason cancelled
        }
        if (
            $machineEventStatus -eq 'ok' -and
            $null -ne $machineEventStream -and
            -not $machineTerminalEventWritten
        ) {
            if (-not (
                Write-AiCliMachineEvent -Stream $machineEventStream `
                    -Sequence ([ref]$machineEventSequence) -Kind 'run.failed' `
                    -Data @{
                        status = 'failed'
                        error_category = 'runner_failure'
                        steps = $stepCount
                        tool_calls = $toolCallCount
                        events_seen = $eventsSeen
                    } -SecretValues $SecretValues
            )) {
                $machineEventStatus = 'degraded'
            }
        }
        throw
    } finally {
        $stopwatch.Stop()
        if ($null -ne $machineEventStream) {
            try { $machineEventStream.Dispose() } catch {}
        }
        if ($privateTaskWriter) {
            try { $privateTaskWriter.Dispose() } catch {}
        }
        if ($privateTaskPipe) {
            try { $privateTaskPipe.Dispose() } catch {}
        }
        try { $proc.Dispose() } catch {}
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Register-AiCliActiveSession {
    param($Process, [string]$Note)
    try {
        $paths = Initialize-AiCliDirectories
        $file = Join-Path $paths.StateDir 'active-sessions.json'
        $list = Read-AiCliJsonFile -Path $file -Default @()
        if ($list -isnot [System.Collections.IList]) { $list = @($list) }
        $entry = [ordered]@{
            pid        = $Process.Id
            startTime  = $Process.StartTime.ToUniversalTime().ToString('o')
            fileName   = $Process.StartInfo.FileName
            note       = $Note
            recordedUtc= (Get-Date).ToUniversalTime().ToString('o')
        }
        $arr = @($list) + @($entry)
        Write-AiCliJsonFile -Path $file -Value $arr
    } catch {
        Write-AiCliLog -Level Debug -Message "active session register failed: $($_.Exception.Message)"
    }
}

function Unregister-AiCliActiveSession {
    param([int]$ProcessId)
    try {
        $paths = Get-AiCliAppPaths
        $file = Join-Path $paths.StateDir 'active-sessions.json'
        $list = Read-AiCliJsonFile -Path $file -Default @()
        $new = @($list | Where-Object { [int](Get-AiCliProperty $_ 'pid') -ne $ProcessId })
        Write-AiCliJsonFile -Path $file -Value $new
    } catch {}
}

function Find-AiCliCommandPath {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        if ($cmd.Source) { return $cmd.Source }
        if ($cmd.Path) { return $cmd.Path }
    }
    return $null
}

function Resolve-AiCliLaunchExecutable {
    <#
    .SYNOPSIS
      Resolve CLI name to a real ProcessStartInfo FileName + optional prefix args.
      Windows npm shims (*.ps1/*.cmd) cannot be started via ProcessStartInfo.FileName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$PreferNpmCodex
    )

    if ($Name -eq 'codex' -and -not $PreferNpmCodex) {
        $localBin = Join-Path (Get-AiCliKnownFolder LocalAppData) 'OpenAI\Codex\bin'
        if (Test-Path -LiteralPath $localBin) {
            $desktop = Get-ChildItem -LiteralPath $localBin -Recurse -Filter 'codex.exe' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($desktop) {
                return [pscustomobject]@{ FileName = $desktop.FullName; PrefixArgs = @(); Kind = 'desktop-codex' }
            }
        }
    }

    $path = Find-AiCliCommandPath -Name $Name
    if (-not $path) { return $null }

    $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -eq '.exe' -or $ext -eq '.com') {
        return [pscustomobject]@{ FileName = $path; PrefixArgs = @(); Kind = 'native' }
    }

    if ($Name -eq 'qwen' -and ($ext -eq '.ps1' -or $ext -eq '.cmd')) {
        $npmRoot = Split-Path -Parent $path
        $js = Join-Path $npmRoot 'node_modules\@qwen-code\qwen-code\cli-entry.js'
        $node = (Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if ($node -and (Test-Path -LiteralPath $js -PathType Leaf)) {
            return [pscustomobject]@{ FileName = $node; PrefixArgs = @($js); Kind = 'npm-node' }
        }
    }

    if ($Name -eq 'opencode' -and ($ext -eq '.ps1' -or $ext -eq '.cmd')) {
        $npmRoot = Split-Path -Parent $path
        $native = Join-Path $npmRoot 'node_modules\opencode-ai\bin\opencode.exe'
        if (Test-Path -LiteralPath $native -PathType Leaf) {
            return [pscustomobject]@{ FileName = $native; PrefixArgs = @(); Kind = 'npm-native' }
        }
    }

    if ($Name -eq 'codex' -and ($ext -eq '.ps1' -or $ext -eq '.cmd')) {
        $npmRoot = Split-Path -Parent $path
        $js = Join-Path $npmRoot 'node_modules\@openai\codex\bin\codex.js'
        if (-not (Test-Path -LiteralPath $js)) {
            $js = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\bin\codex.js'
        }
        $node = Find-AiCliCommandPath -Name 'node'
        if ($node -and (Test-Path -LiteralPath $js)) {
            if ([IO.Path]::GetExtension($node).ToLowerInvariant() -eq '.ps1') {
                $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($nodeCmd) { $node = $nodeCmd.Source }
            }
            $packageRoot = Split-Path -Parent (Split-Path -Parent $js)
            $helpers = @(
                Get-ChildItem -LiteralPath (Join-Path $packageRoot 'node_modules') `
                    -Recurse -File -Filter 'codex-windows-sandbox-setup.exe' `
                    -ErrorAction SilentlyContinue
            )
            return [pscustomobject]@{
                FileName = $node
                PrefixArgs = @($js)
                Kind = 'npm-node'
                ManagedPackageRoot = $packageRoot
                SandboxHelperPath = if ($helpers.Count -eq 1) {
                    $helpers[0].FullName
                } else {
                    $null
                }
            }
        }
    }

    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
        $comspec = $env:ComSpec
        if (-not $comspec) { $comspec = 'C:\Windows\System32\cmd.exe' }
        return [pscustomobject]@{ FileName = $comspec; PrefixArgs = @('/c', $path); Kind = 'cmd-shim' }
    }

    if ($ext -eq '.ps1') {
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $pwsh) { $pwsh = 'pwsh' }
        return [pscustomobject]@{ FileName = $pwsh; PrefixArgs = @('-NoProfile', '-File', $path); Kind = 'ps1-shim' }
    }

    return [pscustomobject]@{ FileName = $path; PrefixArgs = @(); Kind = 'raw' }
}

$script:AiCliVersionEvidenceCache = @{}

function Get-AiCliResolvedCliVersionEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Resolved)
    $fileName = [string](Get-AiCliProperty $Resolved 'FileName')
    if ([string]::IsNullOrWhiteSpace($fileName)) { return $null }
    $prefix = @((Get-AiCliProperty $Resolved 'PrefixArgs') | ForEach-Object { [string]$_ })
    $signatureParts = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($fileName) + $prefix) {
        $signatureParts.Add([string]$candidate) | Out-Null
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $item = Get-Item -LiteralPath $candidate -Force
            $signatureParts.Add("$($item.Length):$($item.LastWriteTimeUtc.Ticks)") | Out-Null
        }
    }
    $cacheKey = $signatureParts -join '|'
    if ($script:AiCliVersionEvidenceCache.ContainsKey($cacheKey)) {
        return $script:AiCliVersionEvidenceCache[$cacheKey]
    }
    try {
        $result = Invoke-AiCliChildCapture -FileName $fileName `
            -ArgumentList (@($prefix) + @('--version')) -TimeoutMs 10000 -CloseStdIn
        if ([int]$result.ExitCode -ne 0) { return $null }
        $combined = @([string]$result.StdOut, [string]$result.StdErr) -join "`n"
        $line = @($combined -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1)
        if ($line.Count -eq 0) { return $null }
        $safe = Protect-AiCliSecretText ([string]$line[0])
        $evidence = [pscustomobject]@{
            FileName = $fileName
            PrefixArgs = @($prefix)
            Kind = [string](Get-AiCliProperty $Resolved 'Kind')
            Version = $safe.Substring(0, [Math]::Min(200, $safe.Length))
        }
        $script:AiCliVersionEvidenceCache[$cacheKey] = $evidence
        return $evidence
    } catch {
        return $null
    }
}

function Get-AiCliSemanticVersionEvidence {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match(
        $Text,
        '(?<!\d)(?<core>\d+\.\d+\.\d+)(?<prerelease>-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?(?![0-9A-Za-z.-])'
    )
    if (-not $match.Success) { return $null }
    try {
        return [pscustomobject]@{
            Text = $match.Value
            Version = [version]$match.Groups['core'].Value
            IsPrerelease = $match.Groups['prerelease'].Success
        }
    } catch {
        return $null
    }
}

function Test-AiCliProfileMinimumCliVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$MergedProfile,
        $VersionEvidence
    )
    $compatibility = Get-AiCliProperty $MergedProfile 'compatibility'
    $minimumText = [string](Get-AiCliProperty $compatibility 'minCliVersion')
    if ([string]::IsNullOrWhiteSpace($minimumText)) {
        return [pscustomobject]@{ Required = $false; Supported = $true; Minimum = $null; Actual = $null }
    }
    if ($minimumText -notmatch '^\d+\.\d+\.\d+$') {
        return [pscustomobject]@{ Required = $true; Supported = $false; Minimum = $minimumText; Actual = $null; Reason = 'minimum-invalid' }
    }
    $actualText = if ($VersionEvidence) { [string](Get-AiCliProperty $VersionEvidence 'Version') } else { '' }
    $actual = Get-AiCliSemanticVersionEvidence -Text $actualText
    if (-not $actual) {
        return [pscustomobject]@{ Required = $true; Supported = $false; Minimum = $minimumText; Actual = $actualText; Reason = 'actual-unavailable' }
    }
    $minimum = [version]$minimumText
    $supported = $actual.Version -gt $minimum -or
        ($actual.Version -eq $minimum -and -not $actual.IsPrerelease)
    return [pscustomobject]@{
        Required = $true
        Supported = $supported
        Minimum = $minimumText
        Actual = $actual.Text
        Reason = $(if ($supported) { 'supported' } else { 'below-minimum' })
    }
}

function Assert-AiCliProfileMinimumCliVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$MergedProfile,
        [Parameter(Mandatory)]$Resolved
    )
    $compatibility = Get-AiCliProperty $MergedProfile 'compatibility'
    $minimumText = [string](Get-AiCliProperty $compatibility 'minCliVersion')
    if ([string]::IsNullOrWhiteSpace($minimumText)) { return }
    $evidence = Get-AiCliResolvedCliVersionEvidence -Resolved $Resolved
    $result = Test-AiCliProfileMinimumCliVersion -MergedProfile $MergedProfile -VersionEvidence $evidence
    if (-not $result.Supported) {
        $actualLabel = if ($result.Actual) { $result.Actual } else { '无法取得版本' }
        throw "当前 CLI 版本不支持此 Profile：需要 $($result.Minimum)+，实际 $actualLabel。"
    }
}
