# Build launch plan, native view, eject scripts.

function Build-AiCliLaunchPlan {
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [string]$ProjectPath,
        [string[]]$NativeArgs = @()
    )
    $merged = Get-AiCliResolvedProfile -Id $ProfileId
    if (-not (Get-AiCliProperty $merged 'configured')) {
        $tid = Get-AiCliProperty $merged 'templateId'
        if (-not $tid) { $tid = $ProfileId }
        throw "Profile 未配置完成。下一步：aicli profile configure $tid"
    }
    $project = Resolve-AiCliProjectPath -Project $ProjectPath
    $engine = Get-AiCliProperty $merged 'engine'
    $proxyPort = 0
    $proxyRef = Get-AiCliProperty $merged 'proxyRef'
    if ($proxyRef) {
        $state = Get-AiCliProxyState -ProxyId $proxyRef
        if ($state) {
            $idcheck = Test-AiCliProcessIdentity -State $state
            if ($idcheck.Match) {
                $proxyPort = [int](Get-AiCliProperty $state 'port')
            }
        }
        if ($proxyPort -le 0) {
            # try persisted port for planning native view; start will require running
            $settings = Get-AiCliSettings
            $pp = Get-AiCliProperty $settings.proxyPorts $proxyRef
            if ($pp) { $proxyPort = [int]$pp }
        }
    }

    if ($engine -eq 'codex') {
        return (Build-AiCliCodexLaunchPlan -MergedProfile $merged -ProjectPath $project -NativeArgs $NativeArgs)
    }
    if ($engine -eq 'claude') {
        return (Build-AiCliClaudeLaunchPlan -MergedProfile $merged -ProjectPath $project -NativeArgs $NativeArgs -ProxyPort $proxyPort)
    }
    if ($engine -eq 'interpreter') {
        return (Build-AiCliInterpreterLaunchPlan -MergedProfile $merged -ProjectPath $project -NativeArgs $NativeArgs)
    }
    throw "未知引擎: $engine"
}

function Show-AiCliNative {
    param([Parameter(Mandatory)][string]$ProfileId)
    $plan = Build-AiCliLaunchPlan -ProfileId $ProfileId
    $merged = Get-AiCliResolvedProfile -Id $ProfileId
    Write-Host ''
    Write-Host ("=== native: {0} ===" -f $ProfileId)
    Write-Host ("引擎: {0}" -f (Get-AiCliProperty $plan 'engine'))
    Write-Host ("可执行文件: {0}" -f (Get-AiCliProperty $plan 'fileName'))
    Write-Host ("工作目录: {0}" -f (Get-AiCliProperty $plan 'workingDirectory'))
    $argList = @((Get-AiCliProperty $plan 'argumentList') | ForEach-Object { $_ })
    $safeArgs = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $argList.Count; $i++) {
        $a = [string]$argList[$i]
        $prev = if ($i -gt 0) { [string]$argList[$i - 1] } else { '' }
        if ($prev -in @('--api_key', '-ak', '--api-key') -or $a -match '(?i)(sk-[A-Za-z0-9_\-\.]{8,}|api[_-]?key\s*=)') {
            [void]$safeArgs.Add('***')
        } else {
            $disp = Protect-AiCliSecretText -Text $a
            if ($disp -match '\s') { $disp = '"{0}"' -f $disp }
            [void]$safeArgs.Add($disp)
        }
    }
    Write-Host ("参数: {0}" -f ($safeArgs -join ' '))
    Write-Host '子进程环境（秘密已脱敏）:'
    $envDelta = Get-AiCliProperty $plan 'environmentDelta'
    $envShow = Protect-AiCliObject -InputObject $envDelta
    if ($envShow -is [System.Collections.IDictionary]) {
        foreach ($k in $envShow.Keys) {
            Write-Host ("  {0}={1}" -f $k, $envShow[$k])
        }
    }
    $removeEnv = @((Get-AiCliProperty $plan 'removeEnvironment') | ForEach-Object { $_ })
    if ($removeEnv.Count -gt 0) {
        Write-Host ('清除变量: ' + ($removeEnv -join ', '))
    }
    $configFiles = @((Get-AiCliProperty $plan 'configFiles') | ForEach-Object { $_ })
    if ($configFiles.Count -gt 0) {
        Write-Host '配置文件:'
        foreach ($f in $configFiles) { Write-Host "  $f" }
    }
    Write-Host '说明:'
    foreach ($n in @((Get-AiCliProperty $plan 'notes') | ForEach-Object { $_ })) { Write-Host "  - $n" }
    Write-Host ("数据去向: {0}" -f (Get-AiCliProperty $merged 'dataDestination'))
    $effort = Get-AiCliProperty $plan 'effort'
    $model = Get-AiCliProperty $plan 'model'
    if ($model) { Write-Host ("模型: {0}" -f $model) }
    if ($effort) { Write-Host ("思考等级: {0}" -f $effort) }
    Write-Host ''
}

function Export-AiCliEject {
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [string]$OutputPath
    )
    $merged = Get-AiCliResolvedProfile -Id $ProfileId
    $plan = Build-AiCliLaunchPlan -ProfileId $ProfileId
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path (Get-Location).Path $ProfileId
    }
    $out = [System.IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $out) {
        throw "目标已存在，拒绝覆盖: $out 。请指定 --output <新路径>"
    }
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    $readme = @"
# 导出配方: $ProfileId

由 $(Get-AiCliProductName) eject 生成。不含 API Key / OAuth。

## 引擎
$((Get-AiCliProperty $plan 'engine'))

## 启动
见 ``start.ps1``。运行前请自行设置密钥环境变量。

## 说明
$(($plan.notes | ForEach-Object { "- $_" }) -join "`n")

## 数据去向
$(Get-AiCliProperty $merged 'dataDestination')

## 限制
- 不包含秘密
- 代理型配方需要重新安装与重新登录
- 本目录可脱离 aicli 维护
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Join-Path $out 'README.md'), $readme, $utf8NoBom)

    $envLines = @()
    foreach ($k in $plan.environmentDelta.Keys) {
        $val = $plan.environmentDelta[$k]
        if ($k -match '(?i)(KEY|TOKEN|SECRET|PASSWORD)') {
            $envLines += "`$env:$k = `$env:AICLI_EJECT_SECRET  # 请在运行前设置"
        } else {
            $safe = $val -replace "'", "''"
            $envLines += "`$env:$k = '$safe'"
        }
    }
    foreach ($k in $plan.removeEnvironment) {
        $envLines += "Remove-Item Env:$k -ErrorAction SilentlyContinue"
    }

    $argList = ($plan.argumentList | ForEach-Object { "'{0}'" -f ($_ -replace "'", "''") }) -join ', '
    $startPs1 = @"
# Generated by aicli eject — no secrets embedded
# Requires: PowerShell 7+, upstream CLI installed
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath '$($plan.workingDirectory -replace "'", "''")'
$($envLines -join "`n")
`$exe = '$($plan.fileName -replace "'", "''")'
`$args = @($argList)
`$psi = New-Object System.Diagnostics.ProcessStartInfo
`$psi.FileName = `$exe
`$psi.UseShellExecute = `$false
foreach (`$a in `$args) { [void]`$psi.ArgumentList.Add(`$a) }
foreach (`$e in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
  try { `$psi.Environment[`$e.Key] = [string]`$e.Value } catch {}
}
$($envLines -join "`n")
# Re-apply env to psi
$(($plan.environmentDelta.Keys | ForEach-Object {
  if ($_ -match '(?i)(KEY|TOKEN|SECRET|PASSWORD)') {
    "`$psi.Environment['$_'] = [string]`$env:AICLI_EJECT_SECRET"
  } else {
    $v = $plan.environmentDelta[$_] -replace "'", "''"
    "`$psi.Environment['$_'] = '$v'"
  }
}) -join "`n")
`$p = [System.Diagnostics.Process]::Start(`$psi)
`$p.WaitForExit()
exit `$p.ExitCode
"@
    # Write with BOM for Chinese-safe ps1
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText((Join-Path $out 'start.ps1'), $startPs1, $utf8Bom)

    $proxyRef = Get-AiCliProperty $merged 'proxyRef'
    if ($proxyRef) {
        $artPath = Get-AiCliDataPath -Relative 'proxy-artifacts\approved-windows-artifacts.json'
        $lock = if (Test-Path $artPath) { Get-Content -LiteralPath $artPath -Raw -Encoding utf8 } else { '{"note":"no approved artifacts yet"}' }
        [System.IO.File]::WriteAllText((Join-Path $out 'proxy-lock.json'), $lock, $utf8NoBom)
        $proxyReadme = @"
# 代理重建说明 ($proxyRef)

1. 查看 proxy-lock.json 中的精确仓库、tag、asset、SHA256。
2. 仅当 SHA256 命中批准清单时才可执行下载的二进制。
3. 配置监听 127.0.0.1，不要暴露到局域网。
4. 使用上游登录流程重新登录；本导出不包含 OAuth。
5. 启动代理后再运行 start.ps1。
"@
        [System.IO.File]::WriteAllText((Join-Path $out 'PROXY.md'), $proxyReadme, $utf8NoBom)
    }

    # copy config snippets if any
    foreach ($cf in $plan.configFiles) {
        if (Test-Path -LiteralPath $cf) {
            $dest = Join-Path $out (Split-Path -Leaf $cf)
            $raw = Get-Content -LiteralPath $cf -Raw -Encoding utf8
            # strip any accidental secrets (should only be structure)
            $raw = Protect-AiCliSecretText -Text $raw
            [System.IO.File]::WriteAllText($dest, $raw, $utf8NoBom)
        }
    }

    Write-AiCliSuccess "已导出到: $out"
    return $out
}

function Start-AiCliProfile {
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [string]$ProjectPath,
        [string[]]$NativeArgs = @()
    )
    $merged = Get-AiCliResolvedProfile -Id $ProfileId
    $proxyRef = Get-AiCliProperty $merged 'proxyRef'
    if ($proxyRef) {
        $state = Get-AiCliProxyState -ProxyId $proxyRef
        $ok = $false
        if ($state) {
            $idc = Test-AiCliProcessIdentity -State $state
            $ok = $idc.Match
        }
        if (-not $ok) {
            Write-AiCliWarn "代理 $proxyRef 未运行。"
            Write-AiCliInfo "下一步：aicli proxy $proxyRef start"
            Write-AiCliInfo "若未登录：aicli proxy $proxyRef login"
            throw "代理依赖未满足: $proxyRef"
        }
    }
    $plan = Build-AiCliLaunchPlan -ProfileId $ProfileId -ProjectPath $ProjectPath -NativeArgs $NativeArgs
    $engine = Get-AiCliProperty $plan 'engine'
    Write-AiCliInfo ("启动 {0}（{1}）…" -f $ProfileId, $engine)
    foreach ($n in @((Get-AiCliProperty $plan 'notes') | ForEach-Object { $_ })) {
        Write-AiCliInfo ("  · {0}" -f $n)
    }

    $envDelta = Get-AiCliProperty $plan 'environmentDelta'
    if ($null -eq $envDelta) { $envDelta = @{} }
    $psi = New-AiCliProcessStartInfo `
        -FileName (Get-AiCliProperty $plan 'fileName') `
        -ArgumentList @((Get-AiCliProperty $plan 'argumentList') | ForEach-Object { $_ }) `
        -WorkingDirectory (Get-AiCliProperty $plan 'workingDirectory') `
        -EnvironmentDelta $envDelta `
        -RemoveEnvironment @((Get-AiCliProperty $plan 'removeEnvironment') | ForEach-Object { $_ })

    Set-AiCliLastProfile -Id $ProfileId
    $code = Start-AiCliChildProcess -StartInfo $psi -Wait -SessionNote $ProfileId
    return $code
}
