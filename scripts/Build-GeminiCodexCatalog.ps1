#Requires -Version 7.2
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path -Parent $PSScriptRoot),[string]$ModelSetPath,[string]$OutputRoot,[switch]$RuntimeBundle,[switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CodexUserCommunicationPolicy.ps1')
. (Join-Path $PSScriptRoot 'GeminiModelData.ps1')
if(-not$ModelSetPath){$ModelSetPath=Join-Path $SourceRoot 'data\gemini-models.json'}
if(-not$OutputRoot){$OutputRoot=Join-Path $SourceRoot 'data'}
$set=Read-AiCliGeminiModelSet -Path $ModelSetPath -SchemaPath (Join-Path $SourceRoot 'data\schemas\gemini-model-set.schema.json')
if($CheckOnly){[pscustomobject]@{valid=$true;models=@($set.models).Count;defaultModel=$set.defaultModel};return}
$template=Get-Content -LiteralPath (Join-Path $SourceRoot 'data\model-catalogs\glm-5.3-codex.json') -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable -Depth 100
$entries=[Collections.Generic.List[object]]::new();$outputs=[ordered]@{}
$boundary="`n`n# Gemini Codex adapter`nYou are Gemini running as the model behind the native Codex Harness. Use supplied Codex tools, never native Antigravity tools. Respect instructions, user intent and permissions. Use only supported input modalities. Public summaries go in visible_summary; the independent final answer goes in final_text. These summaries are public explanations, not hidden chain of thought. The current Codex request is the complete history authority; every backend call has a fresh conversation. Do not invent missing tool results or personal facts."
foreach($definition in $set.models){
    $model=($template.models[0]|ConvertTo-Json -Depth 100)|ConvertFrom-Json -AsHashtable -Depth 100
    $model.slug=$definition.menuModel;$model.display_name=$definition.displayName
    $model.description='Google Antigravity model-only adapter; native Codex tools/history. No fallback.'
    $model.default_reasoning_level=$definition.defaultEffort
    $model.supported_reasoning_levels=@($definition.efforts|ForEach-Object {@{effort=$_.effort;description=('Google '+$_.effort)}})
    $window=[long]$definition.contextWindow;$compact=[long][math]::Floor($window*90/100)
    $model.context_window=$window;$model.max_context_window=$window;$model.auto_compact_token_limit=$compact;$model.effective_context_window_percent=95
    $model.default_reasoning_summary='detailed';$model.supports_reasoning_summaries=$definition.supportsPublicSummary;$model.supports_reasoning_summary_parameter=$true
    $model.prefer_websockets=$false;$model.supports_search_tool=$false;$model.input_modalities=@($definition.inputModalities);$model.supports_parallel_tool_calls=$definition.supportsParallelToolCalls;$model.priority=50
    $model.base_instructions=Get-AiCliCodexUserCommunicationPolicy;$model.model_messages.instructions_template=Get-AiCliCodexUserCommunicationPolicy
    Set-AiCliCodexSummaryPresentationPolicy -ModelEntry $model -Provider glm
    $model.base_instructions+=$boundary;$model.model_messages.instructions_template+=$boundary
    $catalogName=$definition.id+'-codex.json'
    $manifest=[ordered]@{
        schemaVersion=1;id=$definition.profileId;displayName=('Codex + '+$definition.displayName);engine='codex';provider='google-antigravity';plan='google-ai-pro';region='global'
        transport='managed-proxy';wireApi='responses';endpoint=$null;codexProviderId='aicli_google_antigravity';codexModelCatalog=$catalogName;codexAutoCompactTokenLimit=$compact;codexAutoCompactTokenLimitScope='total'
        requiresSecret=$false;virtualReady=$false;auth=@{type='consumer-oauth';owner='official-antigravity'}
        models=@{primary=$definition.menuModel;small=$definition.menuModel;candidates=@($definition.menuModel)};defaultEffort=$definition.defaultEffort;effortLevels=@($definition.efforts|ForEach-Object effort);flexible=$false
        capabilities=@{tools=$true;contextStats=$true;images=$false;streaming=$true;effort=$true}
        compatibility=@{minCliVersion='0.154.0';modelVersion=$definition.menuModel;apiStatus='experimental';antigravityVersion=$set.cli.verifiedVersion;antigravitySha256=$set.cli.approvedSha256;contextCapacityBasis='model-set declaration; exact consumer-route acceptance is separate'}
        dataDestination='Google Antigravity via official consumer login; only Codex executes tools'
        notes='Experimental until the actual Desktop acceptance passes. Text-only, explicit model/effort mapping, no fallback.'
        sources=@('https://antigravity.google/docs/cli/headless/')
    }
    $outputs[('model-catalogs\'+$catalogName)]=@{models=@($model)}
    $outputs[('providers\'+$definition.profileId+'.json')]=$manifest
    $entries.Add([ordered]@{modelId=$definition.id;profileId=$definition.profileId;model=$definition.menuModel;defaultEffort=$definition.defaultEffort;contextWindow=$window;catalogModel=$model})
}
if($RuntimeBundle){
    $outputs=[ordered]@{
        'gemini-models.json'=$set
        'gemini-codex-catalog.json'=[ordered]@{schema='aicli.gemini-runtime-catalog.v1';defaultModel=$set.defaultModel;entries=@($entries);models=@($entries|ForEach-Object catalogModel)}
    }
}
# Prepare all data before mutating the destination. Caller stages a runtime
# bundle in a new release directory; the activation pointer moves separately.
[IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
foreach($key in $outputs.Keys){$path=Join-Path $OutputRoot $key;[IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null;$text=($outputs[$key]|ConvertTo-Json -Depth 100)+"`n";$temporary=$path+'.new-'+[guid]::NewGuid().ToString('N');try{[IO.File]::WriteAllText($temporary,$text,[Text.UTF8Encoding]::new($false));[IO.File]::Move($temporary,$path,$true)}finally{if(Test-Path $temporary){Remove-Item -LiteralPath $temporary -Force}}}
[pscustomobject]@{models=@($set.models).Count;defaultModel=$set.defaultModel;outputRoot=[IO.Path]::GetFullPath($OutputRoot);runtimeBundle=[bool]$RuntimeBundle;files=@($outputs.Keys)}