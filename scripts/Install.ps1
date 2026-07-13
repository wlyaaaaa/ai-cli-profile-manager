#Requires -Version 7.0
<#
.SYNOPSIS
  Install AI CLI Profile Manager for the current user (no administrator required).
#>
param(
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Force,
    [switch]$SkipShellIntegration
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

Write-Host "安装 $moduleName $version → $destVer"
if ((Test-Path -LiteralPath $destVer) -and -not $Force) {
    throw '目标版本已存在；默认拒绝覆盖。确认要替换时请重新运行并加 -Force。'
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
try {
    New-Item -ItemType Directory -Force -Path $tempVer | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $tempVer -Recurse -Force
    $dataSrc = Join-Path $SourceRoot 'data'
    if (Test-Path -LiteralPath $dataSrc) {
        Copy-Item -LiteralPath $dataSrc -Destination (Join-Path $tempVer 'data') -Recurse -Force
    }

    Write-Host '验证候选版本…'
    Test-InstallCandidateModule -CandidateManifest (Join-Path $tempVer 'AiCliProfileManager.psd1') -ExpectedVersion $version

    if (Test-Path -LiteralPath $destVer) {
        Move-Item -LiteralPath $destVer -Destination $backupVer
    }
    try {
        Move-Item -LiteralPath $tempVer -Destination $destVer
    } catch {
        if ((Test-Path -LiteralPath $backupVer) -and -not (Test-Path -LiteralPath $destVer)) {
            Move-Item -LiteralPath $backupVer -Destination $destVer
        }
        throw
    }
    if (Test-Path -LiteralPath $backupVer) { Remove-Item -LiteralPath $backupVer -Recurse -Force }
} finally {
    if (Test-Path -LiteralPath $tempVer) { Remove-Item -LiteralPath $tempVer -Recurse -Force -ErrorAction SilentlyContinue }
}

$current = Join-Path $dest 'current-link-note.txt'
Set-Content -LiteralPath $current -Value "Installed version: $version" -Encoding utf8
Test-InstallCandidateModule -CandidateManifest (Join-Path $destVer 'AiCliProfileManager.psd1') -ExpectedVersion $version
Write-Host "OK: aicli 模块版本 $version"

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
