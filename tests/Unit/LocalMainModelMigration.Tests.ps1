#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:LocalMainMigrationRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $profileIds = @(
        'codex-ollama-main', 'claude-ollama-main', 'opencode-ollama-main',
        'qwen-code-ollama-main', 'codex-ollama-qwen3-8-27b',
        'opencode-ollama-qwen3-8-27b', 'codex-ollama-review'
    )
    $script:LocalMainMigrationProfiles = @{}
    foreach ($id in $profileIds) {
        $path = Join-Path $script:LocalMainMigrationRepoRoot "data\providers\$id.json"
        $script:LocalMainMigrationProfiles[$id] = Get-Content -LiteralPath $path -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable -Depth 50
    }
}

Describe 'Local model profile consistency' {
    It 'uses the actual Codex main identity across the four mains with 262144 context' {
        $main = $script:LocalMainMigrationProfiles['codex-ollama-main']
        $model = [string]$main.models.primary
        $model | Should -Not -BeNullOrEmpty
        $main.models.small | Should -BeExactly $model
        @($main.models.candidates) | Should -Be @($model)
        @($main.models.reserved) | Should -BeNullOrEmpty
        $mainArtifact = $main.compatibility.ollamaArtifact
        $mainArtifact.tag | Should -BeExactly $model
        $mainArtifact.numCtx | Should -Be 262144
        $main.modelMetadata[$model].contextWindowTokens | Should -Be 262144

        foreach ($id in @('claude-ollama-main', 'opencode-ollama-main', 'qwen-code-ollama-main')) {
            $profile = $script:LocalMainMigrationProfiles[$id]
            $profile.models.primary | Should -BeExactly $model -Because $id
            $profile.models.small | Should -BeExactly $model -Because $id
            $artifact = $profile.compatibility.ollamaArtifact
            foreach ($field in @('tag', 'baseTag', 'numCtx', 'quantization', 'manifestDigest', 'baseManifestDigest', 'configDigest', 'modelBlobDigest', 'projectorBlobDigest', 'parametersDigest', 'draftNumPredict', 'numBatch')) {
                $artifact[$field] | Should -Be $mainArtifact[$field] -Because "$id $field"
            }
            if ($profile.Contains('modelMetadata')) {
                $metadata = $profile.modelMetadata[$model]
                $metadata | Should -Not -BeNullOrEmpty -Because $id
                $metadata.contextWindowTokens | Should -Be 262144 -Because $id
                $metadata.outputWindowTokens | Should -BeGreaterThan 0 -Because $id
                $metadata.outputWindowTokens | Should -BeLessOrEqual 262144 -Because $id
            }
        }

        $mainCatalogPath = Join-Path $script:LocalMainMigrationRepoRoot "data\model-catalogs\$($main.codexModelCatalog)"
        $mainCatalog = Get-Content -LiteralPath $mainCatalogPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 50
        $mainCatalog.models[0].slug | Should -BeExactly $model
        $mainCatalog.models[0].context_window | Should -Be 262144
        $mainCatalog.models[0].max_context_window | Should -Be 262144
    }

    It 'keeps the fixed exact Codex profile independent when main changes model' {
        $main = $script:LocalMainMigrationProfiles['codex-ollama-main']
        $exact = $script:LocalMainMigrationProfiles['codex-ollama-qwen3-8-27b']
        $exactModel = [string]$exact.models.primary
        $exactModel | Should -Not -BeNullOrEmpty
        $exact.models.small | Should -BeExactly $exactModel
        @($exact.models.candidates) | Should -Be @($exactModel)
        $exact.codexModelCatalog | Should -Not -BeNullOrEmpty
        $exactCatalogPath = Join-Path $script:LocalMainMigrationRepoRoot "data\model-catalogs\$($exact.codexModelCatalog)"
        $exactCatalog = Get-Content -LiteralPath $exactCatalogPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 50
        $exactCatalog.models[0].slug | Should -BeExactly $exactModel
        $exactCatalog.models[0].context_window | Should -Be 262144
        if ($exactModel -ceq $main.models.primary) {
            $exact.codexModelCatalog | Should -BeExactly $main.codexModelCatalog
            $exact.modelMetadata[$exactModel].contextWindowTokens |
                Should -Be $main.modelMetadata[$exactModel].contextWindowTokens
        } else {
            $exact.codexModelCatalog | Should -Not -BeExactly $main.codexModelCatalog
        }
    }

    It 'keeps review separate from main and verifies its actual 256K model metadata' {
        $main = $script:LocalMainMigrationProfiles['codex-ollama-main']
        $review = $script:LocalMainMigrationProfiles['codex-ollama-review']
        $reviewModel = [string]$review.models.primary
        $reviewModel | Should -Not -BeNullOrEmpty
        $reviewModel | Should -Not -BeExactly $main.models.primary
        $review.models.small | Should -BeExactly $reviewModel
        @($review.models.candidates) | Should -Be @($reviewModel)
        $review.codexModelCatalog | Should -Not -BeExactly $main.codexModelCatalog
        $reviewMetadata = $review.modelMetadata[$reviewModel]
        $reviewMetadata.contextWindowTokens | Should -Be 262144
        $reviewMetadata.outputWindowTokens | Should -BeGreaterThan 0
        $reviewMetadata.outputWindowTokens | Should -BeLessOrEqual 262144
        $reviewArtifact = $review.compatibility.ollamaArtifact
        $reviewArtifact.tag | Should -BeExactly $reviewModel
        $reviewArtifact.numCtx | Should -Be 262144
        $reviewArtifact.manifestDigest | Should -BeExactly 'sha256:ee22ef7004d1e835e913313b78c5811d8044002c18b435f88c3f6aae1c820023'
        $reviewArtifact.configDigest | Should -BeExactly 'sha256:85b5358cae239e22459ef81434b8cc4adf10572ab0a6f6657f6abb45fd9f81be'
        $reviewArtifact.modelBlobDigest | Should -BeExactly 'sha256:f5ee307a2982106a6eb82b62b2c00b575c9072145a759ae4660378acda8dcf2d'
        $reviewArtifact.parametersDigest | Should -BeExactly 'sha256:6245134a52e01baba7d42d366ac6ed2f4a5254a21c33ca36c8de6dbd760a78f1'
        $reviewArtifact.parameters.num_batch | Should -Be 128
        $review.capabilities.images | Should -BeTrue
        $review.displayName | Should -Not -BeNullOrEmpty
        $review.displayName | Should -Not -BeExactly $reviewModel
        $review.displayName | Should -Match '\+\s+[A-Za-z0-9]'
        $reviewCatalogPath = Join-Path $script:LocalMainMigrationRepoRoot "data\model-catalogs\$($review.codexModelCatalog)"
        $reviewCatalog = Get-Content -LiteralPath $reviewCatalogPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 50
        $reviewCatalog.models[0].slug | Should -BeExactly $reviewModel
        $reviewCatalog.models[0].context_window | Should -Be 262144
    }
}
