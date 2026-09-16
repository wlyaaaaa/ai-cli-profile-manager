BeforeAll {
    $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    function Write-FixtureJson($Path, $Value) {
        [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 60), [Text.UTF8Encoding]::new($false))
    }
    function Write-MockOllamaArtifact([int]$Batch) {
        $parameters=@{num_ctx=262144;num_batch=$Batch}
        if($global:LocalModelSyncTestAlterParameters){$parameters.num_ctx=32768}
        $bytes=[Text.Encoding]::UTF8.GetBytes(($parameters|ConvertTo-Json -Compress)+"`n")
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        [IO.File]::WriteAllBytes((Join-Path $global:LocalModelSyncTestModelsRoot "blobs/sha256-$hash"),$bytes)
        $manifest=@{config=@{digest=('sha256:'+'e'*64)};layers=@(
            @{mediaType='application/vnd.ollama.image.model';digest=('sha256:'+'d'*64);size=123},
            @{mediaType='application/vnd.ollama.image.params';digest="sha256:$hash";size=$bytes.Length})}
        $path=Join-Path $global:LocalModelSyncTestModelsRoot 'manifests/registry.ollama.ai/library/example-8b/256k'
        Write-FixtureJson $path $manifest
        return (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    }
}
Describe 'Dedicated Ollama model set synchronization' {
    AfterAll {
        Get-Variable -Name 'LocalModelSyncTest*' -Scope Global | Remove-Variable -Scope Global
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
    It 'previews runtime batch updates without touching the source or Ollama' {
        $source=Join-Path $fixture 'data/providers/fixture-local.json'
        $before=Get-Content $source -Raw
        $result=& (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -OllamaNumBatch 512 -Json|ConvertFrom-Json
        $result.ollama_parameter_updates.Count | Should -Be 1
        $result.ollama_parameter_updates[0].before | Should -Be 128
        $result.ollama_parameter_updates[0].after | Should -Be 512
        (Get-Content $source -Raw) | Should -BeExactly $before
        $global:LocalModelSyncTestDeleted.Count | Should -Be 0
    }
    It 'rebuilds an enabled desktop bridge when its disposable build output is absent' {
        Set-Content (Join-Path $fixture 'scripts/Set-CodexDesktopLocalModels.ps1') @'
param($Mode,[switch]$Json)
$binary=Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/desktop-bridge/AiCli.CodexDesktopBridge.exe'
if($Mode -eq 'Build'){New-Item -ItemType Directory -Path (Split-Path $binary) -Force|Out-Null;Set-Content $binary 'fixture'}
if($Mode -eq 'Enable' -and -not (Test-Path $binary)){throw 'Run this script with -Mode Build first.'}
'{"status":"enabled","restartRequired":false}'
'@
        $result=& (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -Apply -Json|ConvertFrom-Json
        $result.status | Should -Be 'applied'
        Test-Path (Join-Path $fixture 'dist/desktop-bridge/AiCli.CodexDesktopBridge.exe') | Should -BeTrue
    }
    Context 'native parameter changes' {
        BeforeEach {
            $global:LocalModelSyncTestBatch=128
            $global:LocalModelSyncTestRejectUpdate=$false
            $global:LocalModelSyncTestRejectRollback=$false
            $global:LocalModelSyncTestAlterParameters=$false
            $global:LocalModelSyncTestModelsRoot=Join-Path $fixture 'ollama'
            foreach($dir in @('blobs','manifests/registry.ollama.ai/library/example-8b')){New-Item -ItemType Directory -Path (Join-Path $global:LocalModelSyncTestModelsRoot $dir) -Force|Out-Null}
            $global:LocalModelSyncTestDigest=Write-MockOllamaArtifact 128
            $global:LocalModelSyncTestTags[0].digest=$global:LocalModelSyncTestDigest
            $source=Join-Path $fixture 'data/providers/fixture-local.json'
            $p=Get-Content $source -Raw|ConvertFrom-Json -AsHashtable
            $p.compatibility.ollamaArtifact.manifestDigest='sha256:'+$global:LocalModelSyncTestDigest
            Write-FixtureJson $source $p
            $c=Get-Content $consumerPath -Raw|ConvertFrom-Json -AsHashtable
            $c.ollamaModelsPath=$global:LocalModelSyncTestModelsRoot
            Write-FixtureJson $consumerPath $c
            Mock Invoke-RestMethod {
                param($Uri,$Method,$Body)
                $request=if($Body){$Body|ConvertFrom-Json}else{$null}
                if ($Uri -like '*/api/tags') { return @{models=@($global:LocalModelSyncTestTags)} }
                if ($Uri -like '*/api/show') {
                    $identity=if($global:LocalModelSyncTestRejectUpdate -and $global:LocalModelSyncTestBatch -eq 512){'changed-weights'}else{'same-weights'}
                    return @{parameters="num_ctx 262144`nnum_batch $global:LocalModelSyncTestBatch";model_info=@{identity=$identity};details=@{quantization_level='Q4_K_M';parent_model=$(if($global:LocalModelSyncTestBatch -eq 512){'example-8b:256k'}else{''})};capabilities=@('completion');template='same template'}
                }
                if ($Uri -like '*/api/copy') {
                    $entry=@($global:LocalModelSyncTestTags|Where-Object name -CEQ $request.source)[0]
                    $global:LocalModelSyncTestTags=@($global:LocalModelSyncTestTags|Where-Object name -CNE $request.destination)+@{name=$request.destination;digest=$entry.digest}
                    $path=Join-Path $global:LocalModelSyncTestModelsRoot 'manifests/registry.ollama.ai/library/example-8b/256k'
                    if($request.destination -eq 'example-8b:256k'){
                        $global:LocalModelSyncTestBatch=128
                        [IO.File]::WriteAllText($path,$global:LocalModelSyncTestBackupManifest)
                        if($global:LocalModelSyncTestRejectRollback){@($global:LocalModelSyncTestTags|Where-Object name -CEQ $request.destination)[0].digest='f'*64}
                    }else{$global:LocalModelSyncTestBackupManifest=Get-Content $path -Raw}
                    return
                }
                if ($Uri -like '*/api/create') {
                    $global:LocalModelSyncTestBatch=$request.parameters.num_batch
                    @($global:LocalModelSyncTestTags|Where-Object name -CEQ $request.model)[0].digest=Write-MockOllamaArtifact $global:LocalModelSyncTestBatch
                    return @{status='success'}
                }
                if ($Uri -like '*/api/delete') {
                    $global:LocalModelSyncTestDeleted+=$request.model
                    $global:LocalModelSyncTestTags=@($global:LocalModelSyncTestTags|Where-Object name -CNE $request.model)
                    return
                }
                throw "Unexpected endpoint: $Uri"
            }
        }
        It 'updates the runtime and source together, retains context, and removes its temporary copy' {
            & (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -OllamaNumBatch 512 -Apply -Json | Out-Null
            $p=Get-Content (Join-Path $fixture 'data/providers/fixture-local.json') -Raw|ConvertFrom-Json
            $p.compatibility.ollamaArtifact.parameters.num_batch | Should -Be 512
            $p.compatibility.ollamaArtifact.parameters.num_ctx | Should -Be 262144
            $p.compatibility.ollamaArtifact.manifestDigest | Should -Be ('sha256:'+$global:LocalModelSyncTestTags[0].digest)
            @($global:LocalModelSyncTestTags.name) | Should -Be @('example-8b:256k')
            $next=& (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -OllamaNumBatch 512 -Json|ConvertFrom-Json
            $next.ollama_parameter_updates.Count | Should -Be 0
        }
        It 'restores the original tag and leaves consumers untouched if model identity changes' {
            $source=Join-Path $fixture 'data/providers/fixture-local.json'
            $sourceBefore=Get-Content $source -Raw
            $consumerBefore=Get-Content $opPath -Raw
            $global:LocalModelSyncTestRejectUpdate=$true
            { & (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -OllamaNumBatch 512 -Apply -Json } | Should -Throw '*changed model content*'
            (Get-Content $source -Raw) | Should -BeExactly $sourceBefore
            (Get-Content $opPath -Raw) | Should -BeExactly $consumerBefore
            @($global:LocalModelSyncTestTags|Where-Object name -CEQ 'example-8b:256k')[0].digest | Should -Be $global:LocalModelSyncTestDigest
            @($global:LocalModelSyncTestTags|Where-Object name -Like 'aicli-sync-*').Count | Should -Be 0
        }
        It 'rejects an unexpected context change in the actual parameter layer' {
            $global:LocalModelSyncTestAlterParameters=$true
            { & (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -OllamaNumBatch 512 -Apply -Json } | Should -Throw '*parameter layer differs*'
            @($global:LocalModelSyncTestTags|Where-Object name -CEQ 'example-8b:256k')[0].digest | Should -Be $global:LocalModelSyncTestDigest
        }
        It 'keeps the native recovery copy when rollback digest verification fails' {
            $global:LocalModelSyncTestRejectUpdate=$true
            $global:LocalModelSyncTestRejectRollback=$true
            { & (Join-Path $fixture 'scripts/Sync-LocalModelConfiguration.ps1') -ConsumerConfigPath $consumerPath -OllamaNumBatch 512 -Apply -Json } | Should -Throw '*recovery copy retained*'
            @($global:LocalModelSyncTestTags|Where-Object name -Like 'aicli-sync-*').Count | Should -Be 1
        }
    }
}
