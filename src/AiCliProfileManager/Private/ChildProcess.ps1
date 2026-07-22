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
                $nodeModulesMarker = '\node_modules\'
                $markerIndex = $parent.IndexOf($nodeModulesMarker, [StringComparison]::OrdinalIgnoreCase)
                if ($markerIndex -gt 0) {
                    $packageRoot = $parent.Substring(0, $markerIndex)
                    if (-not $readRoots.Contains($packageRoot)) { $readRoots.Add($packageRoot) | Out-Null }
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
        [string]$StdInText = $null
    )
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
    try {
        [void]$proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
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
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill($true) } catch {}
            throw [System.TimeoutException]::new("子进程超时 (${TimeoutMs}ms): $FileName")
        }
        $proc.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $truncated = $false
        if ($MaxCaptureChars -gt 0 -and $stdout.Length -gt $MaxCaptureChars) {
            $stdout = $stdout.Substring(0, $MaxCaptureChars)
            $truncated = $true
        }
        if ($MaxCaptureChars -gt 0 -and $stderr.Length -gt $MaxCaptureChars) {
            $stderr = $stderr.Substring(0, $MaxCaptureChars)
            $truncated = $true
        }
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
            TimedOut = $false
            DurationMs = [int]$stopwatch.ElapsedMilliseconds
            OutputTruncated = $truncated
        }
    } finally {
        $stopwatch.Stop()
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
