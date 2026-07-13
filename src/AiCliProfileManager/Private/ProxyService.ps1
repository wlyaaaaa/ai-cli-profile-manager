# Managed third-party proxies: ccp = raine/claude-code-proxy, cliproxy = router-for-me/CLIProxyAPI

function Get-AiCliProxyMeta {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    switch ($ProxyId) {
        'ccp' {
            return [ordered]@{
                id            = 'ccp'
                displayName   = 'claude-code-proxy'
                ownerRepo     = 'raine/claude-code-proxy'
                preferredPort = 43197
                upstreamDefaultPort = 18765
                role          = 'ChatGPT→Claude 首选专用转换器（第三方）'
            }
        }
        'cliproxy' {
            return [ordered]@{
                id            = 'cliproxy'
                displayName   = 'CLIProxyAPI'
                ownerRepo     = 'router-for-me/CLIProxyAPI'
                preferredPort = 43198
                upstreamDefaultPort = 8317
                role          = '多协议备用代理（第三方，维护面更大）'
            }
        }
    }
}

function Get-AiCliProxyPaths {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $root = (Initialize-AiCliDirectories).ProxiesDir
    $base = Join-Path $root $ProxyId
    return [ordered]@{
        Root         = $base
        VersionsDir  = Join-Path $base 'versions'
        CurrentLink  = Join-Path $base 'current'
        DataDir      = Join-Path $base 'data'
        ConfigDir    = Join-Path $base 'data\config'
        AuthDir      = Join-Path $base 'data\auth'
        LogsDir      = Join-Path $base 'data\logs'
    }
}

function Initialize-AiCliProxyDirs {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $p = Get-AiCliProxyPaths -ProxyId $ProxyId
    foreach ($k in @('Root','VersionsDir','DataDir','ConfigDir','AuthDir','LogsDir')) {
        if (-not (Test-Path -LiteralPath $p[$k])) {
            New-Item -ItemType Directory -Force -Path $p[$k] | Out-Null
        }
    }
    return $p
}

function Get-AiCliCcpEnvironmentDelta {
    param(
        [Parameter(Mandatory)]$Paths,
        [int]$Port = 0
    )
    $delta = @{
        # v0.1.15: this override is the parent of codex/auth.json and config.json.
        CCP_CONFIG_DIR = [string]$Paths.AuthDir
        # v0.1.15 resolves Windows state/logs from LOCALAPPDATA. Keep those files
        # inside the aicli-managed proxy tree instead of the upstream global path.
        LOCALAPPDATA = [string]$Paths.LogsDir
    }
    if ($Port -gt 0) { $delta['PORT'] = [string]$Port }
    return $delta
}

function Get-AiCliCcpAuthArguments {
    param([ValidateSet('login','device','status','logout')][string]$Action)
    return @('codex', 'auth', $Action)
}

function Test-AiCliProxyAuthPresent {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $paths = Get-AiCliProxyPaths -ProxyId $ProxyId
    if (-not (Test-Path -LiteralPath $paths.AuthDir -PathType Container)) { return $false }
    if ($ProxyId -eq 'ccp') {
        return (Test-Path -LiteralPath (Join-Path $paths.AuthDir 'codex\auth.json') -PathType Leaf)
    }
    return (@(Get-ChildItem -LiteralPath $paths.AuthDir -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0)
}

function Get-AiCliApprovedArtifacts {
    $path = Get-AiCliDataPath -Relative 'proxy-artifacts\approved-windows-artifacts.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{ schemaVersion = 1; artifacts = @() }
    }
    return (Read-AiCliJsonFile -Path $path)
}

function Find-AiCliApprovedArtifact {
    param(
        [ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [string]$Version
    )
    $all = Get-AiCliApprovedArtifacts
    $arts = @($all.artifacts)
    return @($arts | Where-Object {
        (Get-AiCliProperty $_ 'proxyId') -eq $ProxyId -and (
            -not $Version -or (Get-AiCliProperty $_ 'version') -eq $Version
        )
    })
}

function Get-AiCliFileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($fs)
            return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
        } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

function Get-AiCliProxyExpectedExecutableName {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    if ($ProxyId -eq 'ccp') { return 'claude-code-proxy.exe' }
    return 'cli-proxy-api.exe'
}

function Find-AiCliProxyExecutableInDirectory {
    param(
        [ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [Parameter(Mandatory)][string]$Directory
    )
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
    $expected = Get-AiCliProxyExpectedExecutableName -ProxyId $ProxyId
    $matches = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        [string]::Equals($_.Name, $expected, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($matches.Count -ne 1) { return $null }
    return $matches[0].FullName
}

function Assert-AiCliProxyInstallStructure {
    param(
        [ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [Parameter(Mandatory)][string]$Directory
    )
    $exe = Find-AiCliProxyExecutableInDirectory -ProxyId $ProxyId -Directory $Directory
    if (-not $exe) {
        $expected = Get-AiCliProxyExpectedExecutableName -ProxyId $ProxyId
        throw "Proxy package does not contain exactly one expected executable: $expected"
    }
    return $exe
}

function Assert-AiCliProxyZipSafe {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DestinationRoot
    )
    $root = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd([char[]]@('\','/'))
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = [string]$entry.FullName
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ([string]::IsNullOrWhiteSpace($name) -or
                $name.StartsWith('/') -or $name.StartsWith('\') -or
                $name -match '^[A-Za-z]:' -or $name.Contains(':') -or
                $unixType -eq 0xA000) {
                throw "unsafe ZIP entry: $name"
            }
            $parts = @($name -split '[/\\]')
            if ($parts -contains '..') {
                throw "unsafe ZIP entry: $name"
            }
            $relative = $name.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $target = [IO.Path]::GetFullPath((Join-Path $root $relative))
            if ($target -ne $root -and -not $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "unsafe ZIP entry: $name"
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Set-AiCliProxyCurrentPointer {
    param(
        [ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [Parameter(Mandatory)][string]$CurrentLink,
        [Parameter(Mandatory)][string]$TargetDir
    )
    $null = Assert-AiCliProxyInstallStructure -ProxyId $ProxyId -Directory $TargetDir
    $parent = Split-Path -Parent $CurrentLink
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $currentItem = Get-Item -LiteralPath $CurrentLink -Force -ErrorAction SilentlyContinue
    if ($currentItem -and -not ($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'current pointer exists but is not a managed junction; refusing to replace it'
    }

    $suffix = [guid]::NewGuid().ToString('N')
    $candidate = Join-Path $parent (".current-next-$suffix")
    $backup = Join-Path $parent (".current-previous-$suffix")
    New-Item -ItemType Junction -Path $candidate -Target $TargetDir | Out-Null
    try {
        $null = Assert-AiCliProxyInstallStructure -ProxyId $ProxyId -Directory $candidate
        if ($currentItem) {
            Move-Item -LiteralPath $CurrentLink -Destination $backup
        }
        try {
            Move-Item -LiteralPath $candidate -Destination $CurrentLink
            $null = Assert-AiCliProxyInstallStructure -ProxyId $ProxyId -Directory $CurrentLink
        } catch {
            if (Test-Path -LiteralPath $CurrentLink) {
                Remove-Item -LiteralPath $CurrentLink -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $backup) {
                Move-Item -LiteralPath $backup -Destination $CurrentLink
            }
            throw
        }
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if (Test-Path -LiteralPath $candidate) {
            Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-AiCliProxy {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $lock = Enter-AiCliFileLock -TargetPath (Get-AiCliProxyGlobalLockTarget) -TimeoutMs 300000
    try {
        $paths = Get-AiCliProxyPaths -ProxyId $ProxyId
        $currentItem = Get-Item -LiteralPath $paths.CurrentLink -Force -ErrorAction SilentlyContinue
        if ($currentItem) {
            Write-AiCliErrorLine "0.1.0 暂不对已安装的 $ProxyId 执行受管更新；旧版本不会被替换。请等待具备运行健康回滚的后续版本。"
            return (Get-AiCliExitCode Unavailable)
        }
        return (Invoke-AiCliProxyFirstInstall -ProxyId $ProxyId)
    } finally {
        Exit-AiCliFileLock -Lock $lock
    }
}

function Invoke-AiCliProxyFirstInstall {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $meta = Get-AiCliProxyMeta -ProxyId $ProxyId
    $approved = Find-AiCliApprovedArtifact -ProxyId $ProxyId
    if (-not $approved -or @($approved).Count -eq 0) {
        Write-AiCliErrorLine "没有批准的 Windows artifact（缺少已知 SHA256）。"
        Write-AiCliInfo "按 D-020：未知版本绝不下载执行。"
        Write-AiCliInfo "仓库: https://github.com/$($meta.ownerRepo)"
        Write-AiCliInfo "请在 data/proxy-artifacts/approved-windows-artifacts.json 添加精确 version/asset/sha256 后重试。"
        Write-AiCliInfo "update-check 可报告上游新版本，但 install 在无批准证据时必须拒绝。"
        return (Get-AiCliExitCode Unavailable)
    }
    # pick latest approved entry (first with installable flag)
    $art = $approved | Select-Object -First 1
    $version = Get-AiCliProperty $art 'version'
    $url = Get-AiCliProperty $art 'downloadUrl'
    $sha = (Get-AiCliProperty $art 'sha256').ToLowerInvariant()
    $asset = Get-AiCliProperty $art 'assetName'

    if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($sha)) {
        Write-AiCliErrorLine '批准清单条目缺少 downloadUrl 或 sha256'
        return (Get-AiCliExitCode Unavailable)
    }

    $paths = Initialize-AiCliProxyDirs -ProxyId $ProxyId
    $cache = (Get-AiCliAppPaths).CacheDir
    if (-not (Test-Path $cache)) { New-Item -ItemType Directory -Force -Path $cache | Out-Null }
    $zip = Join-Path $cache "$ProxyId-$version-$asset"
    Write-AiCliInfo "下载 $url …"
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    } catch {
        Write-AiCliErrorLine "下载失败: $($_.Exception.Message)"
        return (Get-AiCliExitCode Unavailable)
    }
    $actual = Get-AiCliFileSha256 -Path $zip
    if ($actual -ne $sha) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Write-AiCliErrorLine "SHA256 不匹配。期望 $sha 实际 $actual。已删除下载文件。"
        return (Get-AiCliExitCode Unavailable)
    }

    $versionKey = "{0}-{1}" -f $version, $sha.Substring(0, [Math]::Min(12, $sha.Length))
    $verDir = Join-Path $paths.VersionsDir $versionKey
    $tmpDir = Join-Path $paths.VersionsDir (".tmp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    try {
        Assert-AiCliProxyZipSafe -ZipPath $zip -DestinationRoot $tmpDir
        Expand-Archive -LiteralPath $zip -DestinationPath $tmpDir -Force
        $null = Assert-AiCliProxyInstallStructure -ProxyId $ProxyId -Directory $tmpDir
        if (Test-Path -LiteralPath $verDir) {
            $null = Assert-AiCliProxyInstallStructure -ProxyId $ProxyId -Directory $verDir
            Remove-Item -LiteralPath $tmpDir -Recurse -Force
        } else {
            Move-Item -LiteralPath $tmpDir -Destination $verDir
        }
        $null = Assert-AiCliProxyInstallStructure -ProxyId $ProxyId -Directory $verDir
        Set-AiCliProxyCurrentPointer -ProxyId $ProxyId -CurrentLink $paths.CurrentLink -TargetDir $verDir
        Write-AiCliSuccess "已安装 $ProxyId $version （SHA256 已校验）"
        Write-AiCliInfo "下一步: aicli proxy $ProxyId configure"
        Write-AiCliInfo "然后: aicli proxy $ProxyId login"
        return (Get-AiCliExitCode Success)
    } catch {
        if (Test-Path $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-AiCliErrorLine $_.Exception.Message
        return (Get-AiCliExitCode InternalError)
    }
}

function Get-AiCliProxyExecutable {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $paths = Get-AiCliProxyPaths -ProxyId $ProxyId
    $current = $paths.CurrentLink
    $candidate = Find-AiCliProxyExecutableInDirectory -ProxyId $ProxyId -Directory $current
    if (-not $candidate) { return $null }
    # Never hand an executable to start/login/logout until its current
    # junction has resolved back into our non-reparse versions tree.
    return (Resolve-AiCliTrustedProxyExecutablePath -ProxyId $ProxyId -Path $candidate)
}

function Get-AiCliProxyMetaFile {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $paths = Initialize-AiCliProxyDirs -ProxyId $ProxyId
    return (Join-Path $paths.ConfigDir 'aicli-proxy.json')
}

function Get-AiCliProxyRuntimeMeta {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $path = Get-AiCliProxyMetaFile -ProxyId $ProxyId
    $meta = Read-AiCliJsonFile -Path $path -Default $null
    if ($null -eq $meta) {
        $meta = [ordered]@{
            host = '127.0.0.1'
            port = $null
            proxyId = $ProxyId
            localClientKey = ('aicli-local-' + [guid]::NewGuid().ToString('N').Substring(0, 24))
        }
    }
    if (-not (Get-AiCliProperty $meta 'localClientKey')) {
        if ($meta -is [System.Collections.IDictionary]) {
            $meta['localClientKey'] = ('aicli-local-' + [guid]::NewGuid().ToString('N').Substring(0, 24))
        } else {
            $meta | Add-Member -NotePropertyName localClientKey -NotePropertyValue ('aicli-local-' + [guid]::NewGuid().ToString('N').Substring(0, 24)) -Force
        }
    }
    return $meta
}

function Write-AiCliCliproxyConfigYaml {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$AuthDir,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$LocalClientKey
    )
    $authUnix = ($AuthDir -replace '\\', '/')
    $yaml = @"
# Generated by AI CLI Profile Manager — do not put upstream secrets in git
host: "127.0.0.1"
port: $Port
auth-dir: "$authUnix"
api-keys:
  - "$LocalClientKey"
remote-management:
  allow-remote: false
  secret-key: ""
  disable-control-panel: true
debug: false
logging-to-file: true
"@
    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ConfigPath, $yaml, $utf8NoBom)
}

function Set-AiCliProxyConfigure {
    param(
        [ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [int]$Port = 0,
        [switch]$AutoPort,
        [switch]$LockHeld,
        [switch]$DeferPersistedPort,
        [int[]]$ExcludePorts = @()
    )
    $lock = $null
    if (-not $LockHeld) {
        $lock = Enter-AiCliFileLock -TargetPath (Get-AiCliProxyGlobalLockTarget) -TimeoutMs 300000
    }
    try {
        $paths = Initialize-AiCliProxyDirs -ProxyId $ProxyId
        $meta = Get-AiCliProxyRuntimeMeta -ProxyId $ProxyId
        $existingSource = [string](Get-AiCliProperty $meta 'portSource')
        $existingPort = [int](Get-AiCliProperty $meta 'port')
        $portSource = 'auto'
        $port = if ($Port -gt 0) {
            $portSource = 'user'
            Select-AiCliProxyPort -ProxyId $ProxyId -UserPort $Port -ExcludePorts $ExcludePorts
        } elseif ($AutoPort) {
            $portSource = 'auto'
            Select-AiCliProxyPort -ProxyId $ProxyId -ExcludePorts $ExcludePorts
        } elseif ($existingSource -eq 'user' -and $existingPort -gt 0) {
            $portSource = 'user'
            Select-AiCliProxyPort -ProxyId $ProxyId -UserPort $existingPort -ExcludePorts $ExcludePorts
        } else {
            $portSource = 'auto'
            Select-AiCliProxyPort -ProxyId $ProxyId -PreferPersisted -ExcludePorts $ExcludePorts
        }
        $finalCheck = Test-AiCliPortCandidate -Port $port
        if (-not $finalCheck.Ok) {
            throw "端口在保存配置前已失效：$port ($($finalCheck.Reason))"
        }
        if (-not $DeferPersistedPort) {
            Save-AiCliProxyPort -ProxyId $ProxyId -Port $port
        }
        if ($meta -is [System.Collections.IDictionary]) {
            $meta['host'] = '127.0.0.1'
            $meta['port'] = $port
            $meta['proxyId'] = $ProxyId
            $meta['portSource'] = $portSource
            $meta['updatedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
            $localKey = [string]$meta['localClientKey']
        } else {
            $meta.host = '127.0.0.1'
            $meta.port = $port
            $meta.proxyId = $ProxyId
            $meta | Add-Member -NotePropertyName portSource -NotePropertyValue $portSource -Force
            $meta.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            $localKey = [string]$meta.localClientKey
        }
        $yamlPath = Join-Path $paths.ConfigDir 'config.yaml'
        if ($ProxyId -eq 'cliproxy') {
            Write-AiCliCliproxyConfigYaml -ConfigPath $yamlPath -AuthDir $paths.AuthDir -Port $port -LocalClientKey $localKey
            if ($meta -is [System.Collections.IDictionary]) { $meta['configYaml'] = $yamlPath } else { $meta | Add-Member configYaml $yamlPath -Force }
        }
        Write-AiCliJsonFile -Path (Get-AiCliProxyMetaFile -ProxyId $ProxyId) -Value $meta
        Write-AiCliSuccess "已配置 $ProxyId → 127.0.0.1:$port"
        if ($ProxyId -eq 'cliproxy') {
            Write-AiCliInfo "CLIProxyAPI 配置: $yamlPath"
            Write-AiCliInfo "本地客户端密钥仅用于 loopback（不打印完整值）。下一步: aicli proxy cliproxy login"
        } else {
            Write-AiCliInfo "下一步: aicli proxy ccp login  （ccp codex auth）"
        }
        return $port
    } finally {
        if ($lock) { Exit-AiCliFileLock -Lock $lock }
    }
}

function Start-AiCliProxyChildProcess {
    param([Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$StartInfo)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    if (-not $process.Start()) {
        $process.Dispose()
        throw '无法启动代理进程'
    }
    return $process
}

function Stop-AiCliStartedProcess {
    param([Parameter(Mandatory)]$Process)
    if ($Process.HasExited) { return }
    $Process.Kill($true)
    if (-not $Process.WaitForExit(5000) -or -not $Process.HasExited) {
        throw "无法清理启动失败的代理进程 PID=$($Process.Id)"
    }
}

function Test-AiCliProxyHttpProtocol {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 1500
    )
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
    $response = $null
    try {
        $uri = [Uri]("http://127.0.0.1:{0}/v1/models" -f $Port)
        $response = $client.GetAsync($uri).GetAwaiter().GetResult()
        return [pscustomobject]@{
            Responded = $true
            StatusCode = [int]$response.StatusCode
            Reason = 'http-response'
            ProbePath = '/v1/models'
        }
    } catch {
        return [pscustomobject]@{
            Responded = $false
            StatusCode = $null
            Reason = 'no-http-response'
            ProbePath = '/v1/models'
        }
    } finally {
        if ($response) { $response.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Wait-AiCliProxyReady {
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 15000,
        [int]$PollIntervalMs = 100
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastProtocolReason = $null
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($Process.HasExited) {
            $exitCode = $null
            try { $exitCode = $Process.ExitCode } catch {}
            return [pscustomobject]@{ Ready = $false; Reason = "process-exited:$exitCode"; Listeners = @() }
        }
        $listeners = @(Get-AiCliTcpListeners -Port $Port)
        if ($listeners.Count -gt 0) {
            foreach ($listener in $listeners) {
                if ([string]$listener.LocalAddress -ne '127.0.0.1') {
                    return [pscustomobject]@{ Ready = $false; Reason = 'unsafe-listener-address'; Listeners = $listeners }
                }
                if ([int]$listener.OwningProcess -ne [int]$Process.Id) {
                    return [pscustomobject]@{ Ready = $false; Reason = 'listener-owned-by-other-process'; Listeners = $listeners }
                }
            }
            $probe = Test-AiCliProxyHttpProtocol -Port $Port
            if ($probe.Responded) {
                return [pscustomobject]@{
                    Ready = $true
                    Reason = 'ready'
                    Listeners = $listeners
                    ProtocolStatusCode = $probe.StatusCode
                    ProbePath = $probe.ProbePath
                    AuthenticationVerified = $false
                    UpstreamVerified = $false
                }
            }
            $lastProtocolReason = $probe.Reason
        }
        Start-Sleep -Milliseconds $PollIntervalMs
    }
    if ($lastProtocolReason) {
        return [pscustomobject]@{ Ready = $false; Reason = "protocol-probe-failed:$lastProtocolReason"; Listeners = @() }
    }
    return [pscustomobject]@{ Ready = $false; Reason = 'startup-timeout'; Listeners = @() }
}

function New-AiCliProxyLoginStartInfo {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [hashtable]$EnvironmentDelta = @{}
    )
    return (New-AiCliProcessStartInfo -FileName $FileName -ArgumentList $ArgumentList `
        -WorkingDirectory $WorkingDirectory -EnvironmentDelta $EnvironmentDelta)
}

function Invoke-AiCliProxyInteractiveProcess {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [hashtable]$EnvironmentDelta = @{},
        [int]$TimeoutMs = 300000
    )
    $psi = New-AiCliProxyLoginStartInfo -FileName $FileName -ArgumentList $ArgumentList `
        -WorkingDirectory $WorkingDirectory -EnvironmentDelta $EnvironmentDelta
    $process = Start-AiCliProxyChildProcess -StartInfo $psi
    try {
        if (-not $process.WaitForExit($TimeoutMs)) {
            try {
                Stop-AiCliStartedProcess -Process $process
            } catch {
                throw "登录进程超时且清理失败：$($_.Exception.Message)"
            }
            return [pscustomobject]@{ Exited = $false; ExitCode = $null; ProcessId = $process.Id }
        }
        return [pscustomobject]@{ Exited = $true; ExitCode = $process.ExitCode; ProcessId = $process.Id }
    } finally {
        $process.Dispose()
    }
}

function Start-AiCliProxy {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $lock = Enter-AiCliFileLock -TargetPath (Get-AiCliProxyGlobalLockTarget) -TimeoutMs 300000
    $launchedProcess = $null
    $stateSaved = $false
    $committed = $false
    try {
        $state = Get-AiCliProxyState -ProxyId $ProxyId
        if ($state) {
            $idc = Test-AiCliProcessIdentity -State $state -Strict -ExpectedProxyId $ProxyId
            if ($idc.Match) {
                $probe = Test-AiCliProxyHttpProtocol -Port ([int](Get-AiCliProperty $state 'port'))
                if ($probe.Responded) {
                    Write-AiCliInfo "代理已在运行 PID=$($state.pid) port=$($state.port)，本地 HTTP 有明确响应。"
                    return (Get-AiCliExitCode Success)
                }
                Write-AiCliErrorLine "代理进程和监听仍匹配，但本地 HTTP 协议未响应。请先 aicli proxy $ProxyId stop，再重新 start。"
                return (Get-AiCliExitCode Unavailable)
            }
            $recordedPid = [int](Get-AiCliProperty $state 'pid')
            if ($recordedPid -gt 0) {
                $stillAlive = Get-Process -Id $recordedPid -ErrorAction SilentlyContinue
                if ($stillAlive) {
                    Write-AiCliErrorLine "已有状态指向仍在运行但身份不匹配的进程 PID=$recordedPid ($($idc.Reason))。为避免覆盖取证状态，本次拒绝再启动。"
                    return (Get-AiCliExitCode Unavailable)
                }
            }
        }
        $exe = Get-AiCliProxyExecutable -ProxyId $ProxyId
        if (-not $exe) {
            Write-AiCliErrorLine "未安装可执行文件。下一步: aicli proxy $ProxyId install"
            return (Get-AiCliExitCode Unavailable)
        }
        $paths = Get-AiCliProxyPaths -ProxyId $ProxyId
        $excludedPorts = @()
        $fastExitRetryUsed = $false
        $proc = $null
        $port = 0
        $meta = $null
        $nonce = $null
        $ready = $false
        $maxAttempts = @(Get-AiCliCandidatePorts -ProxyId $ProxyId).Count + 1
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $port = [int](Set-AiCliProxyConfigure -ProxyId $ProxyId -LockHeld -DeferPersistedPort -ExcludePorts $excludedPorts)
            $meta = Get-AiCliProxyRuntimeMeta -ProxyId $ProxyId
            if ($port -le 0) { throw '代理配置没有返回有效端口' }
            $finalPortCheck = Test-AiCliPortCandidate -Port $port
            if (-not $finalPortCheck.Ok) {
                $excludedPorts += $port
                continue
            }
            $nonce = [guid]::NewGuid().ToString('N')
            $argList = @()
            $environmentDelta = @{
                'AICLI_PROXY_ID' = $ProxyId
                'AICLI_PROXY_NONCE' = $nonce
            }
            if ($ProxyId -eq 'cliproxy') {
                $yaml = Join-Path $paths.ConfigDir 'config.yaml'
                if (-not (Test-Path -LiteralPath $yaml)) {
                    Write-AiCliCliproxyConfigYaml -ConfigPath $yaml -AuthDir $paths.AuthDir -Port $port -LocalClientKey (Get-AiCliProperty $meta 'localClientKey')
                }
                $argList = @('-config', $yaml)
            } else {
                # claude-code-proxy v0.1.15 takes the port from PORT, not a
                # --port argument. --no-monitor is required for a managed child.
                $argList = @('serve', '--no-monitor')
                $ccpEnvironment = Get-AiCliCcpEnvironmentDelta -Paths $paths -Port $port
                foreach ($key in $ccpEnvironment.Keys) {
                    $environmentDelta[$key] = $ccpEnvironment[$key]
                }
            }
            $psi = New-AiCliProcessStartInfo -FileName $exe -ArgumentList $argList `
                -WorkingDirectory (Split-Path $exe) -EnvironmentDelta $environmentDelta
            $proc = Start-AiCliProxyChildProcess -StartInfo $psi
            $launchedProcess = $proc
            $readiness = Wait-AiCliProxyReady -Process $proc -Port $port
            if ($readiness.Ready) {
                $ready = $true
                break
            }
            $launchedPid = [int]$proc.Id
            $cleanupSucceeded = $false
            try {
                Stop-AiCliStartedProcess -Process $proc
                $cleanupSucceeded = $true
            } catch {
                throw "代理启动验证失败（$($readiness.Reason)），且清理进程失败：$($_.Exception.Message)"
            } finally {
                if ($cleanupSucceeded) {
                    try { $proc.Dispose() } catch {}
                    $launchedProcess = $null
                }
            }
            $retry = $readiness.Reason -eq 'listener-owned-by-other-process'
            if ($readiness.Reason -eq 'unsafe-listener-address') {
                $retry = -not (@($readiness.Listeners | Where-Object { [int]$_.OwningProcess -eq $launchedPid }).Count -gt 0)
            }
            if ($readiness.Reason -like 'process-exited:*' -and -not $fastExitRetryUsed) {
                $fastExitRetryUsed = $true
                $retry = $true
            }
            if (-not $retry) {
                throw "代理启动验证失败：$($readiness.Reason)。进程已停止，未保存运行状态。"
            }
            $excludedPorts += $port
            $proc = $null
        }
        if (-not $ready -or -not $proc) {
            throw '候选端口均未能形成由新进程持有的安全 loopback listener。'
        }
        $actualExecutablePath = $exe
        try {
            $reportedExecutablePath = $proc.MainModule.FileName
            if (-not [string]::IsNullOrWhiteSpace([string]$reportedExecutablePath)) {
                $actualExecutablePath = [string]$reportedExecutablePath
            }
        } catch {}
        $actualExecutablePath = Resolve-AiCliTrustedProxyExecutablePath -ProxyId $ProxyId -Path $actualExecutablePath
        if (-not $actualExecutablePath) {
            throw '已启动进程的可执行文件不在对应代理的受管版本目录。'
        }
        $stateObj = [ordered]@{
            proxyId         = $ProxyId
            pid             = $proc.Id
            startTimeUtc    = $proc.StartTime.ToUniversalTime().ToString('o')
            executablePath  = $actualExecutablePath
            versionDir      = (Split-Path -Parent $actualExecutablePath)
            configPath      = (Get-AiCliProxyMetaFile -ProxyId $ProxyId)
            host            = '127.0.0.1'
            port            = $port
            nonce           = $nonce
            localClientKeyPresent = [bool](Get-AiCliProperty $meta 'localClientKey')
            listenerVerified = $true
            protocolProbePath = $readiness.ProbePath
            protocolStatusCode = $readiness.ProtocolStatusCode
            authenticationVerified = $false
            upstreamVerified = $false
        }
        Save-AiCliProxyState -ProxyId $ProxyId -State $stateObj
        $stateSaved = $true
        Save-AiCliProxyPort -ProxyId $ProxyId -Port $port
        $committed = $true
        $startedPid = [int]$proc.Id
        try { $proc.Dispose() } catch {}
        $launchedProcess = $null
        Write-AiCliSuccess "已启动 $ProxyId PID=$startedPid 127.0.0.1:$port"
        Write-AiCliInfo "登录（如需要）: aicli proxy $ProxyId login"
        return (Get-AiCliExitCode Success)
    } catch {
        $failure = $_.Exception.Message
        if (-not $committed -and $launchedProcess) {
            try {
                Stop-AiCliStartedProcess -Process $launchedProcess
                try { $launchedProcess.Dispose() } catch {}
                $launchedProcess = $null
                if ($stateSaved) {
                    Clear-AiCliProxyState -ProxyId $ProxyId
                    $stateSaved = $false
                }
                $failure += ' 本次启动的进程已清理。'
            } catch {
                $failure += " 清理本次进程失败：$($_.Exception.Message)；状态未静默删除。"
            }
        }
        Write-AiCliErrorLine $failure
        return (Get-AiCliExitCode Unavailable)
    } finally {
        Exit-AiCliFileLock -Lock $lock
    }
}

function Stop-AiCliProxy {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $lock = Enter-AiCliFileLock -TargetPath (Get-AiCliProxyGlobalLockTarget) -TimeoutMs 300000
    try {
        try {
            Stop-AiCliManagedProcess -ProxyId $ProxyId
            Write-AiCliSuccess "已停止 $ProxyId"
            return (Get-AiCliExitCode Success)
        } catch {
            Write-AiCliErrorLine $_.Exception.Message
            return (Get-AiCliExitCode Unavailable)
        }
    } finally {
        Exit-AiCliFileLock -Lock $lock
    }
}

function Get-AiCliProxyStatus {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId, [switch]$Json)
    $meta = Get-AiCliProxyMeta -ProxyId $ProxyId
    $state = Get-AiCliProxyState -ProxyId $ProxyId
    $idc = Test-AiCliProcessIdentity -State $state -Strict -ExpectedProxyId $ProxyId
    $exe = Get-AiCliProxyExecutable -ProxyId $ProxyId
    $protocolProbe = $null
    if ($idc.Match) {
        $protocolProbe = Test-AiCliProxyHttpProtocol -Port ([int](Get-AiCliProperty $state 'port'))
    }
    $protocolVerified = [bool]($protocolProbe -and $protocolProbe.Responded)
    $result = New-AiCliResult -Command "proxy $ProxyId status" -OverallStatus $(if ($idc.Match -and $protocolVerified) { '可用' } elseif ($exe) { '可用但有限制' } else { '不可用' }) -Extra @{
        proxyId = $ProxyId
        meta = $meta
        running = [bool]$idc.Match
        processAndListenerVerified = [bool]$idc.Match
        protocolResponded = $protocolVerified
        protocolStatusCode = $(if ($protocolProbe) { $protocolProbe.StatusCode } else { $null })
        authenticationVerified = $false
        upstreamVerified = $false
        identityReason = $idc.Reason
        state = $(if ($state) { Protect-AiCliObject $state } else { $null })
        executable = $exe
    }
    if ($Json) { Write-AiCliJson $result } else {
        Write-Host ("代理: {0} ({1})" -f $meta.displayName, $meta.ownerRepo)
        Write-Host ("角色: {0}" -f $meta.role)
        Write-Host ("安装: {0}" -f $(if ($exe) { $exe } else { '未安装' }))
        Write-Host ("进程/监听: {0}" -f $(if ($idc.Match) { "已验证 PID=$($state.pid) 127.0.0.1:$($state.port)" } else { "未验证 ($($idc.Reason))" }))
        Write-Host ("本地 HTTP 协议: {0}" -f $(if ($protocolVerified) { "有明确响应 HTTP $($protocolProbe.StatusCode)" } else { '未验证' }))
        Write-Host '认证/上游连通: 未验证（status 不调用真实 Provider）'
    }
    return (Get-AiCliExitCodeFromStatus $result.overallStatus)
}

function Invoke-AiCliProxyLogin {
    param(
        [ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [ValidateSet('codex','claude','device')][string]$Provider = 'codex'
    )
    $exe = Get-AiCliProxyExecutable -ProxyId $ProxyId
    $meta = Get-AiCliProxyMeta -ProxyId $ProxyId
    Write-AiCliInfo "登录由上游代理交互完成；本工具不读取 OAuth token 正文。"
    Write-AiCliInfo "仓库: https://github.com/$($meta.ownerRepo)"
    if (-not $exe) {
        Write-AiCliErrorLine "未安装。下一步: aicli proxy $ProxyId install"
        return (Get-AiCliExitCode Unavailable)
    }
    $null = Set-AiCliProxyConfigure -ProxyId $ProxyId
    $paths = Get-AiCliProxyPaths -ProxyId $ProxyId
    $argList = @()
    $workDir = Split-Path $exe
    if ($ProxyId -eq 'cliproxy') {
        $yaml = Join-Path $paths.ConfigDir 'config.yaml'
        # Tibo 路线：Codex OAuth → CLIProxyAPI → Claude Code
        $flag = switch ($Provider) {
            'claude' { '-claude-login' }
            'device' { '-codex-device-login' }
            default { '-codex-login' }
        }
        $argList = @($flag, '-config', $yaml)
        Write-AiCliInfo "将启动: $exe $($argList -join ' ')"
        Write-AiCliInfo "请在浏览器完成 ChatGPT/Codex 授权；凭据写入: $($paths.AuthDir)"
        Write-AiCliWarn "第三方代理；Tibo 分享 ≠ OpenAI 官方背书。仅 loopback。"
        # Interactive: inherit the terminal, but preserve each argument as an ArgumentList entry.
        $run = Invoke-AiCliProxyInteractiveProcess -FileName $exe -ArgumentList $argList -WorkingDirectory $workDir
        if (-not $run.Exited) {
            Write-AiCliWarn '登录进程等待超时，未确认成功。'
            return (Get-AiCliExitCode Limited)
        }
        if ([int]$run.ExitCode -ne 0) {
            Write-AiCliWarn "登录进程退出码为 $($run.ExitCode)，未确认成功。"
            return (Get-AiCliExitCode Limited)
        }
        $authFiles = @(Get-ChildItem -LiteralPath $paths.AuthDir -File -ErrorAction SilentlyContinue)
        if ($authFiles.Count -gt 0) {
            Write-AiCliSuccess "检测到 auth 目录已有 $($authFiles.Count) 个文件（不列出内容）。"
            Write-AiCliInfo "下一步: aicli proxy cliproxy start"
            Write-AiCliInfo "然后: aicli start claude-chatgpt-cliproxy"
            return (Get-AiCliExitCode Success)
        }
        Write-AiCliWarn "未检测到 auth 文件。若浏览器未弹出，可手动运行："
        Write-Host "  & '$exe' -codex-login -config '$yaml'"
        Write-Host "  或设备码: & '$exe' -codex-device-login -config '$yaml'"
        return (Get-AiCliExitCode Limited)
    }

    # ccp v0.1.15: codex auth login|device|status|logout. All commands must use
    # the same CCP_CONFIG_DIR as the managed serve process.
    $ccpEnvironment = Get-AiCliCcpEnvironmentDelta -Paths $paths
    $authAction = if ($Provider -eq 'device') { 'device' } else { 'login' }
    $argList = Get-AiCliCcpAuthArguments -Action $authAction
    Write-AiCliInfo "将启动: $exe $($argList -join ' ')"
    Write-AiCliInfo "凭据只写入本项目隔离目录: $($paths.AuthDir)"
    $run = Invoke-AiCliProxyInteractiveProcess -FileName $exe -ArgumentList $argList `
        -WorkingDirectory $workDir -EnvironmentDelta $ccpEnvironment
    if (-not $run.Exited -or [int]$run.ExitCode -ne 0) {
        Write-AiCliWarn "登录未确认成功（退出码：$($run.ExitCode)）。"
        return (Get-AiCliExitCode Limited)
    }
    try {
        $status = Invoke-AiCliChildCapture -FileName $exe `
            -ArgumentList (Get-AiCliCcpAuthArguments -Action status) `
            -EnvironmentDelta $ccpEnvironment -WorkingDirectory $workDir -TimeoutMs 15000
    } catch {
        Write-AiCliWarn "无法完成 codex auth status 确认：$((Protect-AiCliSecretText $_.Exception.Message))"
        return (Get-AiCliExitCode Limited)
    }
    if ([int]$status.ExitCode -ne 0 -or -not (Test-AiCliProxyAuthPresent -ProxyId ccp)) {
        Write-AiCliWarn '上游登录命令已结束，但 codex auth status 或隔离凭据文件未通过确认。'
        return (Get-AiCliExitCode Limited)
    }
    Write-AiCliSuccess 'ccp Codex OAuth 已由上游 status 和隔离凭据文件确认。'
    Write-AiCliInfo "完成后: aicli proxy ccp start && aicli start claude-chatgpt-ccp"
    return (Get-AiCliExitCode Success)
}

function Invoke-AiCliProxyLogout {
    param(
        [ValidateSet('ccp','cliproxy')][string]$ProxyId,
        [switch]$PurgeLocalAuth,
        [switch]$Yes
    )
    $local = '未删除'
    $remote = '未执行（上游需手动撤销时请打开对应账号安全页）'
    $upstreamLogoutSucceeded = $false
    $purgeSucceeded = $false
    try {
        $exe = Get-AiCliProxyExecutable -ProxyId $ProxyId
        if ($exe -and $ProxyId -eq 'cliproxy') {
            # CLIProxyAPI 7.2.72 exposes login flags but no logout command.
            # Passing a positional "logout" may start the server instead, so
            # never execute it. Users can explicitly purge this product's
            # isolated local auth and revoke remotely from the account page.
            $local = 'CLIProxyAPI 未提供 logout 子命令；未删除本地认证目录'
        } elseif ($exe) {
            try {
                $paths = Get-AiCliProxyPaths -ProxyId $ProxyId
                $logoutArgs = Get-AiCliCcpAuthArguments -Action logout
                $logoutEnvironment = Get-AiCliCcpEnvironmentDelta -Paths $paths
                $logout = Invoke-AiCliChildCapture -FileName $exe -ArgumentList $logoutArgs `
                    -EnvironmentDelta $logoutEnvironment -WorkingDirectory (Split-Path $exe) -TimeoutMs 8000
                if ([int]$logout.ExitCode -eq 0) {
                    $local = '已请求上游 logout（本地）'
                    $upstreamLogoutSucceeded = $true
                } else {
                    $local = "上游 logout 返回非零退出码 $($logout.ExitCode)"
                }
            } catch {
                $local = '上游 logout 子命令不可用'
            }
        } else {
            $local = '未安装可执行文件，跳过上游 logout'
        }
    } catch {}

    if ($PurgeLocalAuth) {
        if (-not (Confirm-AiCliAction -Message "将强制删除本项目隔离的 $ProxyId 本地认证目录（不等于远程撤销 OAuth）" -Yes:$Yes)) {
            Write-AiCliWarn '用户取消 purge'
            Write-Host "本地凭据: $local"
            Write-Host "远程撤销: $remote"
            return (Get-AiCliExitCode Cancelled)
        }
        # ensure stopped first if ours
        try { Stop-AiCliManagedProcess -ProxyId $ProxyId } catch {}
        $auth = (Get-AiCliProxyPaths -ProxyId $ProxyId).AuthDir
        # Delete only an authentication directory that is provably below the
        # managed proxy root. A missing directory already satisfies the purge;
        # recreate the empty directory so subsequent upstream commands have a
        # deterministic private location.
        $root = (Get-AiCliProxyPaths -ProxyId $ProxyId).Root
        $rootPrefix = $root.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if (-not $auth.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "认证目录不在受管代理根目录下，拒绝删除: $auth"
        }
        if (Test-Path -LiteralPath $auth) {
            if ((Get-Item -LiteralPath $auth -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "认证目录是重解析点，拒绝递归删除: $auth"
            }
            if ($auth.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $auth -Recurse -Force
            }
        }
        New-Item -ItemType Directory -Force -Path $auth | Out-Null
        $local = '已强制删除本项目隔离认证目录'
        $purgeSucceeded = $true
    }
    Write-Host "本地凭据: $local"
    Write-Host "远程撤销: $remote"
    Write-AiCliWarn '删除本地 OAuth 文件 ≠ 远程撤销。请在 ChatGPT/上游账号安全设置中确认已授权应用。'
    if ($upstreamLogoutSucceeded -or $purgeSucceeded) {
        return (Get-AiCliExitCode Success)
    }
    return (Get-AiCliExitCode Limited)
}

function Invoke-AiCliProxyUpdateCheck {
    param([ValidateSet('ccp','cliproxy')][string]$ProxyId)
    $meta = Get-AiCliProxyMeta -ProxyId $ProxyId
    $approved = Find-AiCliApprovedArtifact -ProxyId $ProxyId
    Write-Host ("仓库: https://github.com/{0}/releases" -f $meta.ownerRepo)
    if (@($approved).Count -gt 0) {
        Write-Host '已批准可安装版本:'
        foreach ($a in $approved) {
            Write-Host ("  - {0} sha256={1}" -f (Get-AiCliProperty $a 'version'), (Get-AiCliProperty $a 'sha256'))
        }
    } else {
        Write-Host '当前没有批准 artifact；发现上游新版本也不会自动执行。'
    }
    Write-Host '提示: 将新版本 SHA256 写入 approved-windows-artifacts.json 后才能 install/update。'
    return (Get-AiCliExitCode Success)
}
