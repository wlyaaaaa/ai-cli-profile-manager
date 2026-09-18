#Requires -Version 7.0
<#
.SYNOPSIS
  Install AI CLI Profile Manager for the current user (no administrator required).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$DryRun,
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Force,
    [switch]$SkipShellIntegration,
    [string]$RetirementRootOverride
)

$ErrorActionPreference = 'Stop'
$moduleName = 'AiCliProfileManager'
$src = Join-Path $SourceRoot 'src\AiCliProfileManager'
$manifestPath = Join-Path $src 'AiCliProfileManager.psd1'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "找不到模块源: $src" }
$version = [string](Import-PowerShellDataFile -LiteralPath $manifestPath).ModuleVersion

$destRoot = $null
foreach ($p in ($env:PSModulePath -split ';' | Where-Object { $_ })) {
    if ($p -match '(?i)[\\/]PowerShell[\\/]Modules$' -and
        $p -notmatch '(?i)Program Files|WindowsApps|system32') {
        $destRoot = $p
        break
    }
}
if (-not $destRoot) {
    $destRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
}
$dest = Join-Path $destRoot $moduleName
$destVer = Join-Path $dest $version
$tempVer = Join-Path $dest (".$version.install-" + [guid]::NewGuid().ToString('N'))
$backupVer = Join-Path $dest (".$version.backup-" + [guid]::NewGuid().ToString('N'))
$migrationScript = Join-Path $SourceRoot 'scripts\Invoke-AiCliRetirementMigration.ps1'
if (-not (Test-Path -LiteralPath $migrationScript -PathType Leaf)) {
    throw "找不到退役迁移脚本: $migrationScript"
}
$migrationParameters = @{
    ModuleRoot = $dest
    CurrentVersion = $version
    FailOnBlocked = $true
}
if (-not [string]::IsNullOrWhiteSpace($RetirementRootOverride)) {
    $retirementRoot = [IO.Path]::GetFullPath($RetirementRootOverride)
    $migrationParameters.RoamingRoot = Join-Path $retirementRoot 'Roaming\AiCliProfileManager'
    $migrationParameters.LocalRoot = Join-Path $retirementRoot 'Local\AiCliProfileManager'
    $migrationParameters.CodexHome = Join-Path $retirementRoot 'codex'
}

function Test-InstallCandidateModule {
    param(
        [Parameter(Mandatory)][string]$CandidateManifest,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    # Validate in an isolated runspace so installing from a development tree,
    # or replacing a loaded version, never leaves two same-named modules in
    # the caller's session.
    $powershell = [powershell]::Create()
    $modulePathBefore = $env:PSModulePath
    try {
        $script = {
            param($Manifest, $Expected)
            $ErrorActionPreference = 'Stop'
            Import-Module -Name $Manifest -Force
            if ((Get-AiCliVersion) -ne $Expected) {
                throw '候选模块版本与 Manifest 不一致。'
            }
        }
        $null = $powershell.AddScript($script).AddArgument($CandidateManifest).AddArgument($ExpectedVersion)
        $null = $powershell.Invoke()
        if ($powershell.HadErrors) {
            $messages = @($powershell.Streams.Error | ForEach-Object { $_.Exception.Message })
            throw ($messages -join ' | ')
        }
    } finally {
        $powershell.Dispose()
        $env:PSModulePath = $modulePathBefore
    }
}

function Remove-InstallDirectorySafely {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedParent
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolvedPath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
    $resolvedParent = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($ExpectedParent))
    $actualParent = [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath((Split-Path -Parent $resolvedPath))
    )
    if ($actualParent -cne $resolvedParent) {
        throw "拒绝删除安装根目录之外的路径: $resolvedPath"
    }
    $item = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "拒绝递归删除非普通安装目录或重解析点: $resolvedPath"
    }
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function Test-InstallDirectoryMoveRetryableLock {
    param([Parameter(Mandatory)][Exception]$Exception)
    $current = $Exception
    while ($current) {
        if ($current -is [IO.IOException]) {
            $win32Code = [int]($current.HResult -band 0xFFFF)
            if ($win32Code -in @(32, 33)) { return $true }
        }
        $current = $current.InnerException
    }
    return $false
}

function Move-InstallDirectoryAtomically {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedParent,
        [ValidateRange(0,2000)][int]$WaitForLockMs = 2000
    )
    $sourcePath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Source))
    $destinationPath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Destination))
    $parentPath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($ExpectedParent))
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        throw "安装事务模块父目录不存在: $parentPath"
    }
    $parentItem = Get-Item -LiteralPath $parentPath -Force -ErrorAction Stop
    if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "安装事务拒绝使用重解析点模块父目录: $parentPath"
    }
    foreach ($path in @($sourcePath, $destinationPath)) {
        $actualParent = [IO.Path]::TrimEndingDirectorySeparator(
            [IO.Path]::GetFullPath((Split-Path -Parent $path))
        )
        if ($actualParent -cne $parentPath) {
            throw "安装事务目录必须位于同一模块父目录: $path"
        }
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "安装事务源目录不存在: $sourcePath"
    }
    if (Test-Path -LiteralPath $destinationPath) {
        throw "安装事务目标目录已存在: $destinationPath"
    }
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "安装事务拒绝移动重解析点: $sourcePath"
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $lastException = $null
    do {
        try {
            [IO.Directory]::Move($sourcePath, $destinationPath)
            return
        } catch {
            $lastException = $_.Exception
            if (-not (Test-InstallDirectoryMoveRetryableLock -Exception $lastException)) {
                throw $lastException
            }
        }
        $remainingMs = $WaitForLockMs - [int]$stopwatch.ElapsedMilliseconds
        if ($remainingMs -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Min(100, $remainingMs))
        }
    } while ($remainingMs -gt 0)
    throw $lastException
}

if ($DryRun) {
    [ordered]@{schema='aicli.install-plan.v1';write_mode='zero_write';source=$src;destination=$destVer;version=$version;installed=$false} | ConvertTo-Json
    return
}
if (-not $PSCmdlet.ShouldProcess($destVer, 'Install the verified AICLI module and run its managed retirement migration')) { return }
Write-Host "安装 $moduleName $version → $destVer"
if ((Test-Path -LiteralPath $destVer) -and -not $Force) {
    throw '目标版本已存在；默认拒绝覆盖。确认要替换时请重新运行并加 -Force。'
}
if (Test-Path -LiteralPath $destVer) {
    $existingItem = Get-Item -LiteralPath $destVer -Force -ErrorAction Stop
    if (-not $existingItem.PSIsContainer -or
        ($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        [IO.Path]::GetFullPath((Split-Path -Parent $existingItem.FullName)) -cne
            [IO.Path]::GetFullPath($dest)) {
        throw '现有同版本模块不是目标模块根下的普通目录；拒绝替换。'
    }
    $existingManifest = Join-Path $existingItem.FullName 'AiCliProfileManager.psd1'
    $existingRootModule = Join-Path $existingItem.FullName 'AiCliProfileManager.psm1'
    if (-not (Test-Path -LiteralPath $existingManifest -PathType Leaf) -or
        -not (Test-Path -LiteralPath $existingRootModule -PathType Leaf)) {
        throw '现有同版本模块身份不完整；拒绝替换。'
    }
    $existingIdentity = Import-PowerShellDataFile -LiteralPath $existingManifest
    if ([string]$existingIdentity.GUID -cne 'a1c11c11-0a11-4c11-b111-a1c110110011' -or
        [string]$existingIdentity.RootModule -cne 'AiCliProfileManager.psm1' -or
        [string]$existingIdentity.ModuleVersion -cne $version) {
        throw '现有同版本模块身份不匹配；拒绝替换。'
    }
}

# Abort before copying the new version if any old runnable identity cannot be
# proven safe to quarantine. Unknown or user-modified files are never deleted.
$null = & $migrationScript @migrationParameters -PreflightOnly

New-Item -ItemType Directory -Force -Path $dest | Out-Null
$migrationResult = $null
$backupCreated = $false
$candidatePromoted = $false
try {
    New-Item -ItemType Directory -Force -Path $tempVer | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $tempVer -Recurse -Force
    $dataSrc = Join-Path $SourceRoot 'data'
    if (Test-Path -LiteralPath $dataSrc) {
        Copy-Item -LiteralPath $dataSrc -Destination (Join-Path $tempVer 'data') -Recurse -Force
    }

    Write-Host '验证候选版本…'
    Test-InstallCandidateModule -CandidateManifest (Join-Path $tempVer 'AiCliProfileManager.psd1') -ExpectedVersion $version

    try {
        if (Test-Path -LiteralPath $destVer) {
            Move-InstallDirectoryAtomically -Source $destVer -Destination $backupVer `
                -ExpectedParent $dest
            $backupCreated = $true
        }
        Move-InstallDirectoryAtomically -Source $tempVer -Destination $destVer `
            -ExpectedParent $dest
        $candidatePromoted = $true

        # Keep the previous same-version payload until both the promoted bytes
        # and the retirement migration have completed. A migration failure is
        # an installation failure, so the prior installation is restored.
        Test-InstallCandidateModule `
            -CandidateManifest (Join-Path $destVer 'AiCliProfileManager.psd1') `
            -ExpectedVersion $version
        $migrationResult = & $migrationScript @migrationParameters
    } catch {
        $originalError = $_
        try {
            if ($candidatePromoted -and (Test-Path -LiteralPath $destVer)) {
                Remove-InstallDirectorySafely -Path $destVer -ExpectedParent $dest
                $candidatePromoted = $false
            }
            if ($backupCreated -and (Test-Path -LiteralPath $backupVer) -and
                -not (Test-Path -LiteralPath $destVer)) {
                Move-InstallDirectoryAtomically -Source $backupVer -Destination $destVer `
                    -ExpectedParent $dest
                $backupCreated = $false
            }
        } catch {
            throw "安装失败且旧版本恢复失败: $($originalError.Exception.Message) | $($_.Exception.Message)"
        }
        throw $originalError
    }
    if (Test-Path -LiteralPath $backupVer) {
        Remove-InstallDirectorySafely -Path $backupVer -ExpectedParent $dest
        $backupCreated = $false
    }
} finally {
    if (Test-Path -LiteralPath $tempVer) {
        try { Remove-InstallDirectorySafely -Path $tempVer -ExpectedParent $dest } catch {}
    }
}

$current = Join-Path $dest 'current-link-note.txt'
Set-Content -LiteralPath $current -Value "Installed version: $version" -Encoding utf8
Write-Host "OK: aicli 模块版本 $version"
if (@($migrationResult.moved).Count -gt 0) {
    Write-Host ("已将 {0} 个可验证的 Qwen3.7 遗留入口移入可恢复隔离区: {1}" -f `
        @($migrationResult.moved).Count, $migrationResult.quarantineRoot)
}

if ($SkipShellIntegration) {
    Write-Host '已跳过 PATH 与 PowerShell Profile 集成。'
    return
}

# PATH shim (works in cmd / Windows PowerShell / pwsh without relying on profile)
try {
    $bin = Join-Path $env:LOCALAPPDATA 'aicli\bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $shimPs1 = Join-Path $bin 'aicli.ps1'
    $shimBody = @'
#Requires -Version 7.0
$ErrorActionPreference = "Stop"
Import-Module AiCliProfileManager -ErrorAction Stop
$code = Invoke-AiCli -Tokens $args
exit $code
'@
    Set-Content -LiteralPath $shimPs1 -Value $shimBody -Encoding utf8
    $cmdLines = @(
        '@echo off',
        'setlocal',
        'set "SHIM=%LOCALAPPDATA%\aicli\bin\aicli.ps1"',
        'if not exist "%SHIM%" (echo [aicli] missing shim & exit /b 5)',
        'pwsh -NoLogo -NoProfile -File "%SHIM%" %*',
        'exit /b %ERRORLEVEL%'
    )
    [System.IO.File]::WriteAllLines((Join-Path $bin 'aicli.cmd'), $cmdLines)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
    if ($parts -notcontains $bin) {
        [Environment]::SetEnvironmentVariable('Path', ($bin + ';' + $userPath).TrimEnd(';'), 'User')
        Write-Host "已加入用户 PATH: $bin （请新开终端生效）"
    } else {
        Write-Host "用户 PATH 已含: $bin"
    }
} catch {
    Write-Host "PATH 垫片未完成（可忽略）: $($_.Exception.Message)"
}

# Profile auto-import + PATH shim fallback
try {
    $profilePath = $PROFILE.CurrentUserCurrentHost
    $profileDir = Split-Path -Parent $profilePath
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    }
    $importBlock = @'

# >>> AI CLI Profile Manager >>>
$__aicliOk = $false
try {
  if (-not (Get-Module AiCliProfileManager -ErrorAction SilentlyContinue)) {
    Import-Module AiCliProfileManager -ErrorAction Stop
  }
  $__aicliOk = [bool](Get-Command aicli -ErrorAction SilentlyContinue)
} catch { $__aicliOk = $false }
if (-not $__aicliOk) {
  $shim = Join-Path $env:LOCALAPPDATA 'aicli\bin\aicli.cmd'
  if (Test-Path -LiteralPath $shim) {
    Set-Alias -Name aicli -Value $shim -Scope Global -Force -ErrorAction SilentlyContinue
  }
}
# <<< AI CLI Profile Manager <<<
'@
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Set-Content -LiteralPath $profilePath -Value $importBlock.TrimStart() -Encoding utf8
        Write-Host "已写入 PowerShell 配置: $profilePath"
    } else {
        $raw = [IO.File]::ReadAllText($profilePath)
        if ($raw -match '(?m)^# >>> AI CLI Profile Manager >>>\r?$' -and
            $raw -match '(?m)^# <<< AI CLI Profile Manager <<<\r?$') {
            Write-Host "配置文件已含 aicli 相关导入: $profilePath"
        } else {
            $useCrLf = $raw.Contains("`r`n")
            $normalized = $raw.Replace("`r`n", "`n")
            $legacy = $importBlock.Replace('# >>> AI CLI Profile Manager >>>', '# AI CLI Profile Manager')
            $legacy = [regex]::Replace($legacy, '(?m)^# <<< AI CLI Profile Manager <<<\r?\n?', '')
            $legacy = $legacy.Replace("`r`n", "`n").Trim()
            $hadLegacy = $normalized.Contains($legacy)
            if ($hadLegacy) { $normalized = $normalized.Replace($legacy, '') }
            $normalized = $normalized.TrimEnd("`r", "`n")
            $managed = $importBlock.Replace("`r`n", "`n").Trim()
            $combined = if ([string]::IsNullOrWhiteSpace($normalized)) {
                $managed
            } else {
                $normalized + "`n`n" + $managed
            }
            if ($useCrLf) { $combined = $combined.Replace("`n", "`r`n") }
            [IO.File]::WriteAllText($profilePath, $combined, [Text.UTF8Encoding]::new($false))
            Write-Host $(if ($hadLegacy) { "已迁移旧版自动导入块: $profilePath" } else { "已追加自动导入到: $profilePath" })
        }
    }
    Write-Host '新开终端后可在任意工作区目录运行: aicli version'
    Write-Host '若当前窗口仍提示找不到 aicli，先执行:'
    Write-Host '  $env:Path = "$env:LOCALAPPDATA\aicli\bin;" + $env:Path'
    Write-Host '首次建议: aicli setup'
} catch {
    Write-Host "OK: 模块已安装。未能写入 `$PROFILE: $($_.Exception.Message)"
    Write-Host '可手动: Import-Module AiCliProfileManager; aicli setup'
}
