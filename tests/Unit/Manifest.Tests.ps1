#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Manifest' {
    BeforeAll {
        function Assert-CanonicalCatalogBytes {
            param(
                [Parameter(Mandatory)][string]$Path
            )

            $bytes = [IO.File]::ReadAllBytes($Path)
            $hasUtf8Bom = $bytes.Length -ge 3 -and
                $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF

            $bytes.Length | Should -BeGreaterThan 0
            $hasUtf8Bom | Should -BeFalse
            ([Array]::IndexOf($bytes, [byte]13) -ge 0) | Should -BeFalse
            $bytes[-1] | Should -Be 10
            [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | Should -Not -BeNullOrEmpty
        }

        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module -Name AiCliProfileManager -All -ErrorAction SilentlyContinue |
            Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
        . (Join-Path $root 'src\AiCliProfileManager\Private\Brand.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\Paths.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\JsonStore.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\Redaction.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\ManifestService.ps1')
    }

    It 'loads all public templates' {
        $all = Import-AiCliProviderManifests
        $all.Keys.Count | Should -BeGreaterOrEqual 16
        $all.Contains('codex-official') | Should -BeTrue
        $all.Contains('codex-spark-xhigh') | Should -BeTrue
        $all.Contains('claude-deepseek') | Should -BeTrue
        $all.Contains('oi-qwen-paygo') | Should -BeFalse
        $all.Contains('oi-ollama') | Should -BeTrue
        $all.Contains('oi-deepseek') | Should -BeTrue
        $all.Contains('qwen-code-ollama-main') | Should -BeTrue
        $all.Contains('opencode-ollama-main') | Should -BeTrue
        $all.Contains('opencode-ollama-qwen3-8-27b') | Should -BeTrue
        $all.Contains('codex-ollama-main') | Should -BeTrue
        $all.Contains('codex-ollama-qwen3-8-27b') | Should -BeTrue
        $all.Contains('claude-ollama-main') | Should -BeTrue
        $all.Contains('codex-deepseek') | Should -BeTrue
    }

    It 'exposes the exact supported DeepSeek Flash model through its isolated catalog' {
        $all = Import-AiCliProviderManifests
        $manifest = $all['codex-deepseek']

        $manifest.engine | Should -Be 'codex'
        $manifest.provider | Should -Be 'deepseek'
        $manifest.transport | Should -Be 'responses'
        $manifest.endpoint | Should -Be 'https://api.deepseek.com'
        $manifest.models.primary | Should -Be 'deepseek-v4-flash'
        @($manifest.models.candidates) | Should -Be @('deepseek-v4-flash')
        @($manifest.models.reserved) | Should -BeNullOrEmpty
        $manifest.codexModelCatalog | Should -Be 'deepseek-v4-flash.json'

        $catalogPath = Join-Path $root 'data\model-catalogs\deepseek-v4-flash.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json
        @($catalog.models).Count | Should -Be 1
        $catalog.models[0].slug | Should -Be 'deepseek-v4-flash'
        $catalog.models[0].context_window | Should -Be 1048576
        $catalog.models[0].max_context_window | Should -Be 1048576
        $catalog.models[0].minimal_client_version | Should -Be '0.144.0'
        @($catalog.models[0].supported_reasoning_levels.effort) | Should -Be @('low', 'high', 'max')
        (Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8) | Should -Not -Match 'deepseek-v4-pro'
        $manifest.defaultEffort | Should -Be 'max'
        $manifest.compatibility.modelVersion | Should -Be 'DeepSeek-V4-Flash-0731'
    }

    It 'keeps non-Codex DeepSeek templates Flash-only while Codex Pro stays isolated' {
        $all = Import-AiCliProviderManifests
        foreach ($id in @('claude-deepseek', 'oi-deepseek')) {
            $manifest = $all[$id]
            $manifest.models.primary | Should -Be 'deepseek-v4-flash' -Because $id
            $manifest.models.small | Should -Be 'deepseek-v4-flash' -Because $id
            @($manifest.models.candidates) | Should -Be @('deepseek-v4-flash') -Because $id
            @($manifest.models.reserved) | Should -BeNullOrEmpty -Because $id
        }
        $all['codex-deepseek-v4-pro'].models.primary | Should -Be 'deepseek-v4-pro'
        @($all['codex-deepseek-v4-pro'].models.candidates) | Should -Be @('deepseek-v4-pro')
    }

    It 'binds third-party Claude and OpenCode profiles to exact model context metadata' {
        $all = Import-AiCliProviderManifests
        $runtimeTag = 'qwen3.8-27b:256k'
        $all['claude-deepseek'].compatibility.minCliVersion | Should -Be '2.1.193'
        $all['claude-deepseek'].modelMetadata.'deepseek-v4-flash'.contextWindowTokens | Should -Be 1000000
        $all['claude-deepseek'].modelMetadata.'deepseek-v4-flash'.autoCompactWindowTokens | Should -Be 1000000
        $all['claude-ollama-main'].compatibility.minCliVersion | Should -Be '2.1.193'
        $all['claude-ollama-main'].modelMetadata.$runtimeTag.contextWindowTokens | Should -Be 262144
        $all['claude-ollama-main'].modelMetadata.$runtimeTag.outputWindowTokens | Should -Be 32768
        $all['claude-ollama-main'].modelMetadata.$runtimeTag.autoCompactWindowTokens | Should -Be 262144
        $all['opencode-ollama-main'].modelMetadata.$runtimeTag.contextWindowTokens | Should -Be 262144
        $all['opencode-ollama-main'].modelMetadata.$runtimeTag.inputWindowTokens | Should -Be 262144
        $all['opencode-ollama-main'].modelMetadata.$runtimeTag.outputWindowTokens | Should -Be 32768
        $all['opencode-ollama-main'].modelMetadata.$runtimeTag.compactionReserveTokens | Should -Be 20000
        $all['opencode-ollama-qwen3-8-27b'].modelMetadata.$runtimeTag.contextWindowTokens | Should -Be 262144
        $all['opencode-ollama-qwen3-8-27b'].modelMetadata.$runtimeTag.outputWindowTokens | Should -Be 32768
    }

    It 'publishes only the exact Qwen3.7 Max 06-08 Codex snapshot and keeps every legacy route absent' {
        $all = Import-AiCliProviderManifests
        $all.Contains('codex-qwen3-7-max-paygo') | Should -BeTrue
        $all['codex-qwen3-7-max-paygo'].models.primary | Should -Be 'qwen3.7-max-2026-06-08'
        foreach ($id in @(
            'codex-qwen-paygo', 'codex-qwen-token-plan', 'codex-qwen3-7-plus-paygo',
            'claude-qwen-paygo', 'claude-qwen-token-plan', 'claude-qwen-coding-plan',
            'oi-qwen-paygo'
        )) {
            $all.Contains($id) | Should -BeFalse -Because $id
        }

        $allQwen37Text = @(
            Get-ChildItem -LiteralPath (Join-Path $root 'data\providers') -Filter '*.json' -File
            Get-ChildItem -LiteralPath (Join-Path $root 'data\model-catalogs') -Filter '*.json' -File
        ) | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 }
        ($allQwen37Text -join "`n") | Should -Not -Match 'qwen3\.7-plus|qwen3\.7-max-preview|qwen3\.7-max-2026-05-20'
        ([regex]::Matches(($allQwen37Text -join "`n"), 'qwen3\.7-max-2026-06-08')).Count |
            Should -BeGreaterThan 0
    }

    It 'rebuilds the exact Qwen3.7 Max 06-08 catalog deterministically' {
        $generated = Join-Path $TestDrive 'qwen3.7-max-2026-06-08-codex.json'
        & (Join-Path $root 'scripts\Build-QwenCodexCatalog.ps1') `
            -CatalogKind qwen37max0608 -OutputCatalog $generated | Out-Null

        $checkedIn = Join-Path $root 'data\model-catalogs\qwen3.7-max-2026-06-08-codex.json'
        Assert-CanonicalCatalogBytes -Path $generated
        Assert-CanonicalCatalogBytes -Path $checkedIn
        (Get-FileHash -LiteralPath $generated -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $checkedIn -Algorithm SHA256).Hash
    }

    It 'rebuilds the exact Qwen3.8 Max catalog deterministically' {
        $generated = Join-Path $TestDrive 'qwen3.8-max-0902-codex.json'
        & (Join-Path $root 'scripts\Build-QwenCodexCatalog.ps1') `
            -CatalogKind qwen38max0902 -OutputCatalog $generated | Out-Null

        $checkedIn = Join-Path $root 'data\model-catalogs\qwen3.8-max-0902-codex.json'
        Assert-CanonicalCatalogBytes -Path $generated
        Assert-CanonicalCatalogBytes -Path $checkedIn
        (Get-FileHash -LiteralPath $generated -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $checkedIn -Algorithm SHA256).Hash
    }

    It 'rebuilds both exact DeepSeek catalogs deterministically' {
        foreach ($model in @('flash', 'pro')) {
            $generated = Join-Path $TestDrive "deepseek-v4-$model.json"
            & (Join-Path $root 'scripts\Build-DeepSeekCodexCatalog.ps1') `
                -Model $model -OutputCatalog $generated | Out-Null

            $checkedIn = Join-Path $root "data\model-catalogs\deepseek-v4-$model.json"
            Assert-CanonicalCatalogBytes -Path $generated
            Assert-CanonicalCatalogBytes -Path $checkedIn
            (Get-FileHash -LiteralPath $generated -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $checkedIn -Algorithm SHA256).Hash -Because $model
        }
    }

    It 'binds local Codex main to the exact deterministic Qwen3.8-27B 256K catalog' {
        $all = Import-AiCliProviderManifests
        $profile = $all['codex-ollama-main']
        $runtimeTag = 'qwen3.8-27b:256k'
        $profile.codexModelCatalog | Should -Be 'qwen3.8-27b-codex.json'
        $profile.models.primary | Should -BeExactly $runtimeTag
        @($profile.models.candidates) | Should -Be @($runtimeTag)
        $profile.modelMetadata.$runtimeTag.contextWindowTokens | Should -Be 262144
        $profile.modelMetadata.$runtimeTag.outputWindowTokens | Should -Be 32768
        $profile.compatibility.minCliVersion | Should -Be '0.147.0'

        $catalogPath = Join-Path $root 'data\model-catalogs\qwen3.8-27b-codex.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        @($catalog.models).Count | Should -Be 1
        $catalog.models[0].slug | Should -BeExactly $runtimeTag
        $catalog.models[0].context_window | Should -Be 262144
        $catalog.models[0].max_context_window | Should -Be 262144
        $catalog.models[0].effective_context_window_percent | Should -Be 95
        $catalog.models[0].default_reasoning_level | Should -Be 'max'
        @($catalog.models[0].supported_reasoning_levels.effort) | Should -Be @('low', 'medium', 'high', 'max')
        $catalog.models[0].base_instructions | Should -Not -BeNullOrEmpty

        $generated = Join-Path $TestDrive 'qwen3.8-27b-codex.json'
        & (Join-Path $root 'scripts\Build-QwenCodexCatalog.ps1') `
            -CatalogKind localQwen38_27b -OutputCatalog $generated | Out-Null
        Assert-CanonicalCatalogBytes -Path $generated
        Assert-CanonicalCatalogBytes -Path $catalogPath
        (Get-FileHash -LiteralPath $generated -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
    }

    It 'rejects a native model override for a locked DeepSeek profile' {
        InModuleScope AiCliProfileManager {
            $profile = Get-AiCliProviderManifest -Id 'claude-deepseek'
            $cases = [System.Collections.Generic.List[object]]::new()
            $cases.Add([string[]]@('--model', 'deepseek-v4-pro'))
            $cases.Add([string[]]@('--model=deepseek-v4-pro'))
            $cases.Add([string[]]@('-m', 'deepseek-v4-pro'))
            $cases.Add([string[]]@('-m=deepseek-v4-pro'))
            $cases.Add([string[]]@('-mdeepseek-v4-pro'))
            $cases.Add([string[]]@('--fallback-model', 'deepseek-v4-pro'))
            $cases.Add([string[]]@('--fallback-model=deepseek-v4-pro'))
            foreach ($nativeCase in $cases) {
                {
                    Assert-AiCliLockedModelArgs -MergedProfile $profile -NativeArgs $nativeCase
                } | Should -Throw '*模型由 Profile 固定*'
            }
        }
    }

    It 'accepts interpreter openai-compatible transport' {
        {
            Assert-AiCliManifestCore -M @{
                schemaVersion=1; id='oi-x'; displayName='x'; engine='interpreter'; provider='qwen'; plan='paygo'; transport='openai-compatible'
                wireApi='responses'; endpoint='https://example.com/v1'; models=@{ primary='model-x'; candidates=@('model-x') }
                auth=@{}; capabilities=@{}; sources=@('https://example.com/docs'); requiresSecret=$true
                virtualReady=$false; dataDestination='example.com'
            }
        } | Should -Not -Throw
    }

    It 'accepts local agent engines on an OpenAI compatible transport' {
        foreach ($engine in @('qwen-code', 'opencode')) {
            {
                Assert-AiCliManifestCore -M @{
                    schemaVersion=1; id="$engine-local"; displayName='x'; engine=$engine; provider='ollama'; plan='local'; transport='openai-compatible'
                    endpoint='http://127.0.0.1:32100/v1'; models=@{ primary='qwen3.6-35b:256k' }
                    auth=@{}; capabilities=@{}; sources=@('https://example.com/docs'); requiresSecret=$false
                    virtualReady=$true; dataDestination='local broker'
                }
            } | Should -Not -Throw
        }
    }

    It 'rejects wrong transport for interpreter' {
        {
            Assert-AiCliManifestCore -M @{
                schemaVersion=1; id='oi-bad'; displayName='x'; engine='interpreter'; provider='qwen'; plan='paygo'; transport='responses'
                endpoint='https://example.com/v1'; models=@{ primary='model-x' }; auth=@{}; capabilities=@{}
                sources=@('https://example.com/docs'); requiresSecret=$true; virtualReady=$false; dataDestination='example.com'
            }
        } | Should -Throw
    }

    It 'rejects chat transport for codex via assert' {
        {
            Assert-AiCliManifestCore -M @{
                schemaVersion=1; id='bad'; displayName='x'; engine='codex'; provider='x'; plan='p'; transport='chat'
                endpoint='https://example.com/v1'; models=@{ primary='model-x' }; auth=@{}; capabilities=@{}
                sources=@('https://example.com/docs'); requiresSecret=$true; virtualReady=$false; dataDestination='example.com'
            }
        } | Should -Throw
    }

    It 'hides codex-custom-responses from builtin public list' {
        $ids = Get-AiCliBuiltinTemplateIds
        $ids | Should -Not -Contain 'codex-custom-responses'
    }
}
