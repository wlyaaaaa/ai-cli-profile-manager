#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('flash', 'pro')][string]$Model = 'flash',
    [string]$SourceCatalog = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\model-catalogs\deepseek-v4-flash.json'),
    [string]$OutputCatalog
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'CodexUserCommunicationPolicy.ps1')
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
        description = 'Most capable frontier agentic coding model.'
        priority = 2
        officialCanonicalEntrySha256 = '16e8716359c27ade5f748e586e2b25886f5a7257ab4e9795436e11f9c4fdeedf'
    }
} else {
    [ordered]@{
        slug = 'deepseek-v4-flash'
        display = 'DeepSeek-V4-Flash'
        description = 'Latest frontier agentic coding model.'
        priority = 1
        officialCanonicalEntrySha256 = '8065e17700fe1a88bed911114c10f3e792eac48601aa765e067bec13eb0ae1d4'
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
$entry.priority = $definition.priority
$entry.base_instructions = Remove-AiCliCodexUserCommunicationPolicy -BaseInstructions ([string]$entry.base_instructions)

# Bind every non-policy field to the current official dual-model catalog from
# codex-deepseek-setup-en.ps1 (SHA-256 239c5e7e...54a36). AICLI's only
# deliberate catalog override is the default effort below: users chose max to
# mean the highest level that this model declares.
$officialEntryForHash = $entry | ConvertTo-Json -Depth 100 |
    ConvertFrom-Json -AsHashtable -Depth 100
# These fields are AICLI's Codex client policy, added after validating the
# vendor entry. They were previously checked as if they came from DeepSeek,
# which made the builder fail whenever the managed 90% compaction policy was
# present in its own source catalog.
$null = $officialEntryForHash.Remove('include_plugin_usage_instructions')
$null = $officialEntryForHash.Remove('include_apps_usage_instructions')
$officialEntryForHash.auto_compact_token_limit = $null
$canonicalOfficialEntry = $officialEntryForHash | ConvertTo-Json -Depth 100 -Compress
$canonicalBytes = [Text.Encoding]::UTF8.GetBytes($canonicalOfficialEntry)
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $canonicalHash = [Convert]::ToHexString($sha.ComputeHash($canonicalBytes)).ToLowerInvariant()
} finally {
    $sha.Dispose()
}
if ($canonicalHash -cne $definition.officialCanonicalEntrySha256) {
    throw "DeepSeek official catalog baseline mismatch for $($definition.slug): $canonicalHash"
}
$entry.default_reasoning_level = 'max'
$entry.include_plugin_usage_instructions = $false
$entry.include_apps_usage_instructions = $false
$entry.auto_compact_token_limit = 943718
$entry.base_instructions = Add-AiCliCodexUserCommunicationPolicy -BaseInstructions ([string]$entry.base_instructions)

$json = [ordered]@{ models = @($entry) } | ConvertTo-Json -Depth 100
$canonicalJson = ($json -replace "`r`n?", "`n") + "`n"
[IO.File]::WriteAllText(
    [IO.Path]::GetFullPath($OutputCatalog),
    $canonicalJson,
    [Text.UTF8Encoding]::new($false)
)
Write-Output ([IO.Path]::GetFullPath($OutputCatalog))
