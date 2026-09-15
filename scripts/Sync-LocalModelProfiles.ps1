#Requires -Version 7.2
<#
.SYNOPSIS
  Preview or synchronize local model declarations from the existing Codex manifest.
.DESCRIPTION
  Prepare codex-ollama-main and its catalog first. This maintenance command updates
  the three other main profiles only; exact model profiles and review stay intact.
  It does not install, download, start a model, or grant live acceptance.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidatePattern('^[a-z0-9-]+$')]
    [string] $SourceProfileId = 'codex-ollama-main',
    [switch] $Apply,
    [switch] $Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$providerRoot = Join-Path $RepoRoot 'data/providers'
$sourcePath = Join-Path $providerRoot "$SourceProfileId.json"
$sourceText = [IO.File]::ReadAllText($sourcePath)
$source = $sourceText | ConvertFrom-Json -AsHashtable -Depth 50
$model = [string]$source.models.primary
$metadata = $source.modelMetadata[$model]
$artifact = $source.compatibility.ollamaArtifact
if ($source.id -cne $SourceProfileId -or $source.engine -cne 'codex' -or
    $source.provider -cne 'ollama' -or $source.transport -cne 'responses' -or
    $source.auth.type -cne 'none' -or $source.flexible -ne $false -or
    $source.defaultEffort -cne 'max' -or 'max' -cnotin $source.effortLevels -or
    -not $model -or $source.models.small -cne $model -or
    @($source.models.candidates).Count -ne 1 -or $source.models.candidates[0] -cne $model) {
    throw "${SourceProfileId}: expected one exact local Responses model with max effort."
}
if ($metadata.contextWindowTokens -ne 262144 -or $metadata.outputWindowTokens -le 0 -or
    $metadata.outputWindowTokens -gt 262144 -or $artifact.numCtx -ne 262144 -or $artifact.tag -cne $model) {
    throw "${SourceProfileId}: model metadata and runtime artifact must agree at 262144 context."
}
foreach ($field in @('manifestDigest', 'configDigest', 'modelBlobDigest', 'parametersDigest')) {
    if ([string]$artifact[$field] -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "${SourceProfileId}: missing or invalid ollamaArtifact.$field"
    }
}
if (-not $source.capabilities.tools -or -not $source.capabilities.streaming) {
    throw "${SourceProfileId}: tools and streaming must be supported."
}
$endpoint = [uri]$source.endpoint
if ($endpoint.Scheme -cne 'http' -or -not $endpoint.IsLoopback -or
    $endpoint.AbsolutePath -cne '/v1' -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.UserInfo) {
    throw "${SourceProfileId}: expected a loopback broker endpoint ending in /v1."
}
if ($source.compatibility.localGpuBrokerSession.managementOrigin.TrimEnd('/') -cne $endpoint.GetLeftPart([UriPartial]::Authority)) {
    throw "${SourceProfileId}: endpoint differs from its managed broker origin."
}
$catalogName = [string]$source.codexModelCatalog
if ([IO.Path]::GetFileName($catalogName) -cne $catalogName -or -not $catalogName) {
    throw "${SourceProfileId}: expected a catalog filename."
}
$catalogPath = Join-Path $RepoRoot "data/model-catalogs/$catalogName"
$catalogText = [IO.File]::ReadAllText($catalogPath)
$catalog = $catalogText | ConvertFrom-Json -AsHashtable -Depth 50
if (@($catalog.models).Count -ne 1 -or $catalog.models[0].slug -cne $model -or
    $catalog.models[0].context_window -ne 262144 -or $catalog.models[0].max_context_window -ne 262144 -or
    $catalog.models[0].default_reasoning_level -cne 'max' -or
    'max' -cnotin @($catalog.models[0].supported_reasoning_levels.effort)) {
    throw "${SourceProfileId}: catalog model, 262144 context, or max effort differs from manifest."
}
if ([bool]$source.capabilities.images -ne ('image' -cin @($catalog.models[0].input_modalities))) {
    throw "${SourceProfileId}: catalog image capability differs from manifest."
}
# Exact-model profiles may share today's catalog. A new model needs a new catalog
# file so preparing it cannot silently rewrite those retained entry points.
foreach ($id in @('codex-ollama-qwen3-8-27b', 'codex-ollama-review')) {
    $retained = Get-Content -LiteralPath (Join-Path $providerRoot "$id.json") -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    if ($retained.codexModelCatalog -ceq $catalogName -and $retained.models.primary -cne $model) {
        throw "${id}: catalog is shared with another model; prepare a separate catalog for the new model."
    }
    if ($id -ceq 'codex-ollama-review' -and $retained.models.primary -ceq $model) {
        throw 'codex-ollama-review: keep a distinct model for independent cross-checks.'
    }
}
$modelName = ([string]$source.displayName -replace '^Codex(?: CLI)? \+ ', '').Trim()
if (-not $modelName -or $modelName -ceq $source.displayName -or
    $modelName -match '(?i)(^|\W)(main|local-default|review)(\W|$)|主用|辅助|复核') {
    throw "${SourceProfileId}: displayName must use Codex CLI + the actual model name."
}

$targets = [ordered]@{
    'claude-ollama-main' = @{ name = 'Claude Code'; engine = 'claude'; transport = 'anthropic-messages' }
    'opencode-ollama-main' = @{ name = 'OpenCode'; engine = 'opencode'; transport = 'openai-compatible' }
    'qwen-code-ollama-main' = @{ name = 'Qwen Code'; engine = 'qwen-code'; transport = 'openai-compatible' }
}
$changes = @()
foreach ($id in $targets.Keys) {
    $path = Join-Path $providerRoot "$id.json"
    $before = [IO.File]::ReadAllText($path)
    $target = $before | ConvertFrom-Json -AsHashtable -Depth 50
    if ($target.id -cne $id -or $target.provider -cne 'ollama' -or $target.auth.type -cne 'none' -or
        $target.engine -cne $targets[$id].engine -or $target.transport -cne $targets[$id].transport) {
        throw "${id}: expected its existing local Ollama profile."
    }
    $oldModel = [string]$target.models.primary
    $changedFields = @()
    $models = $target.models | ConvertTo-Json -Depth 50 -Compress | ConvertFrom-Json -AsHashtable -Depth 50
    $models.primary = $model
    $models.small = $model
    if ($models.Contains('candidates')) {
        if (@($models.candidates).Count -ne 1 -or $models.candidates[0] -cne $oldModel) {
            throw "${id}: review extra model candidates before synchronization."
        }
        $models.candidates = @($model)
    }
    if ($models.Contains('reserved') -and @($models.reserved).Count -gt 0) {
        throw "${id}: review reserved model identities before synchronization."
    }
    $updates = [ordered]@{
        displayName = "$($targets[$id].name) + $modelName"
        endpoint = if ($target.engine -ceq 'claude') { $endpoint.GetLeftPart([UriPartial]::Authority) } else { [string]$source.endpoint }
        models = $models
    }
    if ($target.Contains('modelMetadata')) {
        $clientMetadata = $target.modelMetadata[$oldModel]
        if ($target.modelMetadata.Count -ne 1 -or $null -eq $clientMetadata -or $clientMetadata.contextWindowTokens -ne 262144 -or
            $clientMetadata.outputWindowTokens -gt $metadata.outputWindowTokens) {
            throw "${id}: preserve 262144 context; explicitly review client output limits for this candidate."
        }
        $updates.modelMetadata = [ordered]@{ $model = $clientMetadata }
    }
    foreach ($key in $updates.Keys) {
        if (($target[$key] | ConvertTo-Json -Depth 50 -Compress) -cne ($updates[$key] | ConvertTo-Json -Depth 50 -Compress)) {
            $target[$key] = $updates[$key]
            $changedFields += $key
        }
    }
    if (($target.compatibility.ollamaArtifact | ConvertTo-Json -Depth 50 -Compress) -cne ($artifact | ConvertTo-Json -Depth 50 -Compress)) {
        $target.compatibility.ollamaArtifact = $artifact
        $changedFields += 'compatibility.ollamaArtifact'
    }
    foreach ($key in @('tools', 'streaming', 'images')) {
        if ($target.capabilities[$key] -ne $source.capabilities[$key]) {
            $target.capabilities[$key] = $source.capabilities[$key]
            $changedFields += "capabilities.$key"
        }
    }
    if ($changedFields.Count -gt 0) {
        # Current evidence is tied to the old profile; the regular live test owns acceptance.
        $target.Remove('verification')
        $changes += [pscustomobject]@{ profile = $id; from_model = $oldModel; to_model = $model; fields = $changedFields; path = $path; before = $before; after = ($target | ConvertTo-Json -Depth 50) + "`n" }
    }
}

# Validate everything before writing. Preserve original bytes on no-op; restore completed
# writes on a normal I/O failure. Git remains the rollback record, not a new backup store.
function Write-SyncFile {
    param([string] $Path, [string] $Text)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
$written = @()
if ($Apply) {
    try {
        if ([IO.File]::ReadAllText($sourcePath) -cne $sourceText -or [IO.File]::ReadAllText($catalogPath) -cne $catalogText) { throw 'Source changed during preview; rerun synchronization.' }
        foreach ($change in $changes) {
            if ([IO.File]::ReadAllText($change.path) -cne $change.before) { throw "$($change.profile): file changed during preview; rerun synchronization." }
        }
        foreach ($change in $changes) {
            Write-SyncFile $change.path $change.after
            $written += $change
            if ([IO.File]::ReadAllText($change.path) -cne $change.after) { throw "$($change.profile): write verification failed." }
        }
    } catch {
        $writeFailure = $_
        $restoreFailures = @()
        foreach ($change in $written) {
            try { Write-SyncFile $change.path $change.before }
            catch { $restoreFailures += "$($change.profile): $($_.Exception.Message)" }
        }
        if ($restoreFailures.Count) { throw "$($writeFailure.Exception.Message) Restore failures: $($restoreFailures -join '; ')" }
        throw $writeFailure
    }
}
$result = [ordered]@{
    status = if ($Apply) { 'applied' } else { 'preview' }
    model = $model
    display_name = $modelName
    context_window_tokens = 262144
    changes = @($changes | Select-Object profile, from_model, to_model, fields)
    manual_review = @($changes | Where-Object { $_.from_model -cne $_.to_model } | ForEach-Object { "$($_.profile): review retained sources and notes for the new model." })
    live_acceptance = 'not_performed'
}
if ($Json) { $result | ConvertTo-Json -Depth 15 } else { [pscustomobject]$result }
