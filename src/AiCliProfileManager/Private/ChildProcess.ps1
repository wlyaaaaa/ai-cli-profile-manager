# ProcessStartInfo-based child launch: ArgumentList array, child-only env, no IEX.

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
    $codex = Resolve-AiCliLaunchExecutable -Name 'codex'
    if (-not $codex) {
        throw 'Codex CLI sandbox 不可用；machine run 拒绝无沙箱降级。'
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
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)

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
                return [pscustomobject]@{ Attempted = $true; Confirmed = $true; Method = 'taskkill-tree' }
            }
        } catch {}
    }

    try {
        if (-not $Process.HasExited) { $Process.Kill() }
        [void]$Process.WaitForExit(5000)
    } catch {}
    return [pscustomobject]@{ Attempted = $true; Confirmed = $false; Method = 'unconfirmed' }
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

function Write-AiCliMachineEvent {
    param(
        [Parameter(Mandatory)][IO.FileStream]$Stream,
        [Parameter(Mandatory)][ref]$Sequence,
        [Parameter(Mandatory)][string]$Kind,
        [hashtable]$Data = @{}
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
        $encoded = [Text.UTF8Encoding]::new($false).GetBytes(
            (($value | ConvertTo-Json -Depth 10 -Compress) + "`n")
        )
        $Stream.Write($encoded, 0, $encoded.Length)
        $Stream.Flush()
        $Sequence.Value = $nextSequence
        return $true
    } catch {
        return $false
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
        [ValidateSet('none','codex-jsonl')][string]$EventProtocol = 'none',
        [int]$MaxSteps = 20,
        [int]$MaxToolCalls = 80,
        [string]$MachineEventFile = $null,
        [string]$WritableWorkspace = $null
    )
    $machineEventRequested = -not [string]::IsNullOrWhiteSpace($MachineEventFile)
    $resolvedMachineEventFile = if ($machineEventRequested -and $EventProtocol -eq 'codex-jsonl') {
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
        )
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
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        try { $psi.Environment[$entry.Key] = [string]$entry.Value } catch {}
    }
    foreach ($name in $RemoveEnvironment) {
        if ($psi.Environment.ContainsKey($name)) { [void]$psi.Environment.Remove($name) }
    }
    if ($psi.Environment.ContainsKey('AICLI_MACHINE_EVENT_FILE')) {
        [void]$psi.Environment.Remove('AICLI_MACHINE_EVENT_FILE')
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
    foreach ($a in $effectiveArgs) { [void]$psi.ArgumentList.Add([string]$a) }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stepCount = 0
    $toolCallCount = 0
    $eventsSeen = 0
    $limitHit = $null
    $protocolValid = $true
    $protocolError = ''
    $outputTruncated = $false
    $safeStdOut = [Text.StringBuilder]::new()
    $seenSteps = @{}
    $seenTools = @{}
    $stdoutTask = $null
    $stderrTask = $null
    $upstreamFailed = $false
    $upstreamFailureSummary = 'Codex reported an upstream failure.'
    $termination = [pscustomobject]@{ Attempted = $false; Confirmed = $true; Method = 'none' }
    $knownEventTypes = @(
        'thread.started',
        'turn.started',
        'turn.completed',
        'turn.failed',
        'item.started',
        'item.updated',
        'item.completed',
        'error'
    )
    $knownItemTypes = @(
        'agent_message',
        'reasoning',
        'command_execution',
        'file_change',
        'mcp_tool_call',
        'collab_tool_call',
        'web_search',
        'todo_list',
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
        'tool_call',
        'dynamic_tool_call',
        'web_search',
        'computer_use'
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
        [void]$proc.Start()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        try {
            if (-not [string]::IsNullOrEmpty($StdInText)) {
                $proc.StandardInput.Write($StdInText)
                if (-not $StdInText.EndsWith("`n")) {
                    $proc.StandardInput.WriteLine()
                }
            }
            $proc.StandardInput.Close()
        } catch {}

        if ($EventProtocol -eq 'codex-jsonl') {
            while ($true) {
                if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMs) {
                    $termination = Stop-AiCliProcessTree -Process $proc
                    throw [System.TimeoutException]::new("子进程超时 (${TimeoutMs}ms): $FileName")
                }
                $readTask = $proc.StandardOutput.ReadLineAsync()
                while (-not $readTask.IsCompleted) {
                    $remainingReadMs = $TimeoutMs - [int]$stopwatch.ElapsedMilliseconds
                    if ($remainingReadMs -le 0) {
                        $termination = Stop-AiCliProcessTree -Process $proc
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
                    $stepKey = "item:$itemId"
                    if (-not $seenSteps.ContainsKey($stepKey)) {
                        $seenSteps[$stepKey] = $true
                        $stepCount++
                    }
                    if ($itemType -in $toolItemTypes -and -not $seenTools.ContainsKey($stepKey)) {
                        $seenTools[$stepKey] = $true
                        $toolCallCount++
                    }
                    if ($itemType -eq 'collab_tool_call') {
                        $protocolValid = $false
                        $protocolError = 'Codex emitted a collab tool call although multi-agent is disabled.'
                        $termination = Stop-AiCliProcessTree -Process $proc
                        if (-not $termination.Confirmed) {
                            $protocolError += ' Process-tree cleanup could not be confirmed.'
                        }
                        break
                    }
                }

                $isUpstreamFailureEvent = (
                    $eventType -eq 'error' -or
                    $eventType -eq 'turn.failed' -or
                    ($isItemEvent -and $itemType -eq 'error')
                )
                if ($isUpstreamFailureEvent) {
                    $upstreamFailed = $true
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
                            text = [string](Get-AiCliProperty $item 'text')
                        }
                    }
                }
                if ($safeEvent -and -not $upstreamFailed) {
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
                    } elseif ($isUpstreamFailureEvent) {
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
                        $machineEvent = @{
                            Kind = $eventType
                            Data = @{
                                status = $eventType.Substring(5)
                                steps = $stepCount
                                tool_calls = $toolCallCount
                                events_seen = $eventsSeen
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
                        $machineEvent = @{
                            Kind = 'tool.activity'
                            Data = @{
                                status = $eventType.Substring(5)
                                item_type = $itemType
                                steps = $stepCount
                                tool_calls = $toolCallCount
                                events_seen = $eventsSeen
                            }
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
                        $eventType -eq 'item.completed' -and
                        $itemType -eq 'agent_message'
                    ) {
                        $publicText = [string](Get-AiCliProperty $item 'text')
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
                            -Kind $machineEvent.Kind -Data $machineEvent.Data
                    )) {
                        $machineEventStatus = 'degraded'
                    } elseif ($machineEvent -and $machineEvent.Kind -in @('run.failed','limit.hit')) {
                        $machineTerminalEventWritten = $true
                    }
                }

                if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMs) {
                    $termination = Stop-AiCliProcessTree -Process $proc
                    throw [System.TimeoutException]::new("子进程超时 (${TimeoutMs}ms): $FileName")
                } elseif ($stepCount -gt $MaxSteps) {
                    $limitHit = 'maxSteps'
                }
                elseif ($toolCallCount -gt $MaxToolCalls) {
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
                                }
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
                    $termination = Stop-AiCliProcessTree -Process $proc
                    throw [System.TimeoutException]::new("子进程超时 (${TimeoutMs}ms): $FileName")
                }
            }
            $proc.WaitForExit()
            $stdout = $safeStdOut.ToString()
        } else {
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            if (-not $proc.WaitForExit($TimeoutMs)) {
                $termination = Stop-AiCliProcessTree -Process $proc
                throw [System.TimeoutException]::new("子进程超时 (${TimeoutMs}ms): $FileName")
            }
            $proc.WaitForExit()
            $stdout = $stdoutTask.GetAwaiter().GetResult()
        }
        $stderr = if ($EventProtocol -eq 'codex-jsonl') {
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
        if ($EventProtocol -eq 'codex-jsonl' -and $proc.ExitCode -eq 0 -and $eventsSeen -eq 0) {
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
            $stderr = $protocolError
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
            }
            if (-not (
                Write-AiCliMachineEvent -Stream $machineEventStream `
                    -Sequence ([ref]$machineEventSequence) `
                    -Kind $terminalKind -Data $terminalData
            )) {
                $machineEventStatus = 'degraded'
            } else {
                $machineTerminalEventWritten = $true
            }
        }
        $limitsHard = (
            $EventProtocol -eq 'codex-jsonl' -and
            $protocolValid -and
            (-not $termination.Attempted -or $termination.Confirmed)
        )
        return [pscustomobject]@{
            ExitCode = $exitCode
            StdOut   = $stdout
            StdErr   = $stderr
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
        }
    } catch [System.TimeoutException] {
        if (-not $termination.Attempted -or -not $termination.Confirmed) {
            $retriedTermination = Stop-AiCliProcessTree -Process $proc
            if ($retriedTermination.Confirmed -or -not $termination.Attempted) {
                $termination = $retriedTermination
            }
        }

        $stdout = if ($EventProtocol -eq 'codex-jsonl') {
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
                    }
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
            TimedOut = $true
            DurationMs = [int]$stopwatch.ElapsedMilliseconds
            OutputTruncated = $outputTruncated
            StepCount = $stepCount
            ToolCallCount = $toolCallCount
            EventsSeen = $eventsSeen
            EventProtocol = $EventProtocol
            LimitHit = 'timeout'
            LimitsHard = (
                $EventProtocol -eq 'codex-jsonl' -and
                $protocolValid -and
                [bool]$termination.Confirmed
            )
            CleanupConfirmed = [bool]$termination.Confirmed
            CleanupMethod = [string]$termination.Method
            MachineEventProjection = $machineEventProjection
            MachineEventStatus = $machineEventStatus
            MachineEventCount = $machineEventSequence
        }
    } catch {
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
                    }
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
    param([Parameter(Mandatory)][string]$Name)

    if ($Name -eq 'codex') {
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
            return [pscustomobject]@{ FileName = $node; PrefixArgs = @($js); Kind = 'npm-node' }
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
