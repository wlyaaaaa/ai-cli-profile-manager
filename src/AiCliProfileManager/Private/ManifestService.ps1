# Load and validate provider manifests (data only, no executable fields).

function Get-AiCliProviderManifestDir {
    return (Get-AiCliDataPath -Relative 'providers')
}

function Test-AiCliManifestSafety {
    param($Manifest)
    if ($Manifest -is [System.Collections.IDictionary] -or $Manifest -is [hashtable]) {
        foreach ($k in @('scriptBlock','powershell','invokeExpression','headersScript')) {
            if (Test-AiCliMapContains -Map $Manifest -Key $k) { throw "Manifest 禁止字段: $k" }
        }
    } elseif ($Manifest.PSObject.Properties['scriptBlock']) {
        throw 'Manifest 不允许包含可执行 scriptBlock'
    }
}

function Get-AiCliRetiredModelIds {
    # Family tombstones remain so stale Profiles and native model overrides fail
    # closed. The 06-08 snapshot is admitted only by the context-aware exact
    # Profile gate below; it remains forbidden as a free-form override.
    return @(
        'qwen3.7-max',
        'qwen3.7-max-2026-05-20',
        'qwen3.7-max-2026-06-08',
        'qwen3.7-max-preview',
        'qwen3.7-plus',
        'qwen3.7-plus-2026-05-26'
    )
}

function Test-AiCliRetiredModelId {
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return $false }
    $normalized = $ModelId.Trim().Trim('"', "'")
    $lower = $normalized.ToLowerInvariant()
    if ($lower -match '^qwen3(?:\.|[-_])?7(?:[-_.])?(?:max|plus)(?:$|[-._:/+@])') {
        return $true
    }
    if ($lower -match '^deepseek-v4(?:$|[-._:/+@])') {
        return $normalized -cnotin @('deepseek-v4-flash', 'deepseek-v4-pro')
    }
    return $false
}

function Test-AiCliQwen37Max0608ExactProfile {
    param([Parameter(Mandatory)]$Profile)

    $exactProfileId = 'codex-qwen3-7-max-paygo'
    $exactModelId = 'qwen3.7-max-2026-06-08'
    $profileId = [string](Get-AiCliProperty $Profile 'id')
    $templateId = [string](Get-AiCliProperty $Profile 'templateId')
    if (($templateId -and $templateId -cne $exactProfileId) -or
        (-not $templateId -and $profileId -cne $exactProfileId)) {
        return $false
    }

    $models = Get-AiCliProperty $Profile 'models'
    if ($null -eq $models -or
        [string](Get-AiCliProperty $models 'primary') -cne $exactModelId) {
        return $false
    }
    $selected = @(
        foreach ($field in @('primary','small','candidates','reserved')) {
            @((Get-AiCliProperty $models $field)) | Where-Object { $_ } | ForEach-Object { [string]$_ }
        }
    )
    return $selected.Count -gt 0 -and
        @($selected | Where-Object { $_ -cne $exactModelId }).Count -eq 0
}

function Assert-AiCliModelIsActive {
    param(
        [string]$ModelId,
        [string]$Context = '模型'
    )
    if ($ModelId -and $ModelId.Trim().Trim('"', "'") -match '^deepseek-v4(?:$|[-._:/+@])' -and
        (Test-AiCliRetiredModelId -ModelId $ModelId)) {
        throw "$Context 引用了已退役或未登记的 DeepSeek V4 模型 $ModelId；AICLI 只保留 API alias deepseek-v4-flash（DeepSeek-V4-Flash-0731）与 deepseek-v4-pro（DeepSeek-V4-Pro-0813）。"
    }
    if (Test-AiCliRetiredModelId -ModelId $ModelId) {
        throw "$Context 引用了已退役或脱离 exact Profile 的 Qwen3.7 云模型 $ModelId；仅 qwen3.7-max-2026-06-08 可通过 codex-qwen3-7-max-paygo 使用，且不会自动改投其他模型。"
    }
}

function Assert-AiCliProfileDoesNotUseRetiredModel {
    param(
        [Parameter(Mandatory)]$Profile,
        [string]$Context = 'Profile'
    )
    $allowExactQwen37 = Test-AiCliQwen37Max0608ExactProfile -Profile $Profile
    $exactQwen37Model = 'qwen3.7-max-2026-06-08'
    $models = Get-AiCliProperty $Profile 'models'
    if ($null -ne $models) {
        foreach ($field in @('primary','small','candidates','reserved')) {
            foreach ($modelId in @((Get-AiCliProperty $models $field)) | Where-Object { $_ }) {
                if ($allowExactQwen37 -and [string]$modelId -ceq $exactQwen37Model) { continue }
                Assert-AiCliModelIsActive -ModelId ([string]$modelId) -Context $Context
            }
        }
    }
    $metadata = Get-AiCliProperty $Profile 'modelMetadata'
    if ($metadata -is [System.Collections.IDictionary]) {
        foreach ($modelId in $metadata.Keys) {
            if ($allowExactQwen37 -and [string]$modelId -ceq $exactQwen37Model) { continue }
            Assert-AiCliModelIsActive -ModelId ([string]$modelId) -Context $Context
        }
    } elseif ($null -ne $metadata) {
        foreach ($property in $metadata.PSObject.Properties) {
            if ($allowExactQwen37 -and [string]$property.Name -ceq $exactQwen37Model) { continue }
            Assert-AiCliModelIsActive -ModelId ([string]$property.Name) -Context $Context
        }
    }
}

function Assert-AiCliManifestCore {
    param($M)
    if ($M -isnot [System.Collections.IDictionary]) { throw 'Manifest 根节点必须是 JSON object。' }
    $allowed = @(
        'schemaVersion','id','displayName','engine','provider','plan','region','transport','wireApi',
        'endpoint','models','auth','proxyRef','capabilities','compatibility','sources','codexProviderId',
        'interpreterProviderId','requiresSecret','virtualReady','dataDestination','notes','hidden','modelMetadata',
        'defaultEffort','effortLevels','effortMap','flexible','autoRun','modelPrefix','codexModelCatalog',
        'workspaceBaseUrlRequired','codexAutoCompactTokenLimit','codexAutoCompactTokenLimitScope'
    )
    foreach ($key in $M.Keys) {
        if ($allowed -notcontains [string]$key) { throw "Manifest 未知字段: $key ($($M.id))" }
    }
    $required = @(
        'schemaVersion','id','displayName','engine','provider','plan','transport','models',
        'auth','capabilities','sources','requiresSecret','virtualReady','dataDestination'
    )
    foreach ($r in $required) {
        if (-not (Test-AiCliMapHasKey -Map $M -Key $r)) { throw "Manifest 缺少字段: $r ($($M.id))" }
    }
    if ([int](Get-AiCliProperty $M 'schemaVersion') -ne 1) { throw "Manifest schemaVersion 仅支持 1 ($($M.id))" }
    $id = [string](Get-AiCliProperty $M 'id')
    $null = Assert-AiCliSafeIdentifier -Id $id -Kind 'Manifest ID'
    foreach ($field in @('provider','plan')) {
        $value = [string](Get-AiCliProperty $M $field)
        $null = Assert-AiCliSafeIdentifier -Id $value -Kind "Manifest $field"
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-AiCliProperty $M 'displayName'))) { throw "Manifest displayName 不能为空 ($id)" }
    if ([string]::IsNullOrWhiteSpace([string](Get-AiCliProperty $M 'dataDestination'))) { throw "Manifest dataDestination 不能为空 ($id)" }
    foreach ($field in @('requiresSecret','virtualReady','hidden','flexible','workspaceBaseUrlRequired')) {
        if (Test-AiCliMapHasKey -Map $M -Key $field) {
            $value = Get-AiCliProperty $M $field
            if ($value -isnot [bool]) { throw "Manifest $field 必须是 boolean ($id)" }
        }
    }
    $defaultEffort = [string](Get-AiCliProperty $M 'defaultEffort')
    $effortLevels = @()
    if (Test-AiCliMapHasKey -Map $M -Key 'effortLevels') {
        $rawEffortLevels = if ($M -is [System.Collections.IDictionary]) { $M['effortLevels'] } else { $M.effortLevels }
        if ($rawEffortLevels -is [string] -or
            $rawEffortLevels -is [System.Collections.IDictionary] -or
            $rawEffortLevels -isnot [System.Collections.IEnumerable]) {
            throw "Manifest effortLevels 必须是 array ($id)"
        }
        foreach ($effortLevel in @($rawEffortLevels)) {
            $normalizedEffort = [string]$effortLevel
            if ($normalizedEffort -cnotmatch '^[a-z][a-z0-9_-]{0,31}$') {
                throw "Manifest effortLevels 包含非法值 ($id)"
            }
            if ($effortLevels -ccontains $normalizedEffort) {
                throw "Manifest effortLevels 包含重复值: $normalizedEffort ($id)"
            }
            $effortLevels += $normalizedEffort
        }
        if ($effortLevels.Count -eq 0) { throw "Manifest effortLevels 不能为空 ($id)" }
        if ($defaultEffort -and $effortLevels -cnotcontains $defaultEffort) {
            throw "Manifest defaultEffort 必须进入 effortLevels ($id)"
        }
    }
    $effortMap = Get-AiCliProperty $M 'effortMap'
    if ($null -ne $effortMap) {
        if ($effortMap -isnot [System.Collections.IDictionary]) {
            throw "Manifest effortMap 必须是 object ($id)"
        }
        if ($effortLevels.Count -eq 0) {
            throw "Manifest effortMap 需要 effortLevels ($id)"
        }
        foreach ($requestedEffort in @($effortMap.Keys)) {
            $requestedEffort = [string]$requestedEffort
            $effectiveEffort = [string](Get-AiCliProperty $effortMap $requestedEffort)
            if ($effortLevels -cnotcontains $requestedEffort) {
                throw "Manifest effortMap 请求档位不在 effortLevels: $requestedEffort ($id)"
            }
            if ($effectiveEffort -cnotmatch '^[a-z][a-z0-9_-]{0,31}$') {
                throw "Manifest effortMap 有效档位非法: $requestedEffort ($id)"
            }
        }
    }
    $workspaceBaseUrlRequired = [bool](Get-AiCliProperty $M 'workspaceBaseUrlRequired' $false)
    if ($workspaceBaseUrlRequired) {
        if ([string](Get-AiCliProperty $M 'engine') -cne 'codex' -or
            [string](Get-AiCliProperty $M 'provider') -cne 'qwen' -or
            [string](Get-AiCliProperty $M 'plan') -cne 'paygo' -or
            [string](Get-AiCliProperty $M 'transport') -cne 'responses' -or
            -not [string]::IsNullOrWhiteSpace([string](Get-AiCliProperty $M 'endpoint'))) {
            throw "Manifest workspaceBaseUrlRequired 仅允许 endpoint=null 的 Qwen Codex paygo Responses Profile ($id)"
        }
    }
    $autoCompactLimit = Get-AiCliProperty $M 'codexAutoCompactTokenLimit'
    $autoCompactScope = [string](Get-AiCliProperty $M 'codexAutoCompactTokenLimitScope')
    if ($null -ne $autoCompactLimit) {
        if ([string](Get-AiCliProperty $M 'engine') -cne 'codex' -or
            ($autoCompactLimit -isnot [byte] -and $autoCompactLimit -isnot [int16] -and
             $autoCompactLimit -isnot [int32] -and $autoCompactLimit -isnot [int64]) -or
            [long]$autoCompactLimit -lt 32768 -or [long]$autoCompactLimit -gt 4194304) {
            throw "Manifest codexAutoCompactTokenLimit 非法 ($id)"
        }
        if ($autoCompactScope -notin @('total','body_after_prefix')) {
            throw "Manifest codexAutoCompactTokenLimitScope 无效 ($id)"
        }
    } elseif ($autoCompactScope) {
        throw "Manifest codexAutoCompactTokenLimitScope 需要 codexAutoCompactTokenLimit ($id)"
    }
    $endpoint = Get-AiCliProperty $M 'endpoint'
    if ($null -ne $endpoint -and -not [string]::IsNullOrWhiteSpace([string]$endpoint)) {
        Assert-AiCliEndpointSafe -Url ([string]$endpoint)
    }
    $models = Get-AiCliProperty $M 'models'
    if ($models -isnot [System.Collections.IDictionary]) { throw "Manifest models 必须是 object ($id)" }
    foreach ($field in @('primary','small')) {
        $modelId = Get-AiCliProperty $models $field
        if ($null -ne $modelId -and -not [string]::IsNullOrWhiteSpace([string]$modelId)) {
            $null = Assert-AiCliModelId -Model ([string]$modelId)
        }
    }
    foreach ($modelId in @((Get-AiCliProperty $models 'candidates') | Where-Object { $_ })) {
        $null = Assert-AiCliModelId -Model ([string]$modelId)
    }
    foreach ($modelId in @((Get-AiCliProperty $models 'reserved') | Where-Object { $_ })) {
        $null = Assert-AiCliModelId -Model ([string]$modelId)
    }
    Assert-AiCliProfileDoesNotUseRetiredModel -Profile $M -Context "Manifest $id"
    $exactThirdPartyCodex = [string](Get-AiCliProperty $M 'engine') -ceq 'codex' -and
        [string](Get-AiCliProperty $M 'provider') -cin @('qwen','deepseek','ollama') -and
        -not [bool](Get-AiCliProperty $M 'hidden' $false)
    if ($exactThirdPartyCodex) {
        $primaryModel = [string](Get-AiCliProperty $models 'primary')
        $smallModel = [string](Get-AiCliProperty $models 'small')
        $candidateModels = @(
            (Get-AiCliProperty $models 'candidates') |
                Where-Object { $_ } |
                ForEach-Object { [string]$_ }
        )
        $reservedModels = @((Get-AiCliProperty $models 'reserved') | Where-Object { $_ })
        if ([string](Get-AiCliProperty $M 'transport') -cne 'responses' -or
            [bool](Get-AiCliProperty $M 'flexible' $true) -or
            [string]::IsNullOrWhiteSpace($primaryModel) -or
            $smallModel -cne $primaryModel -or
            $candidateModels.Count -ne 1 -or
            $candidateModels[0] -cne $primaryModel -or
            $reservedModels.Count -ne 0) {
            throw "公开第三方 Codex Profile 必须是 Responses 单模型 exact/no-fallback 合同 ($id)"
        }
        if ($defaultEffort -cne 'max' -or $effortLevels -cnotcontains 'max') {
            throw "公开第三方 Codex Profile 必须默认用户最高档 max ($id)"
        }
        $requiresSecret = [bool](Get-AiCliProperty $M 'requiresSecret' $false)
        $providerName = [string](Get-AiCliProperty $M 'provider')
        if ($providerName -in @('qwen','deepseek')) {
            $auth = Get-AiCliProperty $M 'auth'
            if (-not $requiresSecret -or
                [string](Get-AiCliProperty $auth 'type') -cne 'api-key' -or
                [string](Get-AiCliProperty $auth 'envKey') -cne 'AICLI_CODEX_PROVIDER_KEY') {
                throw "远程 exact Codex Profile 必须通过 AICLI_CODEX_PROVIDER_KEY SecretRef 注入 ($id)"
            }
        }
    }
    $modelMetadata = Get-AiCliProperty $M 'modelMetadata'
    if ($null -ne $modelMetadata) {
        if ($modelMetadata -isnot [System.Collections.IDictionary]) {
            throw "Manifest modelMetadata 必须是 object ($id)"
        }
        $activeModels = @(
            (Get-AiCliProperty $models 'primary'),
            (Get-AiCliProperty $models 'small')
        ) + @((Get-AiCliProperty $models 'candidates') | Where-Object { $_ })
        $activeModels = @($activeModels | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        $allowedMetadataFields = @(
            'contextWindowTokens','autoCompactWindowTokens','inputWindowTokens','outputWindowTokens',
            'compactionReserveTokens','preserveRecentTokens','tailTurns'
        )
        foreach ($modelName in @($modelMetadata.Keys)) {
            $modelName = [string]$modelName
            $null = Assert-AiCliModelId -Model $modelName
            if ($activeModels -notcontains $modelName) {
                throw "modelMetadata 模型未进入活动模型列表: $modelName ($id)"
            }
            $entry = Get-AiCliProperty $modelMetadata $modelName
            if ($entry -isnot [System.Collections.IDictionary]) {
                throw "modelMetadata 条目必须是 object: $modelName ($id)"
            }
            foreach ($field in @($entry.Keys)) {
                if ($allowedMetadataFields -notcontains [string]$field) {
                    throw "modelMetadata 未知字段: $field ($modelName / $id)"
                }
                $value = Get-AiCliProperty $entry ([string]$field)
                if ($value -isnot [byte] -and $value -isnot [int16] -and $value -isnot [int32] -and $value -isnot [int64]) {
                    throw "modelMetadata $field 必须是整数 ($modelName / $id)"
                }
                if ([long]$value -le 0) {
                    throw "modelMetadata $field 必须大于 0 ($modelName / $id)"
                }
            }
            $contextWindow = [long](Get-AiCliProperty $entry 'contextWindowTokens')
            if ($contextWindow -lt 32768 -or $contextWindow -gt 4194304) {
                throw "modelMetadata contextWindowTokens 超出允许范围 ($modelName / $id)"
            }
            foreach ($field in @('autoCompactWindowTokens','inputWindowTokens','outputWindowTokens','compactionReserveTokens','preserveRecentTokens')) {
                $value = Get-AiCliProperty $entry $field
                if ($null -ne $value -and [long]$value -gt $contextWindow) {
                    throw "modelMetadata $field 不得超过 contextWindowTokens ($modelName / $id)"
                }
            }
            if ([string](Get-AiCliProperty $M 'engine') -eq 'claude') {
                if ($null -eq (Get-AiCliProperty $entry 'autoCompactWindowTokens')) {
                    throw "Claude modelMetadata 缺少 autoCompactWindowTokens ($modelName / $id)"
                }
            }
            if ([string](Get-AiCliProperty $M 'engine') -eq 'opencode') {
                foreach ($field in @('inputWindowTokens','outputWindowTokens','compactionReserveTokens','preserveRecentTokens','tailTurns')) {
                    if ($null -eq (Get-AiCliProperty $entry $field)) {
                        throw "OpenCode modelMetadata 缺少 $field ($modelName / $id)"
                    }
                }
            }
        }
        if ([string](Get-AiCliProperty $M 'engine') -notin @('claude','opencode','codex')) {
            throw "modelMetadata 当前仅允许 Claude/OpenCode/Codex Manifest ($id)"
        }
    }
    $compatibility = Get-AiCliProperty $M 'compatibility'
    $minimumCliVersion = [string](Get-AiCliProperty $compatibility 'minCliVersion')
    if ($minimumCliVersion -and $minimumCliVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "compatibility.minCliVersion 必须是三段数字版本: $minimumCliVersion ($id)"
    }
    # Do not route this collection through Get-AiCliProperty: PowerShell
    # enumerates a one-item array at a function boundary and would turn a
    # perfectly valid JSON array into a scalar string.
    $sources = $null
    if ($M -is [System.Collections.IDictionary]) {
        $sources = $M['sources']
    } else {
        $sources = $M.sources
    }
    # JSON single-element arrays may deserialize as a bare string; normalize to list
    if ($null -eq $sources) {
        throw "Manifest sources 必须是 array ($id)"
    }
    if ($sources -is [string]) {
        $sources = @([string]$sources)
    } elseif ($sources -is [System.Collections.IDictionary]) {
        throw "Manifest sources 必须是 array ($id)"
    } elseif ($sources -isnot [System.Collections.IEnumerable]) {
        throw "Manifest sources 必须是 array ($id)"
    }
    foreach ($source in @($sources)) {
        if ($null -eq $source -or [string]::IsNullOrWhiteSpace([string]$source)) { continue }
        try { $sourceUri = [Uri][string]$source } catch { throw "Manifest source URL 非法: $source ($id)" }
        if ($sourceUri.Scheme -ne 'https') { throw "Manifest source 必须使用 HTTPS: $source ($id)" }
    }
    $engine = Get-AiCliProperty $M 'engine'
    $transport = Get-AiCliProperty $M 'transport'
    if ($engine -eq 'codex' -and $transport -ne 'responses' -and $transport -ne 'managed-proxy') {
        # codex only responses for first party; official uses responses via openai
        if ($transport -ne 'responses') {
            throw "Codex Manifest 仅允许 transport=responses，收到: $transport ($($M.id))"
        }
    }
    if ($engine -eq 'claude' -and $transport -notin @('anthropic-messages','managed-proxy')) {
        throw "Claude Manifest transport 非法: $transport ($($M.id))"
    }
    if ($engine -eq 'interpreter') {
        if ($transport -notin @('openai-compatible')) {
            throw "Open Interpreter Manifest transport 仅允许 openai-compatible，收到: $transport ($($M.id))"
        }
        $wireApi = [string](Get-AiCliProperty $M 'wireApi')
        if ($wireApi -and $wireApi -notin @('responses', 'chat')) {
            throw "Open Interpreter Manifest wireApi 仅允许 responses 或 chat，收到: $wireApi ($($M.id))"
        }
        $provider = [string](Get-AiCliProperty $M 'provider')
        if ($wireApi -and $provider -in @('qwen', 'ollama') -and $wireApi -ne 'responses') {
            throw "Open Interpreter $provider Profile 必须使用 wireApi=responses ($($M.id))"
        }
        if ($wireApi -and $provider -eq 'deepseek' -and $wireApi -ne 'chat') {
            throw "Open Interpreter DeepSeek Profile 必须使用 wireApi=chat ($($M.id))"
        }
    }
    if ($engine -in @('qwen-code', 'opencode') -and $transport -ne 'openai-compatible') {
        throw "Agent Manifest transport 仅允许 openai-compatible，收到: $transport ($($M.id))"
    }
    if ($engine -notin @('codex', 'claude', 'interpreter', 'qwen-code', 'opencode')) {
        throw "未知引擎: $engine ($($M.id))"
    }
    if ($engine -eq 'codex') {
        $providerId = if ($M -is [System.Collections.IDictionary]) { $M['codexProviderId'] } else { $M.codexProviderId }
        if ($providerId -and ($script:AiCliCodexReservedProviderIds -contains $providerId)) {
            throw "Codex Provider ID 保留不可用: $providerId"
        }
        if ($providerId) { $null = Assert-AiCliSafeIdentifier -Id ([string]$providerId) -Kind 'Codex Provider ID' }

        $catalogName = [string](Get-AiCliProperty $M 'codexModelCatalog')
        if ($catalogName) {
            if ($catalogName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}\.json$' -or
                [IO.Path]::GetFileName($catalogName) -ne $catalogName) {
                throw "Codex model catalog 名称非法: $catalogName ($id)"
            }
            $catalogPath = Get-AiCliDataPath -Relative (Join-Path 'model-catalogs' $catalogName)
            if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
                throw "Codex model catalog 不存在: $catalogName ($id)"
            }
            $catalog = Read-AiCliJsonFile -Path $catalogPath
            $catalogModels = if ($catalog -is [System.Collections.IDictionary]) {
                @($catalog['models'])
            } else {
                @($catalog.models)
            }
            if ($catalogModels.Count -eq 0) {
                throw "Codex model catalog 必须至少包含一个模型: $catalogName ($id)"
            }
            $catalogSlugs = @($catalogModels | ForEach-Object {
                $slug = [string](Get-AiCliProperty $_ 'slug')
                $null = Assert-AiCliModelId -Model $slug
                $slug
            })
            if ($effortLevels.Count -gt 0) {
                foreach ($catalogModel in $catalogModels) {
                    $catalogSlug = [string](Get-AiCliProperty $catalogModel 'slug')
                    $catalogEfforts = @(
                        @((Get-AiCliProperty $catalogModel 'supported_reasoning_levels')) |
                            ForEach-Object { [string](Get-AiCliProperty $_ 'effort') }
                    )
                    if ($catalogEfforts.Count -eq 0) {
                        throw "Codex reasoning catalog 缺少 effort: $catalogSlug ($id)"
                    }
                    foreach ($requestedEffort in $effortLevels) {
                        $effectiveEffort = [string](Get-AiCliProperty $effortMap $requestedEffort)
                        if (-not $effectiveEffort) { $effectiveEffort = $requestedEffort }
                        if ($catalogEfforts -cnotcontains $effectiveEffort) {
                            throw "Codex reasoning effort 不在 catalog 中: $requestedEffort -> $effectiveEffort / $catalogSlug ($id)"
                        }
                    }
                }
            }
            $candidateModels = @((Get-AiCliProperty $models 'candidates') | Where-Object { $_ } | ForEach-Object { [string]$_ })
            if ($candidateModels.Count -eq 0) {
                throw "带 model catalog 的 Codex Manifest 必须声明 models.candidates ($id)"
            }
            foreach ($candidate in $candidateModels) {
                if ($catalogSlugs -notcontains $candidate) {
                    throw "Codex 候选模型不在目录中: $candidate ($id)"
                }
            }
            foreach ($catalogSlug in $catalogSlugs) {
                if ($candidateModels -notcontains $catalogSlug) {
                    throw "Codex 目录模型未进入候选列表: $catalogSlug ($id)"
                }
            }
            $primary = [string](Get-AiCliProperty $models 'primary')
            if ($catalogSlugs -notcontains $primary) {
                throw "Codex 主模型不在目录中: $primary ($id)"
            }
            foreach ($reserved in @((Get-AiCliProperty $models 'reserved') | Where-Object { $_ })) {
                if ($catalogSlugs -contains [string]$reserved -or $candidateModels -contains [string]$reserved) {
                    throw "Codex 预留模型不得进入活动目录或候选列表: $reserved ($id)"
                }
            }
        }
    } elseif (Get-AiCliProperty $M 'codexModelCatalog') {
        throw "仅 Codex Manifest 可以声明 codexModelCatalog ($id)"
    }
    if ($engine -eq 'interpreter') {
        $providerId = [string](Get-AiCliProperty $M 'interpreterProviderId')
        if ($providerId) { $null = Assert-AiCliSafeIdentifier -Id $providerId -Kind 'Open Interpreter Provider ID' }
    }
    Test-AiCliManifestSafety -Manifest $M | Out-Null
}

function Import-AiCliProviderManifests {
    [CmdletBinding()]
    param()
    $dir = Get-AiCliProviderManifestDir
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "找不到 Provider Manifest 目录: $dir"
    }
    $map = [ordered]@{}
    Get-ChildItem -LiteralPath $dir -Filter '*.json' | ForEach-Object {
        $m = Read-AiCliJsonFile -Path $_.FullName
        if ($null -eq $m) { throw "无法解析 Manifest: $($_.Name)" }
        Assert-AiCliManifestCore -M $m
        $id = [string](Get-AiCliProperty $m 'id')
        if (Test-AiCliMapHasKey -Map $map -Key $id) { throw "重复 Manifest ID: $id" }
        $map[$id] = $m
    }
    return $map
}

function Get-AiCliProviderManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $all = Import-AiCliProviderManifests
    if (-not (Test-AiCliMapHasKey -Map $all -Key $Id)) {
        throw "未知 Profile 模板: $Id"
    }
    return $all[$Id]
}

function Get-AiCliBuiltinTemplateIds {
    $all = Import-AiCliProviderManifests
    $ids = @()
    foreach ($k in $all.Keys) {
        $hidden = Get-AiCliProperty $all[$k] 'hidden' $false
        if (-not $hidden) { $ids += $k }
    }
    return $ids
}
