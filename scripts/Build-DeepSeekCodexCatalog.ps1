#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('flash', 'pro')][string]$Model = 'flash',
    [string]$SourceCatalog = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\model-catalogs\deepseek-v4-flash.json'),
    [string]$OutputCatalog
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($OutputCatalog)) {
    $OutputCatalog = Join-Path $repoRoot ("data\model-catalogs\deepseek-v4-{0}.json" -f $Model)
}

$source = Get-Content -LiteralPath $SourceCatalog -Raw -Encoding utf8 |
    ConvertFrom-Json -AsHashtable -Depth 100
if (@($source.models).Count -ne 1) {
    throw 'The source catalog must contain exactly one baseline model.'
}
$entry = $source.models[0] | ConvertTo-Json -Depth 100 |
    ConvertFrom-Json -AsHashtable -Depth 100

$definition = if ($Model -eq 'pro') {
    [ordered]@{
        slug = 'deepseek-v4-pro'
        display = 'DeepSeek-V4-Pro'
        description = 'Exact DeepSeek V4 Pro 0813 Responses model.'
    }
} else {
    [ordered]@{
        slug = 'deepseek-v4-flash'
        display = 'DeepSeek-V4-Flash'
        description = 'Exact DeepSeek V4 Flash 0731 Responses model.'
    }
}

$entry.slug = $definition.slug
$entry.display_name = $definition.display
$entry.description = $definition.description
$entry.context_window = 1048576
$entry.max_context_window = 1048576
$entry.effective_context_window_percent = 95
$entry.default_reasoning_level = 'high'
$entry.supported_reasoning_levels = @(
    [ordered]@{ effort = 'low'; description = 'Fast responses with lighter reasoning' },
    [ordered]@{ effort = 'high'; description = 'Extra high reasoning depth for complex problems' },
    [ordered]@{ effort = 'max'; description = 'Maximum reasoning depth for the hardest problems' }
)
$entry.minimal_client_version = '0.144.0'
$entry.priority = 1

$json = [ordered]@{ models = @($entry) } | ConvertTo-Json -Depth 100
$canonicalJson = ($json -replace "`r`n?", "`n") + "`n"
[IO.File]::WriteAllText(
    [IO.Path]::GetFullPath($OutputCatalog),
    $canonicalJson,
    [Text.UTF8Encoding]::new($false)
)
Write-Output ([IO.Path]::GetFullPath($OutputCatalog))
