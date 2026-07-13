# Verify managed proxy process identity before stop/claim.

function Get-AiCliProxyStatePath {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $paths = Initialize-AiCliDirectories
    return (Join-Path $paths.StateDir "proxy-$ProxyId.json")
}

function Get-AiCliProxyState {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    return (Read-AiCliJsonFile -Path (Get-AiCliProxyStatePath -ProxyId $ProxyId) -Default $null)
}

function Save-AiCliProxyState {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId, $State)
    Write-AiCliJsonFile -Path (Get-AiCliProxyStatePath -ProxyId $ProxyId) -Value $State
}

function Clear-AiCliProxyState {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $p = Get-AiCliProxyStatePath -ProxyId $ProxyId
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

function Resolve-AiCliTrustedProxyExecutablePath {
    param(
        [Parameter(Mandatory)][ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [Parameter(Mandatory)][string]$Path
    )
    try {
        $paths = Get-AiCliProxyPaths -ProxyId $ProxyId
        $full = [IO.Path]::GetFullPath($Path)
        $expectedName = Get-AiCliProxyExpectedExecutableName -ProxyId $ProxyId
        if (-not [string]::Equals([IO.Path]::GetFileName($full), $expectedName, [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }

        $current = [IO.Path]::GetFullPath($paths.CurrentLink).TrimEnd([char[]]@('\','/'))
        $currentPrefix = $current + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($currentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $currentItem = Get-Item -LiteralPath $paths.CurrentLink -Force -ErrorAction Stop
            $targets = @($currentItem.Target)
            if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$targets[0])) {
                return $null
            }
            $targetRoot = [string]$targets[0]
            if (-not [IO.Path]::IsPathRooted($targetRoot)) {
                $targetRoot = Join-Path (Split-Path -Parent $paths.CurrentLink) $targetRoot
            }
            $relative = [IO.Path]::GetRelativePath($current, $full)
            $full = [IO.Path]::GetFullPath((Join-Path $targetRoot $relative))
        }

        $versionsRoot = [IO.Path]::GetFullPath($paths.VersionsDir).TrimEnd([char[]]@('\','/'))
        $versionsPrefix = $versionsRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($versionsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        $versionsRootItem = Get-Item -LiteralPath $versionsRoot -Force -ErrorAction Stop
        if (-not $versionsRootItem.PSIsContainer -or
            ($versionsRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return $null
        }
        $relativeToVersions = [IO.Path]::GetRelativePath($versionsRoot, $full)
        $segments = @($relativeToVersions -split '[/\\]')
        $cursor = $versionsRoot
        for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
            $cursor = Join-Path $cursor $segments[$i]
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                return $null
            }
        }
        $fileItem = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($fileItem.PSIsContainer -or
            ($fileItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return $null
        }
        return $full
    } catch {
        return $null
    }
}

function Test-AiCliProxyListenerOwnership {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][int]$ExpectedProcessId
    )
    $stateHost = [string](Get-AiCliProperty $State 'host')
    if ($stateHost -ne '127.0.0.1') {
        return [pscustomobject]@{ Match = $false; Reason = 'unsafe-state-host'; Listeners = @() }
    }
    $port = [int](Get-AiCliProperty $State 'port')
    if ($port -le 0) {
        return [pscustomobject]@{ Match = $false; Reason = 'missing-port'; Listeners = @() }
    }
    $listeners = @(Get-AiCliTcpListeners -Port $port)
    if ($listeners.Count -eq 0) {
        return [pscustomobject]@{ Match = $false; Reason = 'listener-missing'; Listeners = @() }
    }
    foreach ($listener in $listeners) {
        if ([string]$listener.LocalAddress -ne '127.0.0.1') {
            return [pscustomobject]@{ Match = $false; Reason = 'unsafe-listener-address'; Listeners = $listeners }
        }
        if ([int]$listener.OwningProcess -ne $ExpectedProcessId) {
            return [pscustomobject]@{ Match = $false; Reason = 'listener-owner-mismatch'; Listeners = $listeners }
        }
    }
    return [pscustomobject]@{ Match = $true; Reason = 'ok'; Listeners = $listeners }
}

function Test-AiCliProcessIdentity {
    param(
        $State,
        [switch]$Strict,
        [ValidateSet('ccp','cliproxy')][string]$ExpectedProxyId
    )
    if ($null -eq $State) { return [pscustomobject]@{ Match = $false; Reason = 'no-state' } }
    $stateProxyId = [string](Get-AiCliProperty $State 'proxyId')
    if ($stateProxyId -notin @('ccp','cliproxy')) {
        return [pscustomobject]@{ Match = $false; Reason = 'invalid-proxy-id' }
    }
    if ($ExpectedProxyId -and $stateProxyId -ne $ExpectedProxyId) {
        return [pscustomobject]@{ Match = $false; Reason = 'proxy-id-mismatch' }
    }
    $processId = [int](Get-AiCliProperty $State 'pid')
    if ($processId -le 0) { return [pscustomobject]@{ Match = $false; Reason = 'no-pid' } }
    try {
        $proc = Get-Process -Id $processId -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Match = $false; Reason = 'process-missing' }
    }
    $recordedStart = Get-AiCliProperty $State 'startTimeUtc'
    if (-not $recordedStart) {
        return [pscustomobject]@{ Match = $false; Reason = 'missing-starttime' }
    }
    try {
        $recorded = [datetime]::Parse([string]$recordedStart).ToUniversalTime()
        $actual = $proc.StartTime.ToUniversalTime()
        if ([math]::Abs(($recorded - $actual).TotalMilliseconds) -gt 250) {
            return [pscustomobject]@{ Match = $false; Reason = 'pid-reuse-starttime' }
        }
    } catch {
        return [pscustomobject]@{ Match = $false; Reason = 'starttime-unreadable' }
    }
    $expectedPath = Get-AiCliProperty $State 'executablePath'
    if (-not $expectedPath) {
        return [pscustomobject]@{ Match = $false; Reason = 'missing-executable-path' }
    }
    try {
        $path = $proc.Path
        if (-not $path) {
            return [pscustomobject]@{ Match = $false; Reason = 'path-unreadable' }
        }
        $trustedExpectedPath = Resolve-AiCliTrustedProxyExecutablePath -ProxyId $stateProxyId -Path $expectedPath
        $trustedActualPath = Resolve-AiCliTrustedProxyExecutablePath -ProxyId $stateProxyId -Path $path
        if (-not $trustedExpectedPath -or -not $trustedActualPath) {
            return [pscustomobject]@{ Match = $false; Reason = 'path-outside-managed-root' }
        }
        if (-not [string]::Equals($trustedActualPath, $trustedExpectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Match = $false; Reason = 'path-mismatch' }
        }
    } catch {
        return [pscustomobject]@{ Match = $false; Reason = 'path-unreadable' }
    }
    $nonce = Get-AiCliProperty $State 'nonce'
    if (-not $nonce) {
        return [pscustomobject]@{ Match = $false; Reason = 'missing-nonce' }
    }
    $listenerIdentity = Test-AiCliProxyListenerOwnership -State $State -ExpectedProcessId $processId
    if (-not $listenerIdentity.Match) {
        return [pscustomobject]@{
            Match = $false
            Reason = $listenerIdentity.Reason
            Process = $proc
            Listeners = $listenerIdentity.Listeners
        }
    }
    return [pscustomobject]@{ Match = $true; Reason = 'ok'; Process = $proc; Listeners = $listenerIdentity.Listeners }
}

function Stop-AiCliManagedProcess {
    param(
        [Parameter(Mandatory)][ValidateSet('ccp','cliproxy')][string]$ProxyId
    )
    $state = Get-AiCliProxyState -ProxyId $ProxyId
    $id = Test-AiCliProcessIdentity -State $state -Strict -ExpectedProxyId $ProxyId
    if (-not $id.Match) {
        throw "拒绝停止：进程身份不匹配（$($id.Reason)）。不会杀死未知占用者。"
    }
    try {
        $id.Process.Kill($true)
        if (-not $id.Process.WaitForExit(5000)) {
            throw '等待进程退出超时'
        }
        if (-not $id.Process.HasExited) {
            throw '进程仍在运行'
        }
    } catch {
        throw "停止进程失败: $($_.Exception.Message)"
    }
    Clear-AiCliProxyState -ProxyId $ProxyId
}
