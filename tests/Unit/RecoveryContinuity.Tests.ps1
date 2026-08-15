#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Recoverable continuity after process loss or quota pause' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module AiCliProfileManager -All |
            Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (
            Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1'
        ) -Force
    }

    It 'reconciles a dead controller from append-only events and enables exact resume' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:AiCliDataRootOverride = Join-Path $Work 'data'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future';profileFingerprint=('a'*64)
                        workingDirectory=$Work;model='future-model'
                        modelProvider='future_provider';wire='responses'
                        effort='max';effectiveEffort='max'
                    }
                }
                $created=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $state=Get-AiCliRecoverableRunState $created.runId
                $state.status='running'
                $state.turnContext.attempt=1
                $state.controller.pid=2147483000
                $state.controller.processStartUtc='2000-01-01T00:00:00.0000000Z'
                $state.controller.currentSegment='0001'
                Write-AiCliRecoverableRunState $state
                $rootPath=Get-AiCliRecoverableRunRoot $created.runId
                $events=Join-Path $rootPath 'segments\0001.events.jsonl'
                @(
                    [ordered]@{schema='aicli.machine-event.v1';sequence=1;occurred_utc='2026-08-15T00:00:00Z';kind='runtime.identity';model='future-model';provider_id='future_provider';workspace_hash=(Get-AiCliRecoveryHash ([IO.Path]::GetFullPath($Work).ToLowerInvariant()));run_id=$created.runId;profile_fingerprint=('a'*64);requested_effort='max';reasoning_effort='max';resume_mode='start';thread_id='11111111-1111-4111-8111-111111111111';session_id='22222222-2222-4222-8222-222222222222';approval_policy='never';sandbox_policy='danger-full-access';sandbox_boundary='codex-native';sandbox_type='dangerFullAccess';permission_profile=':danger-full-access'},
                    [ordered]@{schema='aicli.machine-event.v1';sequence=2;occurred_utc='2026-08-15T00:00:01Z';kind='thread.started';thread_id='11111111-1111-4111-8111-111111111111';session_id='22222222-2222-4222-8222-222222222222'},
                    [ordered]@{schema='aicli.machine-event.v1';sequence=3;occurred_utc='2026-08-15T00:00:02Z';kind='turn.started';turn_id='33333333-3333-4333-8333-333333333331'}
                ) | ForEach-Object { $_|ConvertTo-Json -Compress } |
                    Set-Content -LiteralPath $events -Encoding utf8

                $status=Get-AiCliRecoverableRunStatus $created.runId
                $status.status | Should -BeExactly 'interrupted'
                $status.resumeSupported | Should -BeTrue
                $status.resumeReason |
                    Should -BeExactly 'process_or_reboot_interruption_exact_resume_ready'
                $status.threadId |
                    Should -BeExactly '11111111-1111-4111-8111-111111111111'
                $status.sessionId |
                    Should -BeExactly '22222222-2222-4222-8222-222222222222'
                $status.lastTurnId |
                    Should -BeExactly '33333333-3333-4333-8333-333333333331'
                $status.eventCursor | Should -Be 3
                $status.accounting.activeAttemptEvidence |
                    Should -BeExactly 'partial-after-controller-loss'
                $status.accounting.wallTimeEvidence |
                    Should -BeExactly 'host-clock-created-to-observed'

                $segmentPath=Join-Path $rootPath `
                    'segments\0001.receipt.json'
                Test-Path -LiteralPath $segmentPath -PathType Leaf |
                    Should -BeTrue
                $segment=Get-Content -LiteralPath $segmentPath -Raw |
                    ConvertFrom-Json
                $segment.schema |
                    Should -BeExactly 'aicli.recoverable-segment.v1'
                $segment.source |
                    Should -BeExactly 'reconciled-after-controller-loss'
                $segment.threadId | Should -BeExactly $status.threadId
                $segment.sessionId | Should -BeExactly $status.sessionId
                $segment.eventSequenceStart | Should -Be 0
                $segment.eventSequenceEnd | Should -Be 3
                $segment.segmentHash | Should -Match '^[a-f0-9]{64}$'
                @(
                    Get-AiCliRecoverableJournal $created.runId |
                        Where-Object {
                            $_.kind -eq 'state.reconciled' -and
                            $_.data.segmentHash -eq $segment.segmentHash
                        }
                ).Count | Should -Be 1

                Add-Content -LiteralPath $events -Value `
                    '{"schema":"aicli.machine-event.v1","sequence":4,"kind":"late.orphan"}' `
                    -Encoding utf8
                $tampered=Get-AiCliRecoverableRunStatus $created.runId
                $tampered.status | Should -BeExactly 'failed_closed'
                $tampered.resumeSupported | Should -BeFalse
                $tampered.resumeReason |
                    Should -BeExactly 'evidence_chain_invalid'
            } finally {
                $script:AiCliDataRootOverride=$null
            }
        }
    }

    It 'keeps rejected interrupted identity evidence chained with its precise reason' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:AiCliDataRootOverride = Join-Path $Work 'data-invalid-identity'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future';profileFingerprint=('9'*64)
                        workingDirectory=$Work;model='future-model'
                        modelProvider='future_provider';wire='responses'
                        effort='max';effectiveEffort='max'
                    }
                }
                $created=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $state=Get-AiCliRecoverableRunState $created.runId
                $state.status='running';$state.turnContext.attempt=1
                $state.controller.pid=2147483000
                $state.controller.processStartUtc='2000-01-01T00:00:00.0000000Z'
                $state.controller.currentSegment='0001'
                Write-AiCliRecoverableRunState $state
                $events=Join-Path (Get-AiCliRecoverableRunRoot $created.runId) `
                    'segments\0001.events.jsonl'
                @(
                    [ordered]@{schema='aicli.machine-event.v1';sequence=1;kind='runtime.identity';model='future-model';provider_id='future_***REDACTED***';workspace_hash=(Get-AiCliRecoveryHash ([IO.Path]::GetFullPath($Work).ToLowerInvariant()));run_id=$created.runId;profile_fingerprint=('9'*64);requested_effort='max';reasoning_effort='max';resume_mode='start';thread_id='11111111-1111-4111-8111-111111111111';session_id='22222222-2222-4222-8222-222222222222';approval_policy='never';sandbox_policy='danger-full-access';sandbox_boundary='codex-native';sandbox_type='dangerFullAccess';permission_profile=':danger-full-access'},
                    [ordered]@{schema='aicli.machine-event.v1';sequence=2;kind='thread.started';thread_id='11111111-1111-4111-8111-111111111111';session_id='22222222-2222-4222-8222-222222222222'}
                ) | ForEach-Object {$_|ConvertTo-Json -Compress} |
                    Set-Content -LiteralPath $events -Encoding utf8

                $status=Get-AiCliRecoverableRunStatus $created.runId
                $status.status | Should -BeExactly 'failed_closed'
                $status.resumeSupported | Should -BeFalse
                $status.resumeReason |
                    Should -BeExactly 'interrupted_runtime_identity_incomplete'
                $status.eventCursor | Should -Be 2
                $closed=Get-AiCliRecoverableRunState $created.runId
                Assert-AiCliRecoverableEvidenceChain $closed | Should -BeTrue
            } finally {$script:AiCliDataRootOverride=$null}
        }
    }

    It 'fails closed on duplicate or late event sequence after reboot' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:AiCliDataRootOverride=Join-Path $Work 'data'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future';profileFingerprint=('b'*64)
                        workingDirectory=$Work;model='future-model'
                        modelProvider='future_provider';wire='responses'
                        effort='max';effectiveEffort='max'
                    }
                }
                $created=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $state=Get-AiCliRecoverableRunState $created.runId
                $state.status='running';$state.turnContext.attempt=1
                $state.controller.pid=2147483000
                $state.controller.processStartUtc='2000-01-01T00:00:00.0000000Z'
                $state.controller.currentSegment='0001'
                Write-AiCliRecoverableRunState $state
                $events=Join-Path (Get-AiCliRecoverableRunRoot $created.runId) `
                    'segments\0001.events.jsonl'
                @(
                    '{"schema":"aicli.machine-event.v1","sequence":1,"kind":"runtime.identity"}',
                    '{"schema":"aicli.machine-event.v1","sequence":1,"kind":"thread.started"}'
                ) | Set-Content -LiteralPath $events -Encoding utf8

                $status=Get-AiCliRecoverableRunStatus $created.runId
                $status.status | Should -BeExactly 'failed_closed'
                $status.resumeSupported | Should -BeFalse
                $status.resumeReason |
                    Should -BeExactly 'event_reconciliation_failed'
            } finally {
                $script:AiCliDataRootOverride=$null
            }
        }
    }

    It 'pauses on quota without burning retries and resumes on the next supervisor call' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:AiCliDataRootOverride=Join-Path $Work 'data'
            $script:captureCalls=0
            $threadId='11111111-1111-4111-8111-111111111111'
            $sessionId='22222222-2222-4222-8222-222222222222'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future';profileFingerprint=('c'*64)
                        workingDirectory=$Work;model='future-model'
                        modelProvider='future_provider';wire='responses'
                        effort='max';effectiveEffort='max'
                    }
                }
                Mock Invoke-AiCliProfileCapture {
                    $script:captureCalls++
                    $eventKind=if($script:captureCalls -le 2){
                        [ordered]@{
                            schema='aicli.machine-event.v1'
                            sequence=$script:captureCalls
                            kind='run.failed';status='failed'
                            error_category='upstream_error'
                            error_code='codex_appserver.provider_quota_pause'
                        }
                    }else{
                        [ordered]@{
                            schema='aicli.machine-event.v1'
                            sequence=$script:captureCalls
                            kind='run.completed';status='completed'
                        }
                    }
                    [IO.File]::WriteAllText(
                        $MachineEventFile,
                        (($eventKind|ConvertTo-Json -Compress)+"`n"),
                        [Text.UTF8Encoding]::new($false)
                    )
                    [pscustomobject]@{
                        exitCode=if($script:captureCalls -le 2){1}else{0}
                        timedOut=$false
                        errorCode=if($script:captureCalls -le 2){
                            'codex_appserver.provider_quota_pause'
                        }else{$null}
                        stderr=if($script:captureCalls -le 2){
                            'PRIVATE_PROVIDER_MESSAGE_MUST_NOT_DRIVE_CLASSIFICATION'
                        }else{''}
                        threadId=$threadId;sessionId=$sessionId
                        turnId=('33333333-3333-4333-8333-' +
                            ('6979df4169{0:d2}' -f $script:captureCalls))
                        durationMs=10
                        machineEventSequenceStart=$script:captureCalls-1
                        machineEventSequenceEnd=$script:captureCalls
                        machineEventCount=1;usage=[ordered]@{}
                        runtimeIdentity=[ordered]@{model='future-model';model_provider='future_provider'}
                    }
                }
                $created=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $paused=Invoke-AiCliRecoverableRun -RunId $created.runId `
                    -InitialTaskText TASK
                $paused.status | Should -BeExactly 'quota_paused'
                $paused.resumeCount | Should -Be 0
                Should -Invoke Invoke-AiCliProfileCapture -Times 1 -Exactly

                $pausedAgain=Invoke-AiCliRecoverableRun -RunId $created.runId
                $pausedAgain.status | Should -BeExactly 'quota_paused'
                $pausedAgain.resumeCount | Should -Be 0
                Should -Invoke Invoke-AiCliProfileCapture -Times 2 -Exactly

                $completed=Invoke-AiCliRecoverableRun -RunId $created.runId
                $completed.status | Should -BeExactly 'completed'
                $completed.resumeCount | Should -Be 1
                $completed.accounting.quotaPauseMs | Should -BeGreaterOrEqual 0
                Should -Invoke Invoke-AiCliProfileCapture -Times 3 -Exactly
            } finally {
                $script:AiCliDataRootOverride=$null
            }
        }
    }

    It 'never retries hard limits, aborts, or structural protocol failures' {
        InModuleScope AiCliProfileManager {
            Test-AiCliRecoverableFailureRetryable ([pscustomobject]@{
                timedOut=$true;limitHit='timeout';abortRequested=$false
                errorCode=$null
            }) | Should -BeFalse
            Test-AiCliRecoverableFailureRetryable ([pscustomobject]@{
                timedOut=$false;limitHit='maxSteps';abortRequested=$false
                errorCode=$null
            }) | Should -BeFalse
            Test-AiCliRecoverableFailureRetryable ([pscustomobject]@{
                timedOut=$false;limitHit=$null;abortRequested=$true
                errorCode=$null
            }) | Should -BeFalse
            foreach ($code in @(
                'codex_appserver.resume_identity_mismatch',
                'codex_appserver.thread_resume_rejected',
                'codex_appserver.notification_scope_invalid',
                'codex_appserver.response_after_turn_unexpected',
                'codex_appserver.cleanup_unconfirmed',
                'codex_appserver.failure_code_invalid'
            )) {
                Test-AiCliRecoverableFailureRetryable ([pscustomobject]@{
                    timedOut=$false;limitHit=$null;abortRequested=$false
                    errorCode=$code
                }) | Should -BeFalse
            }
            foreach ($code in @(
                'codex_appserver.stream_closed',
                'codex_appserver.turn_stream_failed',
                'codex_appserver.item_unfinished',
                'codex_appserver.upstream_transient'
            )) {
                Test-AiCliRecoverableFailureRetryable ([pscustomobject]@{
                    timedOut=$false;limitHit=$null;abortRequested=$false
                    errorCode=$code
                }) | Should -BeTrue
            }
            Test-AiCliRecoverableFailureRetryable ([pscustomobject]@{
                timedOut=$false;limitHit=$null;abortRequested=$false
                errorCode=$null
            }) | Should -BeTrue
            Test-AiCliRecoverableQuotaPause ([pscustomobject]@{
                errorCode='codex_appserver.provider_quota_pause'
                stderr=''
            }) | Should -BeTrue
            Test-AiCliRecoverableQuotaPause ([pscustomobject]@{
                errorCode='codex_appserver.upstream_failure_unclassified'
                stderr='quota rate limit usage limit'
            }) | Should -BeFalse
        }
    }

    It 'uses cumulative usage deltas and rejects a regressing thread counter' {
        InModuleScope AiCliProfileManager {
            $state=[ordered]@{accounting=[ordered]@{
                providerUsage=[ordered]@{}
                initialAttemptUsage=[ordered]@{}
                recoveryAttemptUsage=[ordered]@{}
                threadUsageObserved=[ordered]@{}
            }}
            Update-AiCliRecoveryUsageAccounting -State $state -Usage @{
                input_tokens=100;output_tokens=10;total_tokens=110
            }
            Update-AiCliRecoveryUsageAccounting -State $state -Usage @{
                input_tokens=125;output_tokens=30;total_tokens=155
            } -IsResume
            $state.accounting.providerUsage.input_tokens|Should -Be 125
            $state.accounting.initialAttemptUsage.input_tokens|Should -Be 100
            $state.accounting.recoveryAttemptUsage.input_tokens|Should -Be 25
            {
                Update-AiCliRecoveryUsageAccounting -State $state -Usage @{
                    input_tokens=124
                } -IsResume
            }|Should -Throw '*usage regressed*'
        }
    }

    It 'fails closed instead of resuming a structural run failure after reboot' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            $script:AiCliDataRootOverride=Join-Path $Work 'data'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future'
                        profileFingerprint=('f'*64);workingDirectory=$Work
                        model='future-model';modelProvider='future_provider'
                        wire='responses';effort='max';effectiveEffort='max'
                    }
                }
                $created=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $state=Get-AiCliRecoverableRunState $created.runId
                $state.status='running';$state.turnContext.attempt=1
                $state.controller.pid=2147483000
                $state.controller.processStartUtc='2000-01-01T00:00:00.0000000Z'
                $state.controller.currentSegment='0001'
                Write-AiCliRecoverableRunState $state
                $events=Join-Path (Get-AiCliRecoverableRunRoot $created.runId) `
                    'segments\0001.events.jsonl'
                @(
                    [ordered]@{schema='aicli.machine-event.v1';sequence=1;kind='runtime.identity';model='future-model';provider_id='future_provider';workspace_hash=(Get-AiCliRecoveryHash ([IO.Path]::GetFullPath($Work).ToLowerInvariant()));run_id=$created.runId;profile_fingerprint=('f'*64);requested_effort='max';reasoning_effort='max';resume_mode='start';thread_id='11111111-1111-4111-8111-111111111111';session_id='22222222-2222-4222-8222-222222222222';approval_policy='never';sandbox_policy='danger-full-access';sandbox_boundary='codex-native';sandbox_type='dangerFullAccess';permission_profile=':danger-full-access'},
                    [ordered]@{schema='aicli.machine-event.v1';sequence=2;kind='thread.started';thread_id='11111111-1111-4111-8111-111111111111';session_id='22222222-2222-4222-8222-222222222222'},
                    [ordered]@{schema='aicli.machine-event.v1';sequence=3;kind='run.failed';status='failed';error_category='protocol_or_process_failure';error_code='codex_appserver.notification_scope_invalid'}
                ) | ForEach-Object {$_|ConvertTo-Json -Compress} |
                    Set-Content -LiteralPath $events -Encoding utf8

                $status=Get-AiCliRecoverableRunStatus $created.runId
                $status.status | Should -BeExactly 'failed_closed'
                $status.resumeSupported | Should -BeFalse
                $status.resumeReason | Should -BeExactly 'failure_not_retryable'
            } finally {$script:AiCliDataRootOverride=$null}
        }
    }

    It 'waits for the prior event writer to close before reboot reconciliation' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            $script:AiCliDataRootOverride=Join-Path $Work 'data'
            $writer=$null
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future'
                        profileFingerprint=('7'*64);workingDirectory=$Work
                        model='future-model';modelProvider='future_provider'
                        wire='responses';effort='max';effectiveEffort='max'
                    }
                }
                $created=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $state=Get-AiCliRecoverableRunState $created.runId
                $state.status='running';$state.turnContext.attempt=1
                $state.controller.pid=2147483000
                $state.controller.processStartUtc='2000-01-01T00:00:00.0000000Z'
                $state.controller.currentSegment='0001'
                Write-AiCliRecoverableRunState $state
                $events=Join-Path (Get-AiCliRecoverableRunRoot $created.runId) `
                    'segments\0001.events.jsonl'
                [IO.File]::WriteAllBytes($events,[byte[]]::new(0))
                $writer=[IO.FileStream]::new($events,[IO.FileMode]::Open,
                    [IO.FileAccess]::Write,[IO.FileShare]::Read)

                $pending=Get-AiCliRecoverableRunStatus $created.runId
                $pending.status | Should -BeExactly 'reconciliation_pending'
                $pending.resumeSupported | Should -BeFalse
                $pending.resumeReason | Should -BeExactly 'event_writer_still_active'
            } finally {
                if($writer){$writer.Dispose()}
                $script:AiCliDataRootOverride=$null
            }
        }
    }


    It 'honors an abort signal before classifying a reconciled process failure' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            $script:AiCliDataRootOverride=Join-Path $Work 'data'
            try {
                Mock Build-AiCliLaunchPlan {
                    [pscustomobject]@{
                        engine='codex';profileId='future'
                        profileFingerprint=('5'*64);workingDirectory=$Work
                        model='future-model';modelProvider='future_provider'
                        wire='responses';effort='max';effectiveEffort='max'
                    }
                }
                $created=New-AiCliRecoverableRun -ProfileId future `
                    -ProjectPath $Work -TaskText TASK
                $state=Get-AiCliRecoverableRunState $created.runId
                $state.status='running';$state.turnContext.attempt=1
                $state.controller.pid=2147483000
                $state.controller.processStartUtc='2000-01-01T00:00:00Z'
                $state.controller.currentSegment='0001'
                Write-AiCliRecoverableRunState $state
                $rootPath=Get-AiCliRecoverableRunRoot $created.runId
                [IO.File]::WriteAllBytes(
                    (Join-Path $rootPath 'abort.requested'),
                    [byte[]]::new(0)
                )
                $events=Join-Path $rootPath 'segments\0001.events.jsonl'
                @(
                    [ordered]@{schema='aicli.machine-event.v1';sequence=1;kind='runtime.identity';model='future-model';provider_id='future_provider';workspace_hash=(Get-AiCliRecoveryHash ([IO.Path]::GetFullPath($Work).ToLowerInvariant()));run_id=$created.runId;profile_fingerprint=('5'*64);requested_effort='max';reasoning_effort='max';resume_mode='start';thread_id='11111111-1111-4111-8111-111111111111';session_id='22222222-2222-4222-8222-222222222222';approval_policy='never';sandbox_policy='danger-full-access';sandbox_boundary='codex-native';sandbox_type='dangerFullAccess';permission_profile=':danger-full-access'},
                    [ordered]@{schema='aicli.machine-event.v1';sequence=2;kind='thread.started';thread_id='11111111-1111-4111-8111-111111111111';session_id='22222222-2222-4222-8222-222222222222'},
                    [ordered]@{schema='aicli.machine-event.v1';sequence=3;kind='run.failed';status='failed';error_category='protocol_or_process_failure';error_code='codex_appserver.stream_closed'}
                ) | ForEach-Object {$_|ConvertTo-Json -Compress} |
                    Set-Content -LiteralPath $events -Encoding utf8

                $status=Get-AiCliRecoverableRunStatus $created.runId
                $status.status | Should -BeExactly 'aborted'
                $status.resumeSupported | Should -BeFalse
                $status.resumeReason | Should -BeExactly 'aborted_by_request'
            } finally {$script:AiCliDataRootOverride=$null}
        }
    }
}

Describe 'Recoverable machine-event mirror' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module AiCliProfileManager -All |
            Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (
            Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1'
        ) -Force
    }

    It 'tees identical append-only bytes and accepts only the matching cursor' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            $primary=Join-Path $Work 'primary.jsonl'
            $mirror=Join-Path $Work 'mirror.jsonl'
            [IO.File]::WriteAllBytes($primary,[byte[]]::new(0))
            [IO.File]::WriteAllBytes($mirror,[byte[]]::new(0))
            $p=[IO.FileStream]::new($primary,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            $m=[IO.FileStream]::new($mirror,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            try {
                $sequence=0
                Write-AiCliMachineEvent -Stream ([pscustomobject]@{Primary=$p;Mirror=$m}) `
                    -Sequence ([ref]$sequence) -Kind 'thread.started' `
                    -Data @{thread_id='11111111-1111-4111-8111-111111111111'} |
                    Should -BeTrue
                $sequence | Should -Be 1
            } finally {$m.Dispose();$p.Dispose()}
            [IO.File]::ReadAllBytes($primary) |
                Should -Be ([IO.File]::ReadAllBytes($mirror))
            Resolve-AiCliMachineEventMirrorFile -Path $mirror `
                -ExpectedSequence 1 | Should -Be ([IO.Path]::GetFullPath($mirror))
            {Resolve-AiCliMachineEventMirrorFile -Path $mirror -ExpectedSequence 0} |
                Should -Throw '*cursor*'
        }
    }

    It 'keeps the authoritative sequence valid when only the consumer mirror fails' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            $primary=Join-Path $Work 'authoritative.jsonl'
            [IO.File]::WriteAllBytes($primary,[byte[]]::new(0))
            $p=[IO.FileStream]::new(
                $primary,[IO.FileMode]::Open,[IO.FileAccess]::Write,
                [IO.FileShare]::Read
            )
            $brokenPath=Join-Path $Work 'broken-mirror.jsonl'
            $broken=[IO.FileStream]::new(
                $brokenPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,
                [IO.FileShare]::Read
            )
            $broken.Dispose()
            try {
                $sequence=0
                Write-AiCliMachineEvent -Stream ([pscustomobject]@{
                    Primary=$p;Mirror=$broken
                }) -Sequence ([ref]$sequence) -Kind 'thread.started' `
                    -Data @{thread_id='11111111-1111-4111-8111-111111111111'} |
                    Should -BeFalse
                $sequence | Should -Be 1
                Write-AiCliMachineEvent -Stream $p -Sequence ([ref]$sequence) `
                    -Kind 'run.completed' -Data @{status='completed'} |
                    Should -BeTrue
                $sequence | Should -Be 2
            } finally {$p.Dispose()}
            $lines=@([IO.File]::ReadAllLines($primary) |
                Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
            $lines.Count | Should -Be 2
            ($lines[0]|ConvertFrom-Json).sequence | Should -Be 1
            ($lines[1]|ConvertFrom-Json).sequence | Should -Be 2
        }
    }
}

Describe 'Durable Codex machine runtime' {
    BeforeAll {
        $root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module AiCliProfileManager -All|Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
    }

    It 'keeps the bound CODEX_HOME while removing only the transient bridge runtime' {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive} {
            $script:AiCliDataRootOverride=Join-Path $Work 'data'
            try {
                $package=Join-Path $Work 'tool\node_modules\@openai\codex'
                $entry=Join-Path $package 'bin\codex.js'
                $native=Join-Path $package 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
                New-Item -ItemType Directory -Path (Split-Path -Parent $entry),(Split-Path -Parent $native) -Force|Out-Null
                Set-Content -LiteralPath $entry -Value '// stub' -Encoding ascii
                Set-Content -LiteralPath $native -Value 'stub' -Encoding ascii
                Set-Content -LiteralPath (Join-Path $package 'package.json') -Value '{}' -Encoding ascii
                $runId='d'*32
                $runRoot=Get-AiCliRecoverableRunRoot $runId
                New-Item -ItemType Directory -Path (Join-Path $runRoot 'codex-home') -Force|Out-Null
                $workspace=[IO.Path]::GetFullPath($Work)
                $plan=[pscustomobject]@{
                    engine='codex';fileName=(Get-Command node.exe).Source
                    argumentList=@($entry,'exec','--json','-')
                    workingDirectory=$workspace;environmentDelta=@{}
                    model='future-model';modelProvider='future_provider'
                    machineRuntime=[ordered]@{kind='codex';configFiles=@();sandboxBoundary='codex-native'}
                }
                $context=[ordered]@{
                    runId=$runId;mode='start';threadId=$null;sessionId=$null
                    workspace=$workspace
                    workspaceHash=Get-AiCliRecoveryHash $workspace.ToLowerInvariant()
                    profileFingerprint=('e'*64);model='future-model'
                    modelProvider='future_provider';requestedEffort='max'
                    effectiveEffort='max'
                    durableCodexHome=Join-Path $runRoot 'codex-home'
                    eventSequenceBase=0;abortSignalPath=Join-Path $runRoot 'abort.requested'
                }
                $runtime=Initialize-AiCliMachineRuntime -Plan $plan `
                    -StdInText TASK -Policy danger-full-access `
                    -RecoveryContext $context
                $transient=$runtime.RuntimePath
                $durable=[IO.Path]::GetFullPath($context.durableCodexHome)
                try {
                    $runtime.DurableSession|Should -BeTrue
                    $runtime.CodexHome|Should -BeExactly $durable
                    $runtime.EnvironmentDelta.CODEX_HOME|Should -BeExactly $durable
                    $bridge=Get-Content -LiteralPath $runtime.ArgumentList[-1] -Raw|ConvertFrom-Json
                    $bridge.durableSession|Should -BeTrue
                    $bridge.mode|Should -BeExactly 'start'
                    $bridge.runId|Should -BeExactly $runId
                    $bridge.workspaceHash|Should -BeExactly $context.workspaceHash
                    $bridge.profileFingerprint|Should -BeExactly ('e'*64)
                    $bridge.effectiveEffort|Should -BeExactly 'max'
                } finally {
                    Remove-AiCliMachineRuntime -RuntimePath $transient -Workspace $workspace
                }
                Test-Path -LiteralPath $transient|Should -BeFalse
                Test-Path -LiteralPath $durable -PathType Container|Should -BeTrue
            } finally {$script:AiCliDataRootOverride=$null}
        }
    }
}
