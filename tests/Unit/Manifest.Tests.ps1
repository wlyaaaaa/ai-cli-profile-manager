#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Manifest' {
    BeforeAll {
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
