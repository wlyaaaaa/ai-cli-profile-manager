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
        $all.Contains('oi-qwen-paygo') | Should -BeTrue
        $all.Contains('oi-ollama') | Should -BeTrue
        $all.Contains('oi-deepseek') | Should -BeTrue
        $all.Contains('qwen-code-ollama-main') | Should -BeTrue
        $all.Contains('opencode-ollama-main') | Should -BeTrue
        $all.Contains('codex-ollama-main') | Should -BeTrue
        $all.Contains('claude-ollama-main') | Should -BeTrue
        $all.Contains('codex-deepseek') | Should -BeTrue
    }

    It 'exposes only the supported DeepSeek Flash model to Codex and reserves Pro' {
        $all = Import-AiCliProviderManifests
        $manifest = $all['codex-deepseek']

        $manifest.engine | Should -Be 'codex'
        $manifest.provider | Should -Be 'deepseek'
        $manifest.transport | Should -Be 'responses'
        $manifest.endpoint | Should -Be 'https://api.deepseek.com'
        $manifest.models.primary | Should -Be 'deepseek-v4-flash'
        @($manifest.models.candidates) | Should -Be @('deepseek-v4-flash')
        @($manifest.models.reserved) | Should -Contain 'deepseek-v4-pro'
        $manifest.codexModelCatalog | Should -Be 'deepseek-v4-flash.json'

        $catalogPath = Join-Path $root 'data\model-catalogs\deepseek-v4-flash.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json
        @($catalog.models).Count | Should -Be 1
        $catalog.models[0].slug | Should -Be 'deepseek-v4-flash'
        $catalog.models[0].context_window | Should -Be 1000000
        $catalog.models[0].max_context_window | Should -Be 1000000
        $catalog.models[0].minimal_client_version | Should -Be '0.144.0'
        @($catalog.models[0].supported_reasoning_levels.effort) | Should -Be @('low', 'high', 'max')
        (Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8) | Should -Not -Match 'deepseek-v4-pro'
    }

    It 'keeps every current DeepSeek template Flash-only and reserves Pro' {
        $all = Import-AiCliProviderManifests
        foreach ($id in @('codex-deepseek', 'claude-deepseek', 'oi-deepseek')) {
            $manifest = $all[$id]
            $manifest.models.primary | Should -Be 'deepseek-v4-flash' -Because $id
            $manifest.models.small | Should -Be 'deepseek-v4-flash' -Because $id
            @($manifest.models.candidates) | Should -Be @('deepseek-v4-flash') -Because $id
            @($manifest.models.reserved) | Should -Contain 'deepseek-v4-pro' -Because $id
        }
    }

    It 'binds third-party Claude and OpenCode profiles to exact model context metadata' {
        $all = Import-AiCliProviderManifests
        $all['claude-deepseek'].compatibility.minCliVersion | Should -Be '2.1.193'
        $all['claude-deepseek'].modelMetadata.'deepseek-v4-flash'.contextWindowTokens | Should -Be 1000000
        $all['claude-deepseek'].modelMetadata.'deepseek-v4-flash'.autoCompactWindowTokens | Should -Be 1000000
        $all['claude-qwen-token-plan'].modelMetadata.'qwen3.7-max-2026-06-08'.contextWindowTokens | Should -Be 983616
        $all['claude-qwen-coding-plan'].modelMetadata.'qwen3-coder-next'.contextWindowTokens | Should -Be 262144
        $all['claude-ollama-main'].compatibility.minCliVersion | Should -Be '2.1.193'
        $all['claude-ollama-main'].modelMetadata.'qwen-main-v1'.contextWindowTokens | Should -Be 262144
        $all['claude-ollama-main'].modelMetadata.'qwen-main-v1'.autoCompactWindowTokens | Should -Be 262144
        $all['opencode-ollama-main'].modelMetadata.'qwen-main-v1'.contextWindowTokens | Should -Be 262144
        $all['opencode-ollama-main'].modelMetadata.'qwen-main-v1'.compactionReserveTokens | Should -Be 20000
    }

    It 'uses one complete non-empty Qwen Codex model catalog without changing the default model' {
        $all = Import-AiCliProviderManifests
        $paygo = $all['codex-qwen-paygo']
        $tokenPlan = $all['codex-qwen-token-plan']
        $paygo.codexModelCatalog | Should -Be 'qwen3.7-codex.json'
        $tokenPlan.codexModelCatalog | Should -Be 'qwen3.7-codex.json'
        $paygo.models.primary | Should -Be 'qwen3.7-max-2026-06-08'
        @($paygo.effortLevels) | Should -Be @('low', 'medium', 'high', 'xhigh', 'max')
        @($paygo.effortLevels) | Should -Not -Contain 'ultra'

        $catalogPath = Join-Path $root 'data\model-catalogs\qwen3.7-codex.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        $candidateSlugs = @($paygo.models.candidates | Select-Object -Unique | Sort-Object)
        $catalogSlugs = @($catalog.models.slug | Sort-Object)
        $catalogSlugs | Should -Be $candidateSlugs
        foreach ($model in @($catalog.models)) {
            $model.context_window | Should -Be 983616
            $model.max_context_window | Should -Be 983616
            $model.effective_context_window_percent | Should -Be 95
            $model.auto_compact_token_limit | Should -BeNullOrEmpty
            $model.base_instructions | Should -Not -BeNullOrEmpty
            $model.base_instructions | Should -Match 'Codex'
            $model.supports_parallel_tool_calls | Should -BeFalse
            @($model.input_modalities) | Should -Be @('text')
        }
    }

    It 'rebuilds the Qwen Codex catalog deterministically from the checked-in baseline' {
        $generated = Join-Path $TestDrive 'qwen3.7-codex.json'
        & (Join-Path $root 'scripts\Build-QwenCodexCatalog.ps1') -OutputCatalog $generated | Out-Null

        Assert-CanonicalCatalogBytes -Path $generated
        Assert-CanonicalCatalogBytes -Path (Join-Path $root 'data\model-catalogs\qwen3.7-codex.json')

        (Get-FileHash -LiteralPath $generated -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath (Join-Path $root 'data\model-catalogs\qwen3.7-codex.json') -Algorithm SHA256).Hash
    }

    It 'binds local Codex Qwen to an exact deterministic 262144 catalog' {
        $all = Import-AiCliProviderManifests
        $profile = $all['codex-ollama-main']
        $profile.codexModelCatalog | Should -Be 'qwen-main-v1-codex.json'
        $profile.compatibility.minCliVersion | Should -Be '0.147.0'

        $catalogPath = Join-Path $root 'data\model-catalogs\qwen-main-v1-codex.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        @($catalog.models).Count | Should -Be 1
        $catalog.models[0].slug | Should -Be 'qwen-main-v1'
        $catalog.models[0].context_window | Should -Be 262144
        $catalog.models[0].max_context_window | Should -Be 262144
        $catalog.models[0].effective_context_window_percent | Should -Be 95
        $catalog.models[0].default_reasoning_level | Should -Be 'max'
        @($catalog.models[0].supported_reasoning_levels.effort) | Should -Be @('low', 'medium', 'high', 'max')
        $catalog.models[0].base_instructions | Should -Not -BeNullOrEmpty

        $generated = Join-Path $TestDrive 'qwen-main-v1-codex.json'
        & (Join-Path $root 'scripts\Build-QwenCodexCatalog.ps1') -CatalogKind local -OutputCatalog $generated | Out-Null
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
                    endpoint='http://127.0.0.1:32100/v1'; models=@{ primary='qwen-main-v1' }
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
