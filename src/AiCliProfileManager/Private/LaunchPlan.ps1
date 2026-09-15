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

function Assert-AiCliNativeArgsDoNotUseRetiredModel {
    param([string[]]$NativeArgs)
    $expectModel = $false
    foreach ($argument in @($NativeArgs)) {
        $value = [string]$argument
        if ($expectModel) {
            Assert-AiCliModelIsActive -ModelId $value -Context '原生命令参数'
            $expectModel = $false
            continue
        }
        if ($value -in @('--model','-m','--fallback-model')) {
            $expectModel = $true
            continue
        }
        $candidate = $null
        if ($value -cmatch '^--(?:fallback-)?model=(.+)$') { $candidate = $Matches[1] }
        elseif ($value -cmatch '^-m(.+)$') { $candidate = $Matches[1] }
        elseif ($value -cmatch '(?:^|\s)model\s*=\s*["'']?([^"''\s]+)') { $candidate = $Matches[1] }
        if ($candidate) {
            Assert-AiCliModelIsActive -ModelId $candidate -Context '原生命令参数'
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
    Assert-AiCliNativeArgsDoNotUseRetiredModel -NativeArgs $NativeArgs
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
    $planModel = [string](Get-AiCliProperty $plan 'model')
    $allowExactQwen37 = (Test-AiCliQwen37Max0608ExactProfile -Profile $merged) -and
        $planModel -ceq 'qwen3.7-max-2026-06-08'
    if (-not $allowExactQwen37) {
        Assert-AiCliModelIsActive -ModelId $planModel -Context '最终启动计划'
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
    $effectiveEffort = Get-AiCliProperty $plan 'effectiveEffort'
    $model = Get-AiCliProperty $plan 'model'
    if ($model) { Write-Host ("模型: {0}" -f $model) }
    if ($effort) {
        if ($effectiveEffort -and $effectiveEffort -ne $effort) {
            Write-Host ("思考等级: {0}（供应商有效档位: {1}）" -f $effort, $effectiveEffort)
        } else {
            Write-Host ("思考等级: {0}" -f $effort)
        }
    }
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
    $localReadiness = Test-AiCliSelectedLocalProviderReadiness -MergedProfile $merged
    if ($localReadiness.Applicable -and -not $localReadiness.Ready) {
        Write-AiCliWarn "选定本地 Provider 不可用: $($localReadiness.Summary)"
        return (Get-AiCliExitCode Unavailable)
    }
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
    Write-AiCliInfo ("启动 {0}（{1}）…" -f (Get-AiCliProperty $merged 'displayName'), $engine)
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
        [ValidateSet('danger-full-access','read-only','workspace-write')][string]$SandboxPolicy = 'danger-full-access',
        [int]$MaxSteps = 20,
        [int]$MaxToolCalls = 80,
        [string]$MachineEventFile = $null,
        [switch]$EnforceStepLimit,
        [switch]$EnforceToolCallLimit,
        [switch]$WatchdogOnly,
        [switch]$AuthorityPreludeStdout,
        [switch]$DisableWebSearch,
        [object]$RecoveryContext = $null
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
    $engine = [string](Get-AiCliProperty $plan 'engine')
    if ($engine -eq 'codex' -and $SandboxPolicy -ne 'danger-full-access') {
        throw 'Codex harness requires danger-full-access for every current and future model.'
    }
    if ($engine -ne 'codex' -and $DisableWebSearch) {
        throw '--no-web-search is supported only by Codex harness runs.'
    }
    if ($null -ne $RecoveryContext) {
        if ($engine -ne 'codex') {
            throw 'Recoverable sessions require the Codex app-server harness.'
        }
        foreach ($binding in @(
            @{ Name='workspace'; Actual=[string](Get-AiCliProperty $plan 'workingDirectory') },
            @{ Name='profileFingerprint'; Actual=[string](Get-AiCliProperty $plan 'profileFingerprint') },
            @{ Name='model'; Actual=[string](Get-AiCliProperty $plan 'model') },
            @{ Name='modelProvider'; Actual=[string](Get-AiCliProperty $plan 'modelProvider') },
            @{ Name='requestedEffort'; Actual=[string](Get-AiCliProperty $plan 'effort') },
            @{ Name='effectiveEffort'; Actual=[string](Get-AiCliProperty $plan 'effectiveEffort') }
        )) {
            $expected = [string](Get-AiCliProperty $RecoveryContext $binding.Name)
            $actual = $binding.Actual
            $matches = if ($binding.Name -eq 'workspace') {
                try {
                    [IO.Path]::GetFullPath($expected).Equals(
                        [IO.Path]::GetFullPath($actual),
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } catch { $false }
            } else {
                $expected -ceq $actual
            }
            if (-not $matches) {
                throw "Recoverable run binding changed: $($binding.Name)."
            }
        }
    }
    if ($engine -eq 'codex' -and @($NativeArgs).Count -eq 0) {
        $plan.argumentList = @((Get-AiCliProperty $plan 'argumentList')) + @('exec', '--json', '-')
    }
    $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText $StdInText `
        -Policy $SandboxPolicy -MaxSteps $MaxSteps -MaxToolCalls $MaxToolCalls `
        -DisableWebSearch:$DisableWebSearch -RecoveryContext $RecoveryContext
    $started = [System.Diagnostics.Stopwatch]::StartNew()
    $defaultEventProtocol = if ($engine -eq 'codex') { 'codex-jsonl' } else { 'none' }
    $runtimeEventProtocol = [string](Get-AiCliProperty $runtime 'EventProtocol')
    $eventProtocol = if ([string]::IsNullOrWhiteSpace($runtimeEventProtocol)) {
        $defaultEventProtocol
    } else {
        $runtimeEventProtocol
    }
    $localGpuBrokerSession = $null
    $localGpuBrokerBindingObservation = $null
    $captureSecretValues = @(
        Get-AiCliEnvironmentSecretValues -EnvironmentDelta $runtime.EnvironmentDelta
    )
    $beforeProcessTreeStop = $null
    $receipt = $null
    $sessionConfiguration = Get-AiCliProperty `
        (Get-AiCliProperty $plan 'machineRuntime') 'localGpuBrokerSession'
    $requireRuntimeIdentity = $engine -eq 'codex'
    $verifiedPublicRuntimeIdentity = $null
    $verifiedRecoveryIds = $null
    $verifiedPublicBrokerReceiptSummary = $null
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
            $captureSecretValues = @(
                @($captureSecretValues) +
                @(
                    [string]$localGpuBrokerSession.Capability
                    [string]$localGpuBrokerSession.LeaseId
                ) |
                    Where-Object { -not [string]::IsNullOrEmpty([string]$_) } |
                    Sort-Object -Unique
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
            -SecretValues $captureSecretValues `
            -RequireRuntimeIdentity:$requireRuntimeIdentity `
            -ExpectedRuntimeModel $(if ($requireRuntimeIdentity) {
                [string](Get-AiCliProperty $plan 'model')
            } else { '' }) `
            -ExpectedRuntimeModelProvider $(if ($requireRuntimeIdentity) {
                [string](Get-AiCliProperty $plan 'modelProvider')
            } else { '' }) `
            -MachineEventSequenceBase $(if ($null -ne $RecoveryContext) {
                [int](Get-AiCliProperty $RecoveryContext 'eventSequenceBase' 0)
            } else { 0 }) `
            -AbortSignalPath $(if ($null -ne $RecoveryContext) {
                [string](Get-AiCliProperty $RecoveryContext 'abortSignalPath')
            } else { '' }) `
            -MachineEventMirrorFile $(if ($null -ne $RecoveryContext) {
                [string](Get-AiCliProperty $RecoveryContext 'consumerEventFile')
            } else { '' })
        if ($requireRuntimeIdentity) {
            $capturedIdentity = Get-AiCliProperty $captured 'RuntimeIdentity'
            $capturedPermission = Get-AiCliProperty $capturedIdentity 'permission'
            if ($null -eq $capturedIdentity -or
                [string](Get-AiCliProperty $capturedIdentity 'model') -cne
                    [string](Get-AiCliProperty $plan 'model') -or
                [string](Get-AiCliProperty $capturedIdentity 'model_provider') -cne
                    [string](Get-AiCliProperty $plan 'modelProvider') -or
                [string](Get-AiCliProperty $capturedPermission 'approval_policy') -cne 'never' -or
                [string](Get-AiCliProperty $capturedPermission 'requested_policy') -cne 'danger-full-access' -or
                [string](Get-AiCliProperty $capturedPermission 'sandbox_boundary') -cne 'codex-native' -or
                [string](Get-AiCliProperty $capturedPermission 'sandbox_type') -cne 'dangerFullAccess' -or
                [string](Get-AiCliProperty $capturedPermission 'permission_profile') -cne ':danger-full-access') {
                if ($null -ne $capturedIdentity -and
                    [string](Get-AiCliProperty $capturedIdentity 'model') -ceq
                        [string](Get-AiCliProperty $plan 'model') -and
                    [string](Get-AiCliProperty $capturedIdentity 'model_provider') -ceq
                        [string](Get-AiCliProperty $plan 'modelProvider')) {
                    throw 'Codex machine run has no verified danger-full-access runtime permission identity.'
                }
                throw 'Codex machine run has no matching verified runtime identity.'
            }
            # Preserve only the closed, non-secret identity surface after the
            # whole-receipt exact-secret scrub below. A local compatibility key
            # can legitimately equal a substring of a public Provider ID (for
            # example, "ollama"); generic string replacement must not corrupt
            # runtime attestation that has already passed the checks above.
            $verifiedPublicRuntimeIdentity = [ordered]@{
                model = [string](Get-AiCliProperty $capturedIdentity 'model')
                model_provider = [string](
                    Get-AiCliProperty $capturedIdentity 'model_provider'
                )
                cli_version = [string](
                    Get-AiCliProperty $capturedIdentity 'cli_version'
                )
                permission = [ordered]@{
                    approval_policy = [string](
                        Get-AiCliProperty $capturedPermission 'approval_policy'
                    )
                    requested_policy = [string](
                        Get-AiCliProperty $capturedPermission 'requested_policy'
                    )
                    sandbox_boundary = [string](
                        Get-AiCliProperty $capturedPermission 'sandbox_boundary'
                    )
                    sandbox_type = [string](
                        Get-AiCliProperty $capturedPermission 'sandbox_type'
                    )
                    permission_profile = [string](
                        Get-AiCliProperty $capturedPermission 'permission_profile'
                    )
                }
            }
            if ($null -ne $RecoveryContext) {
                $capturedRecovery = Get-AiCliProperty `
                    $capturedIdentity 'recovery'
                $capturedThreadId = Get-AiCliPublicThreadId (
                    Get-AiCliProperty $captured 'ThreadId'
                )
                $capturedSessionId = Get-AiCliPublicThreadId (
                    Get-AiCliProperty $captured 'SessionId'
                )
                $capturedTurnId = Get-AiCliPublicThreadId (
                    Get-AiCliProperty $captured 'TurnId'
                )
                $recoveryMode = [string](
                    Get-AiCliProperty $RecoveryContext 'mode'
                )
                if ($null -eq $capturedRecovery -or
                    [string](Get-AiCliProperty $capturedRecovery 'mode') -cne
                        $recoveryMode -or
                    [string](Get-AiCliProperty $capturedRecovery 'thread_id') -cne
                        $capturedThreadId -or
                    [string](Get-AiCliProperty $capturedRecovery 'session_id') -cne
                        $capturedSessionId -or
                    [string](Get-AiCliProperty $capturedRecovery 'workspace_hash') -cne
                        [string](Get-AiCliProperty $RecoveryContext 'workspaceHash') -or
                    [string](Get-AiCliProperty $capturedRecovery 'run_id') -cne
                        [string](Get-AiCliProperty $RecoveryContext 'runId') -or
                    [string](Get-AiCliProperty $capturedRecovery 'profile_fingerprint') -cne
                        [string](Get-AiCliProperty $RecoveryContext 'profileFingerprint') -or
                    [string](Get-AiCliProperty $capturedRecovery 'requested_effort') -cne
                        [string](Get-AiCliProperty $RecoveryContext 'requestedEffort') -or
                    [string](Get-AiCliProperty $capturedRecovery 'reasoning_effort') -cne
                        [string](Get-AiCliProperty $RecoveryContext 'effectiveEffort') -or
                    [string]::IsNullOrWhiteSpace($capturedThreadId) -or
                    [string]::IsNullOrWhiteSpace($capturedSessionId) -or
                    [string]::IsNullOrWhiteSpace($capturedTurnId) -or
                    ($recoveryMode -eq 'resume' -and (
                        $capturedThreadId -cne [string](
                            Get-AiCliProperty $RecoveryContext 'threadId'
                        ) -or
                        $capturedSessionId -cne [string](
                            Get-AiCliProperty $RecoveryContext 'sessionId'
                        )
                    ))) {
                    throw 'Codex recoverable run has no matching session/thread/turn identity.'
                }
                $verifiedPublicRuntimeIdentity['recovery'] = [ordered]@{
                    mode = $recoveryMode
                    thread_id = $capturedThreadId
                    session_id = $capturedSessionId
                    workspace_hash = [string](
                        Get-AiCliProperty $capturedRecovery 'workspace_hash'
                    )
                    run_id = [string](
                        Get-AiCliProperty $capturedRecovery 'run_id'
                    )
                    profile_fingerprint = [string](
                        Get-AiCliProperty $capturedRecovery 'profile_fingerprint'
                    )
                    requested_effort = [string](
                        Get-AiCliProperty $capturedRecovery 'requested_effort'
                    )
                    reasoning_effort = [string](
                        Get-AiCliProperty $capturedRecovery 'reasoning_effort'
                    )
                }
                $verifiedRecoveryIds = [ordered]@{
                    threadId = $capturedThreadId
                    sessionId = $capturedSessionId
                    turnId = $capturedTurnId
                }
            }
        }
        $codexLimitsHard = $engine -eq 'codex' -and [bool](Get-AiCliProperty $captured 'LimitsHard' $false)
        $cleanupConfirmed = [bool](Get-AiCliProperty $captured 'CleanupConfirmed' $true)
        $receipt = [pscustomobject]@{
            profileId = $ProfileId
            profileFingerprint = [string](Get-AiCliProperty $plan 'profileFingerprint')
            engine = $engine
            model = [string](Get-AiCliProperty $plan 'model')
            modelProvider = [string](Get-AiCliProperty $plan 'modelProvider')
            wire = [string](Get-AiCliProperty $plan 'wire')
            requestedEffort = [string](Get-AiCliProperty $plan 'effort')
            effectiveEffort = [string](Get-AiCliProperty $plan 'effectiveEffort')
            effortEvidence = 'launch-plan'
            attestedEffort = $null
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
            machineEventSequenceStart = [int](
                Get-AiCliProperty $captured 'MachineEventSequenceStart' 0
            )
            machineEventSequenceEnd = [int](
                Get-AiCliProperty $captured 'MachineEventSequenceEnd' (
                    Get-AiCliProperty $captured 'MachineEventCount' 0
                )
            )
            threadId = Get-AiCliProperty $captured 'ThreadId'
            sessionId = Get-AiCliProperty $captured 'SessionId'
            turnId = Get-AiCliProperty $captured 'TurnId'
            usage = ConvertTo-AiCliSafeUsage (
                Get-AiCliProperty $captured 'Usage'
            )
            runtimeIdentity = Get-AiCliProperty $captured 'RuntimeIdentity'
            runtimeCliPath = [string](Get-AiCliProperty $runtime 'TargetFileName' (
                Get-AiCliProperty $runtime 'FileName'
            ))
            webSearch = [ordered]@{
                enabled = [bool](Get-AiCliProperty $runtime 'WebSearchEnabled' $false)
                provider = $(if ([bool](Get-AiCliProperty $runtime 'WebSearchEnabled' $false)) {
                    'bing-rss-v1'
                } else { $null })
                searches = [int](Get-AiCliProperty $captured 'WebSearchCount' 0)
                eventEvidence = $(if ([bool](Get-AiCliProperty $runtime 'WebSearchEnabled' $false)) {
                    'runtime-lifecycle'
                } else { 'disabled' })
            }
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
            profileFingerprint = [string](Get-AiCliProperty $plan 'profileFingerprint')
            engine = [string](Get-AiCliProperty $plan 'engine')
            model = [string](Get-AiCliProperty $plan 'model')
            modelProvider = [string](Get-AiCliProperty $plan 'modelProvider')
            wire = [string](Get-AiCliProperty $plan 'wire')
            requestedEffort = [string](Get-AiCliProperty $plan 'effort')
            effectiveEffort = [string](Get-AiCliProperty $plan 'effectiveEffort')
            effortEvidence = 'launch-plan'
            attestedEffort = $null
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
            machineEventSequenceStart = $(if ($null -ne $RecoveryContext) {
                [int](Get-AiCliProperty $RecoveryContext 'eventSequenceBase' 0)
            } else { 0 })
            machineEventSequenceEnd = $(if ($null -ne $RecoveryContext) {
                [int](Get-AiCliProperty $RecoveryContext 'eventSequenceBase' 0)
            } else { 0 })
            threadId = $null
            sessionId = $null
            turnId = $null
            usage = [ordered]@{}
            runtimeIdentity = $null
            webSearch = [ordered]@{
                enabled = [bool](Get-AiCliProperty $runtime 'WebSearchEnabled' $false)
                provider = $(if ([bool](Get-AiCliProperty $runtime 'WebSearchEnabled' $false)) {
                    'bing-rss-v1'
                } else { $null })
                searches = 0
                eventEvidence = $(if ([bool](Get-AiCliProperty $runtime 'WebSearchEnabled' $false)) {
                    'incomplete'
                } else { 'disabled' })
            }
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
        if ($captureSecretValues.Count -gt 0) {
            $safeMessage = Protect-AiCliExactSecretValues `
                -Text $_.Exception.Message `
                -SecretValues $captureSecretValues
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
                    $verifiedPublicBrokerReceiptSummary = `
                        ConvertTo-AiCliRecoverableBrokerReceiptSummary `
                            -Receipt $terminalBrokerReceipt
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
            if ($captureSecretValues.Count -gt 0) {
                $safeMessage = Protect-AiCliExactSecretValues `
                    -Text $_.Exception.Message `
                    -SecretValues $captureSecretValues
                throw [InvalidOperationException]::new($safeMessage)
            }
            throw
        } finally {
            if ($runtime) {
                $runtimeCleanup = $null
                try {
                    # A Windows sandbox target can release its inherited handle
                    # shortly after the npm/native wrapper exits. Wait only for
                    # this known disposable directory; never discover or stop
                    # unrelated processes.
                    $runtimeCleanup = Remove-AiCliMachineRuntime `
                        -RuntimePath $runtime.RuntimePath `
                        -Workspace (Get-AiCliProperty $plan 'workingDirectory') `
                        -WaitForReleaseMs 10000 -PassThru
                } catch {
                    $runtimeCleanup = [pscustomobject]@{
                        Removed = $false
                        Reason = 'runtime-directory-cleanup-exception'
                        Attempts = 0
                        WaitedMs = 0
                        RuntimeId = Split-Path -Leaf ([IO.Path]::GetFullPath($runtime.RuntimePath))
                        RuntimePath = [IO.Path]::GetFullPath($runtime.RuntimePath)
                    }
                }
                if ($receipt -and $runtimeCleanup) {
                    $receipt | Add-Member -NotePropertyName runtimeCleanup `
                        -NotePropertyValue $runtimeCleanup -Force
                    if (-not [bool]$runtimeCleanup.Removed) {
                        $limitUsage = Get-AiCliProperty $receipt 'limitUsage'
                        if ($limitUsage) {
                            $previousMethod = [string](Get-AiCliProperty $limitUsage 'cleanupMethod')
                            $limitUsage.cleanupConfirmed = $false
                            $limitUsage.cleanupMethod = if ($previousMethod -and $previousMethod -ne 'none') {
                                "$previousMethod+$($runtimeCleanup.Reason)"
                            } else {
                                [string]$runtimeCleanup.Reason
                            }
                        }
                        $limitEnforcement = Get-AiCliProperty $receipt 'limitEnforcement'
                        if ($limitEnforcement) {
                            $limitEnforcement.timeout = 'failed-closed'
                        }
                    }
                }
            }
        }
    }
    if ($receipt -and $captureSecretValues.Count -gt 0) {
        $receiptJson = $receipt | ConvertTo-Json -Depth 50 -Compress
        $safeReceiptJson = Protect-AiCliExactSecretValues `
            -Text $receiptJson -SecretValues $captureSecretValues
        if ($safeReceiptJson -cne $receiptJson) {
            $receipt = $safeReceiptJson |
                ConvertFrom-Json -Depth 50 -ErrorAction Stop
        }
    }
    if ($verifiedPublicRuntimeIdentity) {
        foreach ($publicField in ([ordered]@{
            profileId = $ProfileId
            model = [string](Get-AiCliProperty $plan 'model')
            modelProvider = [string](Get-AiCliProperty $plan 'modelProvider')
            runtimeIdentity = [pscustomobject]$verifiedPublicRuntimeIdentity
        }).GetEnumerator()) {
            $receipt | Add-Member -NotePropertyName $publicField.Key `
                -NotePropertyValue $publicField.Value -Force
        }
    }
    if ($verifiedRecoveryIds) {
        foreach ($publicField in $verifiedRecoveryIds.GetEnumerator()) {
            $receipt | Add-Member -NotePropertyName $publicField.Key `
                -NotePropertyValue $publicField.Value -Force
        }
    }
    if ($verifiedPublicBrokerReceiptSummary) {
        $receipt | Add-Member `
            -NotePropertyName localGpuBrokerSessionSummary `
            -NotePropertyValue ([pscustomobject]$verifiedPublicBrokerReceiptSummary) `
            -Force
    }
    return $receipt
}
