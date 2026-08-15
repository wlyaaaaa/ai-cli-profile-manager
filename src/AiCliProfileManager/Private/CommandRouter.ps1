# Strict subcommand router for aicli.

function ConvertTo-AiCliTokenList {
    <#
    .SYNOPSIS
      Normalize CLI tokens into List[string] (single object — avoids PS array unwrap bugs).
      Critical: a single-element [string[]] often collapses to [string]; then $Tokens[0] is
      the first character (e.g. 'c' from codex-deepseek). Returning List avoids that.
    #>
    param($Tokens)
    $list = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Tokens) {
        # unary comma: prevent PS from enumerating List into pipeline
        return ,$list
    }
    if ($Tokens -is [string]) {
        [void]$list.Add([string]$Tokens)
        return ,$list
    }
    foreach ($item in @($Tokens)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            [void]$list.Add([string]$item)
            continue
        }
        if ($item -is [System.Array]) {
            foreach ($sub in $item) {
                if ($null -eq $sub) { continue }
                [void]$list.Add([string]$sub)
            }
            continue
        }
        [void]$list.Add([string]$item)
    }
    return ,$list
}

function ConvertTo-AiCliTokenArray {
    param($Tokens)
    $list = ConvertTo-AiCliTokenList $Tokens
    return ,([string[]]$list.ToArray())
}

function Split-AiCliArgs {
    param($Tokens)
    $tokenList = ConvertTo-AiCliTokenList $Tokens
    $before = [System.Collections.Generic.List[string]]::new()
    $after = [System.Collections.Generic.List[string]]::new()
    $seen = $false
    foreach ($t in $tokenList) {
        if (-not $seen -and $t -eq '--') { $seen = $true; continue }
        if ($seen) { $after.Add($t) } else { $before.Add($t) }
    }
    return [pscustomobject]@{
        Before = $before
        After  = $after
    }
}

function Get-AiCliFlagValue {
    param($Tokens, [string]$Name, [string]$Default = $null)
    $tokenList = ConvertTo-AiCliTokenList $Tokens
    for ($i = 0; $i -lt $tokenList.Count; $i++) {
        if ($tokenList[$i] -eq $Name -and $i + 1 -lt $tokenList.Count) { return $tokenList[$i + 1] }
        if ($tokenList[$i].StartsWith("$Name=")) { return $tokenList[$i].Substring($Name.Length + 1) }
    }
    return $Default
}

function Test-AiCliHasFlag {
    param($Tokens, [string]$Name)
    $tokenList = ConvertTo-AiCliTokenList $Tokens
    return ($tokenList -contains $Name)
}

function Assert-AiCliTokenShape {
    param(
        $Tokens = @(),
        [int]$MinPositionals = 0,
        [int]$MaxPositionals = 0,
        [string[]]$Switches = @(),
        [string[]]$ValueOptions = @()
    )
    $tokenList = ConvertTo-AiCliTokenList $Tokens
    $positionals = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $tokenList.Count; $i++) {
        $token = [string]$tokenList[$i]
        if ($Switches -contains $token) { continue }
        $matchedValue = $false
        foreach ($option in $ValueOptions) {
            if ($token -eq $option) {
                if ($i + 1 -ge $tokenList.Count -or [string]$tokenList[$i + 1] -like '-*') {
                    throw "参数 $option 缺少值。"
                }
                $i++
                $matchedValue = $true
                break
            }
            if ($token.StartsWith("$option=")) {
                if ([string]::IsNullOrWhiteSpace($token.Substring($option.Length + 1))) {
                    throw "参数 $option 缺少值。"
                }
                $matchedValue = $true
                break
            }
        }
        if ($matchedValue) { continue }
        if ($token -like '-*') { throw "未知参数: $token" }
        [void]$positionals.Add($token)
    }
    if ($positionals.Count -lt $MinPositionals -or $positionals.Count -gt $MaxPositionals) {
        throw "参数数量不正确：需要 $MinPositionals-$MaxPositionals 个位置参数，收到 $($positionals.Count) 个。"
    }
    return ,$positionals
}

function Invoke-AiCliRouter {
    param(
        $Tokens = @(),
        [AllowNull()][string]$StdInText = $null
    )

    try {
        $tokenList = ConvertTo-AiCliTokenList $Tokens
        if ($tokenList.Count -eq 0) {
            return (Invoke-AiCliInteractiveSelector)
        }

        $cmd = $tokenList[0].ToLowerInvariant()
        $rest = [System.Collections.Generic.List[string]]::new()
        if ($tokenList.Count -gt 1) {
            for ($i = 1; $i -lt $tokenList.Count; $i++) { [void]$rest.Add($tokenList[$i]) }
        }

        switch ($cmd) {
            'version' {
                $null = Assert-AiCliTokenShape -Tokens $rest -Switches @('--json')
                if (Test-AiCliHasFlag $rest '--json') {
                    Write-AiCliJson ([ordered]@{
                        command = (Get-AiCliCommandName)
                        version = (Get-AiCliVersion)
                        capabilities = [ordered]@{
                            machineEventProjection = 'aicli.machine-event.v1'
                            managedPublicWebSearch = 'public_web_search/bing-rss-v1'
                            recoverableRuns = 'aicli.recoverable-run.v1'
                            recoverableRunControl = @(
                                'start','resume','status','abort'
                            )
                        }
                    })
                } else {
                    [Console]::Out.WriteLine(("{0} {1}" -f (Get-AiCliCommandName), (Get-AiCliVersion)))
                }
                return (Get-AiCliExitCode Success)
            }
            'help' {
                $null = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 0 -MaxPositionals 1
                $topic = if ($rest.Count -gt 0) { $rest[0] } else { $null }
                Show-AiCliHelp -Topic $topic
                return (Get-AiCliExitCode Success)
            }
            'setup' {
                $null = Assert-AiCliTokenShape -Tokens $rest
                return (Invoke-AiCliSetup)
            }
            'profile' { return (Invoke-AiCliProfileCommand -Tokens $rest) }
            'start' { return (Invoke-AiCliStartCommand -Tokens $rest) }
            'run' {
                $run = @{ Tokens = $rest }
                if ($PSBoundParameters.ContainsKey('StdInText')) {
                    $run['StdInText'] = $StdInText
                }
                return (Invoke-AiCliRunCommand @run)
            }
            'native' {
                $pos = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 1 -MaxPositionals 1
                Show-AiCliNative -ProfileId $pos[0]
                return (Get-AiCliExitCode Success)
            }
            'eject' {
                $pos = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 1 -MaxPositionals 1 -ValueOptions @('--output')
                $out = Get-AiCliFlagValue -Tokens $rest -Name '--output'
                Export-AiCliEject -ProfileId $pos[0] -OutputPath $out | Out-Null
                return (Get-AiCliExitCode Success)
            }
            'doctor' {
                $pos = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 0 -MaxPositionals 1 -Switches @('--json')
                $id = if ($pos.Count) { $pos[0] } else { $null }
                $json = Test-AiCliHasFlag $rest '--json'
                return (Invoke-AiCliDoctor -ProfileId $id -Json:$json)
            }
            'test' { return (Invoke-AiCliTestCommand -Tokens $rest) }
            'proxy' { return (Invoke-AiCliProxyCommand -Tokens $rest) }
            'update' { return (Invoke-AiCliUpdateCommand -Tokens $rest) }
            'uninstall' { return (Invoke-AiCliUninstallCommand -Tokens $rest) }
            default {
                Write-AiCliErrorLine "未知命令: $cmd"
                Write-AiCliInfo '示例: aicli profile list'
                Show-AiCliHelpRoot
                return (Get-AiCliExitCode UsageError)
            }
        }
    } catch [System.OperationCanceledException] {
        Write-AiCliWarn $_.Exception.Message
        return (Get-AiCliExitCode Cancelled)
    } catch {
        $msg = Protect-AiCliSecretText $_.Exception.Message
        if ($msg -match '用法:|未知|参数') {
            Write-AiCliErrorLine $msg
            return (Get-AiCliExitCode UsageError)
        }
        Write-AiCliErrorLine $msg
        Write-AiCliLog -Level Error -Message $msg
        return (Get-AiCliExitCode Unavailable)
    }
}

function Invoke-AiCliProfileCommand {
    param($Tokens)
    $tokenList = ConvertTo-AiCliTokenList $Tokens
    if ($tokenList.Count -lt 1) { throw '用法: aicli profile list|show|configure|set-default|remove' }
    $sub = $tokenList[0].ToLowerInvariant()
    $rest = [System.Collections.Generic.List[string]]::new()
    if ($tokenList.Count -gt 1) {
        for ($i = 1; $i -lt $tokenList.Count; $i++) { [void]$rest.Add($tokenList[$i]) }
    }
    switch ($sub) {
        'list' {
            $null = Assert-AiCliTokenShape -Tokens $rest -Switches @('--available','--json')
            $available = Test-AiCliHasFlag $rest '--available'
            $json = Test-AiCliHasFlag $rest '--json'
            $list = Get-AiCliProfileList -Available:$available
            if ($json) {
                $rows = @($list | ForEach-Object {
                    $models = Get-AiCliProperty $_ 'models'
                    $requestedEffort = [string](Get-AiCliProperty $_ 'defaultEffort')
                    $effortMap = Get-AiCliProperty $_ 'effortMap'
                    $effectiveEffort = [string](Get-AiCliProperty $effortMap $requestedEffort)
                    if (-not $effectiveEffort) { $effectiveEffort = $requestedEffort }
                    [ordered]@{
                        id = (Get-AiCliProperty $_ 'id')
                        displayName = (Get-AiCliProperty $_ 'displayName')
                        engine = (Get-AiCliProperty $_ 'engine')
                        provider = (Get-AiCliProperty $_ 'provider')
                        model = (Get-AiCliProperty $models 'primary')
                        wire = (Get-AiCliProperty $_ 'transport')
                        requestedEffort = $requestedEffort
                        effectiveEffort = $effectiveEffort
                        status = (Get-AiCliProperty $_ 'status')
                        configured = (Get-AiCliProperty $_ 'configured')
                        secretPresence = (Format-AiCliSecretPresence ([bool](Get-AiCliProperty $_ 'secretConfigured')))
                    }
                })
                Write-AiCliJson (New-AiCliResult -Command 'profile list' -OverallStatus '通过' -Extra @{ profiles = $rows })
            } else {
                Write-Host ("{0,-32} {1,-8} {2,-24} {3,-12} {4,-16} {5}" -f 'ID','引擎','模型','effort','状态','名称')
                foreach ($p in $list) {
                    $models = Get-AiCliProperty $p 'models'
                    $requestedEffort = [string](Get-AiCliProperty $p 'defaultEffort')
                    $effortMap = Get-AiCliProperty $p 'effortMap'
                    $effectiveEffort = [string](Get-AiCliProperty $effortMap $requestedEffort)
                    if (-not $effectiveEffort) { $effectiveEffort = $requestedEffort }
                    $effortDisplay = if ($requestedEffort -and $effectiveEffort -and $requestedEffort -cne $effectiveEffort) {
                        "$requestedEffort→$effectiveEffort"
                    } else {
                        $requestedEffort
                    }
                    Write-Host ("{0,-32} {1,-8} {2,-24} {3,-12} {4,-16} {5}" -f `
                        (Get-AiCliProperty $p 'id'),
                        (Get-AiCliProperty $p 'engine'),
                        (Get-AiCliProperty $models 'primary'),
                        $effortDisplay,
                        (Get-AiCliProperty $p 'status'),
                        (Get-AiCliProperty $p 'displayName'))
                }
                if (-not $available) {
                    Write-Host ''
                    Write-Host '提示: aicli profile list --available 查看全部模板'
                }
            }
            return (Get-AiCliExitCode Success)
        }
        'show' {
            $pos = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 1 -MaxPositionals 1 -Switches @('--json')
            $p = Get-AiCliResolvedProfile -Id $pos[0]
            $view = Protect-AiCliObject -InputObject $p
            $hasSecret = [bool](Get-AiCliProperty $p 'secretConfigured')
            if ($view -is [System.Collections.IDictionary]) {
                $view['secretRef'] = Format-AiCliSecretPresence $hasSecret
                $view['secretConfigured'] = Format-AiCliSecretPresence $hasSecret
            } else {
                $view | Add-Member -NotePropertyName secretRef -NotePropertyValue (Format-AiCliSecretPresence $hasSecret) -Force
                $view | Add-Member -NotePropertyName secretConfigured -NotePropertyValue (Format-AiCliSecretPresence $hasSecret) -Force
            }
            if (Test-AiCliHasFlag $rest '--json') {
                Write-AiCliJson (New-AiCliResult -Command 'profile show' -OverallStatus (Get-AiCliProperty $p 'status') -Extra @{ profile = $view })
            } else {
                Write-Host ("ID: {0}" -f (Get-AiCliProperty $p 'id'))
                Write-Host ("名称: {0}" -f (Get-AiCliProperty $p 'displayName'))
                Write-Host ("引擎: {0}  Provider: {1}  套餐: {2}" -f (Get-AiCliProperty $p 'engine'), (Get-AiCliProperty $p 'provider'), (Get-AiCliProperty $p 'plan'))
                Write-Host ("状态: {0}" -f (Get-AiCliProperty $p 'status'))
                Write-Host ("密钥: {0}" -f (Format-AiCliSecretPresence ([bool](Get-AiCliProperty $p 'secretConfigured'))))
                $ep = Get-AiCliProperty $p 'endpoint'
                if (-not $ep -and (Get-AiCliProperty $p 'proxyRef')) {
                    $ep = "managed-proxy:$([string](Get-AiCliProperty $p 'proxyRef'))"
                }
                Write-Host ("端点: {0}" -f $ep)
                Write-Host ("数据去向: {0}" -f (Get-AiCliProperty $p 'dataDestination'))
            }
            return (Get-AiCliExitCode Success)
        }
        'configure' {
            $pos = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 1 -MaxPositionals 1 `
                -Switches @('--reuse-existing-secret') `
                -ValueOptions @('--id','--reuse-secret-from')
            $newId = Get-AiCliFlagValue -Tokens $rest -Name '--id'
            $reuseSecretFrom = Get-AiCliFlagValue -Tokens $rest -Name '--reuse-secret-from'
            Invoke-AiCliProfileConfigure `
                -TemplateId $pos[0] `
                -ProfileId $newId `
                -ReuseExistingSecret:(Test-AiCliHasFlag $rest '--reuse-existing-secret') `
                -ReuseSecretFrom $reuseSecretFrom | Out-Null
            return (Get-AiCliExitCode Success)
        }
        'set-default' {
            $pos = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 1 -MaxPositionals 1
            Set-AiCliDefaultProfile -Id $pos[0]
            Write-AiCliSuccess "默认 Profile: $($pos[0])"
            return (Get-AiCliExitCode Success)
        }
        'remove' {
            $pos = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 1 -MaxPositionals 1 -Switches @('--yes')
            Remove-AiCliUserProfile -Id $pos[0] -Yes:(Test-AiCliHasFlag $rest '--yes')
            Write-AiCliSuccess "已删除用户 Profile: $($pos[0])"
            return (Get-AiCliExitCode Success)
        }
        default { throw "未知 profile 子命令: $sub" }
    }
}

function Invoke-AiCliStartCommand {
    param($Tokens)
    $tokenList = ConvertTo-AiCliTokenList $Tokens
    if ($tokenList.Count -lt 1) { throw '用法: aicli start <id> [--project <path>] [-- <native-args...>]' }
    $split = Split-AiCliArgs -Tokens $tokenList
    $pos = Assert-AiCliTokenShape -Tokens $split.Before -MinPositionals 1 -MaxPositionals 1 -ValueOptions @('--project')
    $id = [string]$pos[0]
    $project = Get-AiCliFlagValue -Tokens $split.Before -Name '--project'
    $native = ConvertTo-AiCliTokenList $split.After
    $code = Start-AiCliProfile -ProfileId $id -ProjectPath $project -NativeArgs ([string[]]$native.ToArray())
    return $code
}

function Invoke-AiCliRunCommand {
    param(
        $Tokens,
        [AllowNull()][string]$StdInText = $null
    )
    try {
        $tokenList = ConvertTo-AiCliTokenList $Tokens
        if ($tokenList.Count -lt 1) {
            throw '用法: aicli run start <id> --stdin --json ... | aicli run resume|status|abort <run-id> --json'
        }
        $runAction = ([string]$tokenList[0]).ToLowerInvariant()
        $legacyStartSyntax = $runAction -notin @('start','resume','status','abort')
        if ($runAction -in @('resume','status','abort')) {
            $controlTokens = [Collections.Generic.List[string]]::new()
            if ($tokenList.Count -gt 1) {
                for ($i = 1; $i -lt $tokenList.Count; $i++) {
                    [void]$controlTokens.Add([string]$tokenList[$i])
                }
            }
            $controlPositionals = Assert-AiCliTokenShape `
                -Tokens $controlTokens -MinPositionals 1 -MaxPositionals 1 `
                -Switches @('--json','--background')
            if (-not (Test-AiCliHasFlag $controlTokens '--json')) {
                throw 'Recoverable run control commands require --json.'
            }
            $backgroundControl = Test-AiCliHasFlag `
                $controlTokens '--background'
            if ($backgroundControl -and $runAction -ne 'resume') {
                throw '--background is supported only by run start or run resume.'
            }
            $runId = [string]$controlPositionals[0]
            $controlResult = switch ($runAction) {
                'resume' {
                    if ($backgroundControl) {
                        Start-AiCliRecoverableControllerProcess -RunId $runId
                    } else {
                        Invoke-AiCliRecoverableRun -RunId $runId
                    }
                }
                'status' { Get-AiCliRecoverableRunStatus -RunId $runId }
                'abort' { Stop-AiCliRecoverableRun -RunId $runId }
            }
            $controlStatus = if ($runAction -eq 'status' -or
                $controlResult.status -in @('completed','running','interrupted','quota_paused','abort_requested','aborted')) {
                '通过'
            } else { '不可用' }
            Write-AiCliJson (New-AiCliResult -Command "run.$runAction" `
                -OverallStatus $controlStatus -Extra @{
                    recovery = $controlResult
                })
            return (Get-AiCliExitCodeFromStatus $controlStatus)
        }
        if ($runAction -eq 'start') {
            $withoutAction = [Collections.Generic.List[string]]::new()
            if ($tokenList.Count -gt 1) {
                for ($i = 1; $i -lt $tokenList.Count; $i++) {
                    [void]$withoutAction.Add([string]$tokenList[$i])
                }
            }
            $tokenList = $withoutAction
        }
        $split = Split-AiCliArgs -Tokens $tokenList
        $pos = Assert-AiCliTokenShape -Tokens $split.Before -MinPositionals 1 -MaxPositionals 1 `
            -Switches @('--stdin','--json','--watchdog-only','--authority-prelude-stdout','--no-web-search','--background') `
            -ValueOptions @('--project','--sandbox-policy','--timeout-seconds','--max-steps','--max-tool-calls','--max-output-chars','--event-file','--max-resume-attempts')
        if (-not (Test-AiCliHasFlag $split.Before '--stdin')) {
            throw '参数 --stdin 是 machine run 的必需项；任务正文不得放入命令行参数。'
        }
        if (-not (Test-AiCliHasFlag $split.Before '--json')) {
            throw '参数 --json 是 machine run 的必需项。'
        }
        $timeoutSecondsText = Get-AiCliFlagValue -Tokens $split.Before -Name '--timeout-seconds' -Default '120'
        $profileId = [string]$pos[0]
        $resolvedForHarness = Get-AiCliResolvedProfile -Id $profileId
        $isCodexHarness = [string](Get-AiCliProperty $resolvedForHarness 'engine') -eq 'codex'
        $disableWebSearch = Test-AiCliHasFlag $split.Before '--no-web-search'
        $sandboxPolicy = Get-AiCliFlagValue -Tokens $split.Before -Name '--sandbox-policy'
        if ($isCodexHarness) {
            if (-not [string]::IsNullOrWhiteSpace($sandboxPolicy) -and
                $sandboxPolicy -ne 'danger-full-access') {
                throw 'Codex harness 固定使用 danger-full-access；拒绝静默降级为其他权限。'
            }
            $sandboxPolicy = 'danger-full-access'
        } else {
            if ($disableWebSearch) {
                throw '参数 --no-web-search 仅适用于 Codex harness。'
            }
            if ([string]::IsNullOrWhiteSpace($sandboxPolicy)) { $sandboxPolicy = 'read-only' }
            if ($sandboxPolicy -notin @('read-only','workspace-write')) {
                throw '非 Codex machine run 的 --sandbox-policy 只能是 read-only 或 workspace-write。'
            }
        }
        $maxStepsText = Get-AiCliFlagValue -Tokens $split.Before -Name '--max-steps' -Default '20'
        $maxToolCallsText = Get-AiCliFlagValue -Tokens $split.Before -Name '--max-tool-calls' -Default '80'
        $maxOutputText = Get-AiCliFlagValue -Tokens $split.Before -Name '--max-output-chars' -Default '1000000'
        $maxResumeText = Get-AiCliFlagValue -Tokens $split.Before `
            -Name '--max-resume-attempts' -Default '3'
        $timeoutSeconds = 0
        $maxSteps = 0
        $maxToolCalls = 0
        $maxOutputChars = 0
        $maxResumeAttempts = 0
        if (-not [int]::TryParse($timeoutSecondsText, [ref]$timeoutSeconds) -or $timeoutSeconds -lt 1 -or $timeoutSeconds -gt 86400) {
            throw '参数 --timeout-seconds 必须是 1 到 86400。'
        }
        if (-not [int]::TryParse($maxStepsText, [ref]$maxSteps) -or $maxSteps -lt 1 -or $maxSteps -gt 200) {
            throw '参数 --max-steps 必须是 1 到 200。'
        }
        if (-not [int]::TryParse($maxToolCallsText, [ref]$maxToolCalls) -or $maxToolCalls -lt 0 -or $maxToolCalls -gt 10000) {
            throw '参数 --max-tool-calls 必须是 0 到 10000。'
        }
        if (-not [int]::TryParse($maxOutputText, [ref]$maxOutputChars) -or $maxOutputChars -lt 1024 -or $maxOutputChars -gt 10000000) {
            throw '参数 --max-output-chars 必须是 1024 到 10000000。'
        }
        if (-not [int]::TryParse($maxResumeText, [ref]$maxResumeAttempts) -or
            $maxResumeAttempts -lt 0 -or $maxResumeAttempts -gt 3) {
            throw '参数 --max-resume-attempts 必须是 0 到 3。'
        }
        $native = ConvertTo-AiCliTokenList $split.After
        if ($native.Count -gt 0) {
            $allowedNative = @(
                'exec','e','--json','--ephemeral',
                '--dangerously-bypass-approvals-and-sandbox',
                '--skip-git-repo-check','-'
            )
            if ($native[0] -notin @('exec','e') -or
                $native[-1] -cne '-' -or
                $native -notcontains '--json' -or
                @($native | Where-Object { $_ -notin $allowedNative }).Count -gt 0) {
                throw 'Recoverable Codex run only accepts the canonical exec --json ... - native shape.'
            }
        }
        $requestedEventFile = Get-AiCliFlagValue -Tokens $split.Before `
            -Name '--event-file'
        if ($requestedEventFile) {
            $requestedEventFile = Resolve-AiCliMachineEventMirrorFile `
                -Path $requestedEventFile -ExpectedSequence 0
        }
        $taskText = if ($PSBoundParameters.ContainsKey('StdInText')) {
            $StdInText
        } else {
            [Console]::In.ReadToEnd()
        }
        if ([string]::IsNullOrWhiteSpace($taskText)) {
            throw '参数 --stdin 未提供任务正文；拒绝启动空任务。'
        }
        $watchdogOnly = Test-AiCliHasFlag $split.Before '--watchdog-only'
        $projectPath = Resolve-AiCliProjectPath (
            Get-AiCliFlagValue -Tokens $split.Before -Name '--project'
        )
        $created = New-AiCliRecoverableRun -ProfileId $profileId `
            -ProjectPath $projectPath -TaskText $taskText `
            -TimeoutMs ($timeoutSeconds * 1000) `
            -MaxCaptureChars $maxOutputChars -MaxSteps $maxSteps `
            -MaxToolCalls $maxToolCalls -WatchdogOnly:$watchdogOnly `
            -DisableWebSearch:$disableWebSearch `
            -AuthorityPreludeStdout:(Test-AiCliHasFlag $split.Before '--authority-prelude-stdout') `
            -MaxResumeAttempts $maxResumeAttempts `
            -ConsumerEventFile $requestedEventFile
        if (Test-AiCliHasFlag $split.Before '--background') {
            $spawned = Start-AiCliRecoverableControllerProcess `
                -RunId $created.runId -InitialTaskText $taskText
            $resultCommand = if ($legacyStartSyntax) {
                'run'
            } else { 'run.start' }
            Write-AiCliJson (New-AiCliResult -Command $resultCommand `
                -OverallStatus '通过' -Extra @{
                    run = [ordered]@{
                        exitCode = 0
                        timedOut = $false
                        background = $true
                        recoveryRunId = $created.runId
                    }
                    recovery = $spawned
                })
            return (Get-AiCliExitCode Success)
        }
        $recovery = Invoke-AiCliRecoverableRun -RunId $created.runId `
            -InitialTaskText $taskText
        $run = Get-AiCliProperty $recovery 'receipt'
        if ($null -eq $run) {
            $run = [pscustomobject]@{
                profileId = $profileId
                exitCode = (Get-AiCliExitCode Unavailable)
                timedOut = $false
                stdout = ''
                stderr = 'Recoverable run ended without a public attempt receipt.'
            }
        }
        $run | Add-Member -NotePropertyName recoveryRunId `
            -NotePropertyValue $created.runId -Force
        $run | Add-Member -NotePropertyName resumeSupported `
            -NotePropertyValue ([bool]$recovery.resumeSupported) -Force
        $run | Add-Member -NotePropertyName resumeReason `
            -NotePropertyValue ([string]$recovery.resumeReason) -Force
        $status = if ($recovery.status -eq 'completed' -and
            [int]$run.exitCode -eq 0 -and -not [bool]$run.timedOut) {
            '通过'
        } else { '不可用' }
        $publicRecovery = $recovery | Select-Object * -ExcludeProperty receipt
        $resultCommand = if ($legacyStartSyntax) { 'run' } else { 'run.start' }
        Write-AiCliJson (New-AiCliResult -Command $resultCommand `
            -OverallStatus $status -Extra @{
                run = $run
                recovery = $publicRecovery
            })
        return (Get-AiCliExitCodeFromStatus $status)
    } catch {
        $summary = Protect-AiCliSecretText $_.Exception.Message
        Write-AiCliJson (New-AiCliResult -Command 'run' -OverallStatus '不可用' -Extra @{
            error = [ordered]@{ category = 'invalid_run'; summary = $summary }
        })
        if ($summary -match '用法:|参数|machine run') { return (Get-AiCliExitCode UsageError) }
        return (Get-AiCliExitCode Unavailable)
    }
}

function Invoke-AiCliTestCommand {
    param($Tokens)
    $tokenList = ConvertTo-AiCliTokenList $Tokens
    if ($tokenList.Count -lt 1) { throw '用法: aicli test <id> --live [--level text|tool|all] [--yes] [--json]' }
    $pos = Assert-AiCliTokenShape -Tokens $tokenList -MinPositionals 1 -MaxPositionals 1 -Switches @('--live','--yes','--json') -ValueOptions @('--level')
    if (-not (Test-AiCliHasFlag $tokenList '--live')) {
        throw '必须显式指定 --live。用法: aicli test <id> --live [--yes]'
    }
    $id = [string]$pos[0]
    $level = Get-AiCliFlagValue -Tokens $tokenList -Name '--level' -Default 'text'
    if ($level -notin @('text','tool','all')) { throw "参数 --level 无效: $level" }
    return (Invoke-AiCliLiveTest -ProfileId $id -Level $level -Yes:(Test-AiCliHasFlag $tokenList '--yes') -Json:(Test-AiCliHasFlag $tokenList '--json'))
}

function Invoke-AiCliProxyCommand {
    param($Tokens)
    $tokenList = ConvertTo-AiCliTokenList $Tokens
    if ($tokenList.Count -lt 2) { throw '用法: aicli proxy <ccp|cliproxy> <install|login|...>' }
    # avoid $pid — PowerShell automatic process-id variable
    $proxyId = $tokenList[0].ToLowerInvariant()
    if ($proxyId -notin @('ccp','cliproxy')) { throw '代理 id 只能是 ccp 或 cliproxy' }
    $sub = $tokenList[1].ToLowerInvariant()
    $rest = [System.Collections.Generic.List[string]]::new()
    if ($tokenList.Count -gt 2) {
        for ($i = 2; $i -lt $tokenList.Count; $i++) { [void]$rest.Add($tokenList[$i]) }
    }
    switch ($sub) {
        'install' {
            $null = Assert-AiCliTokenShape -Tokens $rest
            return (Install-AiCliProxy -ProxyId $proxyId)
        }
        'login' {
            $pos = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 0 -MaxPositionals 1
            $provider = if ($pos.Count) { $pos[0] } else { 'codex' }
            if ($provider -notin @('codex','claude','device')) { throw "参数 provider 无效: $provider" }
            if ($proxyId -eq 'ccp' -and $provider -eq 'claude') {
                throw '参数组合无效：ccp 0.1.15 只支持 codex 或 device 登录；claude 登录仅用于 cliproxy。'
            }
            return (Invoke-AiCliProxyLogin -ProxyId $proxyId -Provider $provider)
        }
        'logout' {
            $null = Assert-AiCliTokenShape -Tokens $rest -Switches @('--purge-local-auth','--yes')
            return (Invoke-AiCliProxyLogout -ProxyId $proxyId -PurgeLocalAuth:(Test-AiCliHasFlag $rest '--purge-local-auth') -Yes:(Test-AiCliHasFlag $rest '--yes'))
        }
        'configure' {
            $null = Assert-AiCliTokenShape -Tokens $rest -Switches @('--auto-port') -ValueOptions @('--port')
            $port = Get-AiCliFlagValue -Tokens $rest -Name '--port'
            $p = 0; if ($port) { $p = [int]$port }
            Set-AiCliProxyConfigure -ProxyId $proxyId -Port $p -AutoPort:(Test-AiCliHasFlag $rest '--auto-port') | Out-Null
            return (Get-AiCliExitCode Success)
        }
        'start' { $null = Assert-AiCliTokenShape -Tokens $rest; return (Start-AiCliProxy -ProxyId $proxyId) }
        'stop' { $null = Assert-AiCliTokenShape -Tokens $rest; return (Stop-AiCliProxy -ProxyId $proxyId) }
        'status' {
            $null = Assert-AiCliTokenShape -Tokens $rest -Switches @('--json')
            return (Get-AiCliProxyStatus -ProxyId $proxyId -Json:(Test-AiCliHasFlag $rest '--json'))
        }
        'update-check' { $null = Assert-AiCliTokenShape -Tokens $rest; return (Invoke-AiCliProxyUpdateCheck -ProxyId $proxyId) }
        'update' {
            $null = Assert-AiCliTokenShape -Tokens $rest
            Write-AiCliInfo '0.1.0 对已安装代理禁用受管替换；update 会安全拒绝，不会覆盖当前版本。'
            return (Install-AiCliProxy -ProxyId $proxyId)
        }
        'native' {
            $null = Assert-AiCliTokenShape -Tokens $rest
            $meta = Get-AiCliProxyMeta -ProxyId $proxyId
            $paths = Get-AiCliProxyPaths -ProxyId $proxyId
            Write-Host ($meta | ConvertTo-Json -Depth 5)
            Write-Host ($paths | ConvertTo-Json -Depth 5)
            Write-Host "可执行文件: $(Get-AiCliProxyExecutable $proxyId)"
            return (Get-AiCliExitCode Success)
        }
        default { throw "未知 proxy 子命令: $sub" }
    }
}

function Invoke-AiCliUpdateCommand {
    param([string[]]$Tokens)
    if ($Tokens.Count -lt 1) { throw '用法: aicli update check|guide [component]' }
    $sub = $Tokens[0].ToLowerInvariant()
    $rest = if ($Tokens.Count -gt 1) { @($Tokens[1..($Tokens.Count - 1)]) } else { @() }
    switch ($sub) {
        'check' {
            $pos = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 0 -MaxPositionals 1 -Switches @('--json')
            $comp = if ($pos.Count) { $pos[0] } else { $null }
            return (Invoke-AiCliUpdateCheck -Component $comp -Json:(Test-AiCliHasFlag $rest '--json'))
        }
        'guide' {
            $pos = Assert-AiCliTokenShape -Tokens $rest -MinPositionals 0 -MaxPositionals 1
            $comp = if ($pos.Count) { $pos[0] } else { 'codex' }
            return (Invoke-AiCliUpdateGuide -Component $comp)
        }
        default { throw '用法: aicli update check|guide' }
    }
}

function Invoke-AiCliUninstallCommand {
    param([string[]]$Tokens)
    $null = Assert-AiCliTokenShape -Tokens $Tokens -Switches @('--purge-user-data','--yes')
    $purge = Test-AiCliHasFlag $Tokens '--purge-user-data'
    $yes = Test-AiCliHasFlag $Tokens '--yes'
    # Preflight every recursive-delete target and every recorded process before
    # confirmation or mutation. A failed late check must never leave a partial
    # purge or half-uninstall behind.
    $modName = (Get-AiCliBrand).ModuleName
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($p in ($env:PSModulePath -split ';' | Where-Object { $_ })) {
        if ($p -notmatch '(?i)Program Files' -and $p -notmatch '(?i)WindowsApps' -and $p -notmatch '(?i)system32') {
            $candidates.Add((Join-Path $p $modName)) | Out-Null
        }
    }
    $candidates.Add((Join-Path ([Environment]::GetFolderPath('MyDocuments')) "PowerShell\Modules\$modName")) | Out-Null
    $moduleTargets = @($candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
    foreach ($m in $moduleTargets) {
        if (-not (Test-AiCliManagedModuleDirectory -Path $m)) {
            throw "发现同名但身份无法确认的模块目录，拒绝递归删除: $m"
        }
    }

    $proxyActions = [System.Collections.Generic.List[object]]::new()
    foreach ($proxyId in @('ccp','cliproxy')) {
        $proxyState = Get-AiCliProxyState -ProxyId $proxyId
        if (-not $proxyState) { continue }
        $identity = Test-AiCliProcessIdentity -State $proxyState -Strict -ExpectedProxyId $proxyId
        if ($identity.Match) {
            $proxyActions.Add([pscustomobject]@{ ProxyId = $proxyId; Action = 'stop' }) | Out-Null
            continue
        }
        $recordedPid = [int](Get-AiCliProperty $proxyState 'pid' 0)
        $liveProcess = if ($recordedPid -gt 0) { Get-Process -Id $recordedPid -ErrorAction SilentlyContinue } else { $null }
        if ($liveProcess) {
            throw "代理 $proxyId 的记录指向仍在运行但身份不匹配的进程 PID=$recordedPid ($($identity.Reason))；拒绝卸载。"
        }
        $proxyActions.Add([pscustomobject]@{ ProxyId = $proxyId; Action = 'clear-stale' }) | Out-Null
    }

    Write-Host '将卸载 AI CLI Profile Manager 模块（不会卸载 Codex/Claude/Ollama）。'
    if ($purge) {
        Write-Host '--purge-user-data 将删除本项目 AppData/Local 数据（Profile、秘密、代理数据）。'
        Write-Host '代理 OAuth：建议先 aicli proxy <id> logout；强制本地删除用 --purge-local-auth（≠ 远程撤销）。'
    } else {
        Write-Host '默认保留用户 Profile、秘密与导出物。'
    }
    if (-not (Confirm-AiCliAction -Message '确认卸载？' -Yes:$yes)) {
        return (Get-AiCliExitCode Cancelled)
    }

    foreach ($action in $proxyActions) {
        if ($action.Action -eq 'stop') {
            Stop-AiCliManagedProcess -ProxyId $action.ProxyId
        } else {
            Clear-AiCliProxyState -ProxyId $action.ProxyId
            Write-AiCliInfo "已清理不存在进程的过期代理状态: $($action.ProxyId)"
        }
    }
    foreach ($m in $moduleTargets) {
        Remove-Item -LiteralPath $m -Recurse -Force
        Write-AiCliSuccess "已删除模块: $m"
    }
    Remove-AiCliShellIntegration
    Write-AiCliSuccess '已移除 aicli 垫片、用户 PATH 项与受管 PowerShell Profile 块'
    if ($purge) {
        $paths = Get-AiCliAppPaths
        foreach ($d in @($paths.AppDataRoot, $paths.LocalRoot)) {
            if (Test-Path -LiteralPath $d) {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $d) { throw "用户数据目录未能删除: $d" }
            }
        }
        Write-AiCliSuccess '已删除用户数据目录'
    }
    Write-AiCliInfo '若从仓库开发使用，删除模块目录即可；仓库源码不会被本命令删除。'
    return (Get-AiCliExitCode Success)
}

function Invoke-AiCliSetup {
    Write-Host @"
欢迎使用 $(Get-AiCliProductName)

本工具只管理启动配置与代理运维；对话仍由原生 Codex CLI / Claude Code 完成。
"@
    $null = Invoke-AiCliDoctor
    Write-Host ''
    Write-Host '建议步骤：'
    Write-Host '  1) 官方 Codex:  aicli start codex-official'
    Write-Host '  2) 官方 Claude: aicli start claude-official'
    Write-Host '  3) 第三方:      aicli profile configure <template-id>'
    Write-Host '  4) 体检:        aicli doctor <id>'
    Write-Host '  5) 可选 Live:   aicli test <id> --live --yes'
    $idx = Show-AiCliMenu -Title '选择要配置的方向' -Choices @(
        '仅查看说明（稍后手动）',
        '配置 Codex DeepSeek V4 Flash 0731',
        '配置 Codex DeepSeek V4 Pro 0813',
        '配置 Codex Qwen3.7 Max 06-08 Workspace 按量',
        '配置 Codex Qwen3.8 Max Workspace 按量',
        '配置 Claude DeepSeek',
        '查看全部模板'
    )
    switch ($idx) {
        1 { Invoke-AiCliProfileConfigure -TemplateId 'codex-deepseek' | Out-Null }
        2 { Invoke-AiCliProfileConfigure -TemplateId 'codex-deepseek-v4-pro' | Out-Null }
        3 { Invoke-AiCliProfileConfigure -TemplateId 'codex-qwen3-7-max-paygo' | Out-Null }
        4 { Invoke-AiCliProfileConfigure -TemplateId 'codex-qwen3-8-max-paygo' | Out-Null }
        5 { Invoke-AiCliProfileConfigure -TemplateId 'claude-deepseek' | Out-Null }
        6 { Invoke-AiCliRouter -Tokens @('profile','list','--available') | Out-Null }
        default { Write-AiCliInfo '已结束 setup。' }
    }
    return (Get-AiCliExitCode Success)
}

function Invoke-AiCliInteractiveSelector {
    $settings = Get-AiCliSettings
    $choices = [System.Collections.Generic.List[string]]::new()
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(
        [pscustomobject]@{ Label = '最近'; Id = [string]$settings.lastProfileId },
        [pscustomobject]@{ Label = '默认'; Id = [string]$settings.defaultProfileId }
    )) {
        if ([string]::IsNullOrWhiteSpace($entry.Id) -or $ids -contains $entry.Id) { continue }
        try {
            $resolvedRecent = Get-AiCliResolvedProfile -Id $entry.Id
            if (-not [bool](Get-AiCliProperty $resolvedRecent 'configured' $false)) { continue }
            $choices.Add("$($entry.Label): $($entry.Id)")
            $ids.Add($entry.Id)
        } catch {
            # A removed/retired/conflicting ID must not survive as a launchable
            # interactive shortcut merely because it remains in old settings.
        }
    }
    $list = Get-AiCliProfileList
    foreach ($p in $list) {
        $pidStr = [string](Get-AiCliProperty $p 'id')
        if ($ids -contains $pidStr) { continue }
        $choices.Add(("{0} ({1})" -f (Get-AiCliProperty $p 'displayName'), $pidStr))
        $ids.Add($pidStr)
    }
    if ($choices.Count -eq 0) {
        Write-AiCliInfo '暂无可用 Profile。运行: aicli setup'
        return (Get-AiCliExitCode Success)
    }
    $sel = Show-AiCliMenu -Title '选择 Profile 启动（当前目录）' -Choices @($choices)
    if ($null -eq $sel) { return (Get-AiCliExitCode Cancelled) }
    return (Start-AiCliProfile -ProfileId $ids[$sel])
}
