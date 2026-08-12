# Build launch plan, native view, eject scripts.

function Assert-AiCliLockedModelArgs {
    param(
        [Parameter(Mandatory)]$MergedProfile,
        [string[]]$NativeArgs
    )
    if ([bool](Get-AiCliProperty $MergedProfile 'flexible' $true)) { return }
    foreach ($argument in @($NativeArgs)) {
        $value = [string]$argument
        if ($value -in @('--model', '-m', '--fallback-model') -or
            $value.StartsWith('--model=') -or
            ($value.Length -gt 2 -and $value.StartsWith('-m')) -or
            $value.StartsWith('--fallback-model=')) {
            throw "参数 $value 不可用：模型由 Profile 固定。"
        }
    }
}

function Build-AiCliLaunchPlan {
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [string]$ProjectPath,
        [string[]]$NativeArgs = @(),
        [switch]$MachineRun
    )
    $merged = Get-AiCliResolvedProfile -Id $ProfileId
    if (-not (Get-AiCliProperty $merged 'configured')) {
        $tid = Get-AiCliProperty $merged 'templateId'
        if (-not $tid) { $tid = $ProfileId }
        throw "Profile 未配置完成。下一步：aicli profile configure $tid"
    }
    Assert-AiCliLockedModelArgs -MergedProfile $merged -NativeArgs $NativeArgs
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

    $plan = switch ($engine) {
        'codex' { Build-AiCliCodexLaunchPlan -MergedProfile $merged -ProjectPath $project -NativeArgs $NativeArgs -MachineRun:$MachineRun; break }
        'claude' { Build-AiCliClaudeLaunchPlan -MergedProfile $merged -ProjectPath $project -NativeArgs $NativeArgs -ProxyPort $proxyPort; break }
        'interpreter' { Build-AiCliInterpreterLaunchPlan -MergedProfile $merged -ProjectPath $project -NativeArgs $NativeArgs; break }
        'qwen-code' { Build-AiCliQwenCodeLaunchPlan -MergedProfile $merged -ProjectPath $project -NativeArgs $NativeArgs; break }
        'opencode' { Build-AiCliOpenCodeLaunchPlan -MergedProfile $merged -ProjectPath $project -NativeArgs $NativeArgs; break }
        default { throw "未知引擎: $engine" }
    }
    return (Apply-AiCliContextManagementPolicy -Plan $plan -MergedProfile $merged)
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
    if ([bool](Get-AiCliProperty $plan 'machineOnly' $false)) {
        throw "Profile $ProfileId 仅用于 aicli run 机器调用，不提供无沙箱交互启动。"
    }
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

function Invoke-AiCliProfileCapture {
    <#
    .SYNOPSIS
      Run one resolved Profile as a bounded machine-facing child process.
    .DESCRIPTION
      The launch environment remains inside this module. Only process output and
      result-side metadata are returned; provider keys and environment deltas are
      never included in the result object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [string]$ProjectPath,
        [string[]]$NativeArgs = @(),
        [string]$StdInText = $null,
        [int]$TimeoutMs = 120000,
        [int]$MaxCaptureChars = 1000000,
        [ValidateSet('read-only','workspace-write')][string]$SandboxPolicy = 'read-only',
        [int]$MaxSteps = 20,
        [int]$MaxToolCalls = 80,
        [string]$MachineEventFile = $null,
        [switch]$EnforceStepLimit,
        [switch]$EnforceToolCallLimit,
        [switch]$WatchdogOnly,
        [switch]$AuthorityPreludeStdout
    )
    $enforceStepLimitEffective = if ($PSBoundParameters.ContainsKey('EnforceStepLimit')) {
        [bool]$EnforceStepLimit
    } else {
        -not [bool]$WatchdogOnly
    }
    $enforceToolCallLimitEffective = if ($PSBoundParameters.ContainsKey('EnforceToolCallLimit')) {
        [bool]$EnforceToolCallLimit
    } else {
        -not [bool]$WatchdogOnly
    }
    $plan = Build-AiCliLaunchPlan -ProfileId $ProfileId -ProjectPath $ProjectPath -NativeArgs $NativeArgs -MachineRun
    $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText $StdInText `
        -Policy $SandboxPolicy -MaxSteps $MaxSteps -MaxToolCalls $MaxToolCalls
    $started = [System.Diagnostics.Stopwatch]::StartNew()
    $engine = [string](Get-AiCliProperty $plan 'engine')
    $defaultEventProtocol = if ($engine -eq 'codex') { 'codex-jsonl' } else { 'none' }
    $runtimeEventProtocol = [string](Get-AiCliProperty $runtime 'EventProtocol')
    $eventProtocol = if ([string]::IsNullOrWhiteSpace($runtimeEventProtocol)) {
        $defaultEventProtocol
    } else {
        $runtimeEventProtocol
    }
    $localGpuBrokerSession = $null
    $localGpuBrokerBindingObservation = $null
    $localGpuBrokerSecretValues = @()
    $beforeProcessTreeStop = $null
    $receipt = $null
    $sessionConfiguration = Get-AiCliProperty `
        (Get-AiCliProperty $plan 'machineRuntime') 'localGpuBrokerSession'
    $requireRuntimeIdentity = $null -ne $sessionConfiguration
    try {
        if ($null -ne $sessionConfiguration) {
            $localGpuBrokerSession = Open-AiCliLocalGpuBrokerSession `
                -Plan $plan -RequestText ([string]$runtime.StdInText) `
                -TimeoutMs $TimeoutMs
            $localGpuBrokerBindingObservation = `
                $localGpuBrokerSession.BindingObservation
            $null = Assert-AiCliLocalGpuBrokerBindingObservation `
                -Observation $localGpuBrokerBindingObservation `
                -Session $localGpuBrokerSession
            Set-AiCliLocalGpuBrokerSessionEnvironment `
                -EnvironmentDelta $runtime.EnvironmentDelta `
                -Session $localGpuBrokerSession
            $localGpuBrokerSecretValues = @(
                [string]$localGpuBrokerSession.Capability
            )
            $beforeProcessTreeStop = New-AiCliLocalGpuBrokerBeforeStopAction `
                -Session $localGpuBrokerSession
        }
        if ($AuthorityPreludeStdout) {
            if ($null -eq $localGpuBrokerSession -or
                $null -eq $localGpuBrokerBindingObservation) {
                throw 'Authority prelude stdout requires a verified LocalGpuBroker session.'
            }
            Write-AiCliLocalGpuBrokerAuthorityPrelude `
                -Observation $localGpuBrokerBindingObservation
        }
        $sandboxWorkspace = if ([bool](Get-AiCliProperty $runtime 'UseOuterSandbox' $true)) {
            Get-AiCliProperty $plan 'workingDirectory'
        } else {
            $null
        }
        $captured = Invoke-AiCliChildCapture `
            -FileName ([string](
                Get-AiCliProperty $runtime 'FileName' (
                    Get-AiCliProperty $plan 'fileName'
                )
            )) `
            -ArgumentList @($runtime.ArgumentList) `
            -WorkingDirectory (Get-AiCliProperty $plan 'workingDirectory') `
            -EnvironmentDelta $runtime.EnvironmentDelta `
            -RemoveEnvironment @((Get-AiCliProperty $plan 'removeEnvironment') | ForEach-Object { $_ }) `
            -StdInText $runtime.StdInText `
            -TimeoutMs $TimeoutMs `
            -MaxCaptureChars $MaxCaptureChars `
            -SandboxWorkspace $sandboxWorkspace `
            -SandboxPolicy $SandboxPolicy `
            -EventProtocol $eventProtocol `
            -MaxSteps $MaxSteps `
            -MaxToolCalls $MaxToolCalls `
            -EnforceStepLimit:$enforceStepLimitEffective `
            -EnforceToolCallLimit:$enforceToolCallLimitEffective `
            -WatchdogOnly:$WatchdogOnly `
            -MachineEventFile $MachineEventFile `
            -WritableWorkspace (Get-AiCliProperty $plan 'workingDirectory') `
            -PrivateTaskPipeName ([string](
                Get-AiCliProperty $runtime 'PrivateTaskPipeName'
            )) `
            -AdditionalSandboxReadRoots @(
                (Get-AiCliProperty $runtime 'AdditionalReadRoots') |
                    ForEach-Object { [string]$_ }
            ) `
            -BeforeProcessTreeStop $beforeProcessTreeStop `
            -AuthorityMachineEvent $(if ($MachineEventFile) {
                $localGpuBrokerBindingObservation
            } else {
                $null
            }) `
            -SecretValues @($(if ($localGpuBrokerSession) {
                [string]$localGpuBrokerSession.Capability
            })) `
            -RequireRuntimeIdentity:$requireRuntimeIdentity `
            -ExpectedRuntimeModel $(if ($requireRuntimeIdentity) {
                [string](Get-AiCliProperty $plan 'model')
            } else { '' }) `
            -ExpectedRuntimeModelProvider $(if ($requireRuntimeIdentity) {
                [string](Get-AiCliProperty $plan 'modelProvider')
            } else { '' })
        if ($requireRuntimeIdentity) {
            $capturedIdentity = Get-AiCliProperty $captured 'RuntimeIdentity'
            if ($null -eq $capturedIdentity -or
                [string](Get-AiCliProperty $capturedIdentity 'model') -cne
                    [string](Get-AiCliProperty $plan 'model') -or
                [string](Get-AiCliProperty $capturedIdentity 'model_provider') -cne
                    [string](Get-AiCliProperty $plan 'modelProvider')) {
                throw 'LocalGpuBroker machine run has no matching verified runtime identity.'
            }
        }
        $codexLimitsHard = $engine -eq 'codex' -and [bool](Get-AiCliProperty $captured 'LimitsHard' $false)
        $cleanupConfirmed = [bool](Get-AiCliProperty $captured 'CleanupConfirmed' $true)
        $receipt = [pscustomobject]@{
            profileId = $ProfileId
            engine = $engine
            model = [string](Get-AiCliProperty $plan 'model')
            modelProvider = [string](Get-AiCliProperty $plan 'modelProvider')
            exitCode = [int]$captured.ExitCode
            stdout = [string]$captured.StdOut
            stderr = [string]$captured.StdErr
            errorCode = Get-AiCliProperty $captured 'ErrorCode'
            timedOut = [bool](Get-AiCliProperty $captured 'TimedOut' $false)
            durationMs = [int](Get-AiCliProperty $captured 'DurationMs' $started.ElapsedMilliseconds)
            outputTruncated = [bool](Get-AiCliProperty $captured 'OutputTruncated' $false)
            sandboxPolicy = $SandboxPolicy
            eventProjection = if ($engine -eq 'codex') { 'codex-public-v1' } else { 'raw-v1' }
            machineEventProjection = [string](
                Get-AiCliProperty $captured 'MachineEventProjection' 'disabled'
            )
            machineEventStatus = [string](
                Get-AiCliProperty $captured 'MachineEventStatus' 'disabled'
            )
            machineEventCount = [int](
                Get-AiCliProperty $captured 'MachineEventCount' 0
            )
            usage = ConvertTo-AiCliSafeUsage (
                Get-AiCliProperty $captured 'Usage'
            )
            runtimeIdentity = Get-AiCliProperty $captured 'RuntimeIdentity'
            limitEnforcement = [ordered]@{
                timeout = if ($cleanupConfirmed) { 'hard' } else { 'failed-closed' }
                maxSteps = if (-not $enforceStepLimitEffective) {
                    'not-configured'
                } elseif ($codexLimitsHard) {
                    'hard'
                } elseif ($engine -eq 'codex') {
                    'failed-closed'
                } elseif ($engine -in @('qwen-code','claude')) {
                    'upstream'
                } else {
                    'not-enforced'
                }
                maxToolCalls = if (-not $enforceToolCallLimitEffective) {
                    'not-configured'
                } elseif ($codexLimitsHard) {
                    'hard'
                } elseif ($engine -eq 'codex') {
                    'failed-closed'
                } elseif ($engine -eq 'qwen-code') {
                    'upstream'
                } else {
                    'not-enforced'
                }
            }
            limitUsage = [ordered]@{
                steps = [int](Get-AiCliProperty $captured 'StepCount' 0)
                toolCalls = [int](Get-AiCliProperty $captured 'ToolCallCount' 0)
                eventsSeen = [int](Get-AiCliProperty $captured 'EventsSeen' 0)
                protocol = [string](Get-AiCliProperty $captured 'EventProtocol' $eventProtocol)
                stepDefinition = if ($engine -eq 'codex') { 'distinct-non-output-thread-item-v2' } else { 'upstream' }
                cleanupConfirmed = $cleanupConfirmed
                cleanupMethod = [string](Get-AiCliProperty $captured 'CleanupMethod' 'none')
            }
            limitHit = Get-AiCliProperty $captured 'LimitHit'
        }
        $receipt | Add-Member -NotePropertyName budgetMode -NotePropertyValue $(
            if ($WatchdogOnly) { 'watchdog-only' } else { 'explicit-limits' }
        )
    } catch [System.TimeoutException] {
        $receipt = [pscustomobject]@{
            profileId = $ProfileId
            engine = [string](Get-AiCliProperty $plan 'engine')
            model = [string](Get-AiCliProperty $plan 'model')
            modelProvider = [string](Get-AiCliProperty $plan 'modelProvider')
            exitCode = (Get-AiCliExitCode Unavailable)
            stdout = ''
            stderr = 'Child process exceeded the configured wall timeout.'
            errorCode = $null
            timedOut = $true
            durationMs = [int]$started.ElapsedMilliseconds
            outputTruncated = $false
            sandboxPolicy = $SandboxPolicy
            eventProjection = if ($engine -eq 'codex') { 'codex-public-v1' } else { 'raw-v1' }
            machineEventProjection = if ($MachineEventFile -and $engine -eq 'codex') {
                'aicli.machine-event.v1'
            } else {
                'disabled'
            }
            machineEventStatus = if ($MachineEventFile -and $engine -eq 'codex') {
                'degraded'
            } elseif ($MachineEventFile) {
                'unsupported'
            } else {
                'disabled'
            }
            machineEventCount = 0
            usage = [ordered]@{}
            runtimeIdentity = $null
            limitEnforcement = [ordered]@{
                timeout = 'failed-closed'
                maxSteps = if ($enforceStepLimitEffective) { 'failed-closed' } else { 'not-configured' }
                maxToolCalls = if ($enforceToolCallLimitEffective) { 'failed-closed' } else { 'not-configured' }
            }
            limitUsage = [ordered]@{
                steps = 0
                toolCalls = 0
                eventsSeen = 0
                protocol = $eventProtocol
                stepDefinition = if ($engine -eq 'codex') { 'distinct-non-output-thread-item-v2' } else { 'upstream' }
                cleanupConfirmed = $false
                cleanupMethod = 'unconfirmed'
            }
            limitHit = 'timeout'
        }
        $receipt | Add-Member -NotePropertyName budgetMode -NotePropertyValue $(
            if ($WatchdogOnly) { 'watchdog-only' } else { 'explicit-limits' }
        )
    } catch {
        if ($localGpuBrokerSecretValues.Count -gt 0) {
            $safeMessage = Protect-AiCliExactSecretValues `
                -Text $_.Exception.Message `
                -SecretValues $localGpuBrokerSecretValues
            throw [InvalidOperationException]::new($safeMessage)
        }
        throw
    } finally {
        $started.Stop()
        try {
            try {
                if ($localGpuBrokerSession) {
                    $closeReason = if ([bool]$localGpuBrokerSession.CloseRequested) {
                        [string]$localGpuBrokerSession.CloseReason
                    } elseif ($null -eq $receipt) {
                        'launch_failed'
                    } elseif ([bool](Get-AiCliProperty $receipt 'timedOut' $false)) {
                        'timeout'
                    } elseif (-not [bool](
                        Get-AiCliProperty (
                            Get-AiCliProperty $receipt 'limitUsage'
                        ) 'cleanupConfirmed' $false
                    )) {
                        'cleanup_failed'
                    } elseif (Get-AiCliProperty $receipt 'limitHit') {
                        'cancelled'
                    } else {
                        'normal'
                    }
                    $terminalBrokerReceipt = Complete-AiCliLocalGpuBrokerSession `
                        -Session $localGpuBrokerSession -Reason $closeReason
                    if ($receipt) {
                        $receipt | Add-Member `
                            -NotePropertyName localGpuBrokerSession `
                            -NotePropertyValue $terminalBrokerReceipt
                    }
                }
            } finally {
                if ($localGpuBrokerSession -and $runtime.EnvironmentDelta) {
                    Clear-AiCliLocalGpuBrokerSessionEnvironment `
                        -EnvironmentDelta $runtime.EnvironmentDelta `
                        -Session $localGpuBrokerSession
                }
            }
        } catch {
            if ($localGpuBrokerSecretValues.Count -gt 0) {
                $safeMessage = Protect-AiCliExactSecretValues `
                    -Text $_.Exception.Message `
                    -SecretValues $localGpuBrokerSecretValues
                throw [InvalidOperationException]::new($safeMessage)
            }
            throw
        } finally {
            if ($runtime) {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath `
                    -Workspace (Get-AiCliProperty $plan 'workingDirectory')
            }
        }
    }
    if ($receipt -and $localGpuBrokerSecretValues.Count -gt 0) {
        $receiptJson = $receipt | ConvertTo-Json -Depth 50 -Compress
        $safeReceiptJson = Protect-AiCliExactSecretValues `
            -Text $receiptJson -SecretValues $localGpuBrokerSecretValues
        if ($safeReceiptJson -cne $receiptJson) {
            $receipt = $safeReceiptJson |
                ConvertFrom-Json -Depth 50 -ErrorAction Stop
        }
    }
    return $receipt
}
