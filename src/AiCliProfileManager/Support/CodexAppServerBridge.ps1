#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Get-BridgeProperty {
    param(
        [object]$Value,
        [Parameter(Mandatory)][string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $Default
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function ConvertTo-BridgeInt64 {
    param([object]$Value)

    $isInteger = (
        $Value -is [sbyte] -or
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    )
    if (-not $isInteger) { return $null }
    try {
        if ([decimal]$Value -lt 0 -or [decimal]$Value -gt [long]::MaxValue) {
            return $null
        }
        return [long]$Value
    } catch {
        return $null
    }
}

function ConvertTo-BridgeInt32 {
    param([object]$Value)

    $isInteger = (
        $Value -is [sbyte] -or
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    )
    if (-not $isInteger) { return $null }
    try {
        if (
            [decimal]$Value -lt [int]::MinValue -or
            [decimal]$Value -gt [int]::MaxValue
        ) {
            return $null
        }
        return [int]$Value
    } catch {
        return $null
    }
}

function ConvertTo-BridgeCommandProjection {
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)]
        [ValidateSet('item/started', 'item/completed')]
        [string]$Method
    )

    $rawStatus = Get-BridgeProperty $Item 'status'
    if ($rawStatus -isnot [string]) {
        Throw-BridgeFailure -Code 'codex_appserver.command_status_invalid'
    }
    $allowedStatuses = if ($Method -eq 'item/started') {
        @('inProgress')
    } else {
        @('completed', 'failed', 'declined')
    }
    if ($rawStatus -notin $allowedStatuses) {
        Throw-BridgeFailure -Code 'codex_appserver.command_status_invalid'
    }

    $projection = [ordered]@{}
    $rawExitCode = Get-BridgeProperty $Item 'exitCode'
    if ($null -ne $rawExitCode) {
        $exitCode = ConvertTo-BridgeInt32 $rawExitCode
        if ($null -eq $exitCode) {
            Throw-BridgeFailure -Code 'codex_appserver.command_metric_invalid'
        }
        $projection['exit_code'] = $exitCode
    }
    $rawDurationMs = Get-BridgeProperty $Item 'durationMs'
    if ($null -ne $rawDurationMs) {
        $durationMs = ConvertTo-BridgeInt64 $rawDurationMs
        if ($null -eq $durationMs) {
            Throw-BridgeFailure -Code 'codex_appserver.command_metric_invalid'
        }
        $projection['duration_ms'] = $durationMs
    }

    $commandStatus = switch ($rawStatus) {
        'inProgress' { 'in_progress' }
        'completed' {
            if ($projection.Contains('exit_code') -and $projection['exit_code'] -ne 0) {
                'failed'
            } else {
                'succeeded'
            }
        }
        'failed' { 'failed' }
        'declined' { 'declined' }
    }
    $projection['command_status'] = $commandStatus
    return $projection
}

function ConvertTo-BridgeUsage {
    param([object]$TokenUsage)

    $safe = [ordered]@{}
    $last = Get-BridgeProperty $TokenUsage 'last'
    $total = Get-BridgeProperty $TokenUsage 'total'
    foreach ($mapping in @(
        @('input_tokens', 'inputTokens'),
        @('cached_input_tokens', 'cachedInputTokens'),
        @('output_tokens', 'outputTokens'),
        @('reasoning_output_tokens', 'reasoningOutputTokens')
    )) {
        $value = ConvertTo-BridgeInt64 (Get-BridgeProperty $total $mapping[1])
        if ($null -eq $value) { continue }
        if ($mapping[0] -eq 'cached_input_tokens' -and $value -eq 0) {
            continue
        }
        $safe[$mapping[0]] = $value
    }
    $currentContext = ConvertTo-BridgeInt64 (
        Get-BridgeProperty $last 'totalTokens'
    )
    if ($null -ne $currentContext) {
        $safe['current_context_tokens'] = $currentContext
    }
    $upstreamTotal = ConvertTo-BridgeInt64 (
        Get-BridgeProperty $total 'totalTokens'
    )
    if (
        $null -ne $upstreamTotal -and
        (
            $safe.Contains('input_tokens') -or
            $safe.Contains('output_tokens') -or
            $safe.Contains('reasoning_output_tokens')
        )
    ) {
        $safe['total_tokens'] = $upstreamTotal
    }
    $contextWindow = ConvertTo-BridgeInt64 (
        Get-BridgeProperty $TokenUsage 'modelContextWindow'
    )
    if ($null -ne $contextWindow -and $contextWindow -gt 0) {
        $safe['context_window_tokens'] = $contextWindow
    }
    return $safe
}

function Write-BridgeJson {
    param([Parameter(Mandatory)][object]$Value)

    [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 30 -Compress))
    [Console]::Out.Flush()
}

function Publish-BridgeAgentMessageDeltaBuffer {
    param([Parameter(Mandatory)][string]$ItemId)

    if (-not $script:AgentMessageDeltaBuffers.ContainsKey($ItemId)) {
        return
    }
    $text = [string]$script:AgentMessageDeltaBuffers[$ItemId]
    $script:AgentMessageDeltaBuffers[$ItemId] = ''
    if ([string]::IsNullOrEmpty($text)) {
        return
    }
    Write-BridgeJson ([ordered]@{
        type = 'item.updated'
        item = [ordered]@{
            id = $ItemId
            type = 'agent_message'
            text = $text
        }
    })
}

function Flush-BridgeAgentMessageDeltaBuffers {
    foreach ($itemId in @($script:AgentMessageDeltaBuffers.Keys)) {
        Publish-BridgeAgentMessageDeltaBuffer -ItemId ([string]$itemId)
    }
}

function Test-BridgeUsageComplete {
    param([object]$Usage)

    return (
        $Usage -is [System.Collections.IDictionary] -and
        $Usage.Contains('current_context_tokens') -and
        $Usage.Contains('context_window_tokens')
    )
}

function Publish-BridgeUsage {
    param([Parameter(Mandatory)][object]$Usage)

    $script:LastUsage = $Usage
    Write-BridgeJson ([ordered]@{
        type = 'context.usage.updated'
        usage = $Usage
    })
}

function Throw-BridgeFailure {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'codex_appserver.setup_failed',
            'codex_appserver.initialize_failed',
            'codex_appserver.initialize_rejected',
            'codex_appserver.thread_start_failed',
            'codex_appserver.thread_start_rejected',
            'codex_appserver.turn_start_failed',
            'codex_appserver.turn_start_rejected',
            'codex_appserver.turn_stream_failed',
            'codex_appserver.stream_closed',
            'codex_appserver.protocol_line_invalid',
            'codex_appserver.response_id_invalid',
            'codex_appserver.response_after_turn_unexpected',
            'codex_appserver.version_unsupported',
            'codex_appserver.workspace_write_unavailable',
            'codex_appserver.runtime_identity_missing',
            'codex_appserver.runtime_identity_mismatch',
            'codex_appserver.notification_unknown',
            'codex_appserver.notification_scope_invalid',
            'codex_appserver.turn_status_invalid',
            'codex_appserver.context_usage_incomplete',
            'codex_appserver.item_lifecycle_invalid',
            'codex_appserver.item_identity_invalid',
            'codex_appserver.item_started_duplicate',
            'codex_appserver.item_started_unexpected',
            'codex_appserver.item_completed_without_start',
            'codex_appserver.item_type_changed',
            'codex_appserver.item_completed_duplicate',
            'codex_appserver.item_unfinished',
            'codex_appserver.command_status_invalid',
            'codex_appserver.command_metric_invalid',
            'codex_appserver.server_request_unsupported'
        )]
        [string]$Code
    )

    $script:FailureCode = $Code
    throw 'Codex app-server bridge validation failed.'
}

function Resolve-BridgeFailureCode {
    if (-not [string]::IsNullOrWhiteSpace($script:FailureCode)) {
        return $script:FailureCode
    }
    $resolved = switch ($script:BridgeStage) {
        'initialize' { 'codex_appserver.initialize_failed' }
        'thread_start' { 'codex_appserver.thread_start_failed' }
        'workspace_write_probe' { 'codex_appserver.workspace_write_unavailable' }
        'turn_start' { 'codex_appserver.turn_start_failed' }
        'turn_stream' { 'codex_appserver.turn_stream_failed' }
        default { 'codex_appserver.setup_failed' }
    }
    return [string]$resolved
}

function Send-BridgeMessage {
    param([Parameter(Mandatory)][object]$Value)

    $script:ServerProcess.StandardInput.WriteLine(
        ($Value | ConvertTo-Json -Depth 30 -Compress)
    )
    $script:ServerProcess.StandardInput.Flush()
}

function Receive-BridgeMessage {
    $line = $script:ServerProcess.StandardOutput.ReadLine()
    if ($null -eq $line) {
        Throw-BridgeFailure -Code 'codex_appserver.stream_closed'
    }
    if ([string]::IsNullOrWhiteSpace($line)) {
        return (Receive-BridgeMessage)
    }
    try {
        return ($line | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop)
    } catch {
        Throw-BridgeFailure -Code 'codex_appserver.protocol_line_invalid'
    }
}

function Test-BridgeVersionAtLeast {
    param(
        [string]$Actual,
        [string]$Minimum
    )

    $actualMatch = [regex]::Match(
        $Actual,
        '^(\d+\.\d+\.\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$'
    )
    $minimumMatch = [regex]::Match($Minimum, '^\d+\.\d+\.\d+$')
    if (-not $actualMatch.Success -or -not $minimumMatch.Success) { return $false }
    try {
        $actualVersion = [version]$actualMatch.Groups[1].Value
        $minimumVersion = [version]$minimumMatch.Value
        if ($actualVersion -gt $minimumVersion) { return $true }
        if ($actualVersion -lt $minimumVersion) { return $false }
        return [string]::IsNullOrWhiteSpace($actualMatch.Groups[2].Value)
    } catch {
        return $false
    }
}

function Test-BridgeCodex145Compatibility {
    param([string]$CliVersion)

    return $CliVersion -match '^0\.145\.\d+(?:[-+][0-9A-Za-z.-]+)?$'
}

function ConvertTo-BridgeItemType {
    param([Parameter(Mandatory)][string]$ItemType)

    $mapping = @{
        userMessage = 'user_message'
        hookPrompt = 'hook_prompt'
        agentMessage = 'agent_message'
        plan = 'todo_list'
        reasoning = 'reasoning'
        commandExecution = 'command_execution'
        fileChange = 'file_change'
        mcpToolCall = 'mcp_tool_call'
        dynamicToolCall = 'dynamic_tool_call'
        collabAgentToolCall = 'collab_tool_call'
        subAgentActivity = 'sub_agent_activity'
        webSearch = 'web_search'
        imageView = 'image_view'
        sleep = 'sleep'
        imageGeneration = 'image_generation'
        enteredReviewMode = 'entered_review_mode'
        exitedReviewMode = 'exited_review_mode'
        contextCompaction = 'context_compaction'
    }
    if (-not $mapping.ContainsKey($ItemType)) {
        Throw-BridgeFailure -Code 'codex_appserver.item_lifecycle_invalid'
    }
    return [string]$mapping[$ItemType]
}

$script:AllowedNotificationMethods = @(
    'error',
    'thread/started',
    'thread/status/changed',
    'thread/archived',
    'thread/deleted',
    'thread/unarchived',
    'thread/closed',
    'skills/changed',
    'thread/name/updated',
    'thread/goal/updated',
    'thread/goal/cleared',
    'thread/environment/connected',
    'thread/environment/disconnected',
    'thread/settings/updated',
    'thread/tokenUsage/updated',
    'turn/started',
    'hook/started',
    'turn/completed',
    'hook/completed',
    'turn/diff/updated',
    'turn/plan/updated',
    'item/started',
    'item/autoApprovalReview/started',
    'item/autoApprovalReview/completed',
    'item/completed',
    'item/agentMessage/delta',
    'item/plan/delta',
    'command/exec/outputDelta',
    'process/outputDelta',
    'process/exited',
    'item/commandExecution/outputDelta',
    'item/commandExecution/terminalInteraction',
    'item/fileChange/outputDelta',
    'item/fileChange/patchUpdated',
    'serverRequest/resolved',
    'item/mcpToolCall/progress',
    'mcpServer/oauthLogin/completed',
    'mcpServer/startupStatus/updated',
    'account/updated',
    'account/rateLimits/updated',
    'app/list/updated',
    'remoteControl/status/changed',
    'externalAgentConfig/import/progress',
    'externalAgentConfig/import/completed',
    'fs/changed',
    'item/reasoning/summaryTextDelta',
    'item/reasoning/summaryPartAdded',
    'item/reasoning/textDelta',
    'thread/compacted',
    'model/rerouted',
    'model/verification',
    'turn/moderationMetadata',
    'model/safetyBuffering/updated',
    'warning',
    'guardianWarning',
    'deprecationNotice',
    'configWarning',
    'fuzzyFileSearch/sessionUpdated',
    'fuzzyFileSearch/sessionCompleted',
    'thread/realtime/started',
    'thread/realtime/itemAdded',
    'thread/realtime/transcript/delta',
    'thread/realtime/transcript/done',
    'thread/realtime/outputAudio/delta',
    'thread/realtime/sdp',
    'thread/realtime/error',
    'thread/realtime/closed',
    'windows/worldWritableWarning',
    'windowsSandbox/setupCompleted',
    'account/login/completed'
)

$script:RequiredThreadScopeNotificationMethods = @(
    'thread/status/changed',
    'thread/archived',
    'thread/deleted',
    'thread/unarchived',
    'thread/closed',
    'thread/name/updated',
    'thread/goal/cleared',
    'thread/environment/connected',
    'thread/environment/disconnected',
    'thread/settings/updated',
    'serverRequest/resolved',
    'guardianWarning',
    'thread/realtime/started',
    'thread/realtime/itemAdded',
    'thread/realtime/transcript/delta',
    'thread/realtime/transcript/done',
    'thread/realtime/outputAudio/delta',
    'thread/realtime/sdp',
    'thread/realtime/error',
    'thread/realtime/closed'
)

$script:RequiredTurnScopeNotificationMethods = @(
    'error',
    'turn/diff/updated',
    'turn/plan/updated',
    'item/autoApprovalReview/started',
    'item/autoApprovalReview/completed',
    'item/agentMessage/delta',
    'item/plan/delta',
    'item/commandExecution/outputDelta',
    'item/commandExecution/terminalInteraction',
    'item/fileChange/outputDelta',
    'item/fileChange/patchUpdated',
    'item/mcpToolCall/progress',
    'item/reasoning/summaryTextDelta',
    'item/reasoning/summaryPartAdded',
    'item/reasoning/textDelta',
    'thread/compacted',
    'model/rerouted',
    'model/verification',
    'turn/moderationMetadata',
    'model/safetyBuffering/updated'
)

$script:OptionalTurnScopeNotificationMethods = @(
    'hook/started',
    'hook/completed',
    'thread/goal/updated'
)

function Write-BridgeThreadStarted {
    param([object]$Thread)

    $threadId = [string](Get-BridgeProperty $Thread 'id')
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ThreadId) -and
        $script:ThreadId -ne $threadId) {
        Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
    }
    $script:ThreadId = $threadId
    if ($script:RequireRuntimeIdentity -and
        -not $script:RuntimeIdentityVerified) {
        return
    }
    if ($script:ThreadStartedWritten) { return }
    Write-BridgeJson ([ordered]@{
        type = 'thread.started'
        thread_id = $threadId
    })
    $script:ThreadStartedWritten = $true
}

function Assert-AndWriteBridgeRuntimeIdentity {
    param(
        [Parameter(Mandatory)][object]$ThreadResult,
        [Parameter(Mandatory)][string]$ExpectedModel,
        [Parameter(Mandatory)][string]$ExpectedModelProvider,
        [Parameter(Mandatory)][string]$CliVersion,
        [Parameter(Mandatory)][string]$SandboxBoundary,
        [Parameter(Mandatory)][string]$SandboxPolicy
    )

    $actualModelValue = Get-BridgeProperty $ThreadResult 'model'
    $actualProviderValue = Get-BridgeProperty $ThreadResult 'modelProvider'
    if ($actualModelValue -isnot [string] -or
        $actualProviderValue -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$actualModelValue) -or
        [string]::IsNullOrWhiteSpace([string]$actualProviderValue)) {
        Throw-BridgeFailure -Code 'codex_appserver.runtime_identity_missing'
    }
    $actualModel = [string]$actualModelValue
    $actualProvider = [string]$actualProviderValue
    if ($actualModel -cne $ExpectedModel -or
        $actualProvider -cne $ExpectedModelProvider) {
        Throw-BridgeFailure -Code 'codex_appserver.runtime_identity_mismatch'
    }

    $sandboxType = if ($SandboxBoundary -eq 'outer-codex') {
        'externalSandbox'
    } elseif ($SandboxPolicy -eq 'workspace-write') {
        'workspaceWrite'
    } else {
        'readOnly'
    }
    $script:RuntimeIdentityVerified = $true
    Write-BridgeJson ([ordered]@{
        type = 'runtime.identity'
        model = $actualModel
        model_provider = $actualProvider
        cli_version = $CliVersion
        permission = [ordered]@{
            approval_policy = 'never'
            requested_policy = $SandboxPolicy
            sandbox_boundary = $SandboxBoundary
            sandbox_type = $sandboxType
            permission_profile = ':' + $SandboxPolicy
        }
    })
}

function Assert-BridgeNotificationScope {
    param(
        [Parameter(Mandatory)][object]$Params,
        [switch]$RequireTurn
    )

    $threadId = [string](Get-BridgeProperty $Params 'threadId')
    if ([string]::IsNullOrWhiteSpace($script:ThreadId) -or
        $threadId -ne $script:ThreadId) {
        Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
    }
    if ($RequireTurn) {
        $turnId = [string](Get-BridgeProperty $Params 'turnId')
        if ([string]::IsNullOrWhiteSpace($script:TurnId)) {
            Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
        }
        if ($turnId -ne $script:TurnId) {
            Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
        }
    }
}

function Assert-BridgeOptionalTurnScope {
    param([Parameter(Mandatory)][object]$Params)

    Assert-BridgeNotificationScope -Params $Params
    $turnId = Get-BridgeProperty $Params 'turnId'
    if ($null -ne $turnId -and -not [string]::IsNullOrWhiteSpace([string]$turnId)) {
        if ([string]::IsNullOrWhiteSpace($script:TurnId) -or
            [string]$turnId -ne $script:TurnId) {
            Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
        }
    }
}

function Write-BridgeTurnStarted {
    param([Parameter(Mandatory)][object]$Turn)

    $turnId = [string](Get-BridgeProperty $Turn 'id')
    if ([string]::IsNullOrWhiteSpace($turnId)) {
        Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
    }
    if (-not [string]::IsNullOrWhiteSpace($script:TurnId) -and
        $script:TurnId -ne $turnId) {
        Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
    }
    $script:TurnId = $turnId
    if ($script:TurnStartedWritten) { return }
    Write-BridgeJson ([ordered]@{
        type = 'turn.started'
        turn_id = $turnId
    })
    $script:TurnStartedWritten = $true

    if (-not [string]::IsNullOrWhiteSpace($script:PendingUsageTurnId)) {
        if ($script:PendingUsageTurnId -ne $script:TurnId) {
            Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
        }
        if (Test-BridgeUsageComplete -Usage $script:PendingUsage) {
            Publish-BridgeUsage -Usage $script:PendingUsage
        }
        $script:PendingUsage = [ordered]@{}
        $script:PendingUsageTurnId = ''
    }
}

function Handle-BridgeNotification {
    param([Parameter(Mandatory)][object]$Message)

    $method = [string](Get-BridgeProperty $Message 'method')
    $script:CurrentNotificationMethod = $method
    if ($method -notin $script:AllowedNotificationMethods) {
        Throw-BridgeFailure -Code 'codex_appserver.notification_unknown'
    }
    $params = Get-BridgeProperty $Message 'params'
    if ($method -in $script:RequiredTurnScopeNotificationMethods) {
        Assert-BridgeNotificationScope -Params $params -RequireTurn
    } elseif ($method -in $script:RequiredThreadScopeNotificationMethods) {
        Assert-BridgeNotificationScope -Params $params
    } elseif ($method -in $script:OptionalTurnScopeNotificationMethods) {
        Assert-BridgeOptionalTurnScope -Params $params
    } elseif ($method -eq 'warning') {
        $warningThreadId = Get-BridgeProperty $params 'threadId'
        if ($null -ne $warningThreadId -and
            -not [string]::IsNullOrWhiteSpace([string]$warningThreadId)) {
            Assert-BridgeNotificationScope -Params $params
        }
    }

    switch ($method) {
        'error' {
            Write-BridgeJson ([ordered]@{ type = 'error' })
        }
        'thread/started' {
            Write-BridgeThreadStarted -Thread (Get-BridgeProperty $params 'thread')
        }
        'thread/tokenUsage/updated' {
            Assert-BridgeNotificationScope -Params $params
            $usageTurnId = [string](Get-BridgeProperty $params 'turnId')
            if ([string]::IsNullOrWhiteSpace($usageTurnId)) {
                Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
            }
            $usage = ConvertTo-BridgeUsage (
                Get-BridgeProperty $params 'tokenUsage'
            )
            if ([string]::IsNullOrWhiteSpace($script:TurnId)) {
                if (-not [string]::IsNullOrWhiteSpace($script:PendingUsageTurnId) -and
                    $script:PendingUsageTurnId -ne $usageTurnId) {
                    Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
                }
                $script:PendingUsageTurnId = $usageTurnId
                if (Test-BridgeUsageComplete -Usage $usage) {
                    $script:PendingUsage = $usage
                }
                break
            }
            if ($usageTurnId -ne $script:TurnId) {
                Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
            }
            if (Test-BridgeUsageComplete -Usage $usage) {
                Publish-BridgeUsage -Usage $usage
            }
        }
        'turn/started' {
            Assert-BridgeNotificationScope -Params $params
            $turn = Get-BridgeProperty $params 'turn'
            Write-BridgeTurnStarted -Turn $turn
        }
        'item/reasoning/summaryTextDelta' {
            $itemId = [string](Get-BridgeProperty $params 'itemId')
            $delta = Get-BridgeProperty $params 'delta'
            $rawSummaryIndex = Get-BridgeProperty $params 'summaryIndex'
            $summaryIndex = if ($null -eq $rawSummaryIndex) {
                0L
            } else {
                ConvertTo-BridgeInt64 $rawSummaryIndex
            }
            if (
                [string]::IsNullOrWhiteSpace($itemId) -or
                $itemId.Length -gt 512 -or
                $delta -isnot [string] -or
                $null -eq $summaryIndex -or
                $summaryIndex -lt 0 -or
                $summaryIndex -gt 10000
            ) {
                Throw-BridgeFailure -Code 'codex_appserver.item_identity_invalid'
            }
            if ($delta.Length -gt 8192) {
                Throw-BridgeFailure -Code 'codex_appserver.item_identity_invalid'
            }
            if (-not $script:ItemStates.ContainsKey($itemId)) {
                Throw-BridgeFailure -Code 'codex_appserver.item_lifecycle_invalid'
            }
            $itemState = $script:ItemStates[$itemId]
            if (
                [string]$itemState['type'] -ne 'reasoning' -or
                [string]$itemState['state'] -ne 'started'
            ) {
                Throw-BridgeFailure -Code 'codex_appserver.item_lifecycle_invalid'
            }
            if (-not [string]::IsNullOrEmpty([string]$delta)) {
                Write-BridgeJson ([ordered]@{
                    type = 'reasoning.summary.delta'
                    item_id = $itemId
                    summary_index = $summaryIndex
                    delta = [string]$delta
                })
            }
        }
        'item/agentMessage/delta' {
            $itemId = [string](Get-BridgeProperty $params 'itemId')
            $delta = Get-BridgeProperty $params 'delta'
            if ([string]::IsNullOrWhiteSpace($itemId) -or $delta -isnot [string]) {
                Throw-BridgeFailure -Code 'codex_appserver.item_identity_invalid'
            }
            if (-not $script:ItemStates.ContainsKey($itemId)) {
                Throw-BridgeFailure -Code 'codex_appserver.item_lifecycle_invalid'
            }
            $itemState = $script:ItemStates[$itemId]
            if ([string]$itemState['type'] -ne 'agentMessage' -or
                [string]$itemState['state'] -ne 'started') {
                Throw-BridgeFailure -Code 'codex_appserver.item_lifecycle_invalid'
            }
            $script:AgentMessageDeltaBuffers[$itemId] = (
                [string]$script:AgentMessageDeltaBuffers[$itemId] +
                [string]$delta
            )
            $buffer = [string]$script:AgentMessageDeltaBuffers[$itemId]
            if ($buffer.Length -ge 48 -or $buffer -match '[。！？；：\r\n]\s*$') {
                Publish-BridgeAgentMessageDeltaBuffer -ItemId $itemId
            }
        }
        { $_ -in @('item/started', 'item/completed') } {
            Assert-BridgeNotificationScope -Params $params -RequireTurn
            $item = Get-BridgeProperty $params 'item'
            $itemId = [string](Get-BridgeProperty $item 'id')
            $rawItemType = [string](Get-BridgeProperty $item 'type')
            if ([string]::IsNullOrWhiteSpace($itemId) -or
                [string]::IsNullOrWhiteSpace($rawItemType)) {
                Throw-BridgeFailure -Code 'codex_appserver.item_identity_invalid'
            }
            $itemType = ConvertTo-BridgeItemType -ItemType $rawItemType
            if ($method -eq 'item/started') {
                Flush-BridgeAgentMessageDeltaBuffers
            } else {
                Publish-BridgeAgentMessageDeltaBuffer -ItemId $itemId
            }
            $script:ItemEventSequence++
            if ($method -eq 'item/started') {
                if ($rawItemType -eq 'subAgentActivity') {
                    Throw-BridgeFailure -Code 'codex_appserver.item_started_unexpected'
                }
                if ($script:ItemStates.ContainsKey($itemId)) {
                    $itemState = $script:ItemStates[$itemId]
                    if ([string]$itemState['type'] -ne $rawItemType) {
                        Throw-BridgeFailure -Code 'codex_appserver.item_type_changed'
                    }
                    Throw-BridgeFailure -Code 'codex_appserver.item_started_duplicate'
                }
                $script:ItemStates[$itemId] = @{
                    type = $rawItemType
                    state = 'started'
                    started_order = $script:ItemEventSequence
                }
                if ($rawItemType -eq 'agentMessage') {
                    $script:AgentMessageDeltaBuffers[$itemId] = ''
                }
            } else {
                if ($rawItemType -eq 'subAgentActivity') {
                    if ($script:PointItemStates.ContainsKey($itemId)) {
                        Throw-BridgeFailure -Code 'codex_appserver.item_completed_duplicate'
                    }
                    $script:PointItemStates[$itemId] = $true
                } else {
                    if (-not $script:ItemStates.ContainsKey($itemId)) {
                        Throw-BridgeFailure -Code 'codex_appserver.item_completed_without_start'
                    }
                    $itemState = $script:ItemStates[$itemId]
                    if ([string]$itemState['type'] -ne $rawItemType) {
                        Throw-BridgeFailure -Code 'codex_appserver.item_type_changed'
                    }
                    if ([string]$itemState['state'] -eq 'completed') {
                        Throw-BridgeFailure -Code 'codex_appserver.item_completed_duplicate'
                    }
                    if ([string]$itemState['state'] -ne 'started') {
                        Throw-BridgeFailure -Code 'codex_appserver.item_lifecycle_invalid'
                    }
                    $itemState['state'] = 'completed'
                    $itemState['completed_order'] = $script:ItemEventSequence
                    if ($rawItemType -eq 'agentMessage') {
                        $completedText = Get-BridgeProperty $item 'text'
                        $itemState['public_text_present'] = (
                            $completedText -is [string] -and
                            -not [string]::IsNullOrWhiteSpace([string]$completedText)
                        )
                        [void]$script:AgentMessageDeltaBuffers.Remove($itemId)
                    }
                }
            }
            $safeItem = [ordered]@{
                id = $itemId
                type = $itemType
            }
            if ($method -eq 'item/completed' -and $itemType -eq 'agent_message') {
                $safeItem['text'] = [string](Get-BridgeProperty $item 'text')
            }
            if ($itemType -eq 'command_execution') {
                $commandProjection = ConvertTo-BridgeCommandProjection `
                    -Item $item `
                    -Method $method
                foreach ($name in @('command_status', 'exit_code', 'duration_ms')) {
                    if ($commandProjection.Contains($name)) {
                        $safeItem[$name] = $commandProjection[$name]
                    }
                }
            }
            Write-BridgeJson ([ordered]@{
                type = $method.Replace('/', '.')
                item = $safeItem
            })
        }
        'turn/completed' {
            Assert-BridgeNotificationScope -Params $params
            Flush-BridgeAgentMessageDeltaBuffers
            $turn = Get-BridgeProperty $params 'turn'
            $turnId = [string](Get-BridgeProperty $turn 'id')
            if ([string]::IsNullOrWhiteSpace($script:TurnId) -or
                $turnId -ne $script:TurnId) {
                Throw-BridgeFailure -Code 'codex_appserver.notification_scope_invalid'
            }
            $status = [string](Get-BridgeProperty $turn 'status')
            if ($status -notin @('completed', 'failed', 'interrupted')) {
                Throw-BridgeFailure -Code 'codex_appserver.turn_status_invalid'
            }
            if ($status -eq 'completed') {
                $unfinishedItems = @(
                    $script:ItemStates.GetEnumerator() |
                        Where-Object { [string]$_.Value['state'] -ne 'completed' }
                )
                # Codex 0.145 can leave each earlier public progress message in
                # `started` while still completing a later, non-empty final
                # agentMessage. Accept only that observed output-only pattern.
                # A future version, any non-message item, a message started
                # after the final, or a missing final remains a hard failure.
                $nonMessageUnfinished = @(
                    $unfinishedItems |
                        Where-Object {
                            [string]$_.Value['type'] -ne 'agentMessage'
                        }
                )
                if (
                    $unfinishedItems.Count -gt 0 -and
                    $nonMessageUnfinished.Count -eq 0 -and
                    (Test-BridgeCodex145Compatibility -CliVersion $script:CliVersion)
                ) {
                    $completedFinalMessages = @(
                        $script:ItemStates.GetEnumerator() |
                            Where-Object {
                                [string]$_.Value['type'] -eq 'agentMessage' -and
                                [string]$_.Value['state'] -eq 'completed' -and
                                [bool]$_.Value['public_text_present']
                            }
                    )
                    if ($completedFinalMessages.Count -gt 0) {
                        $latestFinalOrder = [long](
                            $completedFinalMessages |
                                ForEach-Object {
                                    [long]$_.Value['completed_order']
                                } |
                                Measure-Object -Maximum
                        ).Maximum
                        $notSuperseded = @(
                            $unfinishedItems |
                                Where-Object {
                                    [long]$_.Value['started_order'] -ge $latestFinalOrder
                                }
                        )
                        if ($notSuperseded.Count -eq 0) {
                            foreach ($unfinishedItem in $unfinishedItems) {
                                $unfinishedItem.Value['state'] = 'superseded'
                            }
                            $unfinishedItems = @()
                        }
                    }
                }
                if ($unfinishedItems.Count -gt 0) {
                    $unfinishedTypes = @(
                        $unfinishedItems |
                            ForEach-Object {
                                ConvertTo-BridgeItemType -ItemType (
                                    [string]$_.Value['type']
                                )
                            } |
                            Sort-Object -Unique
                    )
                    if ($unfinishedTypes.Count -eq 1) {
                        $script:FailureItemType = [string]$unfinishedTypes[0]
                    }
                    Throw-BridgeFailure -Code 'codex_appserver.item_unfinished'
                }
                if (-not (Test-BridgeUsageComplete -Usage $script:LastUsage)) {
                    Throw-BridgeFailure -Code 'codex_appserver.context_usage_incomplete'
                }
                Write-BridgeJson ([ordered]@{
                    type = 'turn.completed'
                    usage = $script:LastUsage
                })
                $script:TurnSucceeded = $true
            } else {
                Write-BridgeJson ([ordered]@{ type = 'turn.failed' })
                $script:TurnSucceeded = $false
            }
            $script:TurnTerminal = $true
        }
    }
}

function Wait-BridgeResponse {
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$RejectedCode = ''
    )

    while ($true) {
        $message = Receive-BridgeMessage
        $method = [string](Get-BridgeProperty $message 'method')
        if (-not [string]::IsNullOrWhiteSpace($method)) {
            $requestId = Get-BridgeProperty $message 'id'
            if ($null -ne $requestId) {
                Send-BridgeMessage ([ordered]@{
                    id = $requestId
                    error = [ordered]@{
                        code = -32601
                        message = 'AICLI machine bridge does not accept server requests.'
                    }
                })
                Throw-BridgeFailure -Code 'codex_appserver.server_request_unsupported'
            }
            Handle-BridgeNotification -Message $message
            continue
        }

        $responseId = Get-BridgeProperty $message 'id'
        if ($null -eq $responseId -or [int]$responseId -ne $Id) {
            Throw-BridgeFailure -Code 'codex_appserver.response_id_invalid'
        }
        if ($null -ne (Get-BridgeProperty $message 'error')) {
            $resolvedRejectedCode = if (-not [string]::IsNullOrWhiteSpace($RejectedCode)) {
                $RejectedCode
            } else {
                switch ($Id) {
                    1 { 'codex_appserver.initialize_rejected' }
                    2 { 'codex_appserver.thread_start_rejected' }
                    3 { 'codex_appserver.turn_start_rejected' }
                    default { $null }
                }
            }
            if ($resolvedRejectedCode) {
                Throw-BridgeFailure -Code $resolvedRejectedCode
            }
            throw "Codex app-server request $Id failed."
        }
        return (Get-BridgeProperty $message 'result')
    }
}

function Test-BridgePathEqual {
    param(
        [string]$Left,
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or
        [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    try {
        $leftPath = [IO.Path]::TrimEndingDirectorySeparator(
            [IO.Path]::GetFullPath($Left)
        )
        $rightPath = [IO.Path]::TrimEndingDirectorySeparator(
            [IO.Path]::GetFullPath($Right)
        )
        return $leftPath.Equals($rightPath, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Assert-BridgeNativeWorkspaceWriteReceipt {
    param(
        [Parameter(Mandatory)][object]$ThreadResult,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$RequestedModel = ''
    )

    $effectiveCwd = [string](Get-BridgeProperty $ThreadResult 'cwd')
    $effectiveApprovalPolicy = [string](
        Get-BridgeProperty $ThreadResult 'approvalPolicy'
    )
    $effectiveSandbox = Get-BridgeProperty $ThreadResult 'sandbox'
    $effectiveSandboxType = [string](
        Get-BridgeProperty $effectiveSandbox 'type'
    )
    $effectiveNetworkAccess = Get-BridgeProperty $effectiveSandbox 'networkAccess'
    $effectiveModel = [string](Get-BridgeProperty $ThreadResult 'model')
    $activePermissionProfile = Get-BridgeProperty $ThreadResult 'activePermissionProfile'
    $activePermissionProfileId = [string](
        Get-BridgeProperty $activePermissionProfile 'id'
    )
    $runtimeWorkspaceRoots = @(
        Get-BridgeProperty $ThreadResult 'runtimeWorkspaceRoots'
    )
    $runtimeWorkspaceRootValid = (
        $runtimeWorkspaceRoots.Count -eq 1 -and
        (Test-BridgePathEqual `
            -Left ([string]$runtimeWorkspaceRoots[0]) `
            -Right $WorkingDirectory)
    )
    $networkContractValid = (
        $null -eq $effectiveNetworkAccess -or
        ($effectiveNetworkAccess -is [bool] -and -not $effectiveNetworkAccess)
    )
    $modelContractValid = (
        [string]::IsNullOrWhiteSpace($RequestedModel) -or
        $effectiveModel -eq $RequestedModel
    )
    if (-not (Test-BridgePathEqual -Left $effectiveCwd -Right $WorkingDirectory) -or
        $effectiveApprovalPolicy -ne 'never' -or
        $effectiveSandboxType -ne 'workspaceWrite' -or
        $activePermissionProfileId -ne ':workspace' -or
        -not $runtimeWorkspaceRootValid -or
        -not $networkContractValid -or
        -not $modelContractValid) {
        Throw-BridgeFailure -Code 'codex_appserver.workspace_write_unavailable'
    }
}

function Invoke-BridgeWorkspaceWriteProbe {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][object]$SandboxPolicy
    )

    $normalizedWorkingDirectory = [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath($WorkingDirectory)
    )
    $probeNonce = [guid]::NewGuid().ToString('N')
    $probePath = Join-Path $normalizedWorkingDirectory (
        '.aicli-write-probe-' + $probeNonce + '.tmp'
    )
    if (-not (Test-BridgePathEqual `
        -Left (Split-Path -Parent $probePath) `
        -Right $normalizedWorkingDirectory)) {
        Throw-BridgeFailure -Code 'codex_appserver.workspace_write_unavailable'
    }

    $probeScript = @'
$ErrorActionPreference = 'Stop'
$probePath = [Environment]::GetEnvironmentVariable('AICLI_WRITE_PROBE_PATH', 'Process')
$probeNonce = [Environment]::GetEnvironmentVariable('AICLI_WRITE_PROBE_NONCE', 'Process')
if ([string]::IsNullOrWhiteSpace($probePath) -or [string]::IsNullOrWhiteSpace($probeNonce)) {
    exit 9
}
try {
    [IO.File]::WriteAllText($probePath, $probeNonce, [Text.UTF8Encoding]::new($false))
    $observed = [IO.File]::ReadAllText($probePath, [Text.UTF8Encoding]::new($false))
    if ($observed -ne $probeNonce) { exit 10 }
    [IO.File]::Delete($probePath)
    if ([IO.File]::Exists($probePath)) { exit 11 }
    [Console]::Out.Write($probeNonce)
} finally {
    if ([IO.File]::Exists($probePath)) {
        [IO.File]::Delete($probePath)
    }
}
'@

    try {
        $powerShellPath = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
            Throw-BridgeFailure -Code 'codex_appserver.workspace_write_unavailable'
        }
        Send-BridgeMessage ([ordered]@{
            id = 30
            method = 'command/exec'
            params = [ordered]@{
                command = @(
                    $powerShellPath,
                    '-NoLogo',
                    '-NoProfile',
                    '-NonInteractive',
                    '-Command',
                    $probeScript
                )
                cwd = $normalizedWorkingDirectory
                env = [ordered]@{
                    AICLI_WRITE_PROBE_PATH = $probePath
                    AICLI_WRITE_PROBE_NONCE = $probeNonce
                }
                sandboxPolicy = $SandboxPolicy
                timeoutMs = 5000
                outputBytesCap = 4096
            }
        })
        $probeResult = Wait-BridgeResponse -Id 30 `
            -RejectedCode 'codex_appserver.workspace_write_unavailable'
        $exitCode = ConvertTo-BridgeInt32 (
            Get-BridgeProperty $probeResult 'exitCode'
        )
        $stdout = [string](Get-BridgeProperty $probeResult 'stdout')
        $stderr = [string](Get-BridgeProperty $probeResult 'stderr')
        if ($null -eq $exitCode -or
            $exitCode -ne 0 -or
            $stdout -ne $probeNonce -or
            -not [string]::IsNullOrEmpty($stderr) -or
            (Test-Path -LiteralPath $probePath)) {
            Throw-BridgeFailure -Code 'codex_appserver.workspace_write_unavailable'
        }
    } finally {
        if (Test-Path -LiteralPath $probePath -PathType Leaf) {
            try { Remove-Item -LiteralPath $probePath -Force -ErrorAction Stop } catch {}
        }
    }
}

$script:ServerProcess = $null
$script:ThreadId = ''
$script:TurnId = ''
$script:ThreadStartedWritten = $false
$script:TurnStartedWritten = $false
$script:TurnTerminal = $false
$script:TurnSucceeded = $false
$script:LastUsage = [ordered]@{}
$script:PendingUsage = [ordered]@{}
$script:PendingUsageTurnId = ''
$script:ItemStates = @{}
$script:PointItemStates = @{}
$script:AgentMessageDeltaBuffers = @{}
$script:ItemEventSequence = 0
$script:CliVersion = ''
$script:BridgeStage = 'setup'
$script:FailureCode = ''
$script:FailureItemType = ''
$script:CurrentNotificationMethod = ''
$script:RequireRuntimeIdentity = $false
$script:RuntimeIdentityVerified = $false
$serverErrorTask = $null
$serverStarted = $false
$bridgeExitCode = 1

try {
    if (-not [IO.Path]::IsPathRooted($ConfigPath) -or
        -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw 'Codex app-server bridge config must be an existing absolute file.'
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 |
        ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
    $serverFileName = [string](Get-BridgeProperty $config 'fileName')
    if (-not [IO.Path]::IsPathRooted($serverFileName) -or
        -not (Test-Path -LiteralPath $serverFileName -PathType Leaf)) {
        throw 'Codex app-server executable is unavailable.'
    }
    $workingDirectory = [string](Get-BridgeProperty $config 'workingDirectory')
    if (-not [IO.Path]::IsPathRooted($workingDirectory) -or
        -not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        throw 'Codex app-server working directory is unavailable.'
    }
    $sandboxBoundary = [string](
        Get-BridgeProperty $config 'sandboxBoundary' 'outer-codex'
    )
    $sandboxPolicy = [string](
        Get-BridgeProperty $config 'sandboxPolicy' 'read-only'
    )
    if ($sandboxBoundary -notin @('outer-codex', 'codex-native') -or
        $sandboxPolicy -notin @('read-only', 'workspace-write')) {
        throw 'Codex app-server bridge sandbox contract is invalid.'
    }
    $minimumCliVersion = [string](
        Get-BridgeProperty $config 'minimumCliVersion' '0.145.0'
    )
    if ($minimumCliVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Codex app-server bridge has no valid protocol baseline.'
    }
    $requireRuntimeIdentityValue = Get-BridgeProperty `
        $config 'requireRuntimeIdentity' $false
    if ($requireRuntimeIdentityValue -isnot [bool]) {
        throw 'Codex app-server runtime identity requirement is invalid.'
    }
    $script:RequireRuntimeIdentity = [bool]$requireRuntimeIdentityValue
    $expectedModel = [string](Get-BridgeProperty $config 'expectedModel')
    $expectedModelProvider = [string](
        Get-BridgeProperty $config 'expectedModelProvider'
    )
    if ($script:RequireRuntimeIdentity -and (
        $expectedModel -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,127}$' -or
        $expectedModelProvider -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
    )) {
        throw 'Codex app-server runtime identity expectation is invalid.'
    }
    $taskPipeName = [Environment]::GetEnvironmentVariable(
        'AICLI_CODEX_BRIDGE_TASK_PIPE',
        [EnvironmentVariableTarget]::Process
    )
    $task = if ([string]::IsNullOrWhiteSpace($taskPipeName)) {
        [Console]::In.ReadToEnd()
    } else {
        if ($taskPipeName -notmatch '^aicli-[a-f0-9]{32}$') {
            throw 'Codex app-server private task pipe name is invalid.'
        }
        $taskPipe = $null
        $taskReader = $null
        try {
            $taskPipe = [IO.Pipes.NamedPipeClientStream]::new(
                '.',
                $taskPipeName,
                [IO.Pipes.PipeDirection]::In,
                [IO.Pipes.PipeOptions]::Asynchronous
            )
            $taskPipe.Connect(10000)
            $taskReader = [IO.StreamReader]::new(
                $taskPipe,
                [Text.UTF8Encoding]::new($false),
                $false,
                4096,
                $true
            )
            $taskReader.ReadToEnd()
        } finally {
            try {
                [Environment]::SetEnvironmentVariable(
                    'AICLI_CODEX_BRIDGE_TASK_PIPE',
                    $null,
                    [EnvironmentVariableTarget]::Process
                )
            } catch {}
            if ($taskReader) { try { $taskReader.Dispose() } catch {} }
            if ($taskPipe) { try { $taskPipe.Dispose() } catch {} }
        }
    }
    if ([string]::IsNullOrWhiteSpace($task)) {
        throw 'Codex app-server task is empty.'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $serverFileName
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = $utf8NoBom
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom
    foreach ($argument in @((Get-BridgeProperty $config 'argumentList'))) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $script:ServerProcess = [Diagnostics.Process]::new()
    $script:ServerProcess.StartInfo = $startInfo
    if (-not $script:ServerProcess.Start()) {
        throw 'Codex app-server process did not start.'
    }
    $serverStarted = $true
    $serverErrorTask = $script:ServerProcess.StandardError.ReadToEndAsync()

    $script:BridgeStage = 'initialize'
    Send-BridgeMessage ([ordered]@{
        id = 1
        method = 'initialize'
        params = [ordered]@{
            clientInfo = [ordered]@{
                name = 'ai-cli-profile-manager'
                title = 'AI CLI Profile Manager'
                version = '0.3.3'
            }
            capabilities = [ordered]@{
                # Codex 0.145 materializes the :workspace profile only when
                # runtimeWorkspaceRoots is supplied through its experimental
                # schema. Without this capability the profile resolves with an
                # empty project-root set and rejects every model-turn write.
                experimentalApi = ($sandboxBoundary -eq 'codex-native')
            }
        }
    })
    $null = Wait-BridgeResponse -Id 1
    Send-BridgeMessage ([ordered]@{ method = 'initialized' })

    $script:BridgeStage = 'thread_start'
    $turnSandbox = if ($sandboxBoundary -eq 'outer-codex') {
        # The complete bridge/app-server process tree is already running under
        # `codex sandbox windows`. Declaring that boundary to app-server avoids
        # duplicate sandbox approval requests while `approvalPolicy=never`
        # remains fail-closed. Codex 0.145 names the disabled/restricted network
        # state `restricted`; the outer launcher additionally enforces
        # --sandbox-state-disable-network.
        [ordered]@{
            type = 'externalSandbox'
            networkAccess = 'restricted'
        }
    } elseif ($sandboxPolicy -eq 'workspace-write') {
        # Codex app-server 0.145 exposes the stable workspace contract through
        # the explicit sandboxPolicy object. Keep the same object on the
        # no-model write probe and the real turn so the probe proves the
        # boundary actually used by the model.
        [ordered]@{
            type = 'workspaceWrite'
            writableRoots = @($workingDirectory)
            networkAccess = $false
            excludeTmpdirEnvVar = $false
            excludeSlashTmp = $false
        }
    } else {
        [ordered]@{
            type = 'readOnly'
            networkAccess = $false
        }
    }
    $threadParams = [ordered]@{
        cwd = $workingDirectory
        ephemeral = $true
        approvalPolicy = 'never'
    }
    if ($sandboxBoundary -eq 'codex-native') {
        $threadParams['permissions'] = if ($sandboxPolicy -eq 'workspace-write') {
            ':workspace'
        } else {
            ':read-only'
        }
        $threadParams['runtimeWorkspaceRoots'] = @($workingDirectory)
    } else {
        $threadParams['sandbox'] = 'danger-full-access'
    }
    $model = if ($script:RequireRuntimeIdentity) {
        $expectedModel
    } else {
        [string](Get-BridgeProperty $config 'model')
    }
    if (-not [string]::IsNullOrWhiteSpace($model)) {
        $threadParams['model'] = $model
    }
    Send-BridgeMessage ([ordered]@{
        id = 2
        method = 'thread/start'
        params = $threadParams
    })
    $threadResult = Wait-BridgeResponse -Id 2
    $thread = Get-BridgeProperty $threadResult 'thread'
    if ($script:RequireRuntimeIdentity) {
        # Validate and bind the response thread id while output remains gated.
        Write-BridgeThreadStarted -Thread $thread
    }
    $cliVersion = [string](Get-BridgeProperty $thread 'cliVersion')
    if (-not (
        Test-BridgeVersionAtLeast -Actual $cliVersion -Minimum $minimumCliVersion
    )) {
        Throw-BridgeFailure -Code 'codex_appserver.version_unsupported'
    }
    $script:CliVersion = $cliVersion
    if ($sandboxBoundary -eq 'codex-native' -and
        $sandboxPolicy -eq 'workspace-write') {
        Assert-BridgeNativeWorkspaceWriteReceipt `
            -ThreadResult $threadResult `
            -WorkingDirectory $workingDirectory `
            -RequestedModel $model
        $script:BridgeStage = 'workspace_write_probe'
        Invoke-BridgeWorkspaceWriteProbe `
            -WorkingDirectory $workingDirectory `
            -SandboxPolicy $turnSandbox
    }
    if ($script:RequireRuntimeIdentity) {
        Assert-AndWriteBridgeRuntimeIdentity `
            -ThreadResult $threadResult `
            -ExpectedModel $expectedModel `
            -ExpectedModelProvider $expectedModelProvider `
            -CliVersion $cliVersion `
            -SandboxBoundary $sandboxBoundary `
            -SandboxPolicy $sandboxPolicy
    }
    Write-BridgeThreadStarted -Thread $thread

    $script:BridgeStage = 'turn_start'
    $turnParams = [ordered]@{
        threadId = $script:ThreadId
        input = @([ordered]@{
            type = 'text'
            text = $task
        })
        approvalPolicy = 'never'
    }
    if ($sandboxBoundary -eq 'codex-native') {
        $turnParams['permissions'] = if ($sandboxPolicy -eq 'workspace-write') {
            ':workspace'
        } else {
            ':read-only'
        }
        $turnParams['runtimeWorkspaceRoots'] = @($workingDirectory)
    } else {
        $turnParams['sandboxPolicy'] = $turnSandbox
    }
    Send-BridgeMessage ([ordered]@{
        id = 3
        method = 'turn/start'
        params = $turnParams
    })
    $turnResult = Wait-BridgeResponse -Id 3
    Write-BridgeTurnStarted -Turn (Get-BridgeProperty $turnResult 'turn')

    $script:BridgeStage = 'turn_stream'
    while (-not $script:TurnTerminal) {
        $message = Receive-BridgeMessage
        $method = [string](Get-BridgeProperty $message 'method')
        if ([string]::IsNullOrWhiteSpace($method)) {
            Throw-BridgeFailure -Code 'codex_appserver.response_after_turn_unexpected'
        }
        if ($null -ne (Get-BridgeProperty $message 'id')) {
            Send-BridgeMessage ([ordered]@{
                id = Get-BridgeProperty $message 'id'
                error = [ordered]@{
                    code = -32601
                    message = 'AICLI machine bridge does not accept server requests.'
                }
            })
            Throw-BridgeFailure -Code 'codex_appserver.server_request_unsupported'
        }
        Handle-BridgeNotification -Message $message
    }

    $bridgeExitCode = if ($script:TurnSucceeded) { 0 } else { 1 }
} catch {
    if (-not $script:TurnTerminal) {
        try {
            $failureEvent = [ordered]@{
                type = 'bridge.failed'
                error_code = (Resolve-BridgeFailureCode)
            }
            if (-not [string]::IsNullOrWhiteSpace($script:FailureItemType)) {
                $failureEvent['item_type'] = $script:FailureItemType
            }
            Write-BridgeJson $failureEvent
        } catch {}
    }
    try { [Console]::Error.WriteLine('Codex app-server bridge failed closed.') } catch {}
    $bridgeExitCode = 1
} finally {
    $serverCleanupConfirmed = -not $serverStarted
    if ($serverStarted -and $null -ne $script:ServerProcess) {
        # Give an already-terminating server one short scheduling window. If it
        # exits on its own, no live root remains from which descendants can be
        # authoritatively killed, so cleanup must fail closed. MachineRuntime
        # supplies the native codex.exe as this root rather than a short-lived
        # Node launcher.
        if ($script:TurnTerminal) {
            try { [Threading.Thread]::Sleep(100) } catch {}
        }
        try {
            if ($script:ServerProcess.HasExited) {
                $serverCleanupConfirmed = $false
            } else {
                $script:ServerProcess.Kill($true)
                $serverCleanupConfirmed = $script:ServerProcess.WaitForExit(3000)
            }
        } catch {
            $serverCleanupConfirmed = $false
        }
        if ($serverErrorTask) {
            try {
                if (-not $serverErrorTask.Wait(1000)) {
                    $serverCleanupConfirmed = $false
                } else {
                    [void]$serverErrorTask.GetAwaiter().GetResult()
                }
            } catch {
                $serverCleanupConfirmed = $false
            }
        }
        try { $script:ServerProcess.Dispose() } catch {}
    }
    if (-not $serverCleanupConfirmed) {
        $bridgeExitCode = 76
        try {
            Write-BridgeJson ([ordered]@{
                type = 'cleanup.failed'
                error_code = 'codex_appserver.cleanup_unconfirmed'
            })
        } catch {}
        # Keep the bridge root alive briefly so the parent can terminate and
        # confirm the complete tree rather than racing an orphaned descendant.
        try { [Threading.Thread]::Sleep(3000) } catch {}
    }
}

exit $bridgeExitCode
