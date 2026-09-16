#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ExactProfileRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module -Name AiCliProfileManager -All -ErrorAction SilentlyContinue |
        Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:ExactProfileRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'Exact third-party Codex Profiles' {
    It 'keeps every managed non-OpenAI Codex model on the common 90 percent compaction policy' {
        $profiles = InModuleScope AiCliProfileManager {
            $all = Import-AiCliProviderManifests
            @($all.Values | Where-Object {
                $_.engine -eq 'codex' -and $_.provider -ne 'openai' -and
                -not [string]::IsNullOrWhiteSpace([string](Get-AiCliProperty $_ 'codexModelCatalog'))
            })
        }

        foreach ($manifest in @($profiles)) {
            $catalogPath = Join-Path $script:ExactProfileRepoRoot (
                'data\model-catalogs\' + [string]$manifest.codexModelCatalog
            )
            $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 |
                ConvertFrom-Json -Depth 100
            $model = @($catalog.models | Where-Object slug -CEQ $manifest.models.primary)
            @($model).Count | Should -Be 1 -Because $manifest.id
            $expected = [long][Math]::Floor([long]$model[0].context_window * 0.90)
            [long]$model[0].auto_compact_token_limit | Should -Be $expected -Because $manifest.id
            if ($null -ne $manifest.codexAutoCompactTokenLimit) {
                [long]$manifest.codexAutoCompactTokenLimit | Should -Be $expected -Because $manifest.id
                $manifest.codexAutoCompactTokenLimitScope | Should -BeExactly 'total' -Because $manifest.id
            }
        }
    }

    It 'publishes every exact cloud and local Profile through the normal public catalog' {
        $ids = @(InModuleScope AiCliProfileManager { Get-AiCliBuiltinTemplateIds })

        foreach ($id in @(
            'codex-qwen3-7-max-paygo',
            'codex-qwen3-8-max-paygo',
            'codex-deepseek',
            'codex-deepseek-v4-pro',
            'codex-ollama-main',
            'codex-ollama-qwen3-8-27b',
            'codex-ollama-review'
        )) {
            $ids | Should -Contain $id
        }
    }

    It 'keeps every public third-party Codex Profile exact and defaulted to its maximum effort' {
        $profiles = InModuleScope AiCliProfileManager {
            $all = Import-AiCliProviderManifests
            @($all.Values | Where-Object {
                $_.engine -eq 'codex' -and
                $_.provider -in @('qwen', 'deepseek', 'ollama') -and
                -not [bool](Get-AiCliProperty $_ 'hidden' $false)
            })
        }

        @($profiles).Count | Should -Be 9
        foreach ($manifest in @($profiles)) {
            $manifest.transport | Should -Be 'responses' -Because $manifest.id
            $manifest.flexible | Should -BeFalse -Because $manifest.id
            $manifest.models.small | Should -Be $manifest.models.primary -Because $manifest.id
            @($manifest.models.candidates) | Should -Be @($manifest.models.primary) -Because $manifest.id
            @($manifest.models.reserved) | Should -BeNullOrEmpty -Because $manifest.id
            $manifest.defaultEffort | Should -Be 'max' -Because $manifest.id
            @($manifest.effortLevels) | Should -Contain 'max' -Because $manifest.id
        }
    }

    It 'seals Qwen3.7 Max 06-08 to one paygo Responses snapshot and maps user max to native xhigh' {
        $manifest = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'codex-qwen3-7-max-paygo'
        }

        $manifest.engine | Should -Be 'codex'
        $manifest.provider | Should -Be 'qwen'
        $manifest.plan | Should -Be 'paygo'
        $manifest.region | Should -Be 'cn-beijing'
        $manifest.transport | Should -Be 'responses'
        $manifest.endpoint | Should -BeNullOrEmpty
        $manifest.workspaceBaseUrlRequired | Should -BeTrue
        $manifest.codexProviderId | Should -Be 'aicli_qwen37_max_0608_paygo'
        $manifest.codexModelCatalog | Should -Be 'qwen3.7-max-2026-06-08-codex.json'
        $manifest.models.primary | Should -Be 'qwen3.7-max-2026-06-08'
        $manifest.models.small | Should -Be 'qwen3.7-max-2026-06-08'
        @($manifest.models.candidates) | Should -Be @('qwen3.7-max-2026-06-08')
        @($manifest.models.reserved) | Should -BeNullOrEmpty
        $manifest.flexible | Should -BeFalse
        $manifest.defaultEffort | Should -Be 'max'
        @($manifest.effortLevels) | Should -Be @('low', 'medium', 'high', 'xhigh', 'max')
        $manifest.effortMap.max | Should -Be 'xhigh'
        $manifest.effortMap.high | Should -Be 'xhigh'
        $manifest.compatibility.modelVersion | Should -Be 'qwen3.7-max-2026-06-08'
        ($manifest | ConvertTo-Json -Depth 30) | Should -Not -Match '(?i)preview|token[- ]?plan|2026-05-20|qwen3\.7-plus'

        $catalog = Get-Content -LiteralPath (
            Join-Path $script:ExactProfileRepoRoot 'data\model-catalogs\qwen3.7-max-2026-06-08-codex.json'
        ) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        @($catalog.models).Count | Should -Be 1
        $model = $catalog.models[0]
        $model.slug | Should -Be 'qwen3.7-max-2026-06-08'
        $model.context_window | Should -Be 983616
        $model.max_context_window | Should -Be 983616
        $model.effective_context_window_percent | Should -Be 95
        $model.auto_compact_token_limit | Should -Be 885254
        $model.default_reasoning_level | Should -Be 'xhigh'
        @($model.supported_reasoning_levels.effort) | Should -Be @('low', 'medium', 'xhigh')
        @($model.input_modalities) | Should -Be @('text', 'image')
    }

    It 'seals Qwen3.8 Max 0902 to the paygo Responses route and maps user max to native xhigh' {
        $manifest = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'codex-qwen3-8-max-paygo'
        }

        $manifest.engine | Should -Be 'codex'
        $manifest.provider | Should -Be 'qwen'
        $manifest.plan | Should -Be 'paygo'
        $manifest.transport | Should -Be 'responses'
        $manifest.endpoint | Should -BeNullOrEmpty
        $manifest.workspaceBaseUrlRequired | Should -BeTrue
        $manifest.codexProviderId | Should -Be 'aicli_qwen38_max_paygo'
        $manifest.codexModelCatalog | Should -Be 'qwen3.8-max-0902-codex.json'
        $manifest.models.primary | Should -Be 'qwen3.8-max-0902'
        $manifest.models.small | Should -Be 'qwen3.8-max-0902'
        @($manifest.models.candidates) | Should -Be @('qwen3.8-max-0902')
        @($manifest.models.reserved) | Should -Not -Contain 'qwen3.8-max-preview'
        $manifest.flexible | Should -BeFalse
        $manifest.defaultEffort | Should -Be 'max'
        @($manifest.effortLevels) | Should -Be @('low', 'medium', 'high', 'xhigh', 'max')
        $manifest.effortMap.max | Should -Be 'xhigh'
        $manifest.effortMap.high | Should -Be 'xhigh'
        $manifest.compatibility.modelVersion | Should -Be 'qwen3.8-max-0902'
        ($manifest | ConvertTo-Json -Depth 30) | Should -Not -Match '(?i)preview|token[- ]?plan'

        $catalog = Get-Content -LiteralPath (
            Join-Path $script:ExactProfileRepoRoot 'data\model-catalogs\qwen3.8-max-0902-codex.json'
        ) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        @($catalog.models).Count | Should -Be 1
        $model = $catalog.models[0]
        $model.slug | Should -Be 'qwen3.8-max-0902'
        $model.context_window | Should -Be 983616
        $model.max_context_window | Should -Be 983616
        $model.effective_context_window_percent | Should -Be 95
        $model.auto_compact_token_limit | Should -Be 885254
        $model.default_reasoning_level | Should -Be 'xhigh'
        @($model.supported_reasoning_levels.effort) | Should -Be @('low', 'medium', 'xhigh')
        @($model.input_modalities) | Should -Be @('text', 'image')
    }

    It 'publishes exact DeepSeek Flash and Pro Profiles at the vendor maximum effort' {
        $expected = [ordered]@{
            'codex-deepseek' = [ordered]@{
                Alias = 'deepseek-v4-flash'
                Version = 'DeepSeek-V4-Flash-0731'
                Catalog = 'deepseek-v4-flash.json'
            }
            'codex-deepseek-v4-pro' = [ordered]@{
                Alias = 'deepseek-v4-pro'
                Version = 'DeepSeek-V4-Pro-0813'
                Catalog = 'deepseek-v4-pro.json'
            }
        }

        foreach ($profileId in $expected.Keys) {
            $spec = $expected[$profileId]
            $manifest = InModuleScope AiCliProfileManager -Parameters @{ ProfileId = $profileId } {
                Get-AiCliProviderManifest -Id $ProfileId
            }
            $manifest.engine | Should -Be 'codex' -Because $profileId
            $manifest.provider | Should -Be 'deepseek' -Because $profileId
            $manifest.transport | Should -Be 'responses' -Because $profileId
            $manifest.endpoint | Should -Be 'https://api.deepseek.com' -Because $profileId
            $manifest.models.primary | Should -Be $spec.Alias -Because $profileId
            $manifest.models.small | Should -Be $spec.Alias -Because $profileId
            @($manifest.models.candidates) | Should -Be @($spec.Alias) -Because $profileId
            $manifest.compatibility.modelVersion | Should -Be $spec.Version -Because $profileId
            $manifest.codexModelCatalog | Should -Be $spec.Catalog -Because $profileId
            $manifest.defaultEffort | Should -Be 'max' -Because $profileId
            @($manifest.effortLevels) | Should -Be @('low', 'high', 'max') -Because $profileId
            $manifest.flexible | Should -BeFalse -Because $profileId

            $catalog = Get-Content -LiteralPath (
                Join-Path $script:ExactProfileRepoRoot ('data\model-catalogs\' + $spec.Catalog)
            ) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
            @($catalog.models).Count | Should -Be 1 -Because $profileId
            $model = $catalog.models[0]
            $model.slug | Should -Be $spec.Alias -Because $profileId
            $model.context_window | Should -Be 1048576 -Because $profileId
            $model.max_context_window | Should -Be 1048576 -Because $profileId
            $model.effective_context_window_percent | Should -Be 95 -Because $profileId
            $model.default_reasoning_level | Should -Be 'max' -Because $profileId
            @($model.supported_reasoning_levels.effort) | Should -Be @('low', 'high', 'max') -Because $profileId
        }
    }

    It 'keeps all local exact identities on max without enabling fallback models' {
        $expected = [ordered]@{
            'codex-ollama-main' = 'qwen3.8-27b:256k'
            'codex-ollama-qwen3-8-27b' = 'qwen3.8-27b:256k'
            'codex-ollama-review' = 'qwen3.6-35b:256k'
            'codex-ollama-qwen3-6-35b-abliterated' = 'qwen3.6-35b-abliterated:256k'
            'codex-ollama-qwen3-8-27b-abliterated' = 'qwen3.8-27b-abliterated:256k'
        }
        foreach ($profileId in $expected.Keys) {
            $manifest = InModuleScope AiCliProfileManager -Parameters @{ ProfileId = $profileId } {
                Get-AiCliProviderManifest -Id $ProfileId
            }
            $manifest.models.primary | Should -Be $expected[$profileId] -Because $profileId
            @($manifest.models.candidates) | Should -Be @($expected[$profileId]) -Because $profileId
            @($manifest.models.reserved) | Should -BeNullOrEmpty -Because $profileId
            $manifest.defaultEffort | Should -Be 'max' -Because $profileId
            @($manifest.effortLevels) | Should -Contain 'max' -Because $profileId
            $manifest.flexible | Should -BeFalse -Because $profileId
        }
    }

    It 'rejects native model and fallback overrides for every exact Profile' {
        InModuleScope AiCliProfileManager {
            foreach ($profileId in @(
                'codex-qwen3-7-max-paygo',
                'codex-qwen3-8-max-paygo',
                'codex-deepseek',
                'codex-deepseek-v4-pro',
                'codex-ollama-main',
                'codex-ollama-qwen3-8-27b',
                'codex-ollama-qwen3-6-35b-abliterated',
                'codex-ollama-review'
            )) {
                $profile = Get-AiCliProviderManifest -Id $profileId
                foreach ($nativeArgs in @(
                    [string[]]@('--model', 'wrong-model'),
                    [string[]]@('--model=wrong-model'),
                    [string[]]@('-mwrong-model'),
                    [string[]]@('--fallback-model', 'wrong-model'),
                    [string[]]@('--fallback-model=wrong-model')
                )) {
                    {
                        Assert-AiCliLockedModelArgs -MergedProfile $profile -NativeArgs $nativeArgs
                    } | Should -Throw '*模型由 Profile 固定*' -Because $profileId
                }
            }
        }
    }

    It 'keeps max as the user-visible effort while producing the effective native effort' {
        InModuleScope AiCliProfileManager {
            $qwen = Get-AiCliProviderManifest -Id 'codex-qwen3-8-max-paygo'
            $qwen37 = Get-AiCliProviderManifest -Id 'codex-qwen3-7-max-paygo'
            $deepSeek = Get-AiCliProviderManifest -Id 'codex-deepseek'
            $local = Get-AiCliProviderManifest -Id 'codex-ollama-main'
            $localQwen38 = Get-AiCliProviderManifest -Id 'codex-ollama-qwen3-8-27b'

            Resolve-AiCliCodexEffort -MergedProfile $qwen -NativeArgs @() |
                Should -Be 'max'
            Resolve-AiCliCodexEffectiveEffort -MergedProfile $qwen -RequestedEffort 'max' |
                Should -Be 'xhigh'
            Resolve-AiCliCodexEffort -MergedProfile $qwen37 -NativeArgs @() |
                Should -Be 'max'
            Resolve-AiCliCodexEffectiveEffort -MergedProfile $qwen37 -RequestedEffort 'max' |
                Should -Be 'xhigh'
            Resolve-AiCliCodexEffectiveEffort -MergedProfile $deepSeek -RequestedEffort 'max' |
                Should -Be 'max'
            Resolve-AiCliCodexEffectiveEffort -MergedProfile $local -RequestedEffort 'max' |
                Should -Be 'max'
            Resolve-AiCliCodexEffectiveEffort -MergedProfile $localQwen38 -RequestedEffort 'max' |
                Should -Be 'max'
        }
    }

    It 'normalizes only the official Qwen Workspace Responses endpoint family' {
        InModuleScope AiCliProfileManager {
            Resolve-AiCliQwenWorkspaceResponsesEndpoint `
                -Endpoint 'https://ws-example.cn-beijing.maas.aliyuncs.com/api/v2/apps/protocols/compatible-mode/v1/' |
                Should -Be 'https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1'

            foreach ($invalid in @(
                'https://dashscope.aliyuncs.com/compatible-mode/v1',
                'https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
                'https://ws-example.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1',
                'https://ws-example.cn-beijing.maas.aliyuncs.com/v1'
            )) {
                {
                    Resolve-AiCliQwenWorkspaceResponsesEndpoint -Endpoint $invalid
                } | Should -Throw '*Workspace*'
            }
        }
    }

    It 'forwards the exact Profile and trusted project through the one-command start surface' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:StartCalls = [Collections.Generic.List[object]]::new()
            Mock Start-AiCliProfile {
                $script:StartCalls.Add([pscustomobject]@{
                    ProfileId = $ProfileId
                    ProjectPath = $ProjectPath
                    NativeArgs = @($NativeArgs)
                }) | Out-Null
                0
            }

            $expectedProfiles = @(
                'codex-qwen3-7-max-paygo',
                'codex-qwen3-8-max-paygo',
                'codex-deepseek',
                'codex-deepseek-v4-pro',
                'codex-ollama-main',
                'codex-ollama-qwen3-8-27b',
                'codex-ollama-review'
            )
            foreach ($profileId in $expectedProfiles) {
                Invoke-AiCliStartCommand -Tokens @($profileId, '--project', $Work) |
                    Should -Be 0
            }
            @($script:StartCalls.ProfileId) | Should -Be $expectedProfiles
            @($script:StartCalls.ProjectPath | Select-Object -Unique) | Should -Be @($Work)
            @($script:StartCalls | Where-Object { $_.NativeArgs.Count -ne 0 }).Count | Should -Be 0
            Should -Invoke Start-AiCliProfile -Times $expectedProfiles.Count -Exactly -Scope It
        }
    }

    It 'injects a SecretRef only through env_key and emits Qwen max as effective xhigh' {
        $profile = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'codex-qwen3-8-max-paygo'
        }
        $profile = $profile | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
        $profile.endpoint = 'https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1'
        $profile.secretConfigured = $true
        $profile.secretRef = 'opaque-secret-ref'

        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $profile } {
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{ FileName = 'C:\fake\codex.exe'; PrefixArgs = @(); Kind = 'test' }
            }
            Mock Get-AiCliResolvedCliVersionEvidence {
                [pscustomobject]@{ Version = 'codex-cli 0.147.0'; FileName = 'C:\fake\codex.exe' }
            }
            Mock Write-AiCliCodexManagedProfile {
                [pscustomobject]@{
                    CliProfileName = 'aicli-codex-qwen3-8-max-paygo'
                    FilePath = (Join-Path $Work 'qwen.config.toml')
                    ContentHash = ('0' * 64)
                }
            }
            Mock Publish-AiCliCodexModelCatalog {
                Join-Path $Work 'qwen3.8-max-0902-codex.json'
            }
            Mock Get-AiCliSecret { 'test-secret-never-serialize' }

            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $Profile -ProjectPath $Work

            $plan.model | Should -Be 'qwen3.8-max-0902'
            $plan.effort | Should -Be 'max'
            $plan.effectiveEffort | Should -Be 'xhigh'
            $plan.wire | Should -Be 'responses'
            $plan.argumentList | Should -Contain 'model_reasoning_effort="xhigh"'
            $plan.argumentList | Should -Contain 'model="qwen3.8-max-0902"'
            $plan.argumentList | Should -Contain 'model_providers.aicli_qwen38_max_paygo.wire_api="responses"'
            $plan.argumentList | Should -Contain 'model_providers.aicli_qwen38_max_paygo.env_key="AICLI_CODEX_PROVIDER_KEY"'
            $plan.environmentDelta.AICLI_CODEX_PROVIDER_KEY | Should -Be 'test-secret-never-serialize'
            ($plan.argumentList -join "`n") | Should -Not -Match 'test-secret-never-serialize|opaque-secret-ref'
        }
    }

    It 'builds the Qwen3.7 Max 06-08 launch plan with exact model, Responses and effective xhigh' {
        $profile = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'codex-qwen3-7-max-paygo'
        }
        $profile = $profile | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
        $profile.endpoint = 'https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1'
        $profile.secretConfigured = $true
        $profile.secretRef = 'opaque-qwen37-secret-ref'

        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $profile } {
            $script:qwen37Toml = $null
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{ FileName = 'C:\fake\codex.exe'; PrefixArgs = @(); Kind = 'test' }
            }
            Mock Get-AiCliResolvedCliVersionEvidence {
                [pscustomobject]@{ Version = 'codex-cli 0.147.0'; FileName = 'C:\fake\codex.exe' }
            }
            Mock Write-AiCliCodexManagedProfile {
                $script:qwen37Toml = [string]$TomlBody
                [pscustomobject]@{
                    CliProfileName = 'aicli-codex-qwen3-7-max-paygo'
                    FilePath = (Join-Path $Work 'qwen37.config.toml')
                    ContentHash = ('0' * 64)
                }
            }
            Mock Publish-AiCliCodexModelCatalog {
                Join-Path $Work 'qwen3.7-max-2026-06-08-codex.json'
            }
            Mock Get-AiCliSecret { 'qwen37-secret-canary-never-serialize' }

            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $Profile -ProjectPath $Work

            $plan.model | Should -BeExactly 'qwen3.7-max-2026-06-08'
            $plan.modelProvider | Should -BeExactly 'aicli_qwen37_max_0608_paygo'
            $plan.wire | Should -BeExactly 'responses'
            $plan.effort | Should -BeExactly 'max'
            $plan.effectiveEffort | Should -BeExactly 'xhigh'
            $plan.argumentList | Should -Contain 'model="qwen3.7-max-2026-06-08"'
            $plan.argumentList | Should -Contain 'model_reasoning_effort="xhigh"'
            $plan.argumentList | Should -Contain 'model_providers.aicli_qwen37_max_0608_paygo.wire_api="responses"'
            $plan.argumentList | Should -Contain 'model_providers.aicli_qwen37_max_0608_paygo.env_key="AICLI_CODEX_PROVIDER_KEY"'
            $plan.environmentDelta.AICLI_CODEX_PROVIDER_KEY | Should -BeExactly 'qwen37-secret-canary-never-serialize'
            $script:qwen37Toml | Should -Match '(?m)^model = "qwen3\.7-max-2026-06-08"\r?$'
            $script:qwen37Toml | Should -Match '(?m)^model_provider = "aicli_qwen37_max_0608_paygo"\r?$'
            $script:qwen37Toml | Should -Match '(?m)^model_reasoning_effort = "xhigh"\r?$'
            (($plan.argumentList -join "`n") + "`n" + $script:qwen37Toml) |
                Should -Not -Match 'qwen37-secret-canary-never-serialize|opaque-qwen37-secret-ref'
        }
    }

    It 'admits the exact Qwen3.7 Max 06-08 identity through the final launch-plan retirement gate' {
        $profile = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'codex-qwen3-7-max-paygo'
        }
        $profile = $profile | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
        $profile.configured = $true

        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $profile } {
            Mock Get-AiCliResolvedProfile { $Profile }
            Mock Resolve-AiCliProjectPath { $Work }
            Mock Build-AiCliCodexLaunchPlan {
                [pscustomobject]@{
                    engine = 'codex'
                    model = 'qwen3.7-max-2026-06-08'
                    modelProvider = 'aicli_qwen37_max_0608_paygo'
                    argumentList = @()
                }
            }
            Mock Apply-AiCliContextManagementPolicy { $Plan }

            $plan = Build-AiCliLaunchPlan -ProfileId 'codex-qwen3-7-max-paygo' `
                -ProjectPath $Work

            $plan.model | Should -BeExactly 'qwen3.7-max-2026-06-08'
        }
    }

    It 'closes both DeepSeek Codex Profiles over exact identity, Responses and max in argv and managed TOML' {
        $expected = @(
            [ordered]@{
                ProfileId = 'codex-deepseek'
                Model = 'deepseek-v4-flash'
                ProviderId = 'aicli_deepseek'
                OtherModel = 'deepseek-v4-pro'
            },
            [ordered]@{
                ProfileId = 'codex-deepseek-v4-pro'
                Model = 'deepseek-v4-pro'
                ProviderId = 'aicli_deepseek_v4_pro'
                OtherModel = 'deepseek-v4-flash'
            }
        )

        foreach ($spec in $expected) {
            $profile = InModuleScope AiCliProfileManager -Parameters @{ ProfileId = $spec.ProfileId } {
                Get-AiCliProviderManifest -Id $ProfileId
            }
            $profile = $profile | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
            $profile.secretConfigured = $true
            $profile.secretRef = 'opaque-deepseek-secret-ref'

            InModuleScope AiCliProfileManager -Parameters @{
                Work = $TestDrive
                Profile = $profile
                Spec = $spec
            } {
                $script:managedToml = $null
                Mock Resolve-AiCliCodexLaunchExecutable {
                    [pscustomobject]@{ FileName = 'C:\fake\codex.exe'; PrefixArgs = @(); Kind = 'test' }
                }
                Mock Get-AiCliResolvedCliVersionEvidence {
                    [pscustomobject]@{ Version = 'codex-cli 0.147.0'; FileName = 'C:\fake\codex.exe' }
                }
                Mock Publish-AiCliCodexModelCatalog {
                    Join-Path $Work ($Spec.Model + '.json')
                }
                Mock Write-AiCliCodexManagedProfile {
                    $script:managedToml = [string]$TomlBody
                    [pscustomobject]@{
                        CliProfileName = 'aicli-' + $Spec.ProfileId
                        FilePath = (Join-Path $Work ($Spec.ProfileId + '.config.toml'))
                        ContentHash = ('0' * 64)
                    }
                }
                Mock Get-AiCliSecret { 'deepseek-secret-canary-never-serialize' }

                $plan = Build-AiCliCodexLaunchPlan -MergedProfile $Profile -ProjectPath $Work

                $plan.model | Should -BeExactly $Spec.Model
                $plan.modelProvider | Should -BeExactly $Spec.ProviderId
                $plan.wire | Should -BeExactly 'responses'
                $plan.endpoint | Should -BeExactly 'https://api.deepseek.com'
                $plan.effort | Should -BeExactly 'max'
                $plan.effectiveEffort | Should -BeExactly 'max'
                $plan.argumentList | Should -Contain 'model_reasoning_effort="max"'
                $plan.argumentList | Should -Contain ('model="' + $Spec.Model + '"')
                $plan.argumentList | Should -Contain (
                    'model_providers.' + $Spec.ProviderId + '.wire_api="responses"'
                )
                $plan.argumentList | Should -Contain (
                    'model_providers.' + $Spec.ProviderId + '.env_key="AICLI_CODEX_PROVIDER_KEY"'
                )
                $plan.environmentDelta.AICLI_CODEX_PROVIDER_KEY |
                    Should -BeExactly 'deepseek-secret-canary-never-serialize'
                $script:managedToml | Should -Match (
                    '(?m)^model = "' + [regex]::Escape($Spec.Model) + '"\r?$'
                )
                $script:managedToml | Should -Match (
                    '(?m)^model_provider = "' + [regex]::Escape($Spec.ProviderId) + '"\r?$'
                )
                $script:managedToml | Should -Match '(?m)^model_reasoning_effort = "max"\r?$'
                $script:managedToml | Should -Match '(?m)^wire_api = "responses"\r?$'
                $script:managedToml | Should -Match '(?m)^env_key = "AICLI_CODEX_PROVIDER_KEY"\r?$'
                $allPublicText = ($plan.argumentList -join "`n") + "`n" + $script:managedToml
                $allPublicText | Should -Not -Match 'deepseek-secret-canary-never-serialize|opaque-deepseek-secret-ref'
                $allPublicText | Should -Not -Match ([regex]::Escape($Spec.OtherModel))
            }
        }
    }
}
