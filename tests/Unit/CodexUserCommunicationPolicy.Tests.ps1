#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:CodexCommunicationRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\\..')).Path
    . (Join-Path $script:CodexCommunicationRepoRoot 'scripts\\CodexUserCommunicationPolicy.ps1')
    Remove-Module AiCliProfileManager -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:CodexCommunicationRepoRoot 'src\\AiCliProfileManager\\AiCliProfileManager.psd1') -Force
}

Describe 'Managed Codex user communication policy' {
    It 'keeps the proven progress and human-facing answer instructions in one source' {
        $policy = Get-AiCliCodexUserCommunicationPolicy

        $policy | Should -Match '首次工具调用前'
        $policy | Should -Match '用户可见的助手消息'
        $policy | Should -Match '不重复播报'
        $policy | Should -Match '最终答复'
        $policy | Should -Match '清楚区分已完成的修改'
    }

    It 'applies the policy to every managed non-OpenAI Codex catalog only' {
        $policy = Get-AiCliCodexUserCommunicationPolicy
        $manifests = InModuleScope AiCliProfileManager { Import-AiCliProviderManifests }
        $managed = @(
            $manifests.Values |
                Where-Object {
                    $_.engine -eq 'codex' -and
                    $_.provider -in @('glm', 'qwen', 'deepseek', 'ollama') -and
                    $_.ContainsKey('codexModelCatalog') -and
                    -not [string]::IsNullOrWhiteSpace([string]$_['codexModelCatalog'])
                }
        )

        $managed.Count | Should -BeGreaterThan 0
        foreach ($manifest in $managed) {
            $catalogPath = Join-Path $script:CodexCommunicationRepoRoot (
                Join-Path 'data\\model-catalogs' $manifest.codexModelCatalog
            )
            $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 |
                ConvertFrom-Json -Depth 100
            foreach ($model in @($catalog.models)) {
                $model.base_instructions | Should -Match ([regex]::Escape($policy)) -Because $manifest.id
            }
        }

        $manifests['codex-official'].provider | Should -BeExactly 'openai'
        $manifests['codex-official'].ContainsKey('codexModelCatalog') | Should -BeFalse
        $manifests['codex-spark-xhigh'].provider | Should -BeExactly 'openai'
        $manifests['codex-spark-xhigh'].ContainsKey('codexModelCatalog') | Should -BeFalse
    }

    It 'ships the Chinese policy helper as a BOM-marked PowerShell source file' {
        $path = Join-Path $script:CodexCommunicationRepoRoot 'scripts\\CodexUserCommunicationPolicy.ps1'
        $bytes = [IO.File]::ReadAllBytes($path)

        @($bytes[0..2]) | Should -Be @(0xEF, 0xBB, 0xBF)
    }
}
