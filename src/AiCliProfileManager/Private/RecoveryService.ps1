# Durable, identity-bound recovery for Codex app-server machine runs.

function Get-AiCliRecoveryHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
}

function Assert-AiCliRecoverableRunId {
    param([Parameter(Mandatory)][string]$RunId)
    if ($RunId -notmatch '\A[a-f0-9]{32}\z') {
        throw 'Recoverable run id is invalid.'
    }
    return $RunId
}

function Assert-AiCliRecoveryPathChain {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$LeafMayBeFile
    )
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Recoverable state path contains a reparse point: $cursor"
            }
            if (-not $item.PSIsContainer -and
                (-not $LeafMayBeFile -or $cursor -cne $full)) {
                throw "Recoverable state ancestor is not a directory: $cursor"
            }
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) {
            break
        }
        $cursor = $parent
    }
    return $full
}

function Get-AiCliRecoveryStoreRoot {
    $paths = Get-AiCliAppPaths
    foreach ($directory in @($paths.StateDir, $paths.LocksDir)) {
        $full = Assert-AiCliRecoveryPathChain -Path $directory
        if (-not (Test-Path -LiteralPath $full)) {
            New-Item -ItemType Directory -Path $full -Force | Out-Null
        }
        $null = Assert-AiCliRecoveryPathChain -Path $full
    }
    $root = Join-Path $paths.StateDir 'recoverable-runs'
    $null = Assert-AiCliRecoveryPathChain -Path $root
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    $null = Assert-AiCliRecoveryPathChain -Path $root
    return [IO.Path]::GetFullPath($root)
}

function Get-AiCliRecoverableRunRoot {
    param([Parameter(Mandatory)][string]$RunId)
    $safeId = Assert-AiCliRecoverableRunId -RunId $RunId
    $root = Join-Path (Get-AiCliRecoveryStoreRoot) $safeId
    $null = Assert-AiCliRecoveryPathChain -Path $root
    return $root
}

function Get-AiCliRecoverableStateHash {
    param([Parameter(Mandatory)]$State)
    $copy = ($State | ConvertTo-Json -Depth 100 -Compress) |
        ConvertFrom-Json -AsHashtable -Depth 100
    [void]$copy.Remove('stateHash')
    return (Get-AiCliRecoveryHash -Text (
        $copy | ConvertTo-Json -Depth 100 -Compress
    ))
}

function Test-AiCliRecoverableRunState {
    param([Parameter(Mandatory)]$State)
    try {
        if ([string](Get-AiCliProperty $State 'schema') -cne
                'aicli.recoverable-run.v1' -or
            [string](Get-AiCliProperty $State 'runId') -notmatch
                '\A[a-f0-9]{32}\z' -or
            [string](Get-AiCliProperty $State 'stateHash') -notmatch
                '\A[a-f0-9]{64}\z') {
            return $false
        }
        return [string](Get-AiCliProperty $State 'stateHash') -ceq
            (Get-AiCliRecoverableStateHash -State $State)
    } catch {
        return $false
    }
}

function Write-AiCliRecoverableRunState {
    param([Parameter(Mandatory)]$State)
    $runId = Assert-AiCliRecoverableRunId -RunId ([string]$State.runId)
    $root = Get-AiCliRecoverableRunRoot -RunId $runId
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    $null = Assert-AiCliRecoveryPathChain -Path $root
    $State.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $State.stateHash = Get-AiCliRecoverableStateHash -State $State
    Write-AiCliJsonFile -Path (Join-Path $root 'state.json') -Value $State
}

function Get-AiCliRecoverableRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId)
    $root = Get-AiCliRecoverableRunRoot -RunId $RunId
    $path = Join-Path $root 'state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Recoverable run does not exist: $RunId"
    }
    $null = Assert-AiCliRecoveryPathChain -Path $path -LeafMayBeFile
    $state = Read-AiCliJsonFile -Path $path
    if (-not (Test-AiCliRecoverableRunState -State $state)) {
        throw "Recoverable run state hash mismatch: $RunId"
    }
    return $state
}

function Get-AiCliRecoverableJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId)
    $path = Join-Path (Get-AiCliRecoverableRunRoot -RunId $RunId) 'journal.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $null = Assert-AiCliRecoveryPathChain -Path $path -LeafMayBeFile
    $records = [Collections.Generic.List[object]]::new()
    $previousHash = '0' * 64
    $expectedSequence = 1
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $record = $line | ConvertFrom-Json -AsHashtable -Depth 100
        $actualHash = [string](Get-AiCliProperty $record 'recordHash')
        $hashSource = [ordered]@{
            schema = [string](Get-AiCliProperty $record 'schema')
            sequence = [long](Get-AiCliProperty $record 'sequence')
            occurredUnixMs = [long](Get-AiCliProperty $record 'occurredUnixMs')
            kind = [string](Get-AiCliProperty $record 'kind')
            previousHash = [string](Get-AiCliProperty $record 'previousHash')
            data = Get-AiCliProperty $record 'data'
        }
        $computedHash = Get-AiCliRecoveryHash -Text (
            $hashSource | ConvertTo-Json -Depth 100 -Compress
        )
        if ([int](Get-AiCliProperty $record 'sequence') -ne $expectedSequence -or
            [string](Get-AiCliProperty $record 'previousHash') -cne $previousHash -or
            $actualHash -cne $computedHash) {
            throw "Recoverable journal chain is invalid: $RunId"
        }
        $records.Add([pscustomobject]$record) | Out-Null
        $previousHash = $actualHash
        $expectedSequence++
    }
    return @($records)
}

function Add-AiCliRecoverableJournalRecord {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Kind,
        [hashtable]$Data = @{}
    )
    $root = Get-AiCliRecoverableRunRoot -RunId $RunId
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    $null = Assert-AiCliRecoveryPathChain -Path $root
    $path = Join-Path $root 'journal.jsonl'
    $lock = Enter-AiCliFileLock -TargetPath $path
    try {
        $existing = @(Get-AiCliRecoverableJournal -RunId $RunId)
        $sequence = $existing.Count + 1
        $previousHash = if ($existing.Count -eq 0) {
            '0' * 64
        } else {
            [string]$existing[-1].recordHash
        }
        $record = [ordered]@{
            schema = 'aicli.recoverable-journal.v1'
            sequence = $sequence
            occurredUnixMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            kind = $Kind
            previousHash = $previousHash
            data = [ordered]@{}
        }
        foreach ($key in @($Data.Keys | Sort-Object)) {
            $record.data[[string]$key] = $Data[$key]
        }
        $record['recordHash'] = Get-AiCliRecoveryHash -Text (
            $record | ConvertTo-Json -Depth 100 -Compress
        )
        $json = $record | ConvertTo-Json -Depth 100 -Compress
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
        $stream = [IO.FileStream]::new(
            $path,
            [IO.FileMode]::Append,
            [IO.FileAccess]::Write,
            [IO.FileShare]::Read
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        return [pscustomobject]$record
    } finally {
        Exit-AiCliFileLock -Lock $lock
    }
}

function Get-AiCliRecoverableSegmentHash {
    param([Parameter(Mandatory)]$Receipt)
    $copy = ($Receipt | ConvertTo-Json -Depth 100 -Compress) |
        ConvertFrom-Json -AsHashtable -Depth 100
    [void]$copy.Remove('segmentHash')
    return (Get-AiCliRecoveryHash -Text (
        $copy | ConvertTo-Json -Depth 100 -Compress
    ))
}

function Read-AiCliRecoverableSegmentReceipt {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$SegmentName
    )
    if ($SegmentName -notmatch '\A[0-9]{4}\z') {
        throw 'Recoverable segment name is invalid.'
    }
    $attempt = [int]$SegmentName
    if ($attempt -lt 1) {
        throw 'Recoverable segment attempt is invalid.'
    }
    $segmentRoot = Join-Path (
        Get-AiCliRecoverableRunRoot -RunId ([string]$State.runId)
    ) 'segments'
    $receiptPath = Join-Path $segmentRoot "$SegmentName.receipt.json"
    $eventPath = Join-Path $segmentRoot "$SegmentName.events.jsonl"
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $eventPath -PathType Leaf)) {
        throw 'Recoverable segment evidence is incomplete.'
    }
    $null = Assert-AiCliRecoveryPathChain -Path $receiptPath -LeafMayBeFile
    $null = Assert-AiCliRecoveryPathChain -Path $eventPath -LeafMayBeFile
    $receipt = Read-AiCliJsonFile -Path $receiptPath
    $actualSegmentHash = [string](Get-AiCliProperty $receipt 'segmentHash')
    $eventHash = (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).
        Hash.ToLowerInvariant()
    if ([string](Get-AiCliProperty $receipt 'schema') -cne
            'aicli.recoverable-segment.v1' -or
        [string](Get-AiCliProperty $receipt 'runId') -cne
            [string]$State.runId -or
        [int](Get-AiCliProperty $receipt 'attempt') -ne $attempt -or
        [string](Get-AiCliProperty $receipt 'profileFingerprint') -cne
            [string]$State.sessionMeta.profileFingerprint -or
        [string](Get-AiCliProperty $receipt 'workspaceHash') -cne
            [string]$State.sessionMeta.workspaceHash -or
        [string](Get-AiCliProperty $receipt 'model') -cne
            [string]$State.sessionMeta.model -or
        [string](Get-AiCliProperty $receipt 'modelProvider') -cne
            [string]$State.sessionMeta.modelProvider -or
        [string](Get-AiCliProperty $receipt 'requestedEffort') -cne
            [string]$State.sessionMeta.requestedEffort -or
        [string](Get-AiCliProperty $receipt 'effectiveEffort') -cne
            [string]$State.sessionMeta.effectiveEffort -or
        [string](Get-AiCliProperty $receipt 'eventFileSha256') -cne
            $eventHash -or
        $actualSegmentHash -notmatch '\A[a-f0-9]{64}\z' -or
        $actualSegmentHash -cne
            (Get-AiCliRecoverableSegmentHash -Receipt $receipt)) {
        throw 'Recoverable segment identity or hash is invalid.'
    }
    $start = [long](Get-AiCliProperty $receipt 'eventSequenceStart' -1)
    $end = [long](Get-AiCliProperty $receipt 'eventSequenceEnd' -1)
    if ($start -lt 0 -or $end -lt $start) {
        throw 'Recoverable segment event cursor is invalid.'
    }
    $expectedEventSequence = $start + 1
    foreach ($line in [IO.File]::ReadAllLines(
        $eventPath,
        [Text.Encoding]::UTF8
    )) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $line | ConvertFrom-Json -AsHashtable -Depth 100
        if ([string](Get-AiCliProperty $event 'schema') -cne
                'aicli.machine-event.v1' -or
            [long](Get-AiCliProperty $event 'sequence' -1) -ne
                $expectedEventSequence) {
            throw 'Recoverable segment event sequence is invalid.'
        }
        $expectedEventSequence++
    }
    if (($expectedEventSequence - 1) -ne $end) {
        throw 'Recoverable segment receipt does not match its event count.'
    }
    return $receipt
}

function Assert-AiCliRecoverableEvidenceChain {
    param([Parameter(Mandatory)]$State)
    $journal = @(Get-AiCliRecoverableJournal -RunId ([string]$State.runId))
    if ($journal.Count -lt 1 -or $journal[0].kind -cne 'run.created') {
        throw 'Recoverable evidence journal has no creation record.'
    }
    $referenced = [ordered]@{}
    $cursor = [long]0
    $lastReceipt = $null
    foreach ($record in $journal) {
        if ($record.kind -notin @('attempt.completed','state.reconciled')) {
            continue
        }
        $segmentName = if ($record.kind -eq 'state.reconciled') {
            [string](Get-AiCliProperty $record.data 'segment')
        } else {
            '{0:d4}' -f [int](Get-AiCliProperty $record.data 'attempt')
        }
        if ($referenced.Contains($segmentName)) {
            throw 'Recoverable segment is referenced more than once.'
        }
        $receipt = Read-AiCliRecoverableSegmentReceipt `
            -State $State -SegmentName $segmentName
        if ([string](Get-AiCliProperty $record.data 'segmentHash') -cne
                [string]$receipt.segmentHash -or
            [long]$receipt.eventSequenceStart -ne $cursor) {
            throw 'Recoverable journal and segment chain do not match.'
        }
        $cursor = [long]$receipt.eventSequenceEnd
        $referenced[$segmentName] = $true
        $lastReceipt = $receipt
    }
    $controllerAlive = Test-AiCliRecoverableControllerAlive -State $State
    if (-not $controllerAlive -and $State.status -ne 'pending') {
        $segmentRoot = Join-Path (
            Get-AiCliRecoverableRunRoot -RunId ([string]$State.runId)
        ) 'segments'
        $receiptFiles = @(
            Get-ChildItem -LiteralPath $segmentRoot -File -Filter `
                '*.receipt.json' -ErrorAction Stop
        )
        foreach ($file in $receiptFiles) {
            $segmentName = $file.Name.Substring(
                0,
                $file.Name.Length - '.receipt.json'.Length
            )
            if (-not $referenced.Contains($segmentName)) {
                throw 'Recoverable segment receipt is orphaned.'
            }
        }
        if ($cursor -ne [long]$State.turnContext.eventCursor) {
            throw 'Recoverable state cursor does not match segment evidence.'
        }
        if ($lastReceipt) {
            if ($null -eq $State.lastReceipt -or
                [string]$State.lastReceipt.segmentHash -cne
                    [string]$lastReceipt.segmentHash -or
                [int]$State.lastReceipt.attempt -ne
                    [int]$lastReceipt.attempt) {
                throw 'Recoverable state receipt pointer is invalid.'
            }
        }
    }
    return $true
}

function Set-AiCliRecoverableEvidenceFailure {
    param([Parameter(Mandatory)]$State)
    $State.status = 'failed_closed'
    $State.resume.supported = $false
    $State.resume.reason = 'evidence_chain_invalid'
    $State.controller.pid = 0
    $State.controller.processStartUtc = $null
    $State.controller.currentSegment = $null
    Write-AiCliRecoverableRunState -State $State
    return $State
}

function Update-AiCliRecoveryUsageAccounting {
    param(
        [Parameter(Mandatory)]$State,
        [object]$Usage,
        [switch]$IsResume
    )
    if (-not $State.accounting.Contains('threadUsageObserved')) {
        $State.accounting['threadUsageObserved'] = [ordered]@{}
    }
    $observed = $State.accounting.threadUsageObserved
    $attemptTarget = if ($IsResume) {
        $State.accounting.recoveryAttemptUsage
    } else {
        $State.accounting.initialAttemptUsage
    }
    foreach ($name in @(
        'input_tokens','cached_input_tokens','output_tokens',
        'reasoning_output_tokens','total_tokens'
    )) {
        $value = Get-AiCliProperty $Usage $name
        if ($null -eq $value) { continue }
        try { $number = [long]$value } catch { continue }
        if ($number -lt 0) { continue }
        $prior = [long](Get-AiCliProperty $observed $name 0)
        if ($number -lt $prior) {
            throw "Recoverable cumulative usage regressed: $name"
        }
        $delta = $number - $prior
        $State.accounting.providerUsage[$name] = $number
        $observed[$name] = $number
        if ($IsResume) {
            $attemptTarget[$name] = [long](
                Get-AiCliProperty $attemptTarget $name 0
            ) + $delta
        } else {
            $attemptTarget[$name] = $number
        }
    }
}

function New-AiCliRecoverableRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$TaskText,
        [int]$TimeoutMs = 120000,
        [int]$MaxCaptureChars = 1000000,
        [int]$MaxSteps = 20,
        [int]$MaxToolCalls = 80,
        [switch]$WatchdogOnly,
        [switch]$DisableWebSearch,
        [switch]$AuthorityPreludeStdout,
        [int]$MaxResumeAttempts = 3,
        [string]$ConsumerEventFile = ''
    )
    if ([string]::IsNullOrWhiteSpace($TaskText)) {
        throw 'Recoverable run requires a non-empty task.'
    }
    if ($MaxResumeAttempts -lt 0 -or $MaxResumeAttempts -gt 3) {
        throw 'MaxResumeAttempts must be between 0 and 3.'
    }
    $workspace = [IO.Path]::GetFullPath($ProjectPath)
    if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
        throw "Recoverable run workspace does not exist: $workspace"
    }
    $resolvedConsumerEventFile = if (-not [string]::IsNullOrWhiteSpace(
        $ConsumerEventFile
    )) {
        Resolve-AiCliMachineEventMirrorFile -Path $ConsumerEventFile `
            -ExpectedSequence 0
    } else { $null }
    if ($resolvedConsumerEventFile -and
        (Test-AiCliPathWithinRoot -Path $resolvedConsumerEventFile `
            -Root $workspace)) {
        throw 'Recoverable consumer event file must be outside the model workspace.'
    }
    $plan = Build-AiCliLaunchPlan -ProfileId $ProfileId `
        -ProjectPath $workspace -NativeArgs @() -MachineRun
    if ([string](Get-AiCliProperty $plan 'engine') -cne 'codex') {
        throw 'Exact durable resume is supported only by the Codex app-server harness.'
    }
    $runId = [guid]::NewGuid().ToString('N')
    $root = Get-AiCliRecoverableRunRoot -RunId $runId
    New-Item -ItemType Directory -Path (Join-Path $root 'segments') -Force |
        Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'codex-home') -Force |
        Out-Null
    $null = Assert-AiCliRecoveryPathChain -Path (Join-Path $root 'segments')
    $null = Assert-AiCliRecoveryPathChain -Path (Join-Path $root 'codex-home')
    if (-not [bool](Get-AiCliProperty (Get-AiCliAppPaths) 'IsTestRoot' $false)) {
        Set-AiCliSecretAcl -Path $root
    }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $state = [ordered]@{
        schema = 'aicli.recoverable-run.v1'
        runId = $runId
        productVersion = Get-AiCliVersion
        status = 'pending'
        createdUtc = $now
        updatedUtc = $now
        sessionMeta = [ordered]@{
            workspace = $workspace
            workspaceHash = Get-AiCliRecoveryHash -Text $workspace.ToLowerInvariant()
            profileId = $ProfileId
            profileFingerprint = [string](Get-AiCliProperty $plan 'profileFingerprint')
            engine = 'codex'
            model = [string](Get-AiCliProperty $plan 'model')
            modelProvider = [string](Get-AiCliProperty $plan 'modelProvider')
            wire = [string](Get-AiCliProperty $plan 'wire')
            requestedEffort = [string](Get-AiCliProperty $plan 'effort')
            effectiveEffort = [string](Get-AiCliProperty $plan 'effectiveEffort')
            protocol = 'codex-app-server'
            threadId = $null
            sessionId = $null
        }
        turnContext = [ordered]@{
            lastTurnId = $null
            attempt = 0
            eventCursor = 0
        }
        resume = [ordered]@{
            supported = $false
            reason = 'thread_not_started'
            count = 0
            maxAttempts = $MaxResumeAttempts
        }
        controller = [ordered]@{
            pid = 0
            processStartUtc = $null
            abortRequested = $false
            currentSegment = $null
        }
        config = [ordered]@{
            timeoutMs = $TimeoutMs
            maxCaptureChars = $MaxCaptureChars
            maxSteps = $MaxSteps
            maxToolCalls = $MaxToolCalls
            watchdogOnly = [bool]$WatchdogOnly
            disableWebSearch = [bool]$DisableWebSearch
            authorityPreludeStdout = [bool]$AuthorityPreludeStdout
            consumerEventFile = $resolvedConsumerEventFile
        }
        accounting = [ordered]@{
            activeAttemptMs = [long]0
            activeAttemptEvidence = 'verified-segment-receipt-duration'
            initialAttemptMs = [long]0
            recoveryAttemptMs = [long]0
            quotaPauseMs = [long]0
            quotaPauseStartedUtc = $null
            repeatedInputBytes = [long]0
            providerUsage = [ordered]@{}
            initialAttemptUsage = [ordered]@{}
            recoveryAttemptUsage = [ordered]@{}
            threadUsageObserved = [ordered]@{}
            cost = [ordered]@{
                value = $null
                currency = $null
                evidence = 'unavailable'
            }
        }
        lastReceipt = $null
        stateHash = $null
    }
    Write-AiCliRecoverableRunState -State $state
    Add-AiCliRecoverableJournalRecord -RunId $runId -Kind 'run.created' -Data @{
        workspaceHash = $state.sessionMeta.workspaceHash
        profileFingerprint = $state.sessionMeta.profileFingerprint
        model = $state.sessionMeta.model
        modelProvider = $state.sessionMeta.modelProvider
        requestedEffort = $state.sessionMeta.requestedEffort
        effectiveEffort = $state.sessionMeta.effectiveEffort
    } | Out-Null
    return [pscustomobject]@{
        runId = $runId
        status = 'pending'
        resumeSupported = $false
        resumeReason = 'thread_not_started'
    }
}

function Test-AiCliRecoverableReceiptIdentity {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Receipt)
    $runtime = Get-AiCliProperty $Receipt 'runtimeIdentity'
    return (
        [string](Get-AiCliProperty $Receipt 'threadId') -ceq
            [string]$State.sessionMeta.threadId -and
        [string](Get-AiCliProperty $Receipt 'sessionId') -ceq
            [string]$State.sessionMeta.sessionId -and
        [string](Get-AiCliProperty $runtime 'model') -ceq
            [string]$State.sessionMeta.model -and
        [string](Get-AiCliProperty $runtime 'model_provider') -ceq
            [string]$State.sessionMeta.modelProvider
    )
}

function Test-AiCliRecoverableFailureRetryable {
    param([Parameter(Mandatory)]$Receipt)
    if ([bool](Get-AiCliProperty $Receipt 'timedOut' $false) -or
        [bool](Get-AiCliProperty $Receipt 'abortRequested' $false) -or
        -not [string]::IsNullOrWhiteSpace(
            [string](Get-AiCliProperty $Receipt 'limitHit')
        )) {
        return $false
    }
    $code = [string](Get-AiCliProperty $Receipt 'errorCode')
    if ([string]::IsNullOrWhiteSpace($code)) { return $true }
    return $code -in @(
        'codex_appserver.setup_failed',
        'codex_appserver.initialize_failed',
        'codex_appserver.thread_start_failed',
        'codex_appserver.thread_resume_failed',
        'codex_appserver.turn_start_failed',
        'codex_appserver.turn_stream_failed',
        'codex_appserver.stream_closed',
        'codex_appserver.item_unfinished',
        'codex_appserver.upstream_transient'
    )
}

function Test-AiCliRecoverableQuotaPause {
    param([Parameter(Mandatory)]$Receipt)
    $code = [string](Get-AiCliProperty $Receipt 'errorCode')
    return $code -ceq 'codex_appserver.provider_quota_pause'
}

function Get-AiCliRecoverableRunResult {
    param([Parameter(Mandatory)]$State, [object]$Receipt = $null)
    $created = [datetime]::Parse([string]$State.createdUtc).ToUniversalTime()
    $wallMs = [long][Math]::Max(0, ((Get-Date).ToUniversalTime() - $created).TotalMilliseconds)
    return [pscustomobject]@{
        runId = [string]$State.runId
        status = [string]$State.status
        profileId = [string]$State.sessionMeta.profileId
        workspace = [string]$State.sessionMeta.workspace
        model = [string]$State.sessionMeta.model
        modelProvider = [string]$State.sessionMeta.modelProvider
        requestedEffort = [string]$State.sessionMeta.requestedEffort
        effectiveEffort = [string]$State.sessionMeta.effectiveEffort
        threadId = Get-AiCliProperty $State.sessionMeta 'threadId'
        sessionId = Get-AiCliProperty $State.sessionMeta 'sessionId'
        lastTurnId = Get-AiCliProperty $State.turnContext 'lastTurnId'
        attempts = [int]$State.turnContext.attempt
        resumeCount = [int]$State.resume.count
        resumeSupported = [bool]$State.resume.supported
        resumeReason = [string]$State.resume.reason
        eventCursor = [int]$State.turnContext.eventCursor
        accounting = [pscustomobject][ordered]@{
            wallTimeMs = $wallMs
            wallTimeEvidence = 'host-clock-created-to-observed'
            activeAttemptMs = [long]$State.accounting.activeAttemptMs
            activeAttemptEvidence = [string](
                Get-AiCliProperty $State.accounting 'activeAttemptEvidence' `
                    'unavailable'
            )
            initialAttemptMs = [long]$State.accounting.initialAttemptMs
            recoveryAttemptMs = [long]$State.accounting.recoveryAttemptMs
            quotaPauseMs = [long]$State.accounting.quotaPauseMs
            quotaPauseEvidence = 'host-clock-explicit-pause-intervals'
            repeatedInputBytes = [long]$State.accounting.repeatedInputBytes
            repeatedInput = [pscustomobject][ordered]@{
                bytes = [long]$State.accounting.repeatedInputBytes
                tokens = $null
                evidence = 'client-continuation-bytes-only'
            }
            providerUsage = [pscustomobject]$State.accounting.providerUsage
            providerUsageEvidence = 'latest-cumulative-thread-snapshot'
            initialAttemptUsage = [pscustomobject](
                $State.accounting.initialAttemptUsage
            )
            recoveryAttemptUsage = [pscustomobject](
                $State.accounting.recoveryAttemptUsage
            )
            recoveryAttemptUsageEvidence = `
                'delta-of-monotonic-cumulative-thread-snapshots'
            cost = [pscustomobject]$State.accounting.cost
        }
        receipt = $Receipt
    }
}

function Test-AiCliRecoverableControllerAlive {
    param([Parameter(Mandatory)]$State)
    $processId = [int](Get-AiCliProperty $State.controller 'pid' 0)
    $recordedStart = [string](
        Get-AiCliProperty $State.controller 'processStartUtc'
    )
    if ($processId -le 0 -or [string]::IsNullOrWhiteSpace($recordedStart)) {
        return $false
    }
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        return $process.StartTime.ToUniversalTime().ToString('o') -ceq
            $recordedStart
    } catch {
        return $false
    }
}

function Test-AiCliRecoverableEventWriterClosed {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
    $stream = $null
    try {
        $stream = [IO.FileStream]::new(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        return $true
    } catch [IO.IOException] {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Read-AiCliRecoverableSegmentEvidence {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$SegmentName
    )
    if ($SegmentName -notmatch '^\d{4}$') {
        throw 'Recoverable current segment identity is invalid.'
    }
    $path = Join-Path (Join-Path (
        Get-AiCliRecoverableRunRoot -RunId ([string]$State.runId)
    ) 'segments') "$SegmentName.events.jsonl"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            path = $path; sequenceEnd = [int]$State.turnContext.eventCursor
            threadId = ''; sessionId = ''; turnId = ''
            runtimeIdentity = $null; terminalKind = ''; terminalData = $null
            hash = $null
        }
    }
    $expectedSequence = [int]$State.turnContext.eventCursor + 1
    $threadId = ''
    $sessionId = ''
    $turnId = ''
    $runtimeIdentity = $null
    $terminalKind = ''
    $terminalData = $null
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $line | ConvertFrom-Json -AsHashtable -Depth 100
        $kind = [string](Get-AiCliProperty $event 'kind')
        if ([string](Get-AiCliProperty $event 'schema') -cne
                'aicli.machine-event.v1' -or
            [int](Get-AiCliProperty $event 'sequence') -ne $expectedSequence -or
            -not [string]::IsNullOrWhiteSpace($terminalKind)) {
            throw 'Recoverable event segment is non-monotonic or contains an orphan event.'
        }
        $expectedSequence++
        if ($kind -eq 'thread.started') {
            $candidateThread = Get-AiCliPublicThreadId (
                Get-AiCliProperty $event 'thread_id'
            )
            $candidateSession = Get-AiCliPublicThreadId (
                Get-AiCliProperty $event 'session_id'
            )
            if (-not $candidateThread -or -not $candidateSession -or
                ($threadId -and $threadId -cne $candidateThread) -or
                ($sessionId -and $sessionId -cne $candidateSession)) {
                throw 'Recoverable event segment has an invalid thread/session identity.'
            }
            $threadId = $candidateThread
            $sessionId = $candidateSession
        } elseif ($kind -eq 'runtime.identity') {
            if ($null -ne $runtimeIdentity) {
                throw 'Recoverable event segment repeats runtime identity.'
            }
            $runtimeIdentity = $event
        } elseif ($kind -in @('turn.started','turn.completed')) {
            $candidateTurn = Get-AiCliPublicThreadId (
                Get-AiCliProperty $event 'turn_id'
            )
            if ($candidateTurn) { $turnId = $candidateTurn }
        } elseif ($kind -in @('run.completed','run.failed','limit.hit')) {
            $terminalKind = $kind
            $terminalData = $event
        }
    }
    return [pscustomobject]@{
        path = $path
        sequenceEnd = $expectedSequence - 1
        threadId = $threadId
        sessionId = $sessionId
        turnId = $turnId
        runtimeIdentity = $runtimeIdentity
        terminalKind = $terminalKind
        terminalData = $terminalData
        hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Sync-AiCliRecoverableRunState {
    param([Parameter(Mandatory)]$State)
    if ($State.status -notin @(
            'running','interrupted','quota_paused','reconciliation_pending',
            'abort_requested'
        ) -or
        (Test-AiCliRecoverableControllerAlive -State $State)) {
        return $State
    }
    $segment = [string](Get-AiCliProperty $State.controller 'currentSegment')
    if ([string]::IsNullOrWhiteSpace($segment)) { return $State }
    $segmentRoot = Join-Path (
        Get-AiCliRecoverableRunRoot -RunId ([string]$State.runId)
    ) 'segments'
    $eventPath = Join-Path $segmentRoot "$segment.events.jsonl"
    $receiptPath = Join-Path $segmentRoot "$segment.receipt.json"
    if (-not (Test-AiCliRecoverableEventWriterClosed -Path $eventPath)) {
        $State.status = 'reconciliation_pending'
        $State.resume.supported = $false
        $State.resume.reason = 'event_writer_still_active'
        Write-AiCliRecoverableRunState -State $State
        return $State
    }
    if (Test-Path -LiteralPath $receiptPath) {
        $State.status = 'failed_closed'
        $State.resume.supported = $false
        $State.resume.reason = 'immutable_segment_conflict'
        $State.controller.pid = 0
        $State.controller.processStartUtc = $null
        $State.controller.currentSegment = $null
        Write-AiCliRecoverableRunState -State $State
        Add-AiCliRecoverableJournalRecord -RunId ([string]$State.runId) `
            -Kind 'run.failed_closed' -Data @{
                reason = 'immutable_segment_conflict'
                segment = $segment
            } | Out-Null
        return $State
    }
    try {
        $expectedSegment = '{0:d4}' -f [int]$State.turnContext.attempt
        if ($segment -cne $expectedSegment) {
            throw 'Recoverable controller segment does not match its attempt.'
        }
        $sequenceStart = [long]$State.turnContext.eventCursor
        $evidence = Read-AiCliRecoverableSegmentEvidence `
            -State $State -SegmentName $segment
        $identity = $evidence.runtimeIdentity
        # Once a closed writer segment has been read and is about to receive
        # its immutable receipt, its cursor advances even when the contained
        # runtime identity is rejected. This preserves the precise failure
        # reason instead of creating a receipt/state cursor contradiction.
        $State.turnContext.eventCursor = [int]$evidence.sequenceEnd
        if (-not $evidence.threadId -or -not $evidence.sessionId -or
            $null -eq $identity -or
            [string](Get-AiCliProperty $identity 'model') -cne
                [string]$State.sessionMeta.model -or
            [string](Get-AiCliProperty $identity 'provider_id') -cne
                [string]$State.sessionMeta.modelProvider -or
            [string](Get-AiCliProperty $identity 'workspace_hash') -cne
                [string]$State.sessionMeta.workspaceHash -or
            [string](Get-AiCliProperty $identity 'run_id') -cne
                [string]$State.runId -or
            [string](Get-AiCliProperty $identity 'profile_fingerprint') -cne
                [string]$State.sessionMeta.profileFingerprint -or
            [string](Get-AiCliProperty $identity 'requested_effort') -cne
                [string]$State.sessionMeta.requestedEffort -or
            [string](Get-AiCliProperty $identity 'reasoning_effort') -cne
                [string]$State.sessionMeta.effectiveEffort -or
            [string](Get-AiCliProperty $identity 'approval_policy') -cne 'never' -or
            [string](Get-AiCliProperty $identity 'sandbox_policy') -cne
                'danger-full-access' -or
            [string](Get-AiCliProperty $identity 'sandbox_boundary') -cne
                'codex-native' -or
            [string](Get-AiCliProperty $identity 'sandbox_type') -cne
                'dangerFullAccess' -or
            [string](Get-AiCliProperty $identity 'permission_profile') -cne
                ':danger-full-access' -or
            [string](Get-AiCliProperty $identity 'thread_id') -cne
                $evidence.threadId -or
            [string](Get-AiCliProperty $identity 'session_id') -cne
                $evidence.sessionId) {
            $State.status = 'failed_closed'
            $State.resume.supported = $false
            $State.resume.reason = 'interrupted_runtime_identity_incomplete'
        } elseif ($State.sessionMeta.threadId -and
            [string]$State.sessionMeta.threadId -cne $evidence.threadId) {
            $State.status = 'failed_closed'
            $State.resume.supported = $false
            $State.resume.reason = 'thread_identity_changed'
        } elseif ($State.sessionMeta.sessionId -and
            [string]$State.sessionMeta.sessionId -cne $evidence.sessionId) {
            $State.status = 'failed_closed'
            $State.resume.supported = $false
            $State.resume.reason = 'session_identity_changed'
        } else {
            $State.sessionMeta.threadId = $evidence.threadId
            $State.sessionMeta.sessionId = $evidence.sessionId
            if ($evidence.turnId) {
                $State.turnContext.lastTurnId = $evidence.turnId
            }
            $abortRequested = Test-Path -LiteralPath (Join-Path (
                Get-AiCliRecoverableRunRoot -RunId ([string]$State.runId)
            ) 'abort.requested') -PathType Leaf
            if ($evidence.terminalKind -eq 'run.completed') {
                $State.status = 'completed'
                $State.resume.supported = $false
                $State.resume.reason = 'terminal_completed_reconciled'
            } elseif ($evidence.terminalKind -eq 'limit.hit') {
                $State.status = 'failed_closed'
                $State.resume.supported = $false
                $State.resume.reason = 'hard_limit_terminal'
            } elseif ($abortRequested) {
                $State.status = 'aborted'
                $State.resume.supported = $false
                $State.resume.reason = 'aborted_by_request'
            } elseif ($evidence.terminalKind -eq 'run.failed') {
                $failureCategory = [string](
                    Get-AiCliProperty $evidence.terminalData 'error_category'
                )
                $failureCode = [string](
                    Get-AiCliProperty $evidence.terminalData 'error_code'
                )
                if ($failureCategory -eq 'aborted') {
                    $State.status = 'aborted'
                    $State.resume.supported = $false
                    $State.resume.reason = 'aborted_by_request'
                } elseif ($failureCode -ceq
                        'codex_appserver.provider_quota_pause') {
                    if ([string](Get-AiCliProperty $identity 'resume_mode') `
                            -ceq 'resume') {
                        $State.resume.count = [Math]::Max(
                            0,
                            [int]$State.resume.count - 1
                        )
                    }
                    $State.status = 'quota_paused'
                    $State.resume.supported = $true
                    $State.resume.reason = `
                        'provider_quota_pause_exact_resume_ready'
                    $State.accounting.quotaPauseStartedUtc = (
                        Get-Date
                    ).ToUniversalTime().ToString('o')
                } elseif ($failureCategory -in @(
                    'upstream_error',
                    'protocol_or_process_failure',
                    'runner_failure'
                )) {
                    $retryProbe = [pscustomobject]@{
                        timedOut = $false
                        abortRequested = $false
                        limitHit = $null
                        errorCode = Get-AiCliProperty `
                            $evidence.terminalData 'error_code'
                    }
                    if (Test-AiCliRecoverableFailureRetryable `
                            -Receipt $retryProbe) {
                        $State.status = 'interrupted'
                        $State.resume.supported = $true
                        $State.resume.reason = `
                            'process_or_reboot_interruption_exact_resume_ready'
                    } else {
                        $State.status = 'failed_closed'
                        $State.resume.supported = $false
                        $State.resume.reason = 'failure_not_retryable'
                    }
                } else {
                    $State.status = 'failed_closed'
                    $State.resume.supported = $false
                    $State.resume.reason = 'failure_category_invalid'
                }
            } else {
                $State.status = 'interrupted'
                $State.resume.supported = $true
                $State.resume.reason = 'process_or_reboot_interruption_exact_resume_ready'
            }
        }
        $terminalErrorCode = if ($evidence.terminalData) {
            Get-AiCliProperty $evidence.terminalData 'error_code'
        } else { $null }
        $terminalLimit = if ($evidence.terminalData) {
            [string](Get-AiCliProperty $evidence.terminalData 'limit')
        } else { '' }
        try {
            Update-AiCliRecoveryUsageAccounting -State $State `
                -Usage (Get-AiCliProperty $evidence.terminalData 'usage') `
                -IsResume:([string](Get-AiCliProperty $identity `
                    'resume_mode') -ceq 'resume')
        } catch {
            $State.status = 'failed_closed'
            $State.resume.supported = $false
            $State.resume.reason = 'usage_counter_regressed'
        }
        $reconciledReceipt = [ordered]@{
            schema = 'aicli.recoverable-segment.v1'
            source = 'reconciled-after-controller-loss'
            runId = [string]$State.runId
            attempt = [int]$State.turnContext.attempt
            mode = [string](Get-AiCliProperty $identity 'resume_mode')
            eventSequenceStart = $sequenceStart
            eventSequenceEnd = [long]$evidence.sequenceEnd
            eventFileSha256 = [string]$evidence.hash
            threadId = [string]$evidence.threadId
            sessionId = [string]$evidence.sessionId
            turnId = [string]$evidence.turnId
            profileFingerprint = [string]$State.sessionMeta.profileFingerprint
            workspaceHash = [string]$State.sessionMeta.workspaceHash
            model = [string]$State.sessionMeta.model
            modelProvider = [string]$State.sessionMeta.modelProvider
            requestedEffort = [string]$State.sessionMeta.requestedEffort
            effectiveEffort = [string]$State.sessionMeta.effectiveEffort
            exitCode = if ($State.status -eq 'completed') {
                0
            } elseif ($State.status -eq 'aborted') {
                Get-AiCliExitCode Cancelled
            } elseif ($evidence.terminalKind -eq 'limit.hit') {
                75
            } else { 1 }
            exitCodeEvidence = 'terminal-event-derived'
            timedOut = ($terminalLimit -ceq 'timeout')
            errorCode = $terminalErrorCode
            durationMs = $null
            durationEvidence = 'unavailable-after-controller-loss'
            usage = ConvertTo-AiCliSafeUsage (
                Get-AiCliProperty $evidence.terminalData 'usage'
            )
            outputSha256 = $null
            outputEvidence = 'unavailable-after-controller-loss'
        }
        $reconciledReceipt['segmentHash'] = `
            Get-AiCliRecoverableSegmentHash -Receipt $reconciledReceipt
        $State.accounting.activeAttemptEvidence = `
            'partial-after-controller-loss'
        Write-AiCliJsonFile -Path $receiptPath -Value $reconciledReceipt
        $State.lastReceipt = [ordered]@{
            attempt = [int]$State.turnContext.attempt
            segmentHash = [string]$reconciledReceipt.segmentHash
            eventFileSha256 = [string]$evidence.hash
            exitCode = [int]$reconciledReceipt.exitCode
            errorCode = $terminalErrorCode
        }
        $State.controller.pid = 0
        $State.controller.processStartUtc = $null
        $State.controller.currentSegment = $null
        Write-AiCliRecoverableRunState -State $State
        Add-AiCliRecoverableJournalRecord -RunId ([string]$State.runId) `
            -Kind 'state.reconciled' -Data @{
                segment = $segment
                segmentSha256 = $evidence.hash
                segmentHash = $reconciledReceipt.segmentHash
                sequenceEnd = $evidence.sequenceEnd
                status = $State.status
                reason = $State.resume.reason
            } | Out-Null
    } catch {
        $State.status = 'failed_closed'
        $State.resume.supported = $false
        $State.resume.reason = 'event_reconciliation_failed'
        $State.controller.pid = 0
        $State.controller.processStartUtc = $null
        $State.controller.currentSegment = $null
        Write-AiCliRecoverableRunState -State $State
        Add-AiCliRecoverableJournalRecord -RunId ([string]$State.runId) `
            -Kind 'run.failed_closed' -Data @{
                reason = 'event_reconciliation_failed'
            } | Out-Null
    }
    return $State
}

function Invoke-AiCliRecoverableRunCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [AllowNull()][string]$InitialTaskText = $null
    )
    $state = Sync-AiCliRecoverableRunState -State (
        Get-AiCliRecoverableRunState -RunId $RunId
    )
    if ($state.status -eq 'running' -and
        (Test-AiCliRecoverableControllerAlive -State $state)) {
        return (Get-AiCliRecoverableRunResult -State $state)
    }
    if ($state.status -eq 'reconciliation_pending') {
        return (Get-AiCliRecoverableRunResult -State $state)
    }
    try {
        Assert-AiCliRecoverableEvidenceChain -State $state | Out-Null
    } catch {
        $state = Set-AiCliRecoverableEvidenceFailure -State $state
        return (Get-AiCliRecoverableRunResult -State $state)
    }
    if ($state.status -in @('completed','failed_closed','aborted')) {
        return (Get-AiCliRecoverableRunResult -State $state)
    }
    if ($state.status -eq 'quota_paused' -and
        $state.accounting.quotaPauseStartedUtc) {
        $pauseStarted = [datetime]::Parse(
            [string]$state.accounting.quotaPauseStartedUtc
        ).ToUniversalTime()
        $state.accounting.quotaPauseMs += [long][Math]::Max(
            0,
            ((Get-Date).ToUniversalTime() - $pauseStarted).TotalMilliseconds
        )
        $state.accounting.quotaPauseStartedUtc = $null
    }
    if ([int]$state.turnContext.attempt -eq 0 -and
        [string]::IsNullOrWhiteSpace($InitialTaskText)) {
        throw 'Initial task text is required for the first recoverable attempt.'
    }
    $root = Get-AiCliRecoverableRunRoot -RunId $RunId
    $abortSignal = Join-Path $root 'abort.requested'
    $lastReceipt = $null
    while ($true) {
        if (Test-Path -LiteralPath $abortSignal -PathType Leaf) {
            $state.status = 'aborted'
            $state.controller.abortRequested = $true
            $state.resume.supported = $false
            $state.resume.reason = 'aborted_by_request'
            Write-AiCliRecoverableRunState -State $state
            Add-AiCliRecoverableJournalRecord -RunId $RunId `
                -Kind 'run.aborted' | Out-Null
            return (Get-AiCliRecoverableRunResult -State $state -Receipt $lastReceipt)
        }
        $attempt = [int]$state.turnContext.attempt + 1
        $isResume = -not [string]::IsNullOrWhiteSpace(
            [string]$state.sessionMeta.threadId
        )
        if ($isResume -and [int]$state.resume.count -ge
                [int]$state.resume.maxAttempts) {
            $state.status = 'failed_closed'
            $state.resume.supported = $false
            $state.resume.reason = 'automatic_resume_limit_reached'
            Write-AiCliRecoverableRunState -State $state
            Add-AiCliRecoverableJournalRecord -RunId $RunId `
                -Kind 'run.failed_closed' -Data @{
                    reason = 'automatic_resume_limit_reached'
                } | Out-Null
            return (Get-AiCliRecoverableRunResult -State $state -Receipt $lastReceipt)
        }
        $segmentName = '{0:d4}' -f $attempt
        $segmentRoot = Join-Path $root 'segments'
        $eventFile = Join-Path $segmentRoot "$segmentName.events.jsonl"
        $segmentReceiptPath = Join-Path $segmentRoot `
            "$segmentName.receipt.json"
        if ((Test-Path -LiteralPath $eventFile) -or
            (Test-Path -LiteralPath $segmentReceiptPath)) {
            $state.status = 'failed_closed'
            $state.resume.supported = $false
            $state.resume.reason = 'immutable_segment_conflict'
            $state.controller.pid = 0
            $state.controller.processStartUtc = $null
            $state.controller.currentSegment = $null
            Write-AiCliRecoverableRunState -State $state
            Add-AiCliRecoverableJournalRecord -RunId $RunId `
                -Kind 'run.failed_closed' -Data @{
                    reason = 'immutable_segment_conflict'
                    segment = $segmentName
                } | Out-Null
            return (Get-AiCliRecoverableRunResult -State $state `
                -Receipt $lastReceipt)
        }
        [IO.File]::WriteAllBytes($eventFile, [byte[]]::new(0))
        $taskText = if ($isResume) {
            "Continue the original task in this existing durable thread. Do not repeat completed work. Reconcile the interrupted turn and finish the remaining work. Recovery attempt $([int]$state.resume.count + 1)."
        } else {
            $InitialTaskText
        }
        if ($isResume) {
            $state.accounting.repeatedInputBytes += [long](
                [Text.UTF8Encoding]::new($false).GetByteCount($taskText)
            )
            $state.resume.count = [int]$state.resume.count + 1
        }
        $state.status = 'running'
        $state.turnContext.attempt = $attempt
        $state.controller.pid = $PID
        try {
            $state.controller.processStartUtc = (
                Get-Process -Id $PID -ErrorAction Stop
            ).StartTime.ToUniversalTime().ToString('o')
        } catch {
            $state.controller.processStartUtc = $null
        }
        $state.controller.currentSegment = $segmentName
        Write-AiCliRecoverableRunState -State $state
        Add-AiCliRecoverableJournalRecord -RunId $RunId `
            -Kind 'attempt.started' -Data @{
                attempt = $attempt
                mode = $(if ($isResume) { 'resume' } else { 'start' })
                eventSequenceBase = [int]$state.turnContext.eventCursor
            } | Out-Null
        $recoveryContext = [ordered]@{
            runId = $RunId
            mode = $(if ($isResume) { 'resume' } else { 'start' })
            threadId = Get-AiCliProperty $state.sessionMeta 'threadId'
            sessionId = Get-AiCliProperty $state.sessionMeta 'sessionId'
            workspace = [string]$state.sessionMeta.workspace
            workspaceHash = [string]$state.sessionMeta.workspaceHash
            profileFingerprint = [string]$state.sessionMeta.profileFingerprint
            model = [string]$state.sessionMeta.model
            modelProvider = [string]$state.sessionMeta.modelProvider
            requestedEffort = [string]$state.sessionMeta.requestedEffort
            effectiveEffort = [string]$state.sessionMeta.effectiveEffort
            durableCodexHome = Join-Path $root 'codex-home'
            eventSequenceBase = [int]$state.turnContext.eventCursor
            abortSignalPath = $abortSignal
            consumerEventFile = [string](
                Get-AiCliProperty $state.config 'consumerEventFile'
            )
        }
        try {
            $receipt = Invoke-AiCliProfileCapture `
                -ProfileId ([string]$state.sessionMeta.profileId) `
                -ProjectPath ([string]$state.sessionMeta.workspace) `
                -NativeArgs @() -StdInText $taskText `
                -TimeoutMs ([int]$state.config.timeoutMs) `
                -MaxCaptureChars ([int]$state.config.maxCaptureChars) `
                -SandboxPolicy 'danger-full-access' `
                -MaxSteps ([int]$state.config.maxSteps) `
                -MaxToolCalls ([int]$state.config.maxToolCalls) `
                -EnforceStepLimit:(-not [bool]$state.config.watchdogOnly) `
                -EnforceToolCallLimit:(-not [bool]$state.config.watchdogOnly) `
                -WatchdogOnly:([bool]$state.config.watchdogOnly) `
                -MachineEventFile $eventFile `
                -DisableWebSearch:([bool]$state.config.disableWebSearch) `
                -AuthorityPreludeStdout:([bool]$state.config.authorityPreludeStdout) `
                -RecoveryContext $recoveryContext
        } catch {
            $state.status = 'failed_closed'
            $state.resume.supported = $false
            $captureFailureReason = `
                'capture_exception_before_verified_receipt'
            $captureErrorCode = 'aicli.recovery.capture_exception'
            $captureSequenceStart = [int]$state.turnContext.eventCursor
            $captureSequenceEnd = $captureSequenceStart
            # Invoke-AiCliProfileCapture can fail its parent identity gate after
            # the child has already closed a valid public machine-event
            # segment. Chain those bytes without promoting any partial runtime
            # identity, and preserve only the structured public terminal code.
            try {
                if (-not (Test-AiCliRecoverableEventWriterClosed `
                        -Path $eventFile)) {
                    throw 'Recoverable capture event writer is still open.'
                }
                $captureEvidence = Read-AiCliRecoverableSegmentEvidence `
                    -State $state -SegmentName $segmentName
                $captureSequenceEnd = [int]$captureEvidence.sequenceEnd
                $terminalCode = [string](Get-AiCliProperty `
                    $captureEvidence.terminalData 'error_code')
                if ($terminalCode -match '\A[a-z0-9._-]{1,128}\z') {
                    $captureErrorCode = $terminalCode
                    $captureFailureReason += ':' + $terminalCode
                }
            } catch {
                $captureFailureReason = `
                    'capture_exception_event_evidence_invalid'
            }
            $state.resume.reason = $captureFailureReason
            $receipt = [pscustomobject]@{
                exitCode = (Get-AiCliExitCode Unavailable)
                timedOut = $false
                errorCode = $captureErrorCode
                limitHit = $null
                abortRequested = $false
                threadId = $null
                sessionId = $null
                turnId = $null
                durationMs = 0
                machineEventSequenceStart = $captureSequenceStart
                machineEventSequenceEnd = $captureSequenceEnd
                machineEventCount = $captureSequenceEnd - $captureSequenceStart
                usage = [ordered]@{}
                stdout = ''
                stderr = `
                    'Recoverable capture failed before a verified receipt.'
                runtimeIdentity = $null
            }
        }
        $lastReceipt = $receipt
        $durationMs = [long](Get-AiCliProperty $receipt 'durationMs' 0)
        $state.accounting.activeAttemptMs += $durationMs
        if ($isResume) {
            $state.accounting.recoveryAttemptMs += $durationMs
        } else {
            $state.accounting.initialAttemptMs += $durationMs
        }
        try {
            Update-AiCliRecoveryUsageAccounting -State $state `
                -Usage (Get-AiCliProperty $receipt 'usage') `
                -IsResume:$isResume
        } catch {
            $state.status = 'failed_closed'
            $state.resume.supported = $false
            $state.resume.reason = 'usage_counter_regressed'
        }
        $sequenceStart = [int](Get-AiCliProperty $receipt `
            'machineEventSequenceStart' $state.turnContext.eventCursor)
        $sequenceEnd = [int](Get-AiCliProperty $receipt `
            'machineEventSequenceEnd' (
                $sequenceStart + [int](Get-AiCliProperty $receipt 'machineEventCount' 0)
            ))
        if ($sequenceStart -ne [int]$state.turnContext.eventCursor -or
            $sequenceEnd -lt $sequenceStart) {
            $state.status = 'failed_closed'
            $state.resume.supported = $false
            $state.resume.reason = 'event_sequence_invalid'
        } else {
            $state.turnContext.eventCursor = $sequenceEnd
        }
        $observedThreadId = Get-AiCliPublicThreadId (
            Get-AiCliProperty $receipt 'threadId'
        )
        $observedSessionId = Get-AiCliPublicThreadId (
            Get-AiCliProperty $receipt 'sessionId'
        )
        if ($state.status -eq 'failed_closed') {
            # The capture exception path cannot safely promote any partial
            # identity observed outside a verified public receipt.
        } elseif (-not $isResume) {
            if ($observedThreadId -and $observedSessionId) {
                $state.sessionMeta.threadId = $observedThreadId
                $state.sessionMeta.sessionId = $observedSessionId
                $state.resume.supported = $true
                $state.resume.reason = 'exact_thread_observed'
            } else {
                $state.resume.supported = $false
                $state.resume.reason = if (-not $observedThreadId) {
                    'thread_id_not_observed'
                } else { 'session_id_not_observed' }
            }
        } elseif ($observedThreadId -cne [string]$state.sessionMeta.threadId) {
            $state.status = 'failed_closed'
            $state.resume.supported = $false
            $state.resume.reason = 'thread_identity_changed'
        } elseif ($observedSessionId -cne [string]$state.sessionMeta.sessionId) {
            $state.status = 'failed_closed'
            $state.resume.supported = $false
            $state.resume.reason = 'session_identity_changed'
        }
        $observedTurnId = Get-AiCliPublicThreadId (
            Get-AiCliProperty $receipt 'turnId'
        )
        if ($observedTurnId) { $state.turnContext.lastTurnId = $observedTurnId }
        $eventHash = (Get-FileHash -LiteralPath $eventFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $segmentReceipt = [ordered]@{
            schema = 'aicli.recoverable-segment.v1'
            runId = $RunId
            attempt = $attempt
            mode = $(if ($isResume) { 'resume' } else { 'start' })
            eventSequenceStart = $sequenceStart
            eventSequenceEnd = $sequenceEnd
            eventFileSha256 = $eventHash
            threadId = $observedThreadId
            sessionId = $observedSessionId
            turnId = $observedTurnId
            profileFingerprint = [string]$state.sessionMeta.profileFingerprint
            workspaceHash = [string]$state.sessionMeta.workspaceHash
            model = [string]$state.sessionMeta.model
            modelProvider = [string]$state.sessionMeta.modelProvider
            requestedEffort = [string]$state.sessionMeta.requestedEffort
            effectiveEffort = [string]$state.sessionMeta.effectiveEffort
            exitCode = [int](Get-AiCliProperty $receipt 'exitCode' 1)
            timedOut = [bool](Get-AiCliProperty $receipt 'timedOut' $false)
            errorCode = Get-AiCliProperty $receipt 'errorCode'
            durationMs = $durationMs
            usage = ConvertTo-AiCliSafeUsage (Get-AiCliProperty $receipt 'usage')
            outputSha256 = Get-AiCliRecoveryHash -Text (
                [string](Get-AiCliProperty $receipt 'stdout')
            )
        }
        $segmentReceipt['segmentHash'] = `
            Get-AiCliRecoverableSegmentHash -Receipt $segmentReceipt
        if (Test-Path -LiteralPath $segmentReceiptPath) {
            $state.status = 'failed_closed'
            $state.resume.supported = $false
            $state.resume.reason = 'immutable_segment_conflict'
            $state.controller.pid = 0
            $state.controller.processStartUtc = $null
            $state.controller.currentSegment = $null
            Write-AiCliRecoverableRunState -State $state
            Add-AiCliRecoverableJournalRecord -RunId $RunId `
                -Kind 'run.failed_closed' -Data @{
                    reason = 'immutable_segment_conflict'
                    segment = $segmentName
                } | Out-Null
            return (Get-AiCliRecoverableRunResult -State $state `
                -Receipt $receipt)
        }
        Write-AiCliJsonFile -Path $segmentReceiptPath -Value $segmentReceipt
        $state.lastReceipt = [ordered]@{
            attempt = $attempt
            segmentHash = $segmentReceipt.segmentHash
            eventFileSha256 = $eventHash
            exitCode = $segmentReceipt.exitCode
            errorCode = $segmentReceipt.errorCode
        }
        Add-AiCliRecoverableJournalRecord -RunId $RunId `
            -Kind 'attempt.completed' -Data @{
                attempt = $attempt
                segmentHash = $segmentReceipt.segmentHash
                eventSequenceEnd = $sequenceEnd
                exitCode = $segmentReceipt.exitCode
                errorCode = $segmentReceipt.errorCode
            } | Out-Null
        if ($state.status -eq 'failed_closed') {
            $state.controller.pid = 0
            $state.controller.processStartUtc = $null
            $state.controller.currentSegment = $null
            Write-AiCliRecoverableRunState -State $state
            Add-AiCliRecoverableJournalRecord -RunId $RunId `
                -Kind 'run.failed_closed' -Data @{
                    reason = $state.resume.reason
                } | Out-Null
            return (Get-AiCliRecoverableRunResult -State $state -Receipt $receipt)
        }
        if ([int]$receipt.exitCode -eq 0 -and
            -not [bool](Get-AiCliProperty $receipt 'timedOut' $false)) {
            $state.status = 'completed'
            $state.resume.supported = $false
            $state.resume.reason = 'terminal_completed'
            $state.controller.pid = 0
            $state.controller.processStartUtc = $null
            $state.controller.currentSegment = $null
            Write-AiCliRecoverableRunState -State $state
            Add-AiCliRecoverableJournalRecord -RunId $RunId `
                -Kind 'run.completed' -Data @{
                    attempt = $attempt
                    threadId = $state.sessionMeta.threadId
                    sessionId = $state.sessionMeta.sessionId
                } | Out-Null
            return (Get-AiCliRecoverableRunResult -State $state -Receipt $receipt)
        }
        if (-not [bool]$state.resume.supported) {
            $state.status = 'failed_closed'
            Write-AiCliRecoverableRunState -State $state
            Add-AiCliRecoverableJournalRecord -RunId $RunId `
                -Kind 'run.failed_closed' -Data @{
                    reason = $state.resume.reason
                } | Out-Null
            return (Get-AiCliRecoverableRunResult -State $state -Receipt $receipt)
        }
        if (Test-AiCliRecoverableQuotaPause -Receipt $receipt) {
            if ($isResume) {
                $state.resume.count = [Math]::Max(
                    0,
                    [int]$state.resume.count - 1
                )
            }
            $state.status = 'quota_paused'
            $state.resume.reason = 'provider_quota_pause_exact_resume_ready'
            $state.accounting.quotaPauseStartedUtc = (
                Get-Date
            ).ToUniversalTime().ToString('o')
            $state.controller.pid = 0
            $state.controller.processStartUtc = $null
            $state.controller.currentSegment = $null
            Write-AiCliRecoverableRunState -State $state
            Add-AiCliRecoverableJournalRecord -RunId $RunId `
                -Kind 'quota.paused' -Data @{
                    attempt = $attempt
                    threadId = $state.sessionMeta.threadId
                    sessionId = $state.sessionMeta.sessionId
                } | Out-Null
            return (Get-AiCliRecoverableRunResult -State $state -Receipt $receipt)
        }
        if (-not (Test-AiCliRecoverableFailureRetryable -Receipt $receipt)) {
            $state.status = 'failed_closed'
            $state.resume.supported = $false
            $state.resume.reason = 'failure_not_retryable'
            Write-AiCliRecoverableRunState -State $state
            Add-AiCliRecoverableJournalRecord -RunId $RunId `
                -Kind 'run.failed_closed' -Data @{
                    reason = 'failure_not_retryable'
                } | Out-Null
            return (Get-AiCliRecoverableRunResult -State $state -Receipt $receipt)
        }
        $state.status = 'interrupted'
        $state.resume.reason = 'transient_failure_exact_resume_ready'
        Write-AiCliRecoverableRunState -State $state
        Add-AiCliRecoverableJournalRecord -RunId $RunId `
            -Kind 'resume.scheduled' -Data @{
                nextAttempt = $attempt + 1
                threadId = $state.sessionMeta.threadId
                sessionId = $state.sessionMeta.sessionId
            } | Out-Null
    }
}

function Invoke-AiCliRecoverableRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [AllowNull()][string]$InitialTaskText = $null
    )
    $guardPath = Join-Path (
        Get-AiCliRecoverableRunRoot -RunId $RunId
    ) 'controller.guard'
    $guard = Enter-AiCliFileLock -TargetPath $guardPath -TimeoutMs 250
    try {
        return (Invoke-AiCliRecoverableRunCore -RunId $RunId `
            -InitialTaskText $InitialTaskText)
    } finally {
        Exit-AiCliFileLock -Lock $guard
    }
}

function New-AiCliRecoverableControllerStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ControllerScript,
        [Parameter(Mandatory)][string]$ModuleManifest,
        [Parameter(Mandatory)][string]$RunId,
        [AllowEmptyString()][string]$TaskPipeName = ''
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Join-Path $PSHOME 'pwsh.exe'
    # ShellExecute gives the hidden controller its own standard handles. With
    # UseShellExecute=false, a caller that captures aicli stdout can retain the
    # pipe until the long-lived controller exits, defeating --background.
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($arg in @(
        '-NoLogo','-NoProfile','-File',$ControllerScript,
        '-ModuleManifest',$ModuleManifest,'-RunId',$RunId
    )) {
        [void]$psi.ArgumentList.Add([string]$arg)
    }
    if ($TaskPipeName) {
        [void]$psi.ArgumentList.Add('-TaskPipeName')
        [void]$psi.ArgumentList.Add($TaskPipeName)
    }
    return $psi
}

function Start-AiCliRecoverableControllerProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [AllowNull()][string]$InitialTaskText = $null
    )
    $runRoot = Get-AiCliRecoverableRunRoot -RunId $RunId
    $spawnGuard = Enter-AiCliFileLock `
        -TargetPath (Join-Path $runRoot 'controller-spawn.guard') `
        -TimeoutMs 5000
    $taskPipe = $null
    $taskPipeName = ''
    $process = $null
    try {
        $state = Sync-AiCliRecoverableRunState -State (
            Get-AiCliRecoverableRunState -RunId $RunId
        )
        if ($state.status -eq 'running' -and
            (Test-AiCliRecoverableControllerAlive -State $state)) {
            return [pscustomobject]@{
                runId = $RunId
                controllerPid = [int]$state.controller.pid
                status = 'running'
                alreadyRunning = $true
            }
        }
        if ($state.status -in @('completed','failed_closed','aborted')) {
            throw "Recoverable run is terminal: $($state.status)"
        }
        if ([int]$state.turnContext.attempt -eq 0) {
            if ([string]::IsNullOrWhiteSpace($InitialTaskText)) {
                throw 'Initial task text is required to start the background controller.'
            }
            $taskPipeName = 'aicli-recovery-' + [guid]::NewGuid().ToString('N')
            $pipeSecurity = [IO.Pipes.PipeSecurity]::new()
            $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
            $currentSid = $currentUser.User
            $pipeSecurity.SetOwner($currentSid)
            $pipeSecurity.SetAccessRuleProtection($true, $false)
            $pipeSecurity.AddAccessRule([IO.Pipes.PipeAccessRule]::new(
                $currentSid,
                [IO.Pipes.PipeAccessRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow
            ))
            $taskPipe = [IO.Pipes.NamedPipeServerStreamAcl]::Create(
                $taskPipeName,
                [IO.Pipes.PipeDirection]::Out,
                1,
                [IO.Pipes.PipeTransmissionMode]::Byte,
                [IO.Pipes.PipeOptions]::Asynchronous,
                4096,
                4096,
                $pipeSecurity,
                [IO.HandleInheritability]::None,
                [IO.Pipes.PipeAccessRights]0
            )
        }
        $moduleRoot = Split-Path -Parent $PSScriptRoot
        $moduleManifest = Join-Path $moduleRoot 'AiCliProfileManager.psd1'
        $controllerScript = Join-Path $moduleRoot `
            'Support\RecoverableRunController.ps1'
        foreach ($path in @($moduleManifest, $controllerScript)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw 'Recoverable background controller payload is unavailable.'
            }
        }
        $psi = New-AiCliRecoverableControllerStartInfo `
            -ControllerScript $controllerScript `
            -ModuleManifest $moduleManifest -RunId $RunId `
            -TaskPipeName $taskPipeName
        $process = [Diagnostics.Process]::Start($psi)
        if ($null -eq $process) {
            throw 'Recoverable background controller did not start.'
        }
        if ($taskPipe) {
            $connected = $taskPipe.WaitForConnectionAsync()
            if (-not $connected.Wait(10000)) {
                try { $process.Kill($true) } catch {}
                throw 'Recoverable background controller task transport timed out.'
            }
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($InitialTaskText)
            $taskPipe.Write($bytes, 0, $bytes.Length)
            $taskPipe.Flush()
            $taskPipe.Dispose()
            $taskPipe = $null
        }
        Add-AiCliRecoverableJournalRecord -RunId $RunId `
            -Kind 'controller.spawned' -Data @{
                pid = [int]$process.Id
                taskTransport = $(if ($taskPipeName) {
                    'user-bound-named-pipe'
                } else { 'none-resume' })
            } | Out-Null
        return [pscustomobject]@{
            runId = $RunId
            controllerPid = [int]$process.Id
            status = 'running'
            alreadyRunning = $false
        }
    } finally {
        if ($taskPipe) { try { $taskPipe.Dispose() } catch {} }
        if ($process) { try { $process.Dispose() } catch {} }
        Exit-AiCliFileLock -Lock $spawnGuard
    }
}

function Get-AiCliRecoverableRunStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId)
    $state = Sync-AiCliRecoverableRunState -State (
        Get-AiCliRecoverableRunState -RunId $RunId
    )
    if ($state.status -ne 'reconciliation_pending') {
        try {
            Assert-AiCliRecoverableEvidenceChain -State $state | Out-Null
        } catch {
            $state = Set-AiCliRecoverableEvidenceFailure -State $state
        }
    }
    return (Get-AiCliRecoverableRunResult -State $state)
}

function Stop-AiCliRecoverableRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId)
    $state = Get-AiCliRecoverableRunState -RunId $RunId
    if ($state.status -in @('completed','failed_closed','aborted')) {
        return (Get-AiCliRecoverableRunResult -State $state)
    }
    $signal = Join-Path (Get-AiCliRecoverableRunRoot -RunId $RunId) 'abort.requested'
    $signalCreated = $false
    if (-not (Test-Path -LiteralPath $signal)) {
        try {
            $stream = [IO.FileStream]::new(
                $signal,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::Read
            )
            $stream.Dispose()
            $signalCreated = $true
        } catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $signal -PathType Leaf)) { throw }
        }
    }
    if ($signalCreated) {
        Add-AiCliRecoverableJournalRecord -RunId $RunId `
            -Kind 'abort.requested' | Out-Null
    }
    $controllerAlive = Test-AiCliRecoverableControllerAlive -State $state
    if (-not $controllerAlive -and $state.status -ne 'pending') {
        $state = Sync-AiCliRecoverableRunState -State $state
    }
    if ($state.status -eq 'pending') {
        $state.status = 'abort_requested'
        $state.controller.abortRequested = $true
        $state.resume.supported = $false
        $state.resume.reason = 'abort_requested_before_start'
        Write-AiCliRecoverableRunState -State $state
    }
    $result = Get-AiCliRecoverableRunResult -State $state
    if ($controllerAlive -and $result.status -eq 'running') {
        $result.status = 'abort_requested'
        $result.resumeSupported = $false
        $result.resumeReason = 'cooperative_abort_requested'
    }
    $result | Add-Member -NotePropertyName abortSignalPath `
        -NotePropertyValue $signal
    return $result
}
