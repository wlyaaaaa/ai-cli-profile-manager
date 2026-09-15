#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ConsumerConfigPath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AiCliProfileManager\local-model-consumers.json'),
    [switch]$Apply,
    [switch]$Json
)
# The set selects models; existing provider manifests own their configuration.
# Machine-specific paths stay in the user's consumer configuration.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$utf8 = [Text.UTF8Encoding]::new($false)
$set = Get-Content (Join-Path $root 'data\local-model-set.json') -Raw | ConvertFrom-Json -AsHashtable
$consumers = Get-Content -LiteralPath $ConsumerConfigPath -Raw | ConvertFrom-Json -AsHashtable
$module = Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force -PassThru
$profiles = [ordered]@{}
$modelIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($id in $set.profiles) {
    if ($id -notmatch '^[a-z0-9-]+$' -or $profiles.Contains($id)) { throw 'Invalid or duplicate profile in local model set.' }
    $p = Get-Content (Join-Path $root "data\providers\$id.json") -Raw | ConvertFrom-Json -AsHashtable -Depth 60
    $m = [string]$p.models.primary
    if ($p.provider -ne 'ollama' -or $p.engine -ne 'codex' -or -not $modelIds.Add($m) -or
        $p.modelMetadata[$m].contextWindowTokens -ne 262144 -or -not $set.clients[$id]) { throw "Invalid local model declaration: $id" }
    $profiles[$id] = $p
}
if (-not $profiles.Count) { throw 'Select at least one local model.' }
$writes = [Collections.Generic.List[object]]::new()
function Plan-JsonWrite([string]$Path, $Value, [string]$Before) {
    $after = (($Value | ConvertTo-Json -Depth 80) -replace "`r`n", "`n") + "`n"
    $old = $Before | ConvertFrom-Json -AsHashtable -Depth 80 | ConvertTo-Json -Depth 80
    if (-not [System.Text.Json.Nodes.JsonNode]::DeepEquals([System.Text.Json.Nodes.JsonNode]::Parse($old),[System.Text.Json.Nodes.JsonNode]::Parse($after))) { $writes.Add(@{path=$Path;before=$Before;after=$after}) }
}
function Model-Name($Profile) { return ([string]$Profile.displayName -replace '^Codex(?: CLI)?\s*\+\s*', '') }

$opPath = [string]$consumers.openCodeConfig
$opText = [IO.File]::ReadAllText($opPath)
$op = $opText | ConvertFrom-Json -AsHashtable -Depth 80
$providerId = [string]$consumers.openCodeProvider
if (-not $op.provider[$providerId]) { throw 'Configured OpenCode local provider is missing.' }
$models = [ordered]@{}
foreach ($id in $profiles.Keys) {
    $p=$profiles[$id]; $m=[string]$p.models.primary
    $models[$set.clients[$id].opencodeKey] = [ordered]@{
        id=$m; name=(Model-Name $p); reasoning=$true; tool_call=[bool]$p.capabilities.tools; temperature=$true
        limit=@{context=$p.modelMetadata[$m].contextWindowTokens;output=$p.modelMetadata[$m].outputWindowTokens}
        modalities=@{
            input=@(if($p.capabilities.images){'text';'image'}else{'text'})
            output=@('text')
        }
    }
}
$op.provider[$providerId].models=$models
$endpoints=@($profiles.Values.endpoint | Sort-Object -Unique)
if ($endpoints.Count -ne 1) { throw 'Local models must share one Ollama endpoint.' }
$op.provider[$providerId].options.baseURL=$endpoints[0]
foreach ($selection in @('model','small_model')) {
    if ([string]$op[$selection] -like "$providerId/*" -and -not $models.Contains(([string]$op[$selection] -split '/',2)[1])) { $op[$selection]="$providerId/$(@($models.Keys)[0])" }
}
Plan-JsonWrite $opPath $op $opText

foreach ($registryPath in @($consumers.toolkitRegistry,$consumers.registryMirror) | Select-Object -Unique) {
    $before=[IO.File]::ReadAllText($registryPath)
    $registry=$before | ConvertFrom-Json -AsHashtable -Depth 80
    foreach ($id in $profiles.Keys) {
        $p=$profiles[$id]; $m=[string]$p.models.primary; $backendId=[string]$set.clients[$id].backendId
        $b=$registry.backends[$backendId]
        if (-not $b) { $b=@{adapter='ollama';cloud=$false;fallback_eligible=$false;default_reasoning_mode='on';agent_routes=@{}}; $registry.backends[$backendId]=$b }
        $b.model=$m; $b.display_name=Model-Name $p; $b.supports_vision=[bool]$p.capabilities.images
        $b.context_window_tokens=$p.modelMetadata[$m].contextWindowTokens
        $b.base_url_default=([string]$p.endpoint -replace '/v1/?$','')
        $b.ollama_options=@{num_ctx=$p.modelMetadata[$m].contextWindowTokens;num_predict=$p.modelMetadata[$m].outputWindowTokens}
        $artifact=$p.compatibility.ollamaArtifact
        # Runtime allocation/MTP settings already live in the Ollama tag;
        # Toolkit only accepts its public inference-option schema.
        foreach ($key in @($artifact.parameters.Keys)) {
            if ($key -notin @('num_batch','draft_num_predict')) { $b.ollama_options[$key]=$artifact.parameters[$key] }
        }
        if (-not $b.agent_routes) { $b.agent_routes=@{} }
        if (-not $b.agent_routes.'codex-cli') { $b.agent_routes.'codex-cli'=@{runner='codex-cli';profile=$id} }
        foreach ($route in $b.agent_routes.Values) {
            $route.model=$m
            if ($route.profile -eq $id) {
                $route.reasoning_effort=$p.defaultEffort
                $fingerprint=& $module { param($profileId) Get-AiCliProfileFingerprint -Profile (Get-AiCliResolvedProfile -Id $profileId) } $id
                if ($route.evidence.profile_fingerprint -ne $fingerprint) { $route.evidence=@{basis='configuration_sync_no_e2e';live_verified=$false;evidence_state='unverified';capability_acceptance_state='configured';profile_fingerprint=$fingerprint;provider_id=$p.codexProviderId;wire=$p.transport} }
                $route.evidence.model_digest=([string]$artifact.manifestDigest -replace '^sha256:','')
            }
        }
    }
    foreach ($entry in $set.clients.GetEnumerator()) {
        if ($entry.Key -notin $profiles.Keys) { $registry.backends.Remove([string]$entry.Value.backendId) }
    }
    if ($registry.backends.Contains('local-hard-reasoning')) {
        $mainId=[string]$set.clients[@($profiles.Keys)[0]].backendId
        foreach ($field in @('model','display_name','supports_vision','context_window_tokens','ollama_options','base_url_default')) { $registry.backends.'local-hard-reasoning'[$field]=$registry.backends[$mainId][$field] }
    }
    foreach ($alias in @($registry.aliases.Keys)) { if (-not $registry.backends.Contains([string]$registry.aliases[$alias])) { $registry.aliases.Remove($alias) } }
    if (-not $registry.backends.Contains([string]$registry.default_backend)) { $registry.default_backend=[string]$set.clients[@($profiles.Keys)[0]].backendId }
    Plan-JsonWrite $registryPath $registry $before
}

# Ollama's native catalog also drives its desktop; no inference is needed here.
$native=[string]$consumers.ollamaOrigin
$tags=Invoke-RestMethod "$native/api/tags" -TimeoutSec 15
$retired=@()
foreach ($id in $profiles.Keys) {
    $p=$profiles[$id]; $tag=[string]$p.models.primary
    $canonical=if($tag.Contains(':')){$tag}else{"${tag}:latest"}
    $match=@($tags.models | Where-Object name -CEQ $canonical)
    if ($match.Count -ne 1 -or ('sha256:'+$match[0].digest) -cne $p.compatibility.ollamaArtifact.manifestDigest) { throw "Prepare the declared Ollama artifact before syncing: $tag" }
}
# This configured Ollama instance is dedicated to the selected local model set.
# Validate every retained artifact above before removing extra/obsolete tags.
$expectedTags=@($modelIds | ForEach-Object { if($_.Contains(':')){$_}else{"${_}:latest"} })
$retired=@($tags.models.name | Where-Object { $_ -cnotin $expectedTags })
$desktop=$null
if ($Apply) {
    foreach ($write in $writes) { if ([IO.File]::ReadAllText($write.path) -cne $write.before) { throw 'Configuration changed during sync; rerun.' } }
    foreach ($write in $writes) {
        $temp=$write.path+'.aicli-sync.tmp'
        try { [IO.File]::WriteAllText($temp,$write.after,$utf8); [IO.File]::Move($temp,$write.path,$true) }
        finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force} }
        if ([IO.File]::ReadAllText($write.path) -cne $write.after) { throw 'Configuration readback failed.' }
    }
    & (Join-Path $PSScriptRoot 'Install.ps1') -Force -SkipShellIntegration | Out-Null
    $desktop=& (Join-Path $PSScriptRoot 'Set-CodexDesktopLocalModels.ps1') -Mode Status -Json | ConvertFrom-Json
    if ($desktop.status -eq 'enabled') { $desktop=& (Join-Path $PSScriptRoot 'Set-CodexDesktopLocalModels.ps1') -Mode Enable -Json | ConvertFrom-Json }
    foreach ($tag in $retired) { Invoke-RestMethod "$native/api/delete" -Method Delete -ContentType application/json -Body (@{model=$tag}|ConvertTo-Json) | Out-Null }
    $actual=@((Invoke-RestMethod "$native/api/tags" -TimeoutSec 15).models)
    if ($actual.Count -ne $expectedTags.Count -or @($actual.name | Where-Object { $_ -cnotin $expectedTags }).Count) { throw 'Ollama model set readback differs from the selected profiles.' }
    foreach ($p in $profiles.Values) {
        $tag=[string]$p.models.primary
        if (-not $tag.Contains(':')) { $tag+=':latest' }
        $match=@($actual | Where-Object name -CEQ $tag)
        if ($match.Count -ne 1 -or ('sha256:'+$match[0].digest) -cne $p.compatibility.ollamaArtifact.manifestDigest) { throw "Ollama artifact changed during sync: $tag" }
    }
}
$result=[ordered]@{schema='aicli.local-model-configuration-sync.v1';status=$(if($Apply){'applied'}else{'preview'});models=@($modelIds);changed_files=@($writes | ForEach-Object { $_.path });retired_models=$retired;desktop_restart_required=[bool]$desktop.restartRequired;live_acceptance='not_performed'}
if($Json){$result|ConvertTo-Json -Depth 10}else{[pscustomobject]$result}
