#Requires -Version 7.2
[CmdletBinding()]
param(
    [string[]]$ProfileId = @('codex-ollama-main', 'codex-ollama-review'),
    [string]$ModulePath = (Join-Path $PSScriptRoot '..\AiCliProfileManager.psd1'),
    [switch]$UpstreamOnly
)

# This is configuration discovery only. It neither starts a model nor changes
# the official Codex catalog, credentials, profile selection, or base config.
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
if (-not (Test-Path -LiteralPath $ModulePath) -and -not $PSBoundParameters.ContainsKey('ModulePath')) {
    $ModulePath = 'AiCliProfileManager'
}
$module = Import-Module -Name $ModulePath -Force -PassThru
$engineResolver = Join-Path $PSScriptRoot 'ResolveDesktopEngine.ps1'
$plan = & $module {
    param([string[]]$Ids, [bool]$OnlyUpstream, [string]$EngineResolver)
    $entries = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in $(if ($OnlyUpstream) { @() } else { $Ids })) {
        $profile = Get-AiCliResolvedProfile -Id $id
        if ((Get-AiCliProperty $profile 'engine') -ne 'codex' -or
            (Get-AiCliProperty $profile 'provider') -ne 'ollama') {
            throw "Desktop local model profile must use Codex and Ollama: $id"
        }
        if ((Get-AiCliProperty (Get-AiCliProperty $profile 'auth') 'type') -ne 'none') {
            throw "Desktop local model profile requires an unsupported authentication method: $id"
        }
        $endpoint = [string](Get-AiCliProperty $profile 'endpoint')
        Assert-AiCliEndpointSafe -Url $endpoint
        $uri = [Uri]$endpoint
        if (-not $uri.IsLoopback) { throw "Desktop local model endpoint must be loopback: $id" }
        $model = [string](Get-AiCliProperty (Get-AiCliProperty $profile 'models') 'primary')
        if (-not $seen.Add($model)) { continue }
        $catalogName = [string](Get-AiCliProperty $profile 'codexModelCatalog')
        if (-not $catalogName -or [IO.Path]::GetFileName($catalogName) -ne $catalogName) {
            throw "Desktop local model profile has no valid catalog: $id"
        }
        $catalogPath = Get-AiCliDataPath -Relative (Join-Path 'model-catalogs' $catalogName)
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        $matches = @($catalog.models | Where-Object slug -CEQ $model)
        if ($matches.Count -ne 1) { throw "Desktop catalog does not identify the exact profile model: $id" }
        $info = $matches[0]
        # Profile display names are maintained with the model identity. Older
        # catalogs can still have internal labels such as "Local Qwen Main".
        $displayName = [string](Get-AiCliProperty $profile 'displayName')
        $info.display_name = ($displayName -replace '^Codex(?: CLI)?\s*\+\s*', '') -replace '\s*\uFF08[^\uFF09]*\uFF09\s*$', ''
        $providerId = [string](Get-AiCliProperty $profile 'codexProviderId')
        if (-not $providerId) { throw "Desktop local model profile has no provider ID: $id" }
        $entries.Add([ordered]@{
            profileId = $id
            model = $model
            providerId = $providerId
            provider = [ordered]@{
                name = [string](Get-AiCliProperty $profile 'displayName')
                base_url = $endpoint
                wire_api = 'responses'
                requires_openai_auth = $false
            }
            catalogModel = $info
            catalogPath = [IO.Path]::GetFullPath($catalogPath)
            contextWindow = [long]$info.context_window
            defaultEffort = [string]$info.default_reasoning_level
        })
    }
    if ($entries.Count -eq 0 -and -not $OnlyUpstream) { throw 'No desktop local models were selected.' }
    $codexHome = Get-AiCliCodexHome
    $legacyModels = @()
    if (-not $OnlyUpstream) {
        foreach ($saved in @(Get-ChildItem -LiteralPath $codexHome -Filter 'aicli-codex-ollama-*.config.toml' -File -ErrorAction SilentlyContinue)) {
            if ($saved.Length -gt 65536) { continue }
            $text = Get-Content -LiteralPath $saved.FullName -Raw -Encoding utf8
            if ($text -notmatch '(?m)^# aicli-managed=true\s*$') { continue }
            $oldModel = [regex]::Match($text, '(?m)^model\s*=\s*"([^"]+)"').Groups[1].Value
            if (-not $oldModel -or $seen.Contains($oldModel)) { continue }
            $sameFamily = @($entries | Where-Object { ($_.model -split ':')[0] -ceq ($oldModel -split ':')[0] })
            if ($sameFamily.Count -eq 1) {
                $legacyModels += [ordered]@{ model = $oldModel; canonicalModel = $sameFamily[0].model }
                [void]$seen.Add($oldModel)
            }
        }
    }
    . $EngineResolver
    $upstream = Resolve-AiCliDesktopEngine
    if ($null -eq $upstream) { throw 'The installed Codex engine could not be resolved.' }
    [ordered]@{
        schemaVersion = 1
        codexHome = $codexHome
        upstreamFileName = [string]$upstream.FileName
        upstreamPrefixArgs = @($upstream.PrefixArgs)
        models = @($entries)
        legacyModels = @($legacyModels)
    }
} -Ids $ProfileId -OnlyUpstream $UpstreamOnly.IsPresent -EngineResolver $engineResolver
if (-not $UpstreamOnly) {
    # Read the unmodified engine's current catalog BEFORE launching the desktop
    # app-server with its merged catalog. No official model IDs are embedded here.
    $officialModels = $null
    foreach ($bundled in @($false, $true)) {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $plan.upstreamFileName
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = $utf8
        $start.StandardErrorEncoding = $utf8
        foreach ($arg in $plan.upstreamPrefixArgs) { $start.ArgumentList.Add([string]$arg) }
        $start.ArgumentList.Add('debug')
        $start.ArgumentList.Add('models')
        if ($bundled) { $start.ArgumentList.Add('--bundled') }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $outputTask = $process.StandardOutput.ReadToEndAsync()
            $errorTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(15000)) {
                $process.Kill($true)
                [void]$process.WaitForExit(2000)
                continue
            }
            if ($process.ExitCode -ne 0) { continue }
            try { $catalog = $outputTask.GetAwaiter().GetResult() | ConvertFrom-Json -Depth 100 } catch { continue }
            if (@($catalog.models).Count -gt 0) { $officialModels = @($catalog.models); break }
        } finally { $process.Dispose() }
    }
    if ($null -eq $officialModels) { throw 'The original Codex engine did not provide a usable model catalog.' }
    $plan['upstreamModels'] = $officialModels
}
$plan | ConvertTo-Json -Depth 100 -Compress
