#Requires -Version 7.2
[CmdletBinding()]
param(
    [string] $BrokerOrigin = 'http://127.0.0.1:32100',
    [string] $BaseTag = 'qwen3.8:27b',
    [string] $RuntimeTag = 'aicli-qwen3.8-27b-256k:2026-09-15',
    [int] $ContextLength = 262144,
    [string] $OpenCodeProviderId = 'ollama5090d',
    [string] $OpenCodeModelId = 'qwen3.8-27b-256k',
    [string] $OpenCodeConfigPath = (Join-Path $HOME '.config\opencode\opencode.jsonc'),
    [bool] $RegisterOpenCodeDesktop = $true,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$expectedBaseDigest = '22130167c4c20e20c7b71454612966ca8e8171e9b3cc8ab6ce8aa6cbfec79643'
$expectedRuntimeDigest = '8040835723046ec2631b64b960d44414636ea5147942a7d68eaaa7ccdb492e20'
$expectedOrigin = 'http://127.0.0.1:32100'
if ($BrokerOrigin.TrimEnd('/') -cne $expectedOrigin) {
    throw 'qwen38_setup_broker_origin_invalid'
}
if ($BaseTag -cne 'qwen3.8:27b' -or $ContextLength -ne 262144) {
    throw 'qwen38_setup_artifact_contract_invalid'
}
if ($RuntimeTag -cne 'aicli-qwen3.8-27b-256k:2026-09-15') {
    throw 'qwen38_setup_runtime_tag_invalid'
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$modelfile = Join-Path $repoRoot 'data\ollama\qwen3.8-27b-256k.Modelfile'
$expectedModelfile = "FROM qwen3.8:27b`nPARAMETER num_ctx 262144`nPARAMETER draft_num_predict 0`nPARAMETER num_batch 128"
$actualModelfile = (Get-Content -LiteralPath $modelfile -Raw -Encoding utf8).
    Replace("`r`n", "`n").Trim()
if ($actualModelfile -cne $expectedModelfile) {
    throw 'qwen38_setup_modelfile_invalid'
}

$tags = Invoke-RestMethod -Uri "$expectedOrigin/api/tags" -Method Get -TimeoutSec 15
$base = @($tags.models | Where-Object { [string]$_.name -ceq $BaseTag })
if ($base.Count -ne 1 -or [string]$base[0].digest -cne $expectedBaseDigest) {
    throw 'qwen38_setup_base_artifact_mismatch'
}

$createBody = [ordered]@{
    model = $RuntimeTag
    from = $BaseTag
    parameters = [ordered]@{ num_ctx = $ContextLength; draft_num_predict = 0; num_batch = 128 }
    stream = $false
} | ConvertTo-Json -Depth 10 -Compress
$created = Invoke-RestMethod `
    -Uri "$expectedOrigin/api/create" `
    -Method Post `
    -ContentType 'application/json' `
    -Body $createBody `
    -TimeoutSec 120
if ([string]$created.status -cne 'success') {
    throw 'qwen38_setup_ollama_create_failed'
}

$showBody = @{ model = $RuntimeTag } | ConvertTo-Json -Compress
$shown = Invoke-RestMethod `
    -Uri "$expectedOrigin/api/show" `
    -Method Post `
    -ContentType 'application/json' `
    -Body $showBody `
    -TimeoutSec 30
$parameterLines = @(([string]$shown.parameters -split "`r?`n") | ForEach-Object { $_.Trim() })
if (@($parameterLines | Where-Object { $_ -match '^num_ctx\s+262144$' }).Count -ne 1) {
    throw 'qwen38_setup_runtime_context_not_pinned'
}

if (@($parameterLines | Where-Object { $_ -match '^draft_num_predict\s+0$' }).Count -ne 1) {
    throw 'qwen38_setup_runtime_draft_not_disabled'
}
if (@($parameterLines | Where-Object { $_ -match '^num_batch\s+128$' }).Count -ne 1) {
    throw 'qwen38_setup_runtime_batch_not_pinned'
}

$tagsAfter = Invoke-RestMethod -Uri "$expectedOrigin/api/tags" -Method Get -TimeoutSec 15
$runtime = @($tagsAfter.models | Where-Object { [string]$_.name -ceq $RuntimeTag })
if (
    $runtime.Count -ne 1 -or
    [string]$runtime[0].digest -cne $expectedRuntimeDigest
) {
    throw 'qwen38_setup_runtime_artifact_missing'
}

$backupPath = $null
if ($RegisterOpenCodeDesktop) {
    $configFull = [IO.Path]::GetFullPath($OpenCodeConfigPath)
    $configItem = Get-Item -LiteralPath $configFull -Force -ErrorAction Stop
    if (
        -not $configItem.PSIsContainer -and
        ($configItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    ) {
        $config = Get-Content -LiteralPath $configFull -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 50
    }
    else {
        throw 'qwen38_setup_opencode_config_unsafe'
    }
    $provider = $config.provider.PSObject.Properties[$OpenCodeProviderId]
    if ($null -eq $provider) {
        throw 'qwen38_setup_opencode_provider_missing'
    }
    $baseUrl = [string]$provider.Value.options.baseURL
    if ($baseUrl.TrimEnd('/') -cne "$expectedOrigin/v1") {
        throw 'qwen38_setup_opencode_provider_endpoint_mismatch'
    }
    if ($null -eq $provider.Value.models) {
        throw 'qwen38_setup_opencode_models_missing'
    }
    $model = [pscustomobject][ordered]@{
        name = 'Qwen3.8 27B MAX (256K)'
        id = $RuntimeTag
        reasoning = $true
        tool_call = $true
        temperature = $true
        limit = [pscustomobject][ordered]@{
            context = $ContextLength
            output = 32768
        }
        modalities = [pscustomobject][ordered]@{
            input = @('text', 'image')
            output = @('text')
        }
    }
    $provider.Value.models | Add-Member `
        -NotePropertyName $OpenCodeModelId `
        -NotePropertyValue $model `
        -Force

    $parent = Split-Path -Parent $configFull
    $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if (
        -not $parentItem.PSIsContainer -or
        ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw 'qwen38_setup_opencode_config_parent_unsafe'
    }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $backupPath = "$configFull.aicli-backup.$stamp"
    $tempPath = Join-Path $parent ('.opencode.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    Copy-Item -LiteralPath $configFull -Destination $backupPath -Force:$false
    try {
        $payload = ($config | ConvertTo-Json -Depth 50) + "`n"
        [IO.File]::WriteAllText($tempPath, $payload, $utf8NoBom)
        [IO.File]::Move($tempPath, $configFull, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

$result = [pscustomobject][ordered]@{
    schema = 'aicli.qwen38-27b-256k-setup-result.v1'
    status = 'pass'
    base_tag = $BaseTag
    base_manifest_digest = "sha256:$expectedBaseDigest"
    runtime_tag = $RuntimeTag
    runtime_manifest_digest = "sha256:$expectedRuntimeDigest"
    context_length = $ContextLength
    opencode_desktop_registered = $RegisterOpenCodeDesktop
    opencode_provider = if ($RegisterOpenCodeDesktop) { $OpenCodeProviderId } else { $null }
    opencode_model = if ($RegisterOpenCodeDesktop) { $OpenCodeModelId } else { $null }
    backup_path = $backupPath
}
if ($Json) {
    $result | ConvertTo-Json -Depth 10 -Compress
}
else {
    $result
}
