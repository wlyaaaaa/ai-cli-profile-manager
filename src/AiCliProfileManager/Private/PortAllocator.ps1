# Managed proxy port allocation per PORT-POLICY.md

function Get-AiCliProxyGlobalLockTarget {
    $paths = Initialize-AiCliDirectories
    return (Join-Path $paths.LocksDir 'managed-proxy-allocation-start.lock')
}

function Get-AiCliPortPoolConfig {
    $path = Get-AiCliDataPath -Relative 'ports\managed-proxy-ports.json'
    if (Test-Path -LiteralPath $path) {
        return (Read-AiCliJsonFile -Path $path)
    }
    return [ordered]@{
        schemaVersion = 1
        pool          = @(43192..43209)
        preferred     = [ordered]@{ ccp = 43197; cliproxy = 43198 }
    }
}

function Get-AiCliCandidatePorts {
    param(
        [Parameter(Mandatory)][ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [int]$UserPort = 0
    )
    if ($UserPort -gt 0) {
        if ($UserPort -lt 1024 -or $UserPort -gt 49151) {
            throw "用户端口必须在 1024-49151：$UserPort"
        }
        return @($UserPort)
    }
    $cfg = Get-AiCliPortPoolConfig
    # Normalize to [int] — JSON numbers may deserialize as Int64 and break IndexOf equality
    $pool = @((Get-AiCliProperty $cfg 'pool') | ForEach-Object { [int]$_ })
    if ($pool.Count -eq 0) { $pool = @(43192..43209) }
    $defaults = @{ ccp = 43197; cliproxy = 43198 }
    $pref = [int]$defaults[$ProxyId]
    $preferred = Get-AiCliProperty $cfg 'preferred'
    if ($null -ne $preferred) {
        $fromCfg = Get-AiCliProperty $preferred $ProxyId
        if ($null -ne $fromCfg) { $pref = [int]$fromCfg }
    }
    if ($pref -le 0) { $pref = [int]$pool[0] }
    $idx = 0
    for ($i = 0; $i -lt $pool.Count; $i++) {
        if ([int]$pool[$i] -eq $pref) { $idx = $i; break }
    }
    $ordered = [System.Collections.Generic.List[int]]::new()
    for ($i = $idx; $i -lt $pool.Count; $i++) { $ordered.Add([int]$pool[$i]) | Out-Null }
    for ($i = 0; $i -lt $idx; $i++) { $ordered.Add([int]$pool[$i]) | Out-Null }
    return @($ordered)
}

function Get-AiCliNetshPortRanges {
    param(
        [ValidateSet('ipv4','ipv6')][string]$Protocol = 'ipv4',
        [ValidateSet('dynamicport','excludedportrange')][string]$Kind = 'dynamicport',
        [ValidateSet('active','persistent')][string]$Store = 'active'
    )
    $cliArgs = @('int', $Protocol, 'show', $Kind, 'protocol=tcp', "store=$Store")
    try {
        $outputLines = @(& netsh @cliArgs 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        throw "netsh query failed: $Protocol/$Kind/$Store"
    }
    if ($null -eq $exitCode -or [int]$exitCode -ne 0) {
        throw "netsh query failed: $Protocol/$Kind/$Store exit=$exitCode"
    }
    $output = $outputLines | Out-String
    $ranges = @(Parse-AiCliNetshRanges -Text $output -Kind $Kind)
    if ($Kind -eq 'dynamicport' -and $ranges.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($output)) {
        throw "netsh parse failed: $Protocol/$Kind/$Store"
    }
    if ($Kind -eq 'excludedportrange' -and $Store -eq 'active' -and [string]::IsNullOrWhiteSpace($output)) {
        throw "netsh parse failed: $Protocol/$Kind/$Store"
    }
    return $ranges
}

function Parse-AiCliNetshRanges {
    param([string]$Text, [string]$Kind)
    $ranges = @()
    if ($Kind -eq 'dynamicport') {
        # English: Start Port : 49152  Number of Ports : 16384
        # Chinese variants may use different labels; match numbers near start/number
        $start = $null; $count = $null
        if ($Text -match '(?i)Start Port\s*[:=]\s*(\d+)') { $start = [int]$Matches[1] }
        elseif ($Text -match '起始端口\s*[:=]?\s*(\d+)') { $start = [int]$Matches[1] }
        if ($Text -match '(?i)Number of Ports\s*[:=]\s*(\d+)') { $count = [int]$Matches[1] }
        elseif ($Text -match '端口数\s*[:=]?\s*(\d+)') { $count = [int]$Matches[1] }
        if ($null -ne $start -and $null -ne $count) {
            $ranges += [pscustomobject]@{ Start = $start; End = $start + $count - 1 }
        }
    } else {
        # excluded: lines with start and end numbers
        foreach ($line in ($Text -split "`r?`n")) {
            if ($line -match '(\d+)\s+(\d+)') {
                $a = [int]$Matches[1]; $b = [int]$Matches[2]
                if ($a -ge 1024 -and $b -ge $a) {
                    $ranges += [pscustomobject]@{ Start = $a; End = $b }
                }
            }
        }
    }
    return $ranges
}

function Test-AiCliPortInRanges {
    param([int]$Port, $Ranges)
    foreach ($r in $Ranges) {
        if ($Port -ge $r.Start -and $Port -le $r.End) { return $true }
    }
    return $false
}

function Get-AiCliListeningPorts {
    $set = @{}
    foreach ($listener in (Get-AiCliTcpListeners)) {
        $set[[int]$listener.LocalPort] = $true
    }
    return $set
}

function Get-AiCliTcpListeners {
    [CmdletBinding()]
    param([int]$Port = 0)

    try {
        $query = @{ State = 'Listen'; ErrorAction = 'Stop' }
        if ($Port -gt 0) { $query['LocalPort'] = $Port }
        $rows = @(Get-NetTCPConnection @query)
        return @($rows | ForEach-Object {
            [pscustomobject]@{
                LocalAddress  = [string]$_.LocalAddress
                LocalPort     = [int]$_.LocalPort
                OwningProcess = [int]$_.OwningProcess
            }
        })
    } catch {
        $result = @()
        foreach ($line in @(netstat -ano -p tcp 2>$null)) {
            $parts = @($line.Trim() -split '\s+')
            if ($parts.Count -lt 5 -or $parts[0] -ne 'TCP' -or $parts[3] -ne 'LISTENING') {
                continue
            }
            $local = [string]$parts[1]
            $address = $null
            $localPort = 0
            if ($local -match '^\[(.+)\]:(\d+)$') {
                $address = $Matches[1]
                $localPort = [int]$Matches[2]
            } elseif ($local -match '^(.+):(\d+)$') {
                $address = $Matches[1]
                $localPort = [int]$Matches[2]
            }
            if ($localPort -le 0 -or ($Port -gt 0 -and $localPort -ne $Port)) {
                continue
            }
            $result += [pscustomobject]@{
                LocalAddress  = $address
                LocalPort     = $localPort
                OwningProcess = [int]$parts[4]
            }
        }
        return @($result)
    }
}

function Test-AiCliPortBindable {
    param([int]$Port)
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        # exclusive-ish: default TcpListener exclusive address use on Windows when possible
        $listener.ExclusiveAddressUse = $true
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) {
            try { $listener.Stop() } catch {}
        }
    }
}

function Test-AiCliPortCandidate {
    param([int]$Port)
    if ($Port -lt 1024 -or $Port -gt 49151) {
        return [pscustomobject]@{ Ok = $false; Reason = 'out-of-range' }
    }
    try {
        $dyn = @()
        foreach ($protocol in @('ipv4','ipv6')) {
            foreach ($store in @('active','persistent')) {
                $dyn += Get-AiCliNetshPortRanges -Protocol $protocol -Kind dynamicport -Store $store
            }
        }
        if (Test-AiCliPortInRanges -Port $Port -Ranges $dyn) {
            return [pscustomobject]@{ Ok = $false; Reason = 'dynamic-range' }
        }
        $excl = @()
        foreach ($protocol in @('ipv4','ipv6')) {
            foreach ($store in @('active','persistent')) {
                $excl += Get-AiCliNetshPortRanges -Protocol $protocol -Kind excludedportrange -Store $store
            }
        }
        if (Test-AiCliPortInRanges -Port $Port -Ranges $excl) {
            return [pscustomobject]@{ Ok = $false; Reason = 'excluded-range' }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = 'netsh-query-failed' }
    }
    $listening = Get-AiCliListeningPorts
    if ($listening.ContainsKey($Port)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'listening' }
    }
    if (-not (Test-AiCliPortBindable -Port $Port)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'bind-failed' }
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'ok' }
}

function Test-AiCliPortReservedByOtherProxy {
    param(
        [Parameter(Mandatory)][ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [Parameter(Mandatory)][int]$Port
    )
    $settings = Get-AiCliSettings
    $ports = Get-AiCliProperty $settings 'proxyPorts'
    $otherId = if ($ProxyId -eq 'ccp') { 'cliproxy' } else { 'ccp' }
    $otherPort = Get-AiCliProperty $ports $otherId
    return ($null -ne $otherPort -and [int]$otherPort -eq $Port)
}

function Select-AiCliProxyPort {
    param(
        [Parameter(Mandatory)][ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [int]$UserPort = 0,
        [switch]$PreferPersisted,
        [int[]]$ExcludePorts = @()
    )
    $settings = Get-AiCliSettings
    if ($PreferPersisted -and -not $UserPort) {
        $persisted = Get-AiCliProperty $settings.proxyPorts $ProxyId
        if ($persisted) {
            $persistedPort = [int]$persisted
            $check = Test-AiCliPortCandidate -Port $persistedPort
            if ($persistedPort -in $ExcludePorts) {
                $check = [pscustomobject]@{ Ok = $false; Reason = 'excluded-by-caller' }
            } elseif (Test-AiCliPortReservedByOtherProxy -ProxyId $ProxyId -Port $persistedPort) {
                $check = [pscustomobject]@{ Ok = $false; Reason = 'reserved-by-other-proxy' }
            }
            if ($check.Ok) { return [int]$persisted }
            # if our process already holds it, caller handles reuse
        }
    }
    $candidates = Get-AiCliCandidatePorts -ProxyId $ProxyId -UserPort $UserPort
    $failures = @()
    foreach ($p in $candidates) {
        if ($p -in $ExcludePorts) {
            $failures += "port $p : excluded-by-caller"
            continue
        }
        if (Test-AiCliPortReservedByOtherProxy -ProxyId $ProxyId -Port $p) {
            $failures += "port $p : reserved-by-other-proxy"
            continue
        }
        $check = Test-AiCliPortCandidate -Port $p
        if ($check.Ok) { return $p }
        $failures += "port $p : $($check.Reason)"
    }
    throw ("无法为 {0} 分配安全端口。原因：{1}。可手动：aicli proxy {0} configure --port <端口>" -f $ProxyId, ($failures -join '; '))
}

function Save-AiCliProxyPort {
    param(
        [ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [int]$Port
    )
    $s = Get-AiCliSettings
    if (-not $s.proxyPorts) { $s.proxyPorts = [ordered]@{} }
    if ($s.proxyPorts -is [System.Collections.IDictionary]) {
        $s.proxyPorts[$ProxyId] = $Port
    } else {
        $s.proxyPorts | Add-Member -NotePropertyName $ProxyId -NotePropertyValue $Port -Force
    }
    Save-AiCliSettings -Settings $s
}
