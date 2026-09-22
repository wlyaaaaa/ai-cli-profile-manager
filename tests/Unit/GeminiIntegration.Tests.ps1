#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.0.0'}
Describe 'Gemini consumer adapter integration contracts' {
    BeforeAll {
        $root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        . (Join-Path $root 'src\AiCliProfileManager\Private\Paths.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\JsonStore.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\PortAllocator.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\GeminiBridgeService.ps1')
        function Get-AiCliSettings { @{proxyPorts=@{}} }
        function New-GeminiFixture {
            $paths=Get-AiCliGeminiPaths
            $release='0123456789abcdef'
            $dir=Join-Path $paths.Root ('releases\'+$release)
            [IO.Directory]::CreateDirectory($dir)|Out-Null
            $files=@('AiCli.GeminiResponsesBridge.exe','AiCli.GeminiResponsesBridge.dll','AiCli.GeminiResponsesBridge.runtimeconfig.json')|ForEach-Object {
                $p=Join-Path $dir $_;[IO.File]::WriteAllText($p,'test-only; not executable')
                @{path=$_;sha256=(Get-FileHash $p).Hash.ToLowerInvariant()}
            }
            $plain=[Text.Encoding]::UTF8.GetBytes(('a'*64))
            try {
                [IO.File]::WriteAllBytes($paths.Token,[Security.Cryptography.ProtectedData]::Protect($plain,[Text.Encoding]::UTF8.GetBytes('aicli.gemini-local-token.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser))
            } finally { [Array]::Clear($plain,0,$plain.Length) }
            Write-AiCliJsonFile -Path $paths.Settings -Value @{Port=43199}
            Write-AiCliJsonFile -Path $paths.Deployment -Value @{schema='aicli.gemini-deployment.v1';enabled=$true;releaseId=$release;port=43199;files=@($files);settingsSha256=(Get-FileHash $paths.Settings).Hash.ToLowerInvariant()}
            return $paths
        }
    }
    BeforeEach {
        # Retained pre-freeze engine contracts execute only against synthetic local fixtures.
        Mock Test-AiCliGeminiIntegrationFrozen { $false }
        $script:testLocalRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Get-AiCliAppPaths { [pscustomobject]@{LocalRoot=$script:testLocalRoot;LocksDir=(Join-Path $script:testLocalRoot 'locks');BackupsDir=(Join-Path $script:testLocalRoot 'backups')} }
    }
    It 'does not create application files or start a model during absent deployment discovery' {
        Get-AiCliGeminiDeployment | Should -BeNullOrEmpty
        Get-AiCliDesktopGeminiModels | Should -BeNullOrEmpty
        Test-Path $script:testLocalRoot | Should -BeFalse
    }
    It 'keeps malformed metadata reads read-only and fails closed' {
        $paths=Get-AiCliGeminiPaths
        [IO.Directory]::CreateDirectory($paths.Root)|Out-Null
        [IO.File]::WriteAllText($paths.Deployment,'{broken')
        {Get-AiCliGeminiDeployment} | Should -Throw '*metadata_invalid*'
        @(Get-ChildItem $paths.Root -File).Count | Should -Be 1
    }
    It 'verifies the exact release, settings and locally encrypted token' {
        $paths=New-GeminiFixture
        $d=Get-AiCliGeminiDeployment -VerifyFiles
        $d.ReleaseId | Should -Be '0123456789abcdef'
        $d.Endpoint | Should -Be 'http://127.0.0.1:43199/v1'
        (Get-AiCliGeminiLocalToken).Length | Should -Be 64
        [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($paths.Token)) | Should -Not -Match ('a'*64)
    }
    It 'rejects extra or changed release files before starting a process' {
        $paths=New-GeminiFixture
        $d=Get-AiCliGeminiDeployment
        [IO.File]::AppendAllText($d.Executable,'changed')
        {Get-AiCliGeminiDeployment -VerifyFiles} | Should -Throw '*hash_changed*'
        [IO.File]::WriteAllText((Join-Path (Split-Path $d.Executable) 'extra.txt'),'extra')
        {Get-AiCliGeminiDeployment -VerifyFiles} | Should -Throw '*file_set_changed*'
    }
    It 'rejects an endpoint drift even when the metadata remains parseable' {
        $paths=New-GeminiFixture
        Write-AiCliJsonFile -Path $paths.Settings -Value @{Port=43200}
        {Get-AiCliGeminiDeployment -VerifyFiles} | Should -Throw '*port_identity_invalid*'
    }
    It 'does not report a disabled release as configured' {
        $paths=New-GeminiFixture
        $d=Read-AiCliGeminiJson $paths.Deployment;$d.enabled=$false
        Write-AiCliJsonFile $paths.Deployment $d
        Get-AiCliGeminiDeployment | Should -BeNullOrEmpty
    }
    It 'reserves the third managed proxy without treating it as either existing proxy' {
        Mock Get-AiCliSettings { @{proxyPorts=@{ccp=43197;cliproxy=43198;antigravity=43199}} }
        Test-AiCliPortReservedByOtherProxy -ProxyId ccp -Port 43199 | Should -BeTrue
        Test-AiCliPortReservedByOtherProxy -ProxyId cliproxy -Port 43199 | Should -BeTrue
        Test-AiCliPortReservedByOtherProxy -ProxyId antigravity -Port 43198 | Should -BeTrue
        Test-AiCliPortReservedByOtherProxy -ProxyId antigravity -Port 43199 | Should -BeFalse
    }
    It 'declares the exact model and consumer route without a Google API secret' {
        $m=Get-Content (Join-Path $root 'data\providers\codex-gemini-3-8-flash.json') -Raw|ConvertFrom-Json
        $m.provider | Should -Be 'google-antigravity'
        $m.transport | Should -Be 'managed-proxy'
        $m.auth.type | Should -Be 'consumer-oauth'
        $m.requiresSecret | Should -BeFalse
        $m.models.primary | Should -Be 'gemini-3.8-flash-high'
        @($m.effortLevels) | Should -Be @('low','medium','high')
        $m.compatibility.antigravitySha256 | Should -Match '^[a-f0-9]{64}$'
    }
    It 'uses the GLM public summary presentation policy without its model identity' {
        . (Join-Path $root 'scripts\CodexUserCommunicationPolicy.ps1')
        $j=Get-Content (Join-Path $root 'data\model-catalogs\gemini-3.8-flash-codex.json') -Raw|ConvertFrom-Json -Depth 100
        $m=$j.models[0]
        $m.slug | Should -Be 'gemini-3.8-flash-high'
        $m.default_reasoning_summary | Should -Be 'detailed'
        $m.base_instructions.Replace("`r`n","`n") | Should -Match ([regex]::Escape((Get-AiCliCodexSummaryPresentationPolicy -Provider glm).Replace("`r`n","`n").Trim()))
        $m.model_messages.instructions_template | Should -Match 'visible_summary'
        $m.context_window | Should -Be 1048576
        $m.auto_compact_token_limit | Should -Be 943718
        $m.supports_search_tool | Should -BeFalse
        @($m.input_modalities) | Should -Be @('text')
    }
    It 'verifies the V2 acceptance receipt against release model data and CLI identity' {
        $paths=New-GeminiFixture
        $d=Read-AiCliGeminiJson $paths.Deployment
        $settings=Read-AiCliGeminiJson $paths.Settings
        $release=[string]$d.releaseId;$releaseRoot=Join-Path $paths.Root ('releases\'+$release)
        $modelSetPath=Join-Path $releaseRoot 'gemini-models.json';[IO.File]::WriteAllText($modelSetPath,'{"schema":"fixture"}',[Text.UTF8Encoding]::new($false))
        $d.files+=@(@{path='gemini-models.json';sha256=(Get-FileHash $modelSetPath).Hash.ToLowerInvariant()})
        $settings.ModelCatalogPath=$modelSetPath;$settings.AgySha256='a'*64;Write-AiCliJsonFile $paths.Settings $settings
        $acceptancePath=Join-Path $paths.Root ('model-acceptance-'+$release+'.json')
        $acceptance=@{schema='aicli.gemini-model-acceptance.v1';pass=$true;candidateReleaseId=$release;modelSetSha256=(Get-FileHash $modelSetPath).Hash.ToLowerInvariant();cliSha256=$settings.AgySha256}
        Write-AiCliJsonFile $acceptancePath $acceptance
        $d.driverProtocolVersion=2;$d.modelAcceptanceFile=[IO.Path]::GetFileName($acceptancePath);$d.modelAcceptanceSha256=(Get-FileHash $acceptancePath).Hash.ToLowerInvariant();$d.settingsSha256=(Get-FileHash $paths.Settings).Hash.ToLowerInvariant();Write-AiCliJsonFile $paths.Deployment $d
        (Get-AiCliGeminiDeployment -VerifyFiles).DriverProtocolVersion | Should -Be 2
        [IO.File]::AppendAllText($acceptancePath,' ')
        {Get-AiCliGeminiDeployment -VerifyFiles}|Should -Throw '*acceptance_hash_changed*'
    }}
