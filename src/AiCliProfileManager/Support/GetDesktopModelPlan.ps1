#Requires -Version 7.2
[CmdletBinding()]
param(
    [string[]]$ProfileId = @(),
    [string[]]$CloudProfileId = @(
        'codex-qwen3-8-max-paygo',
        'codex-glm-5-3',
        'codex-glm-5-3-flash'
    ),
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
$setPath = & $module { Get-AiCliDataPath -Relative 'local-model-set.json' }
if ($ProfileId.Count -eq 0 -and -not $UpstreamOnly) {
    $set = Get-Content -LiteralPath $setPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $ProfileId = @($set.profiles | ForEach-Object { [string]$_ })
    if ($ProfileId.Count -eq 0) { throw 'Desktop local model set is empty.' }
}
$engineResolver = Join-Path $PSScriptRoot 'ResolveDesktopEngine.ps1'
$plan = & $module {
    param([string[]]$Ids, [string[]]$CloudIds, [bool]$OnlyUpstream, [string]$EngineResolver, [string]$SupportRoot)
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
            routeProviderId = 'aicli_desktop_local'
            kind = 'local'
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
    foreach ($id in $(if ($OnlyUpstream) { @() } else { $CloudIds })) {
        $profile = Get-AiCliResolvedProfile -Id $id
        if (-not [bool](Get-AiCliProperty $profile 'configured' $false)) { continue }
        $cloudProvider = [string](Get-AiCliProperty $profile 'provider')
        if ((Get-AiCliProperty $profile 'engine') -ne 'codex' -or
            $cloudProvider -notin @('qwen','glm') -or
            (Get-AiCliProperty $profile 'transport') -ne 'responses') {
            throw "Desktop cloud model profile must use an approved Codex Responses provider: $id"
        }
        if ((Get-AiCliProperty (Get-AiCliProperty $profile 'auth') 'type') -ne 'api-key' -or
            -not [bool](Get-AiCliProperty $profile 'secretConfigured' $false)) {
            throw "Desktop cloud model profile has no configured API key: $id"
        }
        $endpoint = [string](Get-AiCliProperty $profile 'endpoint')
        if ($cloudProvider -eq 'qwen') {
            $endpoint = Resolve-AiCliQwenWorkspaceResponsesEndpoint -Endpoint $endpoint
        } else {
            Assert-AiCliEndpointSafe -Url $endpoint
            $uri = [Uri]$endpoint
            if ($uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or
                $uri.Host -cne 'open.bigmodel.cn' -or
                $uri.AbsolutePath.TrimEnd('/') -cne '/api/v1' -or
                $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
                throw "Desktop GLM profile must use the official China Responses endpoint: $id"
            }
            $endpoint = 'https://open.bigmodel.cn/api/v1'
        }
        $model = [string](Get-AiCliProperty (Get-AiCliProperty $profile 'models') 'primary')
        if (-not $seen.Add($model)) { continue }
        $catalogName = [string](Get-AiCliProperty $profile 'codexModelCatalog')
        if (-not $catalogName -or [IO.Path]::GetFileName($catalogName) -ne $catalogName) {
            throw "Desktop cloud model profile has no valid catalog: $id"
        }
        $catalogPath = Get-AiCliDataPath -Relative (Join-Path 'model-catalogs' $catalogName)
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        $matches = @($catalog.models | Where-Object slug -CEQ $model)
        if ($matches.Count -ne 1) { throw "Desktop cloud catalog does not identify the exact profile model: $id" }
        $info = $matches[0]
        $displayName = [string](Get-AiCliProperty $profile 'displayName')
        $info.display_name = ($displayName -replace '^Codex(?: CLI)?\s*\+\s*', '') -replace '\s*\uFF08[^\uFF09]*\uFF09\s*$', ''
        $providerId = [string](Get-AiCliProperty $profile 'codexProviderId')
        if (-not $providerId) { throw "Desktop cloud model profile has no provider ID: $id" }
        $tokenScript = [IO.Path]::GetFullPath((Join-Path $SupportRoot 'GetDesktopProviderToken.ps1'))
        if (-not (Test-Path -LiteralPath $tokenScript -PathType Leaf)) {
            throw 'Desktop provider token helper is unavailable.'
        }
        $entries.Add([ordered]@{
            profileId = $id
            model = $model
            providerId = $providerId
            routeProviderId = $providerId
            kind = 'cloud'
            provider = [ordered]@{
                name = $displayName
                base_url = $endpoint
                wire_api = 'responses'
                requires_openai_auth = $false
                auth = [ordered]@{
                    command = 'pwsh'
                    args = @('-NoProfile', '-NonInteractive', '-File', $tokenScript, '-ProfileId', $id)
                    timeout_ms = 10000
                    refresh_interval_ms = 0
                }
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
} -Ids $ProfileId -CloudIds $CloudProfileId -OnlyUpstream $UpstreamOnly.IsPresent -EngineResolver $engineResolver -SupportRoot $PSScriptRoot
if (-not $UpstreamOnly) {
    # Ask the unmodified engine to refresh its online account catalog BEFORE
    # launching the desktop app-server. `debug models` can silently return the
    # bundled catalog when refresh fails, so its stdout is only a refresh trigger.
    # The native online cache (etag + fetched_at) is the authoritative result.
    # No official model IDs are embedded here.
    $officialModels = $null
    $cachePath = Join-Path $plan.codexHome 'models_cache.json'
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
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
            [void]$outputTask.GetAwaiter().GetResult()
            if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { continue }
            try {
                $cacheFile = Get-Item -LiteralPath $cachePath -Force
                if ($cacheFile.Length -lt 2 -or $cacheFile.Length -gt 16777216) { continue }
                $cache = Get-Content -LiteralPath $cachePath -Raw -Encoding utf8 |
                    ConvertFrom-Json -Depth 100 -DateKind String
                $fetchedAt = [DateTimeOffset]::Parse(
                    [string]$cache.fetched_at,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
                if ([string]::IsNullOrWhiteSpace([string]$cache.etag) -or
                    [string]::IsNullOrWhiteSpace([string]$cache.client_version) -or
                    $fetchedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or
                    @($cache.models).Count -eq 0) {
                    continue
                }
                $officialModels = @($cache.models)
                break
            } catch { continue }
        } finally { $process.Dispose() }
        if ($attempt -lt 2) { Start-Sleep -Milliseconds 150 }
    }
    if ($null -eq $officialModels) {
        throw 'The original Codex engine did not provide a verifiable online model catalog cache.'
    }
    $plan['upstreamModels'] = $officialModels
}
$plan | ConvertTo-Json -Depth 100 -Compress
