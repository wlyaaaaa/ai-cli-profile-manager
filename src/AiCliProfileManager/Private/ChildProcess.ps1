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

function Invoke-AiCliChildCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [hashtable]$EnvironmentDelta = @{},
        [string[]]$RemoveEnvironment = @(),
        [string]$WorkingDirectory = $null,
        [int]$TimeoutMs = 120000,
        [switch]$CloseStdIn,
        [string]$StdInText = $null
    )
    # Redirect to temp files — avoids pipe-buffer deadlock when CLI dumps large logs (e.g. models list)
    $outFile = Join-Path ([IO.Path]::GetTempPath()) ("aicli-out-" + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ("aicli-err-" + [guid]::NewGuid().ToString('N') + '.txt')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
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
    foreach ($a in $ArgumentList) { [void]$psi.ArgumentList.Add([string]$a) }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $stdoutBuilder = New-Object System.Text.StringBuilder
    $stderrBuilder = New-Object System.Text.StringBuilder
    $outHandler = {
        if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
            [void]$Event.MessageData.AppendLine($EventArgs.Data)
        }
    }
    $outEvent = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $outHandler -MessageData $stdoutBuilder
    $errEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action $outHandler -MessageData $stderrBuilder
    try {
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
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
            throw "子进程超时 (${TimeoutMs}ms): $FileName"
        }
        # allow async handlers to flush
        Start-Sleep -Milliseconds 50
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdoutBuilder.ToString()
            StdErr   = $stderrBuilder.ToString()
        }
    } finally {
        if ($outEvent) { Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue; $outEvent.Dispose() }
        if ($errEvent) { Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue; $errEvent.Dispose() }
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
