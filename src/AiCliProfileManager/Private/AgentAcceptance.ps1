# Versioned, exact-model Codex Agent acceptance.

function New-AiCliAgentAcceptanceFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkDir)

    $root = [IO.Path]::GetFullPath($WorkDir)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Agent acceptance workspace does not exist: $root"
    }
    $inputPath = Join-Path $root 'input.json'
    $resultPath = Join-Path $root 'result.json'
    if ((Test-Path -LiteralPath $inputPath) -or
        (Test-Path -LiteralPath $resultPath)) {
        throw 'Agent acceptance workspace contains a conflicting fixture file.'
    }

    $input = [ordered]@{
        records = @(
            [ordered]@{ id = 'alpha'; values = @(12, 5, 12, 3) }
            [ordered]@{ id = 'beta'; values = @(8, 3, 5, 8) }
            [ordered]@{ id = 'gamma'; values = @(13, 2, 13, 7) }
        )
    }
    Write-AiCliJsonFile -Path $inputPath -Value $input
    $inputSha = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $task = @'
This is an isolated AICLI Codex Agent capability check. Read input.json from the
current directory. Use one or more local tools or commands to create result.json.
The JSON object must contain exactly these fields:
- unique_sorted: every distinct integer from all records, ascending;
- sum_of_unique: the sum of unique_sorted;
- frequency: an object whose decimal-string keys count every input occurrence;
- checksum_sha256: lowercase SHA-256 of "<comma-joined unique_sorted>|<sum>".
Do not modify input.json. Finish only after result.json is written and checked.
'@.Trim()
    $taskBytes = [Text.Encoding]::UTF8.GetBytes($task)
    try {
        $taskSha = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($taskBytes)
        ).ToLowerInvariant()
    } finally {
        [Array]::Clear($taskBytes, 0, $taskBytes.Length)
    }
    return [pscustomobject]@{
        InputPath = $inputPath
        ResultPath = $resultPath
        InputSha256 = $inputSha
        Task = $task
        TaskContractSha256 = $taskSha
    }
}

function Test-AiCliAgentAcceptanceFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Fixture)

    $contract = 'aicli-agent-fixture-verifier-v1'
    $contractBytes = [Text.Encoding]::UTF8.GetBytes($contract)
    try {
        $verifierSha = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($contractBytes)
        ).ToLowerInvariant()
    } finally {
        [Array]::Clear($contractBytes, 0, $contractBytes.Length)
    }
    try {
        if (-not (Test-Path -LiteralPath $Fixture.InputPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $Fixture.ResultPath -PathType Leaf)) {
            throw 'fixture file missing'
        }
        if ((Get-FileHash -LiteralPath $Fixture.InputPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne
            [string]$Fixture.InputSha256) {
            throw 'input changed'
        }
        $input = Get-Content -LiteralPath $Fixture.InputPath -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable -Depth 20
        $actual = Get-Content -LiteralPath $Fixture.ResultPath -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable -Depth 20
        if ($actual -isnot [System.Collections.IDictionary] -or
            (@($actual.Keys | Sort-Object) -join ',') -cne
            'checksum_sha256,frequency,sum_of_unique,unique_sorted') {
            throw 'result shape invalid'
        }

        $values = @(
            $input.records |
                ForEach-Object { @($_.values) } |
                ForEach-Object { [int]$_ }
        )
        $unique = @($values | Sort-Object -Unique)
        $sum = [int](($unique | Measure-Object -Sum).Sum)
        if (@($actual.unique_sorted).Count -ne $unique.Count -or
            (@($actual.unique_sorted | ForEach-Object { [int]$_ }) -join ',') -cne
            ($unique -join ',') -or [int]$actual.sum_of_unique -ne $sum) {
            throw 'result aggregate invalid'
        }

        $expectedFrequency = [ordered]@{}
        foreach ($value in $values) {
            $key = [string]$value
            $expectedFrequency[$key] = [int]$expectedFrequency[$key] + 1
        }
        $actualFrequency = $actual.frequency
        if ($actualFrequency -isnot [System.Collections.IDictionary] -or
            (@($actualFrequency.Keys | Sort-Object) -join ',') -cne
            (@($expectedFrequency.Keys | Sort-Object) -join ',')) {
            throw 'frequency shape invalid'
        }
        foreach ($key in $expectedFrequency.Keys) {
            if ([int]$actualFrequency[$key] -ne [int]$expectedFrequency[$key]) {
                throw 'frequency value invalid'
            }
        }

        $canonical = ($unique -join ',') + '|' + $sum
        $canonicalBytes = [Text.Encoding]::UTF8.GetBytes($canonical)
        try {
            $checksum = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($canonicalBytes)
            ).ToLowerInvariant()
        } finally {
            [Array]::Clear($canonicalBytes, 0, $canonicalBytes.Length)
        }
        if ([string]$actual.checksum_sha256 -cne $checksum) {
            throw 'checksum invalid'
        }
        return [pscustomobject]@{
            Pass = $true
            ExitCode = 0
            Method = $contract
            Sha256 = $verifierSha
        }
    } catch {
        return [pscustomobject]@{
            Pass = $false
            ExitCode = 1
            Method = $contract
            Sha256 = $verifierSha
        }
    }
}

function New-AiCliAgentAcceptanceReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Recovery,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)]$Verifier,
        [string]$TaskContractSha256 = ('sha256:' + ('0' * 64))
    )

    $failures = [Collections.Generic.List[string]]::new()
    $expectedModel = [string](Get-AiCliProperty $Plan 'model')
    $expectedProvider = [string](Get-AiCliProperty $Plan 'modelProvider')
    $runtimeIdentity = Get-AiCliProperty $Run 'runtimeIdentity'
    $permission = Get-AiCliProperty $runtimeIdentity 'permission'
    $limitUsage = Get-AiCliProperty $Run 'limitUsage'
    $safePermission = [ordered]@{
        approval_policy = [string](Get-AiCliProperty $permission 'approval_policy')
        requested_policy = [string](Get-AiCliProperty $permission 'requested_policy')
        sandbox_boundary = [string](Get-AiCliProperty $permission 'sandbox_boundary')
        sandbox_type = [string](Get-AiCliProperty $permission 'sandbox_type')
        permission_profile = [string](Get-AiCliProperty $permission 'permission_profile')
    }

    if ([string](Get-AiCliProperty $Recovery 'status') -cne 'completed') {
        $failures.Add('recovery.not_completed')
    }
    if ([int](Get-AiCliProperty $Run 'exitCode' 1) -ne 0) {
        $failures.Add('agent.exit_nonzero')
    }
    if ([bool](Get-AiCliProperty $Run 'timedOut' $false)) {
        $failures.Add('agent.timed_out')
    }
    if ([string](Get-AiCliProperty $runtimeIdentity 'model') -cne $expectedModel) {
        $failures.Add('runtime.model_mismatch')
    }
    if ([string](Get-AiCliProperty $runtimeIdentity 'model_provider') -cne
        $expectedProvider) {
        $failures.Add('runtime.provider_mismatch')
    }
    if ([string](Get-AiCliProperty $permission 'approval_policy') -cne 'never' -or
        [string](Get-AiCliProperty $permission 'requested_policy') -cne
            'danger-full-access' -or
        [string](Get-AiCliProperty $permission 'sandbox_boundary') -cne
            'codex-native' -or
        [string](Get-AiCliProperty $permission 'sandbox_type') -cne
            'dangerFullAccess' -or
        [string](Get-AiCliProperty $permission 'permission_profile') -cne
            ':danger-full-access') {
        $failures.Add('runtime.permission_mismatch')
    }
    $cliVersion = [string](Get-AiCliProperty $runtimeIdentity 'cli_version')
    $cliEvidence = Get-AiCliSemanticVersionEvidence -Text $cliVersion
    if (-not $cliEvidence -or $cliEvidence.Version -lt [version]'0.147.0') {
        $failures.Add('runtime.cli_version_unsupported')
    }
    if ([int](Get-AiCliProperty $limitUsage 'toolCalls' 0) -lt 1) {
        $failures.Add('agent.tool_activity_missing')
    }
    if (-not [bool](Get-AiCliProperty $limitUsage 'cleanupConfirmed' $false)) {
        $failures.Add('agent.cleanup_unconfirmed')
    }
    if (-not [bool](Get-AiCliProperty $Verifier 'Pass' $false) -or
        [int](Get-AiCliProperty $Verifier 'ExitCode' 1) -ne 0) {
        $failures.Add('acceptance.verifier_failed')
    }

    return [ordered]@{
        receipt_schema = 'aicli.agent.acceptance-receipt.v1'
        result = $(if ($failures.Count -eq 0) { 'pass' } else { 'fail' })
        failure_codes = @($failures)
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        product_version = Get-AiCliVersion
        requested = [ordered]@{
            model = $expectedModel
            provider_id = $expectedProvider
            wire = [string](Get-AiCliProperty $Plan 'wire')
            requested_effort = [string](Get-AiCliProperty $Plan 'effort')
            effective_effort = [string](Get-AiCliProperty $Plan 'effectiveEffort')
            approval_policy = 'never'
            sandbox_policy = 'danger-full-access'
        }
        effective = [ordered]@{
            model = [string](Get-AiCliProperty $runtimeIdentity 'model')
            provider_id = [string](Get-AiCliProperty $runtimeIdentity 'model_provider')
            cli_version = $cliVersion
            permission = $safePermission
        }
        recovery = [ordered]@{
            run_id = [string](Get-AiCliProperty $Recovery 'runId')
            status = [string](Get-AiCliProperty $Recovery 'status')
            attempts = [int](Get-AiCliProperty $Recovery 'attempts' 0)
            resume_count = [int](Get-AiCliProperty $Recovery 'resumeCount' 0)
            thread_id = [string](Get-AiCliProperty $Run 'threadId')
            session_id = [string](Get-AiCliProperty $Run 'sessionId')
        }
        agent = [ordered]@{
            exit_code = [int](Get-AiCliProperty $Run 'exitCode' 1)
            error_code = [string](Get-AiCliProperty $Run 'errorCode')
            usage = ConvertTo-AiCliSafeUsage (Get-AiCliProperty $Run 'usage')
            steps = [int](Get-AiCliProperty $limitUsage 'steps' 0)
            tool_calls = [int](Get-AiCliProperty $limitUsage 'toolCalls' 0)
            cleanup_confirmed = [bool](Get-AiCliProperty $limitUsage 'cleanupConfirmed' $false)
        }
        acceptance = [ordered]@{
            task_kind = 'nontrivial_agent'
            task_contract_sha256 = $TaskContractSha256
            verifier = [ordered]@{
                id = [string](Get-AiCliProperty $Verifier 'Method')
                sha256 = [string](Get-AiCliProperty $Verifier 'Sha256')
                passed = [bool](Get-AiCliProperty $Verifier 'Pass' $false)
                exit_code = [int](Get-AiCliProperty $Verifier 'ExitCode' 1)
            }
        }
    }
}

function Invoke-AiCliAgentLiveTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$MergedProfile,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)]$Checks
    )

    if ([string](Get-AiCliProperty $MergedProfile 'engine') -cne 'codex') {
        $Checks.Add((New-AiCliCheck -Id 'live.agent' -Status '不可用' `
            -Summary 'Agent acceptance requires a Codex Profile.')) | Out-Null
        return [pscustomobject]@{ Pass = $false; Receipt = $null }
    }

    $fixture = New-AiCliAgentAcceptanceFixture -WorkDir $WorkDir
    try {
        $created = New-AiCliRecoverableRun `
            -ProfileId ([string](Get-AiCliProperty $MergedProfile 'id')) `
            -ProjectPath $WorkDir -TaskText $fixture.Task `
            -TimeoutMs 7200000 -MaxCaptureChars 1000000 `
            -MaxSteps 200 -MaxToolCalls 1000 -MaxResumeAttempts 3
        $recovery = Invoke-AiCliRecoverableRun -RunId $created.runId `
            -InitialTaskText $fixture.Task
        $run = Get-AiCliProperty $recovery 'receipt'
        if ($null -eq $run) { $run = [ordered]@{} }
        $verifier = Test-AiCliAgentAcceptanceFixture -Fixture $fixture
        $receipt = New-AiCliAgentAcceptanceReceipt -Plan $Plan `
            -Recovery $recovery -Run $run -Verifier $verifier `
            -TaskContractSha256 $fixture.TaskContractSha256
        $pass = [string](Get-AiCliProperty $receipt 'result') -ceq 'pass'
        if ($pass) {
            $Checks.Add((New-AiCliCheck -Id 'live.agent' -Status '通过' `
                -Summary 'Codex Agent completed a durable tool task and the independent verifier passed.')) | Out-Null
        } else {
            $Checks.Add((New-AiCliCheck -Id 'live.agent' -Status '不可用' `
                -Summary 'Codex Agent acceptance failed closed.' `
                -Evidence (@($receipt.failure_codes) -join ','))) | Out-Null
        }
        return [pscustomobject]@{
            Pass = $pass
            Receipt = $receipt
            RuntimeIdentity = Get-AiCliProperty $run 'runtimeIdentity'
            RuntimeCliPath = [string](Get-AiCliProperty $run 'runtimeCliPath')
            Recovery = $recovery
        }
    } catch {
        $Checks.Add((New-AiCliCheck -Id 'live.agent' -Status '不可用' `
            -Summary (Protect-AiCliSecretText $_.Exception.Message))) | Out-Null
        return [pscustomobject]@{ Pass = $false; Receipt = $null }
    }
}
