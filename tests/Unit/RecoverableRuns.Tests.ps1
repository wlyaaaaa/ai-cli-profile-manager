#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Recoverable Codex runs' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module AiCliProfileManager -All |
            Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (
            Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1'
        ) -Force
    }

    It 'persists a closed recovery identity without persisting the task text' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:AiCliDataRootOverride = Join-Path $Work 'data'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine = 'codex'
                        profileId = 'future'
                        profileFingerprint = ('a' * 64)
                        workingDirectory = $Work
                        model = 'future-model'
                        modelProvider = 'future_provider'
                        wire = 'responses'
                        effort = 'max'
                        effectiveEffort = 'max'
                    }
                }

                $created = New-AiCliRecoverableRun -ProfileId 'future' `
                    -ProjectPath $Work -TaskText 'PRIVATE_TASK_CANARY' `
                    -TimeoutMs 5000 -MaxSteps 8 -MaxToolCalls 4
                $state = Get-AiCliRecoverableRunState -RunId $created.runId

                $state.schema | Should -Be 'aicli.recoverable-run.v1'
                $state.status | Should -Be 'pending'
                $state.sessionMeta.workspace | Should -Be ([IO.Path]::GetFullPath($Work))
                $state.sessionMeta.profileId | Should -BeExactly 'future'
                $state.sessionMeta.model | Should -BeExactly 'future-model'
                $state.sessionMeta.modelProvider | Should -BeExactly 'future_provider'
                $state.sessionMeta.requestedEffort | Should -BeExactly 'max'
                $state.sessionMeta.effectiveEffort | Should -BeExactly 'max'
                $state.sessionMeta.protocol | Should -BeExactly 'codex-app-server'
                $state.resume.supported | Should -BeFalse
                $state.resume.reason | Should -BeExactly 'thread_not_started'
                ($state | ConvertTo-Json -Depth 30 -Compress) |
                    Should -Not -Match 'PRIVATE_TASK_CANARY'
                Test-AiCliRecoverableRunState -State $state | Should -BeTrue
            } finally {
                $script:AiCliDataRootOverride = $null
            }
        }
    }

    It 'automatically resumes only the exact same thread and session' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:AiCliDataRootOverride = Join-Path $Work 'data'
            $script:captureCalls = 0
            $threadId = '11111111-1111-4111-8111-111111111111'
            $sessionId = '22222222-2222-4222-8222-222222222222'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine = 'codex'; profileId = 'future'
                        profileFingerprint = ('b' * 64)
                        workingDirectory = $Work; model = 'future-model'
                        modelProvider = 'future_provider'; wire = 'responses'
                        effort = 'max'; effectiveEffort = 'max'
                    }
                }
                Mock Invoke-AiCliProfileCapture {
                    $script:captureCalls++
                    if ($script:captureCalls -eq 1) {
                        $RecoveryContext.mode | Should -BeExactly 'start'
                        $RecoveryContext.threadId | Should -BeNullOrEmpty
                        return [pscustomobject]@{
                            exitCode = 74; timedOut = $false
                            errorCode = 'codex_appserver.item_unfinished'
                            threadId = $threadId; sessionId = $sessionId
                            turnId = '33333333-3333-4333-8333-333333333331'
                            durationMs = 1200; machineEventSequenceStart = 0
                            machineEventSequenceEnd = 5; machineEventCount = 5
                            usage = [ordered]@{ input_tokens = 100; output_tokens = 10 }
                            runtimeIdentity = [ordered]@{
                                model = 'future-model'; model_provider = 'future_provider'
                                cli_version = '0.147.0'
                                permission = [ordered]@{
                                    approval_policy='never'; requested_policy='danger-full-access'
                                    sandbox_boundary='codex-native'; sandbox_type='dangerFullAccess'
                                    permission_profile=':danger-full-access'
                                }
                            }
                        }
                    }
                    $RecoveryContext.mode | Should -BeExactly 'resume'
                    $RecoveryContext.threadId | Should -BeExactly $threadId
                    $RecoveryContext.sessionId | Should -BeExactly $sessionId
                    $StdInText | Should -Match 'existing durable thread'
                    return [pscustomobject]@{
                        exitCode = 0; timedOut = $false; errorCode = $null
                        threadId = $threadId; sessionId = $sessionId
                        turnId = '33333333-3333-4333-8333-333333333332'
                        durationMs = 800; machineEventSequenceStart = 5
                        machineEventSequenceEnd = 9; machineEventCount = 4
                        usage = [ordered]@{ input_tokens = 120; output_tokens = 40 }
                        stdout = '{"type":"item.completed","item":{"type":"agent_message","text":"DONE"}}'
                        runtimeIdentity = [ordered]@{
                            model = 'future-model'; model_provider = 'future_provider'
                            cli_version = '0.147.0'
                            permission = [ordered]@{
                                approval_policy='never'; requested_policy='danger-full-access'
                                sandbox_boundary='codex-native'; sandbox_type='dangerFullAccess'
                                permission_profile=':danger-full-access'
                            }
                        }
                    }
                }

                $created = New-AiCliRecoverableRun -ProfileId 'future' `
                    -ProjectPath $Work -TaskText 'ORIGINAL TASK' `
                    -TimeoutMs 5000 -MaxSteps 8 -MaxToolCalls 4
                $result = Invoke-AiCliRecoverableRun -RunId $created.runId `
                    -InitialTaskText 'ORIGINAL TASK'

                $result.status | Should -BeExactly 'completed'
                $result.threadId | Should -BeExactly $threadId
                $result.sessionId | Should -BeExactly $sessionId
                $result.attempts | Should -Be 2
                $result.resumeCount | Should -Be 1
                $result.accounting.activeAttemptMs | Should -Be 2000
                $result.accounting.initialAttemptMs | Should -Be 1200
                $result.accounting.recoveryAttemptMs | Should -Be 800
                $result.accounting.repeatedInputBytes | Should -BeGreaterThan 0
                $result.accounting.repeatedInput.tokens | Should -BeNullOrEmpty
                $result.accounting.repeatedInput.evidence |
                    Should -BeExactly 'client-continuation-bytes-only'
                $result.accounting.providerUsage.input_tokens | Should -Be 120
                $result.accounting.providerUsage.output_tokens | Should -Be 40
                $result.accounting.initialAttemptUsage.input_tokens |
                    Should -Be 100
                $result.accounting.recoveryAttemptUsage.input_tokens |
                    Should -Be 20
                $result.accounting.providerUsageEvidence |
                    Should -BeExactly 'latest-cumulative-thread-snapshot'
                $result.accounting.recoveryAttemptUsageEvidence |
                    Should -BeExactly `
                        'delta-of-monotonic-cumulative-thread-snapshots'
                $result.eventCursor | Should -Be 9
                Should -Invoke Invoke-AiCliProfileCapture -Times 2 -Exactly

                $journal = @(Get-AiCliRecoverableJournal -RunId $created.runId)
                $journal.Count | Should -BeGreaterOrEqual 4
                for ($i = 0; $i -lt $journal.Count; $i++) {
                    $journal[$i].sequence | Should -Be ($i + 1)
                    $journal[$i].recordHash | Should -Match '^[a-f0-9]{64}$'
                    if ($i -eq 0) {
                        $journal[$i].previousHash | Should -Be ('0' * 64)
                    } else {
                        $journal[$i].previousHash |
                            Should -BeExactly $journal[$i - 1].recordHash
                    }
                }
            } finally {
                $script:AiCliDataRootOverride = $null
            }
        }
    }

    It 'fails closed when a resume response changes the thread identity' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:AiCliDataRootOverride = Join-Path $Work 'data'
            $script:captureCalls = 0
            $threadId = '11111111-1111-4111-8111-111111111111'
            $sessionId = '22222222-2222-4222-8222-222222222222'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex'; profileId='future'; profileFingerprint=('c' * 64)
                        workingDirectory=$Work; model='future-model'
                        modelProvider='future_provider'; wire='responses'
                        effort='max'; effectiveEffort='max'
                    }
                }
                Mock Invoke-AiCliProfileCapture {
                    $script:captureCalls++
                    [pscustomobject]@{
                        exitCode = if ($script:captureCalls -eq 1) { 74 } else { 0 }
                        timedOut = $false
                        errorCode = if ($script:captureCalls -eq 1) {
                            'codex_appserver.stream_closed'
                        } else { $null }
                        threadId = if ($script:captureCalls -eq 1) {
                            $threadId
                        } else { '99999999-9999-4999-8999-999999999999' }
                        sessionId = $sessionId
                        turnId = '33333333-3333-4333-8333-333333333331'
                        durationMs = 20
                        machineEventSequenceStart = $script:captureCalls - 1
                        machineEventSequenceEnd = $script:captureCalls
                        machineEventCount = 1; usage = [ordered]@{}
                        runtimeIdentity = [ordered]@{
                            model='future-model'; model_provider='future_provider'
                            cli_version='0.147.0'; permission=[ordered]@{
                                approval_policy='never'; requested_policy='danger-full-access'
                                sandbox_boundary='codex-native'; sandbox_type='dangerFullAccess'
                                permission_profile=':danger-full-access'
                            }
                        }
                    }
                }

                $created = New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $result = Invoke-AiCliRecoverableRun -RunId $created.runId `
                    -InitialTaskText TASK

                $result.status | Should -BeExactly 'failed_closed'
                $result.resumeSupported | Should -BeFalse
                $result.resumeReason | Should -BeExactly 'thread_identity_changed'
                $result.threadId | Should -BeExactly $threadId
                Should -Invoke Invoke-AiCliProfileCapture -Times 2 -Exactly
            } finally {
                $script:AiCliDataRootOverride = $null
            }
        }
    }

    It 'stops after three bounded automatic exact-resume attempts' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            $script:AiCliDataRootOverride=Join-Path $Work 'data'
            $script:captureCalls=0
            $threadId='11111111-1111-4111-8111-111111111111'
            $sessionId='22222222-2222-4222-8222-222222222222'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future'
                        profileFingerprint=('2'*64);workingDirectory=$Work
                        model='future-model';modelProvider='future_provider'
                        wire='responses';effort='max';effectiveEffort='max'
                    }
                }
                Mock Invoke-AiCliProfileCapture {
                    $script:captureCalls++
                    [pscustomobject]@{
                        exitCode=74;timedOut=$false
                        errorCode='codex_appserver.stream_closed'
                        threadId=$threadId;sessionId=$sessionId
                        turnId=('33333333-3333-4333-8333-{0:d12}' -f $script:captureCalls)
                        durationMs=10
                        machineEventSequenceStart=$script:captureCalls-1
                        machineEventSequenceEnd=$script:captureCalls
                        machineEventCount=1;usage=[ordered]@{}
                        runtimeIdentity=[ordered]@{
                            model='future-model';model_provider='future_provider'
                        }
                    }
                }
                $created=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK -MaxResumeAttempts 3
                $result=Invoke-AiCliRecoverableRun $created.runId `
                    -InitialTaskText TASK
                $result.status|Should -BeExactly 'failed_closed'
                $result.resumeSupported|Should -BeFalse
                $result.resumeReason|
                    Should -BeExactly 'automatic_resume_limit_reached'
                $result.attempts|Should -Be 4
                $result.resumeCount|Should -Be 3
                Should -Invoke Invoke-AiCliProfileCapture -Times 4 -Exactly
            } finally {$script:AiCliDataRootOverride=$null}
        }
    }

    It 'persists an abort request that a running child can observe' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:AiCliDataRootOverride = Join-Path $Work 'data'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex'; profileId='future'; profileFingerprint=('d' * 64)
                        workingDirectory=$Work; model='future-model'
                        modelProvider='future_provider'; wire='responses'
                        effort='max'; effectiveEffort='max'
                    }
                }
                $created = New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $aborted = Stop-AiCliRecoverableRun -RunId $created.runId
                $aborted.status | Should -BeExactly 'abort_requested'
                Test-Path -LiteralPath $aborted.abortSignalPath -PathType Leaf |
                    Should -BeTrue
            } finally {
                $script:AiCliDataRootOverride = $null
            }
        }
    }

    It 'rejects tampered state and journal chains' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            $script:AiCliDataRootOverride=Join-Path $Work 'data'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future'
                        profileFingerprint=('9'*64);workingDirectory=$Work
                        model='future-model';modelProvider='future_provider'
                        wire='responses';effort='max';effectiveEffort='max'
                    }
                }
                $stateRun=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $statePath=Join-Path (Get-AiCliRecoverableRunRoot $stateRun.runId) `
                    'state.json'
                $state=Get-Content -LiteralPath $statePath -Raw |
                    ConvertFrom-Json -AsHashtable -Depth 100
                $state.sessionMeta.model='tampered-model'
                [IO.File]::WriteAllText($statePath,
                    ($state|ConvertTo-Json -Depth 100),
                    [Text.UTF8Encoding]::new($false))
                {Get-AiCliRecoverableRunState $stateRun.runId} |
                    Should -Throw '*state hash mismatch*'

                $journalRun=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $journalPath=Join-Path (
                    Get-AiCliRecoverableRunRoot $journalRun.runId
                ) 'journal.jsonl'
                $raw=[IO.File]::ReadAllText($journalPath,[Text.Encoding]::UTF8)
                [IO.File]::WriteAllText($journalPath,
                    $raw.Replace('run.created','run.changed'),
                    [Text.UTF8Encoding]::new($false))
                {Get-AiCliRecoverableJournal $journalRun.runId} |
                    Should -Throw '*journal chain is invalid*'
            } finally {$script:AiCliDataRootOverride=$null}
        }
    }

    It 'keeps abort idempotent and never overwrites an immutable attempt segment' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            $script:AiCliDataRootOverride=Join-Path $Work 'data'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future'
                        profileFingerprint=('8'*64);workingDirectory=$Work
                        model='future-model';modelProvider='future_provider'
                        wire='responses';effort='max';effectiveEffort='max'
                    }
                }
                Mock Invoke-AiCliProfileCapture {throw 'must not launch'}

                $abortRun=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                Stop-AiCliRecoverableRun $abortRun.runId | Out-Null
                Stop-AiCliRecoverableRun $abortRun.runId | Out-Null
                @(
                    Get-AiCliRecoverableJournal $abortRun.runId |
                        Where-Object kind -eq 'abort.requested'
                ).Count | Should -Be 1

                $conflictRun=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $receipt=Join-Path (
                    Get-AiCliRecoverableRunRoot $conflictRun.runId
                ) 'segments\0001.receipt.json'
                [IO.File]::WriteAllText($receipt,'{"foreign":true}',
                    [Text.UTF8Encoding]::new($false))
                $before=(Get-FileHash $receipt -Algorithm SHA256).Hash
                $blocked=Invoke-AiCliRecoverableRun $conflictRun.runId `
                    -InitialTaskText TASK
                $blocked.status | Should -BeExactly 'failed_closed'
                $blocked.resumeReason | Should -BeExactly 'immutable_segment_conflict'
                (Get-FileHash $receipt -Algorithm SHA256).Hash |
                    Should -BeExactly $before
                Should -Invoke Invoke-AiCliProfileCapture -Times 0 -Exactly
            } finally {$script:AiCliDataRootOverride=$null}
        }
    }

    It 'persists a failed-closed segment when capture throws before a verified receipt' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            $script:AiCliDataRootOverride=Join-Path $Work 'data'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future'
                        profileFingerprint=('6'*64);workingDirectory=$Work
                        model='future-model';modelProvider='future_provider'
                        wire='responses';effort='max';effectiveEffort='max'
                    }
                }
                Mock Invoke-AiCliProfileCapture {
                    throw 'PRIVATE_CAPTURE_EXCEPTION_CANARY'
                }
                $created=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $result=Invoke-AiCliRecoverableRun $created.runId `
                    -InitialTaskText TASK
                $result.status | Should -BeExactly 'failed_closed'
                $result.resumeSupported | Should -BeFalse
                $result.resumeReason |
                    Should -BeExactly 'capture_exception_before_verified_receipt'
                $result.receipt.stderr |
                    Should -BeExactly 'Recoverable capture failed before a verified receipt.'
                ($result|ConvertTo-Json -Depth 30 -Compress) |
                    Should -Not -Match 'PRIVATE_CAPTURE_EXCEPTION_CANARY'
                $segment=Join-Path (
                    Get-AiCliRecoverableRunRoot $created.runId
                ) 'segments\0001.receipt.json'
                Test-Path $segment -PathType Leaf | Should -BeTrue
            } finally {$script:AiCliDataRootOverride=$null}
        }
    }
}

Describe 'Codex app-server exact resume protocol' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module AiCliProfileManager -All |
            Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (
            Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1'
        ) -Force
    }

    It 'starts a durable non-ephemeral thread and returns its exact identity' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work=$TestDrive
            RepoRoot=$root
        } {
            $threadId='11111111-1111-4111-8111-111111111111'
            $sessionId='22222222-2222-4222-8222-222222222222'
            $turnId='33333333-3333-4333-8333-333333333331'
            $workspaceHash=Get-AiCliRecoveryHash `
                ([IO.Path]::GetFullPath($Work).ToLowerInvariant())
            $fakeServer=Join-Path $Work 'fake-durable-start-app-server.ps1'
            $bridgeConfig=Join-Path $Work 'durable-start-bridge.json'
            $eventFile=Join-Path $Work 'durable-start-events.jsonl'
            @'
param($ThreadId,$SessionId,$ExpectedCwd,$TurnId)
while($null -ne ($line=[Console]::In.ReadLine())) {
    $m=$line|ConvertFrom-Json -AsHashtable -Depth 100
    switch([string]$m.method) {
        'initialize' {[Console]::Out.WriteLine('{"id":1,"result":{}}')}
        'initialized' {}
        'thread/start' {
            if($m.params.ephemeral -ne $false -or $null -ne $m.params.threadId) {
                [Console]::Out.WriteLine('{"id":2,"error":{"code":-32602,"message":"not durable"}}')
                continue
            }
            [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'DURABLE_START_USED'),'ok')
            $r=@{id=2;result=@{thread=@{id=$ThreadId;sessionId=$SessionId;cliVersion='0.147.0';cwd=$ExpectedCwd;ephemeral=$false;modelProvider='future_provider';turns=@()};model='future-model';modelProvider='future_provider';cwd=$ExpectedCwd;approvalPolicy='never';approvalsReviewer='user';reasoningEffort='max';sandbox=@{type='dangerFullAccess'};activePermissionProfile=@{id=':danger-full-access'};runtimeWorkspaceRoots=@($ExpectedCwd)}}
            [Console]::Out.WriteLine(($r|ConvertTo-Json -Depth 30 -Compress))
        }
        'turn/start' {
            [Console]::Out.WriteLine((@{id=3;result=@{turn=@{id=$TurnId;items=@();status='inProgress'}}}|ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.WriteLine((@{method='turn/started';params=@{threadId=$ThreadId;turn=@{id=$TurnId;items=@();status='inProgress'}}}|ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.WriteLine((@{method='item/started';params=@{threadId=$ThreadId;turnId=$TurnId;item=@{id='message-1';type='agentMessage';text=''}}}|ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.WriteLine((@{method='item/completed';params=@{threadId=$ThreadId;turnId=$TurnId;item=@{id='message-1';type='agentMessage';text='STARTED_OK'}}}|ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.WriteLine((@{method='thread/tokenUsage/updated';params=@{threadId=$ThreadId;turnId=$TurnId;tokenUsage=@{last=@{inputTokens=2;cachedInputTokens=0;outputTokens=1;reasoningOutputTokens=0;totalTokens=3};total=@{inputTokens=2;cachedInputTokens=0;outputTokens=1;reasoningOutputTokens=0;totalTokens=3};modelContextWindow=262144}}}|ConvertTo-Json -Depth 20 -Compress))
            [Console]::Out.WriteLine((@{method='turn/completed';params=@{threadId=$ThreadId;turn=@{id=$TurnId;items=@();status='completed'}}}|ConvertTo-Json -Depth 10 -Compress))
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config=[ordered]@{
                fileName=(Get-Command pwsh.exe).Source
                argumentList=@('-NoProfile','-File',$fakeServer,$threadId,$sessionId,$Work,$turnId)
                workingDirectory=$Work;sandboxBoundary='codex-native'
                sandboxPolicy='danger-full-access';model='future-model'
                expectedModel='future-model';expectedModelProvider='future_provider'
                requireRuntimeIdentity=$true;minimumCliVersion='0.147.0'
                webSearchEnabled=$false;durableSession=$true;runId=('e'*32)
                mode='start';threadId=$null;sessionId=$null
                workspaceHash=$workspaceHash;profileFingerprint=('f'*64)
                requestedEffort='max';effectiveEffort='max'
            }
            [IO.File]::WriteAllText($bridgeConfig,
                ($config|ConvertTo-Json -Depth 30),
                [Text.UTF8Encoding]::new($false))

            $captured=Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',(
                    Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
                ),'-ConfigPath',$bridgeConfig) `
                -WorkingDirectory $Work -StdInText TASK `
                -EventProtocol codex-app-server -MachineEventFile $eventFile `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000 `
                -RequireRuntimeIdentity -ExpectedRuntimeModel future-model `
                -ExpectedRuntimeModelProvider future_provider

            $captured.ExitCode|Should -Be 0
            $captured.ThreadId|Should -BeExactly $threadId
            $captured.SessionId|Should -BeExactly $sessionId
            $captured.RuntimeIdentity.recovery.mode|Should -BeExactly 'start'
            Test-Path (Join-Path $Work 'DURABLE_START_USED')|Should -BeTrue
        }
    }

    It 'classifies a provider quota turn without exposing provider error text' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work=$TestDrive
            RepoRoot=$root
        } {
            $threadId='11111111-1111-4111-8111-111111111111'
            $sessionId='22222222-2222-4222-8222-222222222222'
            $turnId='33333333-3333-4333-8333-333333333331'
            $fakeServer=Join-Path $Work 'fake-quota-app-server.ps1'
            $bridgeConfig=Join-Path $Work 'quota-bridge.json'
            $eventFile=Join-Path $Work 'quota-events.jsonl'
            @'
param($ThreadId,$SessionId,$ExpectedCwd,$TurnId)
while($null -ne ($line=[Console]::In.ReadLine())) {
    $m=$line|ConvertFrom-Json -AsHashtable -Depth 100
    switch([string]$m.method) {
        'initialize' {[Console]::Out.WriteLine('{"id":1,"result":{}}')}
        'initialized' {}
        'thread/start' {
            $r=@{id=2;result=@{thread=@{id=$ThreadId;sessionId=$SessionId;cliVersion='0.147.0';cwd=$ExpectedCwd;ephemeral=$false;modelProvider='future_provider';turns=@()};model='future-model';modelProvider='future_provider';cwd=$ExpectedCwd;approvalPolicy='never';approvalsReviewer='user';reasoningEffort='max';sandbox=@{type='dangerFullAccess'};activePermissionProfile=@{id=':danger-full-access'};runtimeWorkspaceRoots=@($ExpectedCwd)}}
            [Console]::Out.WriteLine(($r|ConvertTo-Json -Depth 30 -Compress))
        }
        'turn/start' {
            [Console]::Out.WriteLine((@{id=3;result=@{turn=@{id=$TurnId;items=@();status='inProgress'}}}|ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.WriteLine((@{method='turn/started';params=@{threadId=$ThreadId;turn=@{id=$TurnId;items=@();status='inProgress'}}}|ConvertTo-Json -Depth 10 -Compress))
            $turnError=@{message='PRIVATE_QUOTA_MESSAGE_CANARY';additionalDetails='PRIVATE_QUOTA_DETAIL_CANARY';codexErrorInfo='usageLimitExceeded'}
            [Console]::Out.WriteLine((@{method='turn/completed';params=@{threadId=$ThreadId;turn=@{id=$TurnId;items=@();status='failed';error=$turnError}}}|ConvertTo-Json -Depth 20 -Compress))
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config=[ordered]@{
                fileName=(Get-Command pwsh.exe).Source
                argumentList=@('-NoProfile','-File',$fakeServer,$threadId,$sessionId,$Work,$turnId)
                workingDirectory=$Work;sandboxBoundary='codex-native'
                sandboxPolicy='danger-full-access';model='future-model'
                expectedModel='future-model';expectedModelProvider='future_provider'
                requireRuntimeIdentity=$true;minimumCliVersion='0.147.0'
                webSearchEnabled=$false;durableSession=$true;runId=('4'*32)
                mode='start';threadId=$null;sessionId=$null
                workspaceHash=Get-AiCliRecoveryHash ([IO.Path]::GetFullPath($Work).ToLowerInvariant())
                profileFingerprint=('3'*64);requestedEffort='max'
                effectiveEffort='max'
            }
            [IO.File]::WriteAllText($bridgeConfig,
                ($config|ConvertTo-Json -Depth 30),
                [Text.UTF8Encoding]::new($false))

            $captured=Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',(
                    Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
                ),'-ConfigPath',$bridgeConfig) `
                -WorkingDirectory $Work -StdInText TASK `
                -EventProtocol codex-app-server -MachineEventFile $eventFile `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000 `
                -RequireRuntimeIdentity -ExpectedRuntimeModel future-model `
                -ExpectedRuntimeModelProvider future_provider

            $captured.ErrorCode |
                Should -BeExactly 'codex_appserver.provider_quota_pause'
            $captured.ExitCode|Should -Be 1
            $all=Get-Content -LiteralPath $eventFile -Raw
            $all|Should -Match 'codex_appserver.provider_quota_pause'
            $all|Should -Not -Match 'PRIVATE_QUOTA_MESSAGE_CANARY'
            $all|Should -Not -Match 'PRIVATE_QUOTA_DETAIL_CANARY'
        }
    }

    It 'uses thread/resume and returns the exact persisted thread/session identity' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $threadId = '11111111-1111-4111-8111-111111111111'
            $sessionId = '22222222-2222-4222-8222-222222222222'
            $turnId = '33333333-3333-4333-8333-333333333331'
            $workspaceHash = Get-AiCliRecoveryHash `
                -Text ([IO.Path]::GetFullPath($Work).ToLowerInvariant())
            $fakeServer = Join-Path $Work 'fake-resume-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'resume-bridge.json'
            $eventFile = Join-Path $Work 'resume-events.jsonl'
            @'
param($ExpectedThreadId, $ExpectedSessionId, $ExpectedCwd, $TurnId)
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' { [Console]::Out.WriteLine('{"id":1,"result":{}}') }
        'initialized' {}
        'thread/start' {
            [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'MUST_NOT_THREAD_START'),'bad')
            [Console]::Out.WriteLine('{"id":2,"error":{"code":-32602,"message":"must resume"}}')
        }
        'thread/resume' {
            if ([string]$message.params.threadId -cne $ExpectedThreadId -or
                [string]$message.params.cwd -cne $ExpectedCwd -or
                [string]$message.params.model -cne 'future-model' -or
                [string]$message.params.modelProvider -cne 'future_provider' -or
                [string]$message.params.permissions -cne ':danger-full-access' -or
                $message.params.excludeTurns -ne $false -or
                $null -ne $message.params.path -or $null -ne $message.params.history) {
                [Console]::Out.WriteLine('{"id":2,"error":{"code":-32602,"message":"bad resume binding"}}')
                continue
            }
            [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'THREAD_RESUME_USED'),'ok')
            $response = [ordered]@{
                id = 2
                result = [ordered]@{
                    thread = [ordered]@{
                        id=$ExpectedThreadId; sessionId=$ExpectedSessionId
                        cliVersion='0.147.0'; cwd=$ExpectedCwd; ephemeral=$false
                        modelProvider='future_provider'; turns=@()
                    }
                    model='future-model'; modelProvider='future_provider'
                    cwd=$ExpectedCwd; approvalPolicy='never'
                    approvalsReviewer='user'; reasoningEffort='max'
                    sandbox=[ordered]@{ type='dangerFullAccess' }
                    activePermissionProfile=[ordered]@{ id=':danger-full-access' }
                    runtimeWorkspaceRoots=@($ExpectedCwd)
                }
            }
            [Console]::Out.WriteLine(($response|ConvertTo-Json -Depth 30 -Compress))
        }
        'turn/start' {
            if ([string]$message.params.threadId -cne $ExpectedThreadId) { exit 91 }
            [Console]::Out.WriteLine((@{id=3;result=@{turn=@{id=$TurnId;items=@();status='inProgress'}}}|ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.WriteLine((@{method='turn/started';params=@{threadId=$ExpectedThreadId;turn=@{id=$TurnId;items=@();status='inProgress'}}}|ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.WriteLine((@{method='item/started';params=@{threadId=$ExpectedThreadId;turnId=$TurnId;item=@{id='message-1';type='agentMessage';text=''}}}|ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.WriteLine((@{method='item/completed';params=@{threadId=$ExpectedThreadId;turnId=$TurnId;item=@{id='message-1';type='agentMessage';text='RESUMED_OK'}}}|ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.WriteLine((@{method='thread/tokenUsage/updated';params=@{threadId=$ExpectedThreadId;turnId=$TurnId;tokenUsage=@{last=@{inputTokens=2;cachedInputTokens=0;outputTokens=1;reasoningOutputTokens=0;totalTokens=3};total=@{inputTokens=2;cachedInputTokens=0;outputTokens=1;reasoningOutputTokens=0;totalTokens=3};modelContextWindow=262144}}}|ConvertTo-Json -Depth 20 -Compress))
            [Console]::Out.WriteLine((@{method='turn/completed';params=@{threadId=$ExpectedThreadId;turn=@{id=$TurnId;items=@();status='completed'}}}|ConvertTo-Json -Depth 10 -Compress))
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName=(Get-Command pwsh.exe).Source
                argumentList=@('-NoProfile','-File',$fakeServer,$threadId,$sessionId,$Work,$turnId)
                workingDirectory=$Work; sandboxBoundary='codex-native'
                sandboxPolicy='danger-full-access'; model='future-model'
                expectedModel='future-model'; expectedModelProvider='future_provider'
                requireRuntimeIdentity=$true; minimumCliVersion='0.147.0'
                webSearchEnabled=$false; durableSession=$true
                runId=('e' * 32); mode='resume'; threadId=$threadId
                sessionId=$sessionId; workspaceHash=$workspaceHash
                profileFingerprint=('f' * 64); requestedEffort='max'
                effectiveEffort='max'
            }
            [IO.File]::WriteAllText($bridgeConfig,
                ($config|ConvertTo-Json -Depth 30),
                [Text.UTF8Encoding]::new($false))

            $captured = Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',(
                    Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
                ),'-ConfigPath',$bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'CONTINUE' `
                -EventProtocol codex-app-server -MachineEventFile $eventFile `
                -MachineEventSequenceBase 10 -MaxSteps 8 -MaxToolCalls 4 `
                -TimeoutMs 5000 -RequireRuntimeIdentity `
                -ExpectedRuntimeModel future-model `
                -ExpectedRuntimeModelProvider future_provider

            $captured.ExitCode | Should -Be 0
            $captured.ThreadId | Should -BeExactly $threadId
            $captured.SessionId | Should -BeExactly $sessionId
            $captured.TurnId | Should -BeExactly $turnId
            $captured.MachineEventSequenceStart | Should -Be 10
            $captured.MachineEventSequenceEnd | Should -BeGreaterThan 10
            $captured.MachineEventCount | Should -Be (
                $captured.MachineEventSequenceEnd - 10
            )
            $captured.RuntimeIdentity.recovery.mode | Should -BeExactly 'resume'
            $captured.RuntimeIdentity.recovery.workspace_hash |
                Should -BeExactly $workspaceHash
            Test-Path -LiteralPath (Join-Path $Work 'THREAD_RESUME_USED') |
                Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Work 'MUST_NOT_THREAD_START') |
                Should -BeFalse
            $events = @(Get-Content -LiteralPath $eventFile | ConvertFrom-Json)
            $events[0].sequence | Should -Be 11
            @($events.sequence) | Should -Be (
                11..(10 + $events.Count)
            )
        }
    }

    It 'fails before turn start when thread/resume returns a different thread' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $threadId = '11111111-1111-4111-8111-111111111111'
            $sessionId = '22222222-2222-4222-8222-222222222222'
            $workspaceHash = Get-AiCliRecoveryHash `
                -Text ([IO.Path]::GetFullPath($Work).ToLowerInvariant())
            $fakeServer = Join-Path $Work 'fake-wrong-resume-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'wrong-resume-bridge.json'
            @'
param($ExpectedSessionId, $ExpectedCwd)
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' { [Console]::Out.WriteLine('{"id":1,"result":{}}') }
        'initialized' {}
        'thread/resume' {
            $wrong = '99999999-9999-4999-8999-999999999999'
            $r=@{id=2;result=@{thread=@{id=$wrong;sessionId=$ExpectedSessionId;cliVersion='0.147.0';cwd=$ExpectedCwd;ephemeral=$false;modelProvider='future_provider';turns=@()};model='future-model';modelProvider='future_provider';cwd=$ExpectedCwd;approvalPolicy='never';approvalsReviewer='user';reasoningEffort='max';sandbox=@{type='dangerFullAccess'};activePermissionProfile=@{id=':danger-full-access'};runtimeWorkspaceRoots=@($ExpectedCwd)}}
            [Console]::Out.WriteLine(($r|ConvertTo-Json -Depth 20 -Compress))
        }
        'turn/start' {
            [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'MUST_NOT_TURN_START'),'bad')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config=[ordered]@{
                fileName=(Get-Command pwsh.exe).Source
                argumentList=@('-NoProfile','-File',$fakeServer,$sessionId,$Work)
                workingDirectory=$Work;sandboxBoundary='codex-native'
                sandboxPolicy='danger-full-access';model='future-model'
                expectedModel='future-model';expectedModelProvider='future_provider'
                requireRuntimeIdentity=$true;minimumCliVersion='0.147.0'
                webSearchEnabled=$false;durableSession=$true;runId=('e'*32)
                mode='resume';threadId=$threadId;sessionId=$sessionId
                workspaceHash=$workspaceHash;profileFingerprint=('f'*64)
                requestedEffort='max';effectiveEffort='max'
            }
            [IO.File]::WriteAllText($bridgeConfig,
                ($config|ConvertTo-Json -Depth 30),
                [Text.UTF8Encoding]::new($false))

            $captured=Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',(
                    Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
                ),'-ConfigPath',$bridgeConfig) `
                -WorkingDirectory $Work -StdInText CONTINUE `
                -EventProtocol codex-app-server -TimeoutMs 5000 `
                -RequireRuntimeIdentity -ExpectedRuntimeModel future-model `
                -ExpectedRuntimeModelProvider future_provider

            $captured.ExitCode | Should -Be 74
            $captured.ErrorCode |
                Should -BeExactly 'codex_appserver.resume_identity_mismatch'
            Test-Path -LiteralPath (Join-Path $Work 'MUST_NOT_TURN_START') |
                Should -BeFalse
        }
    }
}
