#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:LocalMainMigrationRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $profileIds = @(
        'codex-ollama-main',
        'claude-ollama-main',
        'opencode-ollama-main',
        'qwen-code-ollama-main',
        'codex-ollama-qwen3-8-27b',
        'opencode-ollama-qwen3-8-27b',
        'codex-ollama-review'
    )
    $script:LocalMainMigrationProfiles = [ordered]@{}
    foreach ($id in $profileIds) {
        $path = Join-Path $script:LocalMainMigrationRepoRoot ("data\providers\$id.json")
        $script:LocalMainMigrationProfiles[$id] = Get-Content -LiteralPath $path -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 30
    }
    $script:LocalMainMigrationRuntimeTag = 'aicli-qwen3.8-27b-256k:2026-09-15'
    $script:LocalMainMigrationManifestDigest = 'sha256:885ca6e9d68fbda050eee055145891e7c45fa8a0bec8c62dc8cd90708f6bedcd'
    $script:LocalMainMigrationParametersDigest = 'sha256:14bb2c63f1a0e61969a5bceba301ea9d60740ce64b72813cc018acfc63c940c2'
}

Describe 'Local Qwen main migration consistency' {
    It 'uses the same exact 256K runtime artifact across all four main providers' {
        $mainIds = @(
            'codex-ollama-main',
            'claude-ollama-main',
            'opencode-ollama-main',
            'qwen-code-ollama-main'
        )
        foreach ($id in $mainIds) {
            $manifest = $script:LocalMainMigrationProfiles[$id]
            $artifact = $manifest.compatibility.ollamaArtifact
            $manifest.models.primary | Should -BeExactly $script:LocalMainMigrationRuntimeTag -Because $id
            $manifest.models.small | Should -BeExactly $script:LocalMainMigrationRuntimeTag -Because $id
            $artifact.tag | Should -BeExactly $script:LocalMainMigrationRuntimeTag -Because $id
            $artifact.manifestDigest | Should -BeExactly $script:LocalMainMigrationManifestDigest -Because $id
            $artifact.parametersDigest | Should -BeExactly $script:LocalMainMigrationParametersDigest -Because $id
            $artifact.draftNumPredict | Should -Be 0 -Because $id
            $artifact.baseTag | Should -BeExactly 'qwen3.8:27b' -Because $id
            $artifact.numCtx | Should -Be 262144 -Because $id
            $artifact.quantization | Should -BeExactly 'Q4_K_M' -Because $id
            $manifest.capabilities.tools | Should -BeTrue -Because $id
            $manifest.capabilities.streaming | Should -BeTrue -Because $id
            $manifest.capabilities.images | Should -BeTrue -Because $id
            $manifest.capabilities.machineRun | Should -BeTrue -Because $id

            if ($manifest.modelMetadata) {
                $metadata = $manifest.modelMetadata.$($script:LocalMainMigrationRuntimeTag)
                $metadata.contextWindowTokens | Should -Be 262144 -Because $id
                $metadata.outputWindowTokens | Should -Be 32768 -Because $id
            }
        }
    }

    It 'keeps the explicit Codex and OpenCode 27B profiles capability-equivalent to main' {
        $pairs = @(
            @{ Main = 'codex-ollama-main'; Exact = 'codex-ollama-qwen3-8-27b'; Metadata = @('contextWindowTokens', 'outputWindowTokens') },
            @{ Main = 'opencode-ollama-main'; Exact = 'opencode-ollama-qwen3-8-27b'; Metadata = @('contextWindowTokens', 'inputWindowTokens', 'outputWindowTokens', 'compactionReserveTokens', 'preserveRecentTokens', 'tailTurns') }
        )
        $artifactFields = @(
            'minimumVersion', 'tag', 'baseTag', 'numCtx', 'quantization', 'manifestDigest',
            'baseManifestDigest', 'configDigest', 'modelBlobDigest',
            'projectorBlobDigest', 'parametersDigest', 'draftNumPredict'
        )

        foreach ($pair in $pairs) {
            $main = $script:LocalMainMigrationProfiles[$pair.Main]
            $exact = $script:LocalMainMigrationProfiles[$pair.Exact]
            $main.models.primary | Should -BeExactly $script:LocalMainMigrationRuntimeTag -Because $pair.Main
            $exact.models.primary | Should -BeExactly $script:LocalMainMigrationRuntimeTag -Because $pair.Exact
            $main.models.small | Should -BeExactly $exact.models.small -Because $pair.Main
            $main.endpoint | Should -BeExactly $exact.endpoint -Because $pair.Main
            $main.transport | Should -BeExactly $exact.transport -Because $pair.Main
            $main.defaultEffort | Should -BeExactly $exact.defaultEffort -Because $pair.Main
            @($main.effortLevels) | Should -Be @($exact.effortLevels) -Because $pair.Main
            $main.flexible | Should -Be $exact.flexible -Because $pair.Main
            $main.requiresSecret | Should -Be $exact.requiresSecret -Because $pair.Main
            $main.virtualReady | Should -Be $exact.virtualReady -Because $pair.Main
            $main.capabilities.tools | Should -Be $exact.capabilities.tools -Because $pair.Main
            $main.capabilities.streaming | Should -Be $exact.capabilities.streaming -Because $pair.Main
            $main.capabilities.images | Should -Be $exact.capabilities.images -Because $pair.Main
            $main.capabilities.machineRun | Should -Be $exact.capabilities.machineRun -Because $pair.Main

            foreach ($field in $artifactFields) {
                $main.compatibility.ollamaArtifact.$field |
                    Should -Be $exact.compatibility.ollamaArtifact.$field -Because "$($pair.Main): $field"
            }
            foreach ($field in $pair.Metadata) {
                $main.modelMetadata.$($script:LocalMainMigrationRuntimeTag).$field |
                    Should -Be $exact.modelMetadata.$($script:LocalMainMigrationRuntimeTag).$field -Because "$($pair.Main): $field"
            }

            if ($pair.Main -eq 'codex-ollama-main') {
                $main.codexModelCatalog | Should -BeExactly 'qwen3.8-27b-codex.json'
                $exact.codexModelCatalog | Should -BeExactly 'qwen3.8-27b-codex.json'
                @($main.models.candidates) | Should -Be @($exact.models.candidates)
                @($main.models.reserved) | Should -BeNullOrEmpty
                @($exact.models.reserved) | Should -BeNullOrEmpty
            }
        }
    }

    It 'keeps Codex review on its independent Qwen3.6 35B model and catalog' {
        $main = $script:LocalMainMigrationProfiles['codex-ollama-main']
        $review = $script:LocalMainMigrationProfiles['codex-ollama-review']
        $review.models.primary | Should -BeExactly 'qwen-main-v1'
        $review.models.small | Should -BeExactly 'qwen-main-v1'
        @($review.models.candidates) | Should -Be @('qwen-main-v1')
        $review.codexModelCatalog | Should -BeExactly 'qwen-main-v1-codex.json'
        $review.modelMetadata.'qwen-main-v1'.contextWindowTokens | Should -Be 262144
        $review.modelMetadata.'qwen-main-v1'.outputWindowTokens | Should -Be 8192
        $review.displayName | Should -Match 'Qwen3\.6 35B'
        $review.capabilities.images | Should -BeFalse
        $review.models.primary | Should -Not -BeExactly $main.models.primary
        $review.codexModelCatalog | Should -Not -BeExactly $main.codexModelCatalog
        $review.compatibility.ollamaArtifact | Should -BeNullOrEmpty
    }
}
