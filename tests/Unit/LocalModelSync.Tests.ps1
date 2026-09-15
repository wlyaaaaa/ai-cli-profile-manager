#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:LocalModelSyncRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:LocalModelSyncScript = Join-Path $script:LocalModelSyncRepoRoot 'scripts\Sync-LocalModelProfiles.ps1'
    $script:LocalModelSyncTargetIds = @('claude-ollama-main', 'opencode-ollama-main', 'qwen-code-ollama-main')
    $script:LocalModelSyncProtectedIds = @('codex-ollama-main', 'codex-ollama-qwen3-8-27b', 'opencode-ollama-qwen3-8-27b', 'codex-ollama-review')

    function Read-TestJson {
        param([Parameter(Mandatory)][string]$Path)
        Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 80
    }

    function Write-TestJson {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
        $text = $Value | ConvertTo-Json -Depth 80
        [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
    }

    function New-LocalModelSyncFixture {
        param([Parameter(Mandatory)][string]$WorkRoot)

        $repo = Join-Path $WorkRoot ('model-sync-' + [guid]::NewGuid().ToString('N'))
        $providerRoot = Join-Path $repo 'data\providers'
        $catalogRoot = Join-Path $repo 'data\model-catalogs'
        New-Item -ItemType Directory -Path $providerRoot, $catalogRoot -Force | Out-Null

        $profileIds = @($script:LocalModelSyncTargetIds) + @($script:LocalModelSyncProtectedIds)
        foreach ($id in $profileIds) {
            $sourcePath = Join-Path $script:LocalModelSyncRepoRoot "data\providers\$id.json"
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $providerRoot "$id.json")
        }
        $catalogNames = @{}
        foreach ($id in @('codex-ollama-main', 'codex-ollama-qwen3-8-27b', 'codex-ollama-review')) {
            $profile = Read-TestJson (Join-Path $providerRoot "$id.json")
            $catalogNames[[string]$profile.codexModelCatalog] = $true
        }
        foreach ($name in $catalogNames.Keys) {
            Copy-Item -LiteralPath (Join-Path $script:LocalModelSyncRepoRoot "data\model-catalogs\$name") `
                -Destination (Join-Path $catalogRoot $name)
        }

        $fixture = [pscustomobject]@{
            RepoRoot = $repo
            ProviderRoot = $providerRoot
            CatalogRoot = $catalogRoot
            CandidateModel = 'aicli-candidate-32b-256k:2026-10-01'
            CandidateCatalog = 'candidate-32b-codex.json'
            TargetPaths = @()
            ProtectedPaths = @()
            WatchedPaths = @()
        }
        Set-CandidateModel -Fixture $fixture -Model $fixture.CandidateModel

        foreach ($id in $script:LocalModelSyncTargetIds) {
            $path = Join-Path $providerRoot "$id.json"
            $profile = Read-TestJson $path
            $oldModel = [string]$profile.models.primary
            $profile.sources = @("fixture-source:$id")
            $profile.notes = "fixture-notes:$id"
            $profile.verification = [ordered]@{ result = 'pass'; verified_model = $oldModel }
            $profile.models.fixtureExtension = "keep-model-field:$id"
            $profile.fixtureLaunchOptions = [ordered]@{ startup = "keep-start:$id" }
            if ($profile.Contains('modelMetadata')) {
                $clientMetadata = $profile.modelMetadata[$oldModel]
                if ($id -eq 'claude-ollama-main') {
                    $clientMetadata.outputWindowTokens = 24576
                    $clientMetadata.autoCompactWindowTokens = 262144
                }
                if ($id -eq 'opencode-ollama-main') {
                    $clientMetadata.outputWindowTokens = 16384
                    $clientMetadata.compactionReserveTokens = 12000
                    $clientMetadata.preserveRecentTokens = 8192
                    $clientMetadata.tailTurns = 3
                }
                $profile.modelMetadata[$oldModel] = $clientMetadata
            }
            Write-TestJson -Path $path -Value $profile
        }

        $fixture.TargetPaths = @($script:LocalModelSyncTargetIds | ForEach-Object { Join-Path $providerRoot "$_.json" })
        $fixture.ProtectedPaths = @(
            (Join-Path $providerRoot 'codex-ollama-main.json'),
            (Join-Path $providerRoot 'codex-ollama-qwen3-8-27b.json'),
            (Join-Path $providerRoot 'opencode-ollama-qwen3-8-27b.json'),
            (Join-Path $providerRoot 'codex-ollama-review.json'),
            (Join-Path $catalogRoot $fixture.CandidateCatalog),
            (Join-Path $catalogRoot 'qwen3.8-27b-codex.json'),
            (Join-Path $catalogRoot 'qwen-main-v1-codex.json')
        )
        $fixture.WatchedPaths = @($fixture.TargetPaths) + @($fixture.ProtectedPaths)
        return $fixture
    }

    function Set-CandidateModel {
        param(
            [Parameter(Mandatory)]$Fixture,
            [Parameter(Mandatory)][string]$Model
        )
        $sourcePath = Join-Path $Fixture.ProviderRoot 'codex-ollama-main.json'
        $source = Read-TestJson $sourcePath
        $oldModel = [string]$source.models.primary
        $metadata = $source.modelMetadata[$oldModel]
        $metadata.contextWindowTokens = 262144
        $metadata.outputWindowTokens = 32768
        $source.modelMetadata = [ordered]@{}
        $source.modelMetadata[$Model] = $metadata
        $source.models.primary = $Model
        $source.models.small = $Model
        $source.models.candidates = @($Model)
        $source.displayName = 'Codex CLI + Candidate 32B'
        $source.codexModelCatalog = $Fixture.CandidateCatalog
        $source.sources = @('fixture-source:candidate-model')
        $source.notes = 'fixture-notes:candidate-model'
        $source.compatibility.ollamaArtifact.tag = $Model
        $source.compatibility.ollamaArtifact.numCtx = 262144
        $source.compatibility.ollamaArtifact.baseTag = 'candidate-base:32b'
        $source.compatibility.ollamaArtifact.manifestDigest = 'sha256:' + ('1' * 64)
        $source.compatibility.ollamaArtifact.baseManifestDigest = 'sha256:' + ('2' * 64)
        $source.compatibility.ollamaArtifact.modelBlobDigest = 'sha256:' + ('3' * 64)
        $source.compatibility.ollamaArtifact.parametersDigest = 'sha256:' + ('4' * 64)
        $source.compatibility.ollamaArtifact.draftNumPredict = 0
        Write-TestJson -Path $sourcePath -Value $source

        $catalogPath = Join-Path $Fixture.CatalogRoot $Fixture.CandidateCatalog
        if (Test-Path -LiteralPath $catalogPath) {
            $catalog = Read-TestJson $catalogPath
        } else {
            $template = Read-TestJson (Join-Path $Fixture.CatalogRoot 'qwen3.8-27b-codex.json')
            $catalog = $template
        }
        $catalog.models[0].slug = $Model
        $catalog.models[0].display_name = 'Candidate 32B Q4_K_M'
        $catalog.models[0].description = 'Synthetic catalog for local model synchronization tests.'
        $catalog.models[0].context_window = 262144
        $catalog.models[0].max_context_window = 262144
        Write-TestJson -Path $catalogPath -Value $catalog
        $Fixture.CandidateModel = $Model
    }

    function Invoke-LocalModelSync {
        param(
            [Parameter(Mandatory)][string]$RepoRoot,
            [switch]$Apply
        )
        if ($Apply) {
            $json = & $script:LocalModelSyncScript -RepoRoot $RepoRoot -Json -Apply
        } else {
            $json = & $script:LocalModelSyncScript -RepoRoot $RepoRoot -Json
        }
        ($json -join "`n") | ConvertFrom-Json -AsHashtable -Depth 30
    }

    function Get-TestFileSnapshot {
        param([Parameter(Mandatory)][string[]]$Paths)
        $snapshot = [ordered]@{}
        foreach ($path in $Paths) {
            $snapshot[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
        return $snapshot
    }

    function Assert-TestFileSnapshot {
        param([Parameter(Mandatory)]$Snapshot)
        foreach ($path in $Snapshot.Keys) {
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash |
                Should -BeExactly $Snapshot[$path] -Because $path
        }
    }
}

Describe 'Local model profile synchronization' {
    It 'previews three main changes without writing any profile or catalog bytes' {
        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        $before = Get-TestFileSnapshot -Paths $fixture.WatchedPaths

        $result = Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot

        $result.status | Should -BeExactly 'preview'
        $result.model | Should -BeExactly $fixture.CandidateModel
        $result.context_window_tokens | Should -Be 262144
        @($result.changes).Count | Should -Be 3
        @($result.changes.profile | Sort-Object) | Should -Be @($script:LocalModelSyncTargetIds | Sort-Object)
        @($result.manual_review).Count | Should -Be 3
        $result.live_acceptance | Should -BeExactly 'not_performed'
        Assert-TestFileSnapshot -Snapshot $before
        @(Get-ChildItem -LiteralPath $fixture.ProviderRoot -Filter '*.tmp' -File).Count | Should -Be 0
    }

    It 'applies the candidate only to three mains and preserves engine-owned fields' {
        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        $source = Read-TestJson (Join-Path $fixture.ProviderRoot 'codex-ollama-main.json')
        $before = @{}
        foreach ($id in $script:LocalModelSyncTargetIds) {
            $before[$id] = Read-TestJson (Join-Path $fixture.ProviderRoot "$id.json")
        }
        $protected = Get-TestFileSnapshot -Paths $fixture.ProtectedPaths

        $result = Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply

        $result.status | Should -BeExactly 'applied'
        @($result.changes).Count | Should -Be 3
        @($result.manual_review).Count | Should -Be 3
        $result.live_acceptance | Should -BeExactly 'not_performed'
        foreach ($id in $script:LocalModelSyncTargetIds) {
            $path = Join-Path $fixture.ProviderRoot "$id.json"
            $after = Read-TestJson $path
            $old = $before[$id]
            $after.models.primary | Should -BeExactly $fixture.CandidateModel -Because $id
            $after.models.small | Should -BeExactly $fixture.CandidateModel -Because $id
            $after.models.fixtureExtension | Should -BeExactly $old.models.fixtureExtension -Because $id
            $after.models.primary | Should -BeExactly $after.compatibility.ollamaArtifact.tag -Because $id
            $after.displayName | Should -BeLike "*Candidate 32B" -Because $id
            $after.engine | Should -BeExactly $old.engine -Because $id
            $after.transport | Should -BeExactly $old.transport -Because $id
            $after.provider | Should -BeExactly $old.provider -Because $id
            $after.defaultEffort | Should -Be $old.defaultEffort -Because $id
            $after.effortLevels | Should -Be $old.effortLevels -Because $id
            $after.sources | Should -Be $old.sources -Because $id
            $after.notes | Should -BeExactly $old.notes -Because $id
            ($after.fixtureLaunchOptions | ConvertTo-Json -Compress) |
                Should -BeExactly ($old.fixtureLaunchOptions | ConvertTo-Json -Compress) -Because $id
            $after.Contains('verification') | Should -BeFalse -Because $id
            $after.compatibility.minCliVersion | Should -Be $old.compatibility.minCliVersion -Because $id
            $after.capabilities.machineRun | Should -Be $old.capabilities.machineRun -Because $id
            $after.capabilities.images | Should -Be $source.capabilities.images -Because $id
            if ($id -eq 'claude-ollama-main') {
                $after.endpoint | Should -Be 'http://127.0.0.1:32100'
            } else {
                $after.endpoint | Should -BeExactly $source.endpoint
            }
            if ($old.Contains('modelMetadata')) {
                $oldMetadata = $old.modelMetadata[$old.models.primary]
                $newMetadata = $after.modelMetadata[$fixture.CandidateModel]
                $newMetadata.contextWindowTokens | Should -Be 262144 -Because $id
                $newMetadata.outputWindowTokens | Should -Be $oldMetadata.outputWindowTokens -Because $id
                foreach ($field in @('autoCompactWindowTokens', 'inputWindowTokens', 'compactionReserveTokens', 'preserveRecentTokens', 'tailTurns')) {
                    if ($oldMetadata.Contains($field)) {
                        $newMetadata[$field] | Should -Be $oldMetadata[$field] -Because "$id $field"
                    }
                }
            }
        }
        Assert-TestFileSnapshot -Snapshot $protected
        @(Get-ChildItem -LiteralPath $fixture.ProviderRoot -Filter '*.tmp' -File).Count | Should -Be 0
    }

    It 'leaves target bytes unchanged when an Apply has no remaining changes' {
        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply | Out-Null
        $before = Get-TestFileSnapshot -Paths $fixture.TargetPaths

        $result = Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply

        $result.status | Should -BeExactly 'applied'
        @($result.changes).Count | Should -Be 0
        @($result.manual_review).Count | Should -Be 0
        Assert-TestFileSnapshot -Snapshot $before
    }

    It 'propagates same-tag parameter changes and clears profile-bound verification' {
        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply | Out-Null
        $sourcePath = Join-Path $fixture.ProviderRoot 'codex-ollama-main.json'
        $source = Read-TestJson $sourcePath
        $source.compatibility.ollamaArtifact.parametersDigest = 'sha256:' + ('e' * 64)
        $source.compatibility.ollamaArtifact.draftNumPredict = 1
        Write-TestJson -Path $sourcePath -Value $source

        foreach ($id in $script:LocalModelSyncTargetIds) {
            $path = Join-Path $fixture.ProviderRoot "$id.json"
            $profile = Read-TestJson $path
            $profile.verification = [ordered]@{ result = 'pass'; verified_model = $fixture.CandidateModel }
            Write-TestJson -Path $path -Value $profile
        }
        $before = @{}
        foreach ($id in $script:LocalModelSyncTargetIds) {
            $before[$id] = Read-TestJson (Join-Path $fixture.ProviderRoot "$id.json")
        }

        $result = Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply

        @($result.changes).Count | Should -Be 3
        @($result.manual_review).Count | Should -Be 0
        foreach ($id in $script:LocalModelSyncTargetIds) {
            $after = Read-TestJson (Join-Path $fixture.ProviderRoot "$id.json")
            $after.models.primary | Should -BeExactly $fixture.CandidateModel -Because $id
            $after.compatibility.ollamaArtifact.parametersDigest | Should -BeExactly ('sha256:' + ('e' * 64)) -Because $id
            $after.compatibility.ollamaArtifact.draftNumPredict | Should -Be 1 -Because $id
            $after.Contains('verification') | Should -BeFalse -Because $id
            $after.sources | Should -Be $before[$id].sources -Because $id
            $after.notes | Should -BeExactly $before[$id].notes -Because $id
        }
    }

    It 'rejects a bad candidate context or catalog slug before writing targets' {
        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        $sourcePath = Join-Path $fixture.ProviderRoot 'codex-ollama-main.json'
        $source = Read-TestJson $sourcePath
        $source.modelMetadata[$fixture.CandidateModel].contextWindowTokens = 131072
        Write-TestJson -Path $sourcePath -Value $source
        $before = Get-TestFileSnapshot -Paths $fixture.TargetPaths
        { Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply } | Should -Throw '*262144*'
        Assert-TestFileSnapshot -Snapshot $before

        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        $catalogPath = Join-Path $fixture.CatalogRoot $fixture.CandidateCatalog
        $catalog = Read-TestJson $catalogPath
        $catalog.models[0].slug = 'wrong-model-tag'
        Write-TestJson -Path $catalogPath -Value $catalog
        $before = Get-TestFileSnapshot -Paths $fixture.TargetPaths
        { Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply } | Should -Throw '*catalog model*'
        Assert-TestFileSnapshot -Snapshot $before
    }

    It 'rejects target metadata drift or unknown model metadata before any target write' {
        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        $path = Join-Path $fixture.ProviderRoot 'opencode-ollama-main.json'
        $profile = Read-TestJson $path
        $profile.modelMetadata[$profile.models.primary].contextWindowTokens = 131072
        Write-TestJson -Path $path -Value $profile
        $before = Get-TestFileSnapshot -Paths $fixture.TargetPaths
        { Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply } | Should -Throw '*preserve 262144 context*'
        Assert-TestFileSnapshot -Snapshot $before

        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        $path = Join-Path $fixture.ProviderRoot 'opencode-ollama-main.json'
        $profile = Read-TestJson $path
        $profile.modelMetadata['unreviewed-model'] = [ordered]@{ contextWindowTokens = 262144; outputWindowTokens = 1 }
        Write-TestJson -Path $path -Value $profile
        $before = Get-TestFileSnapshot -Paths $fixture.TargetPaths
        { Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply } | Should -Throw '*explicitly review client output limits*'
        Assert-TestFileSnapshot -Snapshot $before
    }

    It 'rejects an endpoint whose broker origin differs from the candidate main' {
        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        $sourcePath = Join-Path $fixture.ProviderRoot 'codex-ollama-main.json'
        $source = Read-TestJson $sourcePath
        $source.endpoint = 'http://127.0.0.1:32101/v1'
        Write-TestJson -Path $sourcePath -Value $source
        $before = Get-TestFileSnapshot -Paths $fixture.TargetPaths

        { Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply } |
            Should -Throw '*endpoint differs from its managed broker origin*'
        Assert-TestFileSnapshot -Snapshot $before
    }

    It 'rejects alias display names and a main model that reuses the review identity' {
        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        $sourcePath = Join-Path $fixture.ProviderRoot 'codex-ollama-main.json'
        $source = Read-TestJson $sourcePath
        $source.displayName = 'Codex CLI + main'
        Write-TestJson -Path $sourcePath -Value $source
        $before = Get-TestFileSnapshot -Paths $fixture.TargetPaths
        { Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply } | Should -Throw '*actual model name*'
        Assert-TestFileSnapshot -Snapshot $before

        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        $review = Read-TestJson (Join-Path $fixture.ProviderRoot 'codex-ollama-review.json')
        Set-CandidateModel -Fixture $fixture -Model ([string]$review.models.primary)
        $before = Get-TestFileSnapshot -Paths $fixture.TargetPaths
        { Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply } | Should -Throw '*distinct model*'
        Assert-TestFileSnapshot -Snapshot $before
    }

    It 'rejects a catalog shared with a different exact or review profile' {
        foreach ($retainedId in @('codex-ollama-qwen3-8-27b', 'codex-ollama-review')) {
            $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
            $retainedPath = Join-Path $fixture.ProviderRoot "$retainedId.json"
            $retained = Read-TestJson $retainedPath
            $retained.codexModelCatalog = $fixture.CandidateCatalog
            Write-TestJson -Path $retainedPath -Value $retained
            $before = Get-TestFileSnapshot -Paths $fixture.TargetPaths

            { Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply } |
                Should -Throw '*catalog is shared with another model*' -Because $retainedId
            Assert-TestFileSnapshot -Snapshot $before
        }
    }

    It 'restores the first target if a locked second target rejects atomic replacement' {
        $fixture = New-LocalModelSyncFixture -WorkRoot $TestDrive
        $before = Get-TestFileSnapshot -Paths $fixture.TargetPaths
        $lockedPath = Join-Path $fixture.ProviderRoot 'opencode-ollama-main.json'
        $lock = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            { Invoke-LocalModelSync -RepoRoot $fixture.RepoRoot -Apply } | Should -Throw
        } finally {
            $lock.Dispose()
        }
        Assert-TestFileSnapshot -Snapshot $before
        @(Get-ChildItem -LiteralPath $fixture.ProviderRoot -Filter '*.tmp' -File).Count | Should -Be 0
    }
}
