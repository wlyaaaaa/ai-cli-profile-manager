#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SourceCatalog = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\model-catalogs\deepseek-v4-flash.json'),
    [ValidateSet('qwen38', 'qwen37max0608', 'local', 'localQwen38_27b')][string]$CatalogKind = 'qwen38',
    [string]$OutputCatalog = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\model-catalogs\qwen3.8-max-codex.json')
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

if ($CatalogKind -in @('local', 'localQwen38_27b')) {
    $definitions = @(
        [ordered]@{
            slug = $(if ($CatalogKind -eq 'localQwen38_27b') { 'qwen3.8-27b:256k' } else { 'qwen3.6-35b:256k' })
            display = $(if ($CatalogKind -eq 'localQwen38_27b') { 'Qwen3.8 27B' } else { 'Qwen3.6 35B' })
            description = $(if ($CatalogKind -eq 'localQwen38_27b') {
                'Exact local Qwen3.8-27B Responses model using the managed 256K runtime image over the official Ollama weights.'
            } else {
                'Local Qwen3.6 35B Responses model with 256K context.'
            })
        }
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
} elseif ($CatalogKind -in @('qwen38', 'qwen37max0608')) {
    $definitions = @(
        [ordered]@{
            slug = $(if ($CatalogKind -eq 'qwen38') { 'qwen3.8-max' } else { 'qwen3.7-max-2026-06-08' })
            display = $(if ($CatalogKind -eq 'qwen38') { 'Qwen3.8 Max' } else { 'Qwen3.7 Max 2026-06-08' })
            description = $(if ($CatalogKind -eq 'qwen38') {
                'Exact Qwen3.8 Max paygo Responses model.'
            } else {
                'Exact Qwen3.7 Max 2026-06-08 paygo Responses snapshot.'
            })
        }
    )
    $contextWindow = 983616
    $defaultReasoningLevel = 'xhigh'
    $inputModalities = @('text', 'image')
    $reasoningLevels = @(
        [ordered]@{ effort = 'low'; description = 'Fast responses with lighter reasoning' },
        [ordered]@{ effort = 'medium'; description = 'Balanced reasoning depth and latency' },
        [ordered]@{
            effort = 'xhigh'
            description = $(if ($CatalogKind -eq 'qwen38') {
                'Maximum native reasoning depth for Qwen3.8 Max'
            } else {
                'Maximum native reasoning depth for Qwen3.7 Max 2026-06-08'
            })
        }
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
        auto_compact_token_limit = $(if ($CatalogKind -in @('qwen38', 'qwen37max0608')) { 262144 } else { $null })
        comp_hash = '3000'
        reasoning_summary_format = $null
        default_reasoning_summary = 'none'
        display_name = $definition.display
        description = $definition.description
        default_reasoning_level = $defaultReasoningLevel
        supported_reasoning_levels = @($reasoningLevels)
        shell_type = 'default'
        visibility = 'list'
        minimal_client_version = $(if ($CatalogKind -eq 'localQwen38_27b') { '0.147.0' } else { '0.144.0' })
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
# Model catalogs are content-addressed. Normalize the serialization itself
# instead of inheriting the platform newline used by ConvertTo-Json.
$canonicalJson = ($json -replace "`r`n?", "`n") + "`n"
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputCatalog), $canonicalJson, [Text.UTF8Encoding]::new($false))
Write-Output ([IO.Path]::GetFullPath($OutputCatalog))
