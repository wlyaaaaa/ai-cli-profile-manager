function Get-AiCliAntigravityProbeProperty {
    param([AllowNull()][object]$Value, [string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return ,$Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}
# Pure P0 evidence checks. This file does not start a model, alter credentials,
# authorize tools, install a provider, or establish production readiness.
function Get-AiCliAntigravityEnvironmentRemovalNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)
    # Return names only. The existing ChildProcess RemoveEnvironment contract
    # applies them to the child; the parent and machine environment stay intact.
    foreach ($name in $Environment.Keys) {
        if ([string]$name -match '^(OPENAI|ANTHROPIC|CODEX|AICLI|GEMINI|GOOGLE|VERTEX|GCLOUD|CLOUDSDK|DEEPSEEK|DASHSCOPE|ZHIPU|GLM|QWEN|AGENTS)(_|$)') {
            [string]$name
        }
    }
}

function Test-AiCliAntigravityInitialization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Event,
        [ValidateSet('low','medium','high')][string]$Effort = 'high'
    )
    $reason = 'initialization_tool_free'
    $count = $null
    $expectedModel = 'gemini-3.8-flash-' + $Effort.ToLowerInvariant()
    $init = Get-AiCliAntigravityProbeProperty $Event 'init'
    $tools = Get-AiCliAntigravityProbeProperty $init 'tools'
    $id = [Guid]::Empty
    if ($null -eq $Event -or (Get-AiCliAntigravityProbeProperty $Event 'event') -cne 'init' -or $null -eq $init) {
        $reason = 'malformed_init'
    } elseif (-not [Guid]::TryParseExact([string](Get-AiCliAntigravityProbeProperty $Event 'conversation_id'), 'D', [ref]$id) -or $id -eq [Guid]::Empty) {
        $reason = 'invalid_conversation_identity'
    } elseif ((Get-AiCliAntigravityProbeProperty $init 'model') -cne $expectedModel) {
        $reason = 'model_identity_mismatch'
    } elseif ((Get-AiCliAntigravityProbeProperty $init 'agent') -cne 'aicli-codex-model-bridge') {
        $reason = 'agent_identity_mismatch'
    } elseif ((Get-AiCliAntigravityProbeProperty $init 'permission_mode') -cne 'request-review') {
        $reason = 'permission_mode_mismatch'
    } elseif ($null -eq $tools -or $tools -isnot [Array]) {
        $reason = 'tool_inventory_missing_or_invalid'
    } else {
        $count = $tools.Count
        if ($count -gt 0) { $reason = 'native_tools_present' }
    }
    [pscustomobject][ordered]@{
        schema = 'aicli.antigravity-probe-verdict.v1'
        stage = 'initialization'
        status = $(if ($reason -eq 'initialization_tool_free') { 'pass' } else { 'blocked' })
        reason = $reason
        tool_count = $count
        provider_readiness = 'not_evaluated'
    }
}

function Get-AiCliAntigravityUsageDelta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Current,
        [AllowNull()][System.Collections.IDictionary]$Previous
    )
    $fields = @('input_tokens','output_tokens','thinking_tokens','cache_read_tokens','total_tokens')
    $delta = [ordered]@{}
    foreach ($field in $fields) {
        if (-not $Current.Contains($field) -or ($null -ne $Previous -and -not $Previous.Contains($field))) {
            throw 'antigravity_usage_incomplete'
        }
        foreach ($sample in @($Current, $Previous)) {
            if ($null -eq $sample) { continue }
            $value = $sample[$field]
            if ($value -isnot [long] -and $value -isnot [int]) { throw 'antigravity_usage_invalid_counter' }
            if ($value -lt 0) { throw 'antigravity_usage_invalid_counter' }
        }
        $before = if ($null -eq $Previous) { 0L } else { [long]$Previous[$field] }
        if ([long]$Current[$field] -lt $before) { throw 'antigravity_usage_counter_regressed' }
        $delta[$field] = [long]$Current[$field] - $before
    }
    # Preserve the upstream counters' individual meanings. In particular,
    # thinking is not added again to output/total, and cache is not invented.
    [pscustomobject]$delta
}
