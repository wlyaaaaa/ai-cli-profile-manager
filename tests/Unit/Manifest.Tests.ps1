#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Manifest' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
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
