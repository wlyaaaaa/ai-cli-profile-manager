#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.0.0'}
Describe 'Gemini V2 model data and deterministic projections' {
    BeforeAll {
        $repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $generator=Join-Path $repo 'scripts\Build-GeminiCodexCatalog.ps1'
        . (Join-Path $repo 'scripts\GeminiModelData.ps1')
        . (Join-Path $repo 'src\AiCliProfileManager\Private\Paths.ps1')
        . (Join-Path $repo 'src\AiCliProfileManager\Private\JsonStore.ps1')
        . (Join-Path $repo 'src\AiCliProfileManager\Private\GeminiBridgeService.ps1')
        $schema=Join-Path $repo 'data\schemas\gemini-model-set.schema.json'
        function New-Models {
            $d=Get-Content (Join-Path $repo 'data\gemini-models.json') -Raw|ConvertFrom-Json -AsHashtable -Depth 60
            $next=($d.models[0]|ConvertTo-Json -Depth 60)|ConvertFrom-Json -AsHashtable -Depth 60
            $next.id='gemini-next-fixture';$next.profileId='codex-gemini-next-fixture';$next.displayName='Gemini synthetic next'
            $next.menuModel='gemini-next-exact-fixture';$next.defaultEffort='medium';$next.contextWindow=262144
            $next.efforts=@(@{effort='medium';model='gemini-next-exact-fixture';cliEffort='high'})
            $d.models+=@($next)
            return $d
        }
        function Save-Models($Data) {
            $path=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.json')
            [IO.File]::WriteAllText($path,($Data|ConvertTo-Json -Depth 60),[Text.UTF8Encoding]::new($false));return $path
        }
    }
    It 'validates current and future model metadata without executing any model' {
        $path=Save-Models (New-Models)
        $m=Read-AiCliGeminiModelSet $path $schema
        $m.models.Count|Should -Be 2
        $m.models[1].efforts[0].cliEffort|Should -Be 'high'
    }
    It 'generates multiple profiles and catalogs solely from data' {
        $path=Save-Models (New-Models);$out=Join-Path $TestDrive 'source-output'
        $result=& $generator -SourceRoot $repo -ModelSetPath $path -OutputRoot $out
        $result.models|Should -Be 2
        $manifest=Get-Content (Join-Path $out 'providers\codex-gemini-next-fixture.json') -Raw|ConvertFrom-Json
        $manifest.models.primary|Should -Be 'gemini-next-exact-fixture'
        @($manifest.effortLevels)|Should -Be @('medium')
        $catalog=Get-Content (Join-Path $out 'model-catalogs\gemini-next-fixture-codex.json') -Raw|ConvertFrom-Json -Depth 100
        $catalog.models[0].context_window|Should -Be 262144
        $catalog.models[0].auto_compact_token_limit|Should -Be 235929
        $catalog.models[0].base_instructions|Should -Match 'fresh conversation'
        $catalog.models[0].base_instructions|Should -Not -Match 'glm-5.3'
    }
    It 'creates a bounded runtime bundle without rebuilding the adapter' {
        $path=Save-Models (New-Models);$out=Join-Path $TestDrive 'bundle'
        $result=& $generator -SourceRoot $repo -ModelSetPath $path -OutputRoot $out -RuntimeBundle
        @($result.files).Count|Should -Be 2
        @(Get-ChildItem $out -File).Count|Should -Be 2
        $set=Get-Content (Join-Path $out 'gemini-models.json') -Raw|ConvertFrom-Json
        $catalog=Get-Content (Join-Path $out 'gemini-codex-catalog.json') -Raw|ConvertFrom-Json -Depth 100
        $catalog.entries.Count|Should -Be $set.models.Count
        $catalog.entries[1].profileId|Should -Be 'codex-gemini-next-fixture'
    }
    It 'does not write any destination while checking data' {
        $path=Save-Models (New-Models);$out=Join-Path $TestDrive 'check-only'
        $null=& $generator -SourceRoot $repo -ModelSetPath $path -OutputRoot $out -CheckOnly
        Test-Path $out|Should -BeFalse
    }
    It 'rejects collisions without creating output files' {
        $m=New-Models;$m.models[1].profileId=$m.models[0].profileId.ToUpperInvariant();$path=Save-Models $m;$out=Join-Path $TestDrive 'invalid-output'
        {& $generator -SourceRoot $repo -ModelSetPath $path -OutputRoot $out}|Should -Throw '*duplicate_identity*'
        Test-Path $out|Should -BeFalse
    }
    It 'rejects unknown executable data and unsupported capabilities' {
        $m=New-Models;$m.models[1].command='not-allowed';$path=Save-Models $m
        {Read-AiCliGeminiModelSet $path $schema}|Should -Throw
        $m=New-Models;$m.models[1].inputModalities=@('text','image');$path=Save-Models $m
        {Read-AiCliGeminiModelSet $path $schema}|Should -Throw
    }
    It 'rejects duplicate properties and unbound default mappings' {
        $p=Join-Path $TestDrive 'duplicate.json';[IO.File]::WriteAllText($p,'{"schema":"x","schema":"y"}')
        {Read-AiCliGeminiModelSet $p $schema}|Should -Throw '*duplicate_property*'
        $m=New-Models;$m.models[1].defaultEffort='high';$path=Save-Models $m
        {Read-AiCliGeminiModelSet $path $schema}|Should -Throw '*default_mapping_invalid*'
    }
    It 'discovers both models from the installed snapshot not a hardcoded source file' {
        $path=Save-Models (New-Models);$script:bundle=Join-Path $TestDrive 'discovery-release'
        $null=& $generator -SourceRoot $repo -ModelSetPath $path -OutputRoot $script:bundle -RuntimeBundle
        $script:fakeDeployment=[pscustomobject]@{Executable=(Join-Path $script:bundle 'AiCli.GeminiResponsesBridge.exe');Endpoint='http://127.0.0.1:43199/v1';Settings=@{ModelCatalogPath=(Join-Path $script:bundle 'gemini-models.json')}}
        Mock Get-AiCliGeminiDeployment {$script:fakeDeployment}
        Mock Get-AiCliGeminiCodexSearchConfiguration {@{enabled=$true}}
        $models=@(Get-AiCliDesktopGeminiModels)
        $models.Count|Should -Be 2
        $models[1].model|Should -Be 'gemini-next-exact-fixture'
        $models[1].defaultEffort|Should -Be 'medium'
        $models[1].providerId|Should -Be 'aicli_google_antigravity'
        $models[1].adapterProtocol|Should -Be 'gemini-fresh-transaction-v2'
        $models[1].provider.request_max_retries|Should -Be 0
    }
}