function Resolve-AiCliModelSelection {
    param([string]$Model, [AllowNull()][string]$Effort)
    $provider = [Environment]::GetEnvironmentVariable('AICLI_MODEL_ROUTING_PROVIDER', 'Process')
    if (-not $provider) { $provider = [Environment]::GetEnvironmentVariable('AICLI_MODEL_ROUTING_PROVIDER', 'User') }
    if (-not $provider -or -not $Model) { return @{ model=$Model; effort=$Effort; replaced=$false; family=$null } }
    $registry = [Environment]::GetEnvironmentVariable('AICLI_MODEL_ROUTING_REGISTRY', 'Process')
    if (-not $registry) { $registry = [Environment]::GetEnvironmentVariable('AICLI_MODEL_ROUTING_REGISTRY', 'User') }
    & {
        . $provider
        $parameters = @{ Model=$Model; Effort=$Effort }
        if ($registry) { $parameters.Registry = Get-Content -LiteralPath $registry -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100 }
        $selection = Resolve-ModelSelection @parameters
        if (-not $selection.model) { throw 'Model routing provider returned no model.' }
        $null = Assert-AiCliModelId -Model ([string]$selection.model)
        return $selection
    }
}

function Update-AiCliProfileModelRouting {
    param($Profile)
    # Copy runtime data; never rewrite the stored Profile or the provider manifest.
    $provider = [Environment]::GetEnvironmentVariable('AICLI_MODEL_ROUTING_PROVIDER', 'Process')
    if (-not $provider) { $provider = [Environment]::GetEnvironmentVariable('AICLI_MODEL_ROUTING_PROVIDER', 'User') }
    if (-not $provider) { return $Profile }
    $changed = $false
    $copy = $Profile | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $models = Get-AiCliProperty $copy 'models'
    if (-not $models) { return $Profile }
    foreach ($key in @($models.Keys)) {
        if ($null -eq $models[$key]) { continue }
        $resolved = @(foreach ($model in @($models[$key])) {  $choice = Resolve-AiCliModelSelection -Model $model; if ($choice.replaced) { $changed=$true }; $choice.model  })
        $models[$key] = if ($models[$key] -is [array]) { ,$resolved } else { $resolved[0] }
    }
    if (-not $changed) { return $Profile }
    $old = [string](Get-AiCliProperty (Get-AiCliProperty $Profile 'models') 'primary')
    if ($old -cne $models.primary) {
        $copy['displayName'] = [string](Get-AiCliProperty $copy 'engine') + ' + ' + $models.primary
    }
    $metadata = Get-AiCliProperty $copy 'modelMetadata'
    if ($metadata) { foreach ($key in @($metadata.Keys)) {
        $target = (Resolve-AiCliModelSelection -Model $key).model
        if ($key -cne $target) { $metadata[$target] = $metadata[$key]; $null = $metadata.Remove($key) }
    } }
    return $copy
}

function Update-AiCliCatalogModelRouting {
    param($Catalog)
    foreach ($entry in @($Catalog.models)) {
        $old = [string]$entry.slug
        $selection = Resolve-AiCliModelSelection -Model $old -Effort ([string](Get-AiCliProperty $entry 'default_reasoning_level'))
        if ($selection.replaced) {
            $entry.slug = $selection.model
            $entry.display_name = $selection.model
        }
        if ($selection.family -and $selection.effort) { $entry.default_reasoning_level = $selection.effort }
    }
    return $Catalog
}

function Update-AiCliNativeModelRouting {
    param([string[]]$NativeArgs)
    $expect = $false
    foreach ($argument in $NativeArgs) {
        if ($expect) { (Resolve-AiCliModelSelection -Model $argument).model; $expect=$false; continue }
        if ($argument -in @('--model','-m','--fallback-model')) { $argument; $expect=$true; continue }
        if ($argument -cmatch '^(--(?:fallback-)?model=|-m=?)(.+)$') {
            $prefix=$Matches[1]; $value=$Matches[2]
            $prefix + (Resolve-AiCliModelSelection -Model $value).model
        } elseif ($argument -cmatch '^(model\s*=\s*["'']?)([^"''\s]+)(["'']?)$') {
            $prefix=$Matches[1]; $value=$Matches[2]; $suffix=$Matches[3]
            $prefix + (Resolve-AiCliModelSelection -Model $value).model + $suffix
        } else { $argument }
    }
}

function Get-AiCliModelMigration {
    param([string]$Model, [string]$Effort)
    $selection = Resolve-AiCliModelSelection -Model $Model -Effort $Effort
    if ($selection.replaced) {
        return @{ schema='aicli.model-migration.v1'; reason='migration_required'; previousModel=$Model; targetModel=$selection.model; targetEffort=$selection.effort; action='start_new_run'; originalThreadPreserved=$true }
    }
    return $null
}
