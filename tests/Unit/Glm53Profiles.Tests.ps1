BeforeAll {
    $script:GlmRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Remove-Module AiCliProfileManager -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:GlmRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'Exact GLM-5.3 Codex Profiles' {
    It 'publishes the two exact China Responses models with their declared capabilities' {
        $expected = [ordered]@{
            'codex-glm-5-3' = [ordered]@{ Model='glm-5.3'; Catalog='glm-5.3-codex.json'; Modalities=@('text') }
            'codex-glm-5-3-flash' = [ordered]@{ Model='glm-5.3-flash'; Catalog='glm-5.3-flash-codex.json'; Modalities=@('text','image') }
        }
        foreach ($profileId in $expected.Keys) {
            $spec = $expected[$profileId]
            $manifest = InModuleScope AiCliProfileManager -Parameters @{ Id=$profileId } {
                Get-AiCliProviderManifest -Id $Id
            }
            $manifest.provider | Should -BeExactly 'glm'
            $manifest.transport | Should -BeExactly 'responses'
            $manifest.endpoint | Should -BeExactly 'https://open.bigmodel.cn/api/v1'
            $manifest.models.primary | Should -BeExactly $spec.Model
            @($manifest.models.candidates) | Should -Be @($spec.Model)
            $manifest.codexModelCatalog | Should -BeExactly $spec.Catalog
            @($manifest.effortLevels) | Should -Be @('low','high','max')
            $manifest.flexible | Should -BeFalse

            $catalog = Get-Content -LiteralPath (Join-Path $script:GlmRepoRoot ('data\model-catalogs\' + $spec.Catalog)) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
            @($catalog.models).Count | Should -Be 1
            $model = $catalog.models[0]
            $model.slug | Should -BeExactly $spec.Model
            $model.context_window | Should -Be 1048576
            $model.max_context_window | Should -Be 1048576
            $model.auto_compact_token_limit | Should -Be 996147
            @($model.supported_reasoning_levels.effort) | Should -Be @('low','high','max')
            @($model.input_modalities) | Should -Be $spec.Modalities
        }
    }

    It 'builds a secret-isolated GLM Responses launch plan' {
        $profile = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'codex-glm-5-3'
        }
        $profile = $profile | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $profile.secretConfigured = $true
        $profile.secretRef = 'opaque-glm-secret-ref'
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive; Profile=$profile } {
            Mock Resolve-AiCliCodexLaunchExecutable { [pscustomobject]@{ FileName='C:\fake\codex.exe'; PrefixArgs=@(); Kind='test' } }
            Mock Get-AiCliResolvedCliVersionEvidence { [pscustomobject]@{ Version='codex-cli 0.154.0'; FileName='C:\fake\codex.exe' } }
            Mock Publish-AiCliCodexModelCatalog { Join-Path $Work 'glm-5.3-codex.json' }
            Mock Write-AiCliCodexManagedProfile { [pscustomobject]@{ CliProfileName='aicli-codex-glm-5-3'; FilePath=(Join-Path $Work 'glm.config.toml'); ContentHash=('0' * 64) } }
            Mock Get-AiCliSecret { 'glm-secret-canary-never-serialize' }
            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $Profile -ProjectPath $Work
            $plan.model | Should -BeExactly 'glm-5.3'
            $plan.modelProvider | Should -BeExactly 'aicli_glm_5_3'
            $plan.effectiveEffort | Should -BeExactly 'max'
            $plan.argumentList | Should -Contain 'model_providers.aicli_glm_5_3.wire_api="responses"'
            $plan.environmentDelta.AICLI_CODEX_PROVIDER_KEY | Should -BeExactly 'glm-secret-canary-never-serialize'
            ($plan.argumentList -join "`n") | Should -Not -Match 'glm-secret-canary-never-serialize|opaque-glm-secret-ref'
        }
    }
}
