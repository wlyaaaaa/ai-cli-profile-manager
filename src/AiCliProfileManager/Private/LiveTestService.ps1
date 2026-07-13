# Explicit live tests — never run without --live. Text tests disable tools and persistence.

function Test-AiCliExactPongOutput {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    # Strip ANSI CSI/OSC sequences, then require the final non-empty line to be exactly PONG.
    $clean = $Text -replace "`e\][^`a]*(?:`a|`e\\)", ''
    $clean = $clean -replace "`e\[[0-?]*[ -/]*[@-~]", ''
    $lines = @($clean -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -eq 0) { return $false }
    return ($lines[-1] -ceq 'PONG')
}

function Get-AiCliPongLivePrompt {
    return 'Output exactly PONG with no punctuation, whitespace, explanation, or tool calls.'
}

function Get-AiCliPlanVersionEvidence {
    param($Plan)
    $engine = [string](Get-AiCliProperty $Plan 'engine')
    $fileName = [string](Get-AiCliProperty $Plan 'fileName')
    if ([string]::IsNullOrWhiteSpace($fileName)) { return $null }
    $args = @((Get-AiCliProperty $Plan 'versionArgumentList') | ForEach-Object { [string]$_ })
    if ($args.Count -eq 0) {
        $args = @('--version')
        $planArgs = @((Get-AiCliProperty $Plan 'argumentList') | ForEach-Object { [string]$_ })
        if ($engine -eq 'codex' -and $planArgs.Count -gt 0 -and $planArgs[0] -match 'codex\.js$') {
            $args = @($planArgs[0], '--version')
        }
    }
    try {
        $r = Invoke-AiCliChildCapture -FileName $fileName -ArgumentList $args -TimeoutMs 10000 -CloseStdIn
        if ($r.ExitCode -ne 0) { return $null }
        $line = @(([string]$r.StdOut -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1)
        if ($line.Count -eq 0) { return $null }
        $safe = Protect-AiCliSecretText ([string]$line[0])
        return $safe.Substring(0, [Math]::Min(200, $safe.Length))
    } catch {
        return $null
    }
}

function Get-AiCliProfileCliIdentityEvidence {
    param([Parameter(Mandatory)]$MergedProfile)
    $engine = [string](Get-AiCliProperty $MergedProfile 'engine')
    try {
        $resolved = switch ($engine) {
            'codex' { Resolve-AiCliCodexLaunchExecutable -MergedProfile $MergedProfile; break }
            'claude' { Resolve-AiCliLaunchExecutable -Name 'claude'; break }
            'interpreter' { Resolve-AiCliInterpreterExecutable; break }
            default { $null }
        }
        if (-not $resolved) { return $null }
        return (Get-AiCliResolvedCliVersionEvidence -Resolved $resolved)
    } catch {
        return $null
    }
}

function Test-AiCliVerificationRecordCurrent {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)]$MergedProfile
    )
    if ([string](Get-AiCliProperty $Record 'productVersion') -ne (Get-AiCliVersion)) {
        return [pscustomobject]@{ Current = $false; Reason = '产品版本已变化' }
    }
    $recordedPath = [string](Get-AiCliProperty $Record 'cliPath')
    $recordedVersion = [string](Get-AiCliProperty $Record 'cliVersion')
    if ([string]::IsNullOrWhiteSpace($recordedPath) -or [string]::IsNullOrWhiteSpace($recordedVersion)) {
        return [pscustomobject]@{ Current = $false; Reason = '旧验证记录缺少 CLI 路径或版本证据' }
    }
    $current = Get-AiCliProfileCliIdentityEvidence -MergedProfile $MergedProfile
    if (-not $current) {
        return [pscustomobject]@{ Current = $false; Reason = '当前目标 CLI 不可解析或无法取得版本' }
    }
    if (-not [string]::Equals($recordedPath, [string]$current.FileName, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Current = $false; Reason = '目标 CLI 路径已变化' }
    }
    if (-not [string]::Equals($recordedVersion, [string]$current.Version, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Current = $false; Reason = '目标 CLI 版本已变化' }
    }
    return [pscustomobject]@{ Current = $true; Reason = '当前'; Evidence = $current }
}

function Set-AiCliVerificationRecord {
    param([Parameter(Mandatory)][string]$ProfileId, [Parameter(Mandatory)]$Record)
    $settings = Get-AiCliSettings
    if (-not $settings.verification) { $settings.verification = [ordered]@{} }
    if ($settings.verification -is [System.Collections.IDictionary]) {
        $settings.verification[$ProfileId] = $Record
    } else {
        $settings.verification | Add-Member -NotePropertyName $ProfileId -NotePropertyValue $Record -Force
    }
    Save-AiCliSettings -Settings $settings
}

function Invoke-AiCliLiveTest {
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [ValidateSet('text','tool','all')][string]$Level = 'text',
        [switch]$Yes,
        [switch]$Json
    )
    $null = Assert-AiCliSafeIdentifier -Id $ProfileId -Kind 'Profile ID'
    if (-not $Yes) {
        Write-AiCliWarn 'Live Test 会通过目标 CLI 向 Provider/模型发送真实请求，可能消耗 API 或订阅额度。'
        Write-AiCliInfo "Profile: $ProfileId  level: $Level"
        Write-AiCliInfo '文本测试在临时空目录运行，禁用工具、持久化和项目配置；不记录提示或回复正文。'
        if (-not (Confirm-AiCliAction -Message '确认执行 Live Test？' -Yes:$false)) {
            return (Get-AiCliExitCode Cancelled)
        }
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("aicli-live-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $checks = [System.Collections.Generic.List[object]]::new()
    $overall = '不可用'
    $textPass = $false
    $textExitCode = $null
    $toolPass = $false
    $toolSkipped = $false
    $merged = $null
    $plan = $null
    $failureSummary = $null

    try {
        $merged = Get-AiCliResolvedProfile -Id $ProfileId
        $plan = Build-AiCliLaunchPlan -ProfileId $ProfileId -ProjectPath $tmp

        if ($Level -in @('text','all')) {
            $textResult = Invoke-AiCliTextLiveTest -Plan $plan -WorkDir $tmp -Checks $checks
            $textPass = [bool]$textResult.Pass
            $textExitCode = $textResult.ExitCode
        }
        if ($Level -in @('tool','all')) {
            $toolResult = Invoke-AiCliToolLiveTest -Plan $plan -WorkDir $tmp -Nonce ([guid]::NewGuid().ToString('N')) -Checks $checks
            $toolPass = [bool]$toolResult.Pass
            $toolSkipped = [bool]$toolResult.Skipped
        }

        if ($Level -eq 'text') {
            $overall = if ($textPass) { '可用但有限制' } else { '不可用' }
        } elseif ($Level -eq 'tool') {
            $overall = if ($toolPass -and -not $toolSkipped) { '可用但有限制' } else { '可用但有限制' }
        } else {
            $overall = if (-not $textPass) { '不可用' }
                elseif ($toolPass -and -not $toolSkipped) { '可用' }
                else { '可用但有限制' }
        }
    } catch {
        $failureSummary = Protect-AiCliSecretText $_.Exception.Message
        $checks.Add((New-AiCliCheck -Id 'live.error' -Status '不可用' -Summary $failureSummary)) | Out-Null
        $overall = '不可用'
    } finally {
        try {
            if ($merged) {
                $models = Get-AiCliProperty $merged 'models'
                $recordResult = if ($overall -eq '不可用') { 'fail' }
                    elseif ($Level -eq 'tool' -and $toolSkipped) { 'limited' }
                    else { 'pass' }
                $record = [ordered]@{
                    level              = $Level
                    result             = $recordResult
                    textPass           = $textPass
                    textExitCode       = $textExitCode
                    toolPass           = $toolPass
                    toolSkipped        = $toolSkipped
                    timestampUtc       = (Get-Date).ToUniversalTime().ToString('o')
                    productVersion     = (Get-AiCliVersion)
                    profileFingerprint = (Get-AiCliProfileFingerprint -Profile $merged)
                    engine             = (Get-AiCliProperty $merged 'engine')
                    provider           = (Get-AiCliProperty $merged 'provider')
                    transport          = (Get-AiCliProperty $merged 'transport')
                    endpoint           = (Get-AiCliProperty $merged 'endpoint')
                    model              = (Get-AiCliProperty $models 'primary')
                    cliPath            = $(if ($plan) { Get-AiCliProperty $plan 'fileName' } else { $null })
                    cliVersion         = $(if ($plan) { Get-AiCliPlanVersionEvidence -Plan $plan } else { $null })
                    failureSummary     = $failureSummary
                }
                Set-AiCliVerificationRecord -ProfileId $ProfileId -Record $record
            }
        } catch {
            $checks.Add((New-AiCliCheck -Id 'live.record' -Status '可用但有限制' -Summary '验证结果未能持久化' -Limitation (Protect-AiCliSecretText $_.Exception.Message))) | Out-Null
            if ($overall -eq '可用') { $overall = '可用但有限制' }
        }
        try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    $result = New-AiCliResult -Command "test $ProfileId --live" -OverallStatus $overall -Checks @($checks) -Extra @{
        profileId = $ProfileId
        level     = $Level
        note      = '真实目标 CLI；不记录提示/回复正文；未执行的工具层不会标记为通过'
    }
    if ($Json) { Write-AiCliJson $result } else { Write-AiCliDoctorText -Result $result }
    return (Get-AiCliExitCodeFromStatus $overall)
}

function Invoke-AiCliTextLiveTest {
    param($Plan, $WorkDir, $Checks)
    if ($Plan -is [System.Array] -and $Plan.Count -gt 0) {
        $first = $Plan | Where-Object { $_ -is [System.Collections.IDictionary] -or $_.PSObject.Properties['fileName'] } | Select-Object -First 1
        if ($first) { $Plan = $first }
    }
    $engine = [string](Get-AiCliProperty $Plan 'engine')
    $fileName = [string](Get-AiCliProperty $Plan 'fileName')
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $Checks.Add((New-AiCliCheck -Id 'live.text' -Status '不可用' -Summary '启动计划缺少可执行文件路径')) | Out-Null
        return [pscustomobject]@{ Pass = $false; ExitCode = $null }
    }
    $argList = @((Get-AiCliProperty $Plan 'argumentList') | ForEach-Object { [string]$_ })
    $envDelta = Get-AiCliProperty $Plan 'environmentDelta'
    if ($null -eq $envDelta) { $envDelta = @{} }
    $removeEnv = @((Get-AiCliProperty $Plan 'removeEnvironment') | ForEach-Object { [string]$_ })
    $timeoutMs = if ($engine -eq 'interpreter') { 90000 } else { 45000 }

    try {
        if ($engine -in @('codex','interpreter')) {
            $prefix = @()
            $rest = @($argList)
            if ($engine -eq 'codex' -and $argList.Count -gt 0 -and $argList[0] -match 'codex\.js$') {
                $prefix = @($argList[0])
                $rest = if ($argList.Count -gt 1) { @($argList[1..($argList.Count - 1)]) } else { @() }
            }
            $lastMessage = Join-Path $WorkDir ("last-message-" + [guid]::NewGuid().ToString('N') + '.txt')
            # --ask-for-approval is a root option in current Codex/OI Rust CLIs;
            # exec rejects it when placed after the subcommand.
            $fullArgs = @($prefix) + @(
                '--ask-for-approval', 'never',
                'exec', '--skip-git-repo-check', '--ephemeral', '--ignore-user-config', '--ignore-rules',
                '--sandbox', 'read-only', '--output-last-message', $lastMessage
            ) + @($rest) + @((Get-AiCliPongLivePrompt))
            $r = Invoke-AiCliChildCapture -FileName $fileName -ArgumentList $fullArgs `
                -EnvironmentDelta $envDelta -RemoveEnvironment $removeEnv `
                -WorkingDirectory $WorkDir -TimeoutMs $timeoutMs -CloseStdIn
            $body = if (Test-Path -LiteralPath $lastMessage) { Get-Content -LiteralPath $lastMessage -Raw -Encoding utf8 } else { '' }
            $pass = ($r.ExitCode -eq 0) -and (Test-AiCliExactPongOutput -Text $body)
        } elseif ($engine -eq 'claude') {
            $fullArgs = @($argList) + @(
                '--bare', '--setting-sources', '', '--tools', '', '--no-session-persistence',
                '-p', (Get-AiCliPongLivePrompt), '--output-format', 'text'
            )
            $r = Invoke-AiCliChildCapture -FileName $fileName -ArgumentList $fullArgs `
                -EnvironmentDelta $envDelta -RemoveEnvironment $removeEnv `
                -WorkingDirectory $WorkDir -TimeoutMs $timeoutMs -CloseStdIn
            $pass = ($r.ExitCode -eq 0) -and (Test-AiCliExactPongOutput -Text ([string]$r.StdOut))
        } else {
            throw "未知 Live Test 引擎: $engine"
        }

        if ($pass) {
            $Checks.Add((New-AiCliCheck -Id 'live.text' -Status '通过' -Summary '目标 CLI 正常退出，最终模型正文严格匹配 PONG（正文未记录）')) | Out-Null
            return [pscustomobject]@{ Pass = $true; ExitCode = $r.ExitCode }
        }
        $Checks.Add((New-AiCliCheck -Id 'live.text' -Status '不可用' -Summary ("文本测试失败：exit={0} 或最终正文不匹配" -f $r.ExitCode))) | Out-Null
        Write-AiCliLog -Level Warn -Message ("live text fail engine={0} exit={1}" -f $engine, $r.ExitCode)
        return [pscustomobject]@{ Pass = $false; ExitCode = $r.ExitCode }
    } catch {
        $Checks.Add((New-AiCliCheck -Id 'live.text' -Status '不可用' -Summary (Protect-AiCliSecretText $_.Exception.Message))) | Out-Null
        return [pscustomobject]@{ Pass = $false; ExitCode = $null }
    }
}

function Invoke-AiCliToolLiveTest {
    param($Plan, $WorkDir, $Nonce, $Checks)
    $Checks.Add((New-AiCliCheck -Id 'live.tool' -Status '可用但有限制' -Summary '0.1.0 尚未实现可证明隔离的工具调用测试，已明确跳过' -Limitation '未执行工具 Live Test')) | Out-Null
    return [pscustomobject]@{ Pass = $false; Skipped = $true }
}
