#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SourceCatalog = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\model-catalogs\deepseek-v4-flash.json'),
    [ValidateSet('cloud', 'local')][string]$CatalogKind = 'cloud',
    [string]$OutputCatalog = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\model-catalogs\qwen3.7-codex.json')
)

$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath $SourceCatalog -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
if (@($source.models).Count -ne 1) {
    throw 'The source catalog must contain exactly one baseline model.'
}
$baseline = $source.models[0]
if ([string]::IsNullOrWhiteSpace([string]$baseline.base_instructions) -or $null -eq $baseline.model_messages) {
    throw 'The source catalog must provide non-empty Codex instructions and model messages.'
}

if ($CatalogKind -eq 'local') {
    $definitions = @(
        [ordered]@{ slug = 'qwen-main-v1'; display = 'Local Qwen Main'; description = 'AICLI managed local Qwen Responses model.' }
    )
    $contextWindow = 262144
    $defaultReasoningLevel = 'max'
    $inputModalities = @('text', 'image')
    $reasoningLevels = @(
        [ordered]@{ effort = 'low'; description = 'Fast responses with lighter reasoning' },
        [ordered]@{ effort = 'medium'; description = 'Balanced reasoning depth and latency' },
        [ordered]@{ effort = 'high'; description = 'Deeper reasoning for complex tasks' },
        [ordered]@{ effort = 'max'; description = 'Maximum supported reasoning depth' }
    )
} else {
    $definitions = @(
        [ordered]@{ slug = 'qwen3.7-max-2026-06-08'; display = 'Qwen3.7 Max 2026-06-08'; description = 'Pinned Qwen3.7 Max Responses model.' },
        [ordered]@{ slug = 'qwen3.7-plus-2026-05-26'; display = 'Qwen3.7 Plus 2026-05-26'; description = 'Pinned Qwen3.7 Plus Responses model.' },
        [ordered]@{ slug = 'qwen3.7-max'; display = 'Qwen3.7 Max'; description = 'Current Qwen3.7 Max Responses alias.' },
        [ordered]@{ slug = 'qwen3.7-plus'; display = 'Qwen3.7 Plus'; description = 'Current Qwen3.7 Plus Responses alias.' },
        [ordered]@{ slug = 'qwen3.7-max-2026-05-20'; display = 'Qwen3.7 Max 2026-05-20'; description = 'Pinned Qwen3.7 Max Responses model.' },
        [ordered]@{ slug = 'qwen3.7-max-preview'; display = 'Qwen3.7 Max Preview'; description = 'Qwen3.7 Max preview Responses alias.' }
    )
    $contextWindow = 983616
    $defaultReasoningLevel = 'high'
    $inputModalities = @('text')
    $reasoningLevels = @(
        [ordered]@{ effort = 'low'; description = 'Fast responses with lighter reasoning' },
        [ordered]@{ effort = 'medium'; description = 'Balanced reasoning depth and latency' },
        [ordered]@{ effort = 'high'; description = 'Deeper reasoning for complex tasks' },
        [ordered]@{ effort = 'xhigh'; description = 'Extended reasoning for difficult tasks' },
        [ordered]@{ effort = 'max'; description = 'Maximum supported reasoning depth' }
    )
}

$models = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $definitions.Count; $index++) {
    $definition = $definitions[$index]
    # Only the current Codex prompt payload is reused from the baseline. Every
    # capability and limit below is explicit so a future DeepSeek catalog
    # update cannot silently expand the Qwen contract.
    $model = [ordered]@{
        slug = $definition.slug
        prefer_websockets = $false
        support_verbosity = $false
        default_verbosity = $null
        apply_patch_tool_type = 'freeform'
        web_search_tool_type = 'text'
        input_modalities = @($inputModalities)
        supports_image_detail_original = $false
        truncation_policy = [ordered]@{ mode = 'bytes'; limit = 10000 }
        supports_parallel_tool_calls = $false
        tool_mode = $null
        multi_agent_version = 'v2'
        use_responses_lite = $false
        include_skills_usage_instructions = $false
        auto_review_model_override = $null
        context_window = $contextWindow
        max_context_window = $contextWindow
        effective_context_window_percent = 95
        auto_compact_token_limit = $null
        comp_hash = '3000'
        reasoning_summary_format = $null
        default_reasoning_summary = 'none'
        display_name = $definition.display
        description = $definition.description
        default_reasoning_level = $defaultReasoningLevel
        supported_reasoning_levels = @($reasoningLevels)
        shell_type = 'default'
        visibility = 'list'
        minimal_client_version = '0.144.0'
        supported_in_api = $true
        availability_nux = $null
        upgrade = $null
        priority = $index + 1
        model_messages = $baseline.model_messages
        experimental_supported_tools = @()
        supports_search_tool = $true
        default_service_tier = $null
        supports_reasoning_summaries = $false
        base_instructions = [string]$baseline.base_instructions
    }
    $models.Add($model) | Out-Null
}

$json = [ordered]@{ models = @($models) } | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputCatalog), $json + "`n", [Text.UTF8Encoding]::new($false))
Write-Output ([IO.Path]::GetFullPath($OutputCatalog))
