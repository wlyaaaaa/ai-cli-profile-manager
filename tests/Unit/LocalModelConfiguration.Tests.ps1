BeforeAll {
    $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    function Write-FixtureJson($Path, $Value) {
        [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 60), [Text.UTF8Encoding]::new($false))
    }
}
Describe 'Dedicated Ollama model set synchronization' {
    AfterAll {
        Remove-Variable LocalModelSyncTestTags,LocalModelSyncTestDeleted,LocalModelSyncTestDigest -Scope Global -ErrorAction SilentlyContinue
    }
    AfterEach {
        Get-Module AiCliProfileManager -All | Where-Object ModuleBase -Like "$fixture*" | Remove-Module -Force
    }
    BeforeEach {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($path in @('scripts','data/providers','src/AiCliProfileManager')) {
            New-Item -ItemType Directory -Path (Join-Path $fixture $path) -Force | Out-Null
        }
        Copy-Item (Join-Path $sourceRoot 'scripts/Sync-LocalModelConfiguration.ps1') (Join-Path $fixture 'scripts')
        Set-Content (Join-Path $fixture 'scripts/Install.ps1') 'param([switch]$Force,[switch]$SkipShellIntegration)'
        Set-Content (Join-Path $fixture 'scripts/Set-CodexDesktopLocalModels.ps1') 'param($Mode,[switch]$Json) ''{"status":"disabled"}'''
        Set-Content (Join-Path $fixture 'src/AiCliProfileManager/Fixture.psm1') 'function Get-AiCliResolvedProfile { param($Id) $Id }; function Get-AiCliProfileFingerprint { param($Profile) "fixture-fingerprint" }'
        New-ModuleManifest -Path (Join-Path $fixture 'src/AiCliProfileManager/AiCliProfileManager.psd1') -RootModule Fixture.psm1
        $global:LocalModelSyncTestDigest = 'a' * 64
        $profile = @{
            engine='codex'; provider='ollama'; displayName='Codex CLI + Example 8B'; endpoint='http://127.0.0.1:32100/v1'
            models=@{primary='example-8b:256k'}; modelMetadata=@{'example-8b:256k'=@{contextWindowTokens=262144;outputWindowTokens=8192}}
            capabilities=@{tools=$true;images=$false}; defaultEffort='max'; codexProviderId='fixture'; transport='responses'
            compatibility=@{ollamaArtifact=@{manifestDigest="sha256:$global:LocalModelSyncTestDigest";parameters=@{num_ctx=262144;num_batch=128}}}
        }
        Write-FixtureJson (Join-Path $fixture 'data/providers/fixture-local.json') $profile
        Write-FixtureJson (Join-Path $fixture 'data/local-model-set.json') @{profiles=@('fixture-local');clients=@{'fixture-local'=@{opencodeKey='local';backendId='local-default'}}}
        $opPath=Join-Path $fixture 'opencode.json'
        Write-FixtureJson $opPath @{provider=@{local=@{options=@{};models=@{old=@{}}};cloud=@{models=@{future=@{name='Future cloud'}}}};model='cloud/future'}
        $registryPath=Join-Path $fixture 'registry.json'
        Write-FixtureJson $registryPath @{backends=@{};aliases=@{};default_backend='local-default'}
        $consumerPath=Join-Path $fixture 'consumers.json'
        Write-FixtureJson $consumerPath @{openCodeConfig=$opPath;openCodeProvider='local';toolkitRegistry=$registryPath;registryMirror=$registryPath;ollamaOrigin='http://localhost:11434'}
        $global:LocalModelSyncTestTags=@(@{name='example-8b:256k';digest=$global:LocalModelSyncTestDigest},@{name='unregistered-extra:latest';digest=('b'*64)})
        $global:LocalModelSyncTestDeleted=@()
        Mock Invoke-RestMethod {
            param($Uri,$Method,$Body)
            if ($Uri -like '*/api/tags') { return @{models=@($global:LocalModelSyncTestTags)} }
            if ($Uri -like '*/api/delete') {
                $tag=($Body|ConvertFrom-Json).model
                $global:LocalModelSyncTestDeleted+=$tag
                $global:LocalModelSyncTestTags=@($global:LocalModelSyncTestTags|Where-Object name -CNE $tag)
                return
            }
            throw "Unexpected endpoint: $Uri"
        }
    }
    It 'previews extras without deleting or changing consumers' {
        $before=Get-Content $opPath -Raw
        $result=& (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -Json|ConvertFrom-Json
        $result.retired_models | Should -Be @('unregistered-extra:latest')
        $global:LocalModelSyncTestDeleted.Count | Should -Be 0
        (Get-Content $opPath -Raw) | Should -BeExactly $before
    }
    It 'removes unregistered extras, preserves cloud models and is idempotent' {
        $result=& (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -Apply -Json|ConvertFrom-Json
        $global:LocalModelSyncTestDeleted | Should -Be @('unregistered-extra:latest')
        $op=Get-Content $opPath -Raw|ConvertFrom-Json -AsHashtable
        $op.model | Should -Be 'cloud/future'
        $op.provider.cloud.models.future.name | Should -Be 'Future cloud'
        @($op.provider.local.models.Keys) | Should -Be @('local')
        $op.provider.local.models.local.modalities.input.GetType().IsArray | Should -BeTrue
        @($op.provider.local.models.local.modalities.input) | Should -Be @('text')
        $preview=& (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -Json|ConvertFrom-Json
        $preview.changed_files.Count | Should -Be 0
        $preview.retired_models.Count | Should -Be 0
    }
    It 'rejects a missing or changed retained artifact before any consumer write or deletion' {
        $global:LocalModelSyncTestTags[0].digest='c'*64
        $before=Get-Content $opPath -Raw
        { & (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -Apply -Json } | Should -Throw '*Prepare the declared Ollama artifact*'
        $global:LocalModelSyncTestDeleted.Count | Should -Be 0
        (Get-Content $opPath -Raw) | Should -BeExactly $before
    }
}
