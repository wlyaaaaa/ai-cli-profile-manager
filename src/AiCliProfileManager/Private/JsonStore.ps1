# Atomic JSON store with process-level file locks and corrupt-file recovery.

function Get-AiCliLockPath {
    param([Parameter(Mandatory)][string]$TargetPath)
    $paths = Get-AiCliAppPaths
    $safe = ($TargetPath -replace '[\\/:*?"<>|]', '_')
    return (Join-Path $paths.LocksDir ($safe + '.lock'))
}

function Enter-AiCliFileLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [int]$TimeoutMs = 10000
    )
    $lockPath = Get-AiCliLockPath -TargetPath $TargetPath
    $dir = Split-Path -Parent $lockPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            return [pscustomobject]@{ FileStream = $fs; LockPath = $lockPath }
        } catch {
            if ($sw.ElapsedMilliseconds -ge $TimeoutMs) {
                throw "无法获取文件锁: $TargetPath"
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Exit-AiCliFileLock {
    param($Lock)
    if ($null -eq $Lock) { return }
    try { $Lock.FileStream.Dispose() } catch {}
}

function Read-AiCliJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [object]$Default = $null
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        return ($raw | ConvertFrom-Json -AsHashtable -Depth 100)
    } catch {
        $backup = "$Path.corrupt.$(Get-Date -Format 'yyyyMMddHHmmss')"
        try { Copy-Item -LiteralPath $Path -Destination $backup -Force } catch {}
        Write-AiCliLog -Level Warn -Message "JSON 损坏，已备份到 $backup : $($_.Exception.Message)"
        return $Default
    }
}

function Write-AiCliJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [switch]$SkipLock
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $lock = $null
    if (-not $SkipLock) {
        $lock = Enter-AiCliFileLock -TargetPath $Path
    }
    try {
        $json = $Value | ConvertTo-Json -Depth 100 -Compress:$false
        # Ensure UTF-8 no BOM for JSON
        $tmp = Join-Path $dir (".{0}.{1}.tmp" -f [IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        # validate round-trip
        $null = [System.IO.File]::ReadAllText($tmp, $utf8NoBom) | ConvertFrom-Json -AsHashtable -Depth 100
        if (Test-Path -LiteralPath $Path) {
            $bakDir = (Get-AiCliAppPaths).BackupsDir
            if (-not (Test-Path -LiteralPath $bakDir)) { New-Item -ItemType Directory -Force -Path $bakDir | Out-Null }
            $bakName = ("{0}.{1}.bak" -f [IO.Path]::GetFileName($Path), (Get-Date -Format 'yyyyMMddHHmmss'))
            Copy-Item -LiteralPath $Path -Destination (Join-Path $bakDir $bakName) -Force
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } finally {
        if ($lock) { Exit-AiCliFileLock -Lock $lock }
        if (Test-Path -LiteralPath $tmp -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}
