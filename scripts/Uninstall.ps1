#Requires -Version 7.0
param(
    [switch]$PurgeUserData,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '..\src\AiCliProfileManager\AiCliProfileManager.psd1'
if (Test-Path -LiteralPath $module) {
    Import-Module $module -Force
    $tokens = @('uninstall')
    if ($PurgeUserData) { $tokens += '--purge-user-data' }
    if ($Yes) { $tokens += '--yes' }
    exit (Invoke-AiCli -Tokens $tokens)
}

function Get-AiCliFallbackModuleCandidates {
    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($p in ($env:PSModulePath -split ';' | Where-Object { $_ })) {
        if ($p -notmatch '(?i)Program Files|WindowsApps|system32') {
            [void]$items.Add((Join-Path $p 'AiCliProfileManager'))
        }
    }
    [void]$items.Add((Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\AiCliProfileManager'))
    return @($items | Select-Object -Unique)
}

function Test-AiCliFallbackManagedModuleDirectory {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not [string]::Equals($item.Name, 'AiCliProfileManager', [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $versionCount = 0
        foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
            if (-not $child.PSIsContainer) {
                if ([string]::Equals($child.Name, 'current-link-note.txt', [StringComparison]::OrdinalIgnoreCase)) { continue }
                return $false
            }
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            try { $directoryVersion = [version]$child.Name } catch { return $false }
            if ($directoryVersion.ToString() -ne $child.Name) { return $false }
            $manifest = Join-Path $child.FullName 'AiCliProfileManager.psd1'
            $rootModule = Join-Path $child.FullName 'AiCliProfileManager.psm1'
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf) -or
                -not (Test-Path -LiteralPath $rootModule -PathType Leaf)) { return $false }
            $data = Import-PowerShellDataFile -LiteralPath $manifest
            if ([string]$data.GUID -ne 'a1c11c11-0a11-4c11-b111-a1c110110011' -or
                [string]$data.RootModule -ne 'AiCliProfileManager.psm1' -or
                [version][string]$data.ModuleVersion -ne $directoryVersion) { return $false }
            $versionCount++
        }
        return ($versionCount -gt 0)
    } catch {}
    return $false
}

$candidates = [System.Collections.Generic.List[string]]::new()
foreach ($candidate in (Get-AiCliFallbackModuleCandidates)) { [void]$candidates.Add($candidate) }
$existingCandidates = @($candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
foreach ($dest in $existingCandidates) {
    if (-not (Test-AiCliFallbackManagedModuleDirectory -Path $dest)) {
        throw "发现同名但身份无法确认的模块目录，拒绝递归删除: $dest"
    }
}

# Prefer the installed product itself so proxy identity checks and the complete
# unified uninstall path remain available even when this standalone script no
# longer sits next to repository source.
$installed = [System.Collections.Generic.List[object]]::new()
foreach ($dest in $candidates) {
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) { continue }
    foreach ($versionDir in @(Get-ChildItem -LiteralPath $dest -Directory -Force -ErrorAction SilentlyContinue)) {
        $manifest = Get-Item -LiteralPath (Join-Path $versionDir.FullName 'AiCliProfileManager.psd1') -ErrorAction SilentlyContinue
        if (-not $manifest) { continue }
        try {
            $data = Import-PowerShellDataFile -LiteralPath $manifest.FullName
            if ([string]$data.GUID -eq 'a1c11c11-0a11-4c11-b111-a1c110110011' -and
                [string]$data.RootModule -eq 'AiCliProfileManager.psm1' -and
                [version][string]$data.ModuleVersion -eq [version]$versionDir.Name) {
                [void]$installed.Add([pscustomobject]@{
                    Manifest = $manifest.FullName
                    Version = [version][string]$data.ModuleVersion
                })
            }
        } catch {}
    }
}
foreach ($entry in @($installed | Sort-Object Version -Descending)) {
    try {
        Import-Module -Name $entry.Manifest -Force -ErrorAction Stop
        $loaded = Get-Module -Name AiCliProfileManager | Where-Object {
            $_.Guid -eq [guid]'a1c11c11-0a11-4c11-b111-a1c110110011' -and
            [string]::Equals($_.ModuleBase, (Split-Path -Parent $entry.Manifest), [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        $command = Get-Command Invoke-AiCli -ErrorAction Stop
        if ($loaded -and $command.Module -and $command.Module.Guid -eq $loaded.Guid -and
            [string]::Equals($command.Module.ModuleBase, $loaded.ModuleBase, [StringComparison]::OrdinalIgnoreCase)) {
            $tokens = @('uninstall')
            if ($PurgeUserData) { $tokens += '--purge-user-data' }
            if ($Yes) { $tokens += '--yes' }
            exit (Invoke-AiCli -Tokens $tokens)
        }
    } catch {
        Remove-Module AiCliProfileManager -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '模块源和可加载的已安装模块均不可用；进入受限清理。'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AiCliProfileManager\state'
$proxyStates = @(Get-ChildItem -LiteralPath $stateRoot -File -Filter 'proxy-*.json' -ErrorAction SilentlyContinue)
if ($proxyStates.Count -gt 0) {
    throw '检测到受管代理状态，但模块不可用，无法安全核验并停止进程。请先重新安装同版本，再运行 aicli uninstall。'
}

if (-not $Yes) {
    Write-Host '将清理 AI CLI Profile Manager 的垫片、用户 PATH 项和 PowerShell Profile 块。'
    if ($existingCandidates.Count -gt 0) {
        Write-Host '还将删除以下已确认的模块目录：'
        $existingCandidates | ForEach-Object { Write-Host "  $_" }
    }
    if ($PurgeUserData) {
        Write-Host '还将彻底删除用户 Profile、DPAPI 密钥和代理本地数据。'
    }
    if ((Read-Host '继续？输入 yes') -ne 'yes') {
        Write-Host '已取消；未继续清理 PATH、垫片或 PowerShell Profile。'
        exit 6
    }
}
foreach ($dest in $existingCandidates) {
    Remove-Item -LiteralPath $dest -Recurse -Force
    Write-Host "已删除 $dest"
}

if ($PurgeUserData) {
    foreach ($dataDir in @(
        (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'AiCliProfileManager'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AiCliProfileManager')
    )) {
        if (Test-Path -LiteralPath $dataDir) {
            Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $dataDir) { throw "用户数据目录未能删除: $dataDir" }
        }
    }
    Write-Host '已删除用户 Profile、DPAPI 密钥和代理本地数据。'
}

$bin = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'aicli\bin'
foreach ($name in @('aicli.ps1','aicli.cmd')) {
    $file = Join-Path $bin $name
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}
if ((Test-Path -LiteralPath $bin) -and -not (Get-ChildItem -LiteralPath $bin -Force -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $bin -Force -ErrorAction SilentlyContinue
}

$userPath = [string][Environment]::GetEnvironmentVariable('Path', 'User')
$target = $bin.TrimEnd('\','/')
$newPath = (@($userPath -split ';' | Where-Object {
    $part = ([string]$_).Trim()
    $part -and -not [string]::Equals($part.TrimEnd('\','/'), $target, [StringComparison]::OrdinalIgnoreCase)
}) -join ';')
if ($newPath -ne $userPath) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }

$profilePath = $PROFILE.CurrentUserCurrentHost
if (Test-Path -LiteralPath $profilePath) {
    $text = [IO.File]::ReadAllText($profilePath)
    $clean = [regex]::Replace(
        $text,
        '(?ms)# >>> AI CLI Profile Manager >>>\r?\n.*?# <<< AI CLI Profile Manager <<<',
        ''
    )
    if ($clean -ne $text) { [IO.File]::WriteAllText($profilePath, $clean, [Text.UTF8Encoding]::new($false)) }
}
Write-Host '已移除 aicli 垫片、用户 PATH 项与受管 PowerShell Profile 块。'
