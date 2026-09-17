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

Describe 'User-visible summary presentation' {
    It 'places the policy on both legacy and effective template paths for each selected model' {
        foreach ($case in @(
            @{ File = 'deepseek-flash.json'; Provider = 'deepseek' },
            @{ File = 'glm-5.3-codex.json'; Provider = 'glm' },
            @{ File = 'glm-5.3-flash-codex.json'; Provider = 'glm' }
        )) {
            $path = Join-Path $script:CodexCommunicationRepoRoot ('data/model-catalogs/' + $case.File)
            $entry = (Get-Content $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100).models[0]
            $expected = Get-AiCliCodexSummaryPresentationPolicy -Provider $case.Provider
            foreach ($text in @($entry.base_instructions, $entry.model_messages.instructions_template)) {
                $text.Contains($expected, [StringComparison]::Ordinal) | Should -BeTrue -Because $case.File
                $text.Contains((Get-AiCliCodexUserCommunicationPolicy), [StringComparison]::Ordinal) | Should -BeTrue
            }
        }
    }

    It 'is idempotent and preserves final-answer instructions and non-presentation metadata' {
        $entry = [ordered]@{
            slug = 'fixture'; base_instructions = 'Legacy instruction'; context_window = 987654
            model_messages = [ordered]@{
                instructions_template = 'Current instruction'
                instructions_variables = @{ personality_default = 'Keep this variable' }
                future_field = @{ value = 17 }
            }
            supports_reasoning_summaries = $true
        }
        $originalMetadata = $entry.model_messages.future_field | ConvertTo-Json -Compress
        Set-AiCliCodexSummaryPresentationPolicy -ModelEntry $entry -Provider deepseek
        $once = $entry | ConvertTo-Json -Depth 100 -Compress
        Set-AiCliCodexSummaryPresentationPolicy -ModelEntry $entry -Provider deepseek
        ($entry | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly $once
        $entry.context_window | Should -Be 987654
        $entry.supports_reasoning_summaries | Should -BeTrue
        ($entry.model_messages.future_field | ConvertTo-Json -Compress) | Should -BeExactly $originalMetadata
        $entry.model_messages.instructions_variables.personality_default | Should -BeExactly 'Keep this variable'
        $base = Remove-AiCliCodexSummaryPresentationPolicy -Instructions $entry.base_instructions
        $template = Remove-AiCliCodexSummaryPresentationPolicy -Instructions $entry.model_messages.instructions_template
        (Remove-AiCliCodexUserCommunicationPolicy -BaseInstructions $base) | Should -BeExactly 'Legacy instruction'
        (Remove-AiCliCodexUserCommunicationPolicy -BaseInstructions $template) | Should -BeExactly 'Current instruction'
    }

    It 'migrates a legacy-only catalog without discarding its instructions' {
        $entry = [ordered]@{ base_instructions = 'Legacy-only contract'; slug = 'fixture' }
        Set-AiCliCodexSummaryPresentationPolicy -ModelEntry $entry -Provider glm
        $entry.model_messages.instructions_template | Should -BeExactly $entry.base_instructions
        (Remove-AiCliCodexSummaryPresentationPolicy -Instructions $entry.base_instructions).StartsWith('Legacy-only contract', [StringComparison]::Ordinal) | Should -BeTrue
    }

    It 'replaces an old presentation suffix without accumulating old wording' {
        $entry = [ordered]@{ base_instructions = 'Base'; slug = 'fixture' }
        Set-AiCliCodexSummaryPresentationPolicy -ModelEntry $entry -Provider glm
        $entry.base_instructions += 'OBSOLETE_POLICY_CANARY'
        $entry.model_messages.instructions_template += 'OBSOLETE_POLICY_CANARY'
        Set-AiCliCodexSummaryPresentationPolicy -ModelEntry $entry -Provider deepseek
        $serialized = $entry | ConvertTo-Json -Depth 100 -Compress
        $serialized | Should -Not -Match 'OBSOLETE_POLICY_CANARY'
        $entry.base_instructions.Contains((Get-AiCliCodexSummaryPresentationPolicy -Provider deepseek)) | Should -BeTrue
    }

    It 'regenerates DeepSeek while preserving its exact vendor baseline verification' {
        $output = Join-Path $TestDrive 'deepseek-regenerated.json'
        & (Join-Path $script:CodexCommunicationRepoRoot 'scripts/Build-DeepSeekCodexCatalog.ps1') -OutputCatalog $output | Out-Null
        $source = Join-Path $script:CodexCommunicationRepoRoot 'data/model-catalogs/deepseek-flash.json'
        (Get-FileHash $output).Hash | Should -BeExactly (Get-FileHash $source).Hash
        $bad = Get-Content $source -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100
        $bad.models[0].supports_parallel_tool_calls = -not $bad.models[0].supports_parallel_tool_calls
        $badPath = Join-Path $TestDrive 'changed-vendor.json'
        $bad | ConvertTo-Json -Depth 100 | Set-Content $badPath -Encoding utf8
        { & (Join-Path $script:CodexCommunicationRepoRoot 'scripts/Build-DeepSeekCodexCatalog.ps1') -SourceCatalog $badPath -OutputCatalog $output } | Should -Throw '*baseline mismatch*'
    }

    It 'does not leak the selected-provider presentation policy into Qwen generation' {
        $output = Join-Path $TestDrive 'qwen-regenerated.json'
        & (Join-Path $script:CodexCommunicationRepoRoot 'scripts/Build-QwenCodexCatalog.ps1') -OutputCatalog $output | Out-Null
        $entry = (Get-Content $output -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100).models[0]
        $entry.base_instructions | Should -Not -Match 'AICLI user-visible summary presentation'
        $entry.model_messages.instructions_template | Should -Not -Match 'AICLI user-visible summary presentation'
        $entry.base_instructions.Contains((Get-AiCliCodexUserCommunicationPolicy)) | Should -BeTrue
    }

    It 'does not inject this policy into established Qwen and local model catalogs' {
        foreach ($file in Get-ChildItem (Join-Path $script:CodexCommunicationRepoRoot 'data/model-catalogs') -Filter '*.json' | Where-Object { $_.Name -match '^(qwen|gemma|north)' }) {
            if ($file.Name -in @('deepseek-flash.json', 'glm-5.3-codex.json', 'glm-5.3-flash-codex.json')) { continue }
            Get-Content $file.FullName -Raw -Encoding utf8 | Should -Not -Match 'AICLI user-visible summary presentation'
        }
    }
}

Describe 'Separate visible thinking and progress delivery' {
    It 'keeps public thinking presentation distinct from commentary and hidden reasoning' {
        foreach ($provider in @('deepseek', 'glm')) {
            $policy = (Get-AiCliCodexPublicThinkingPrefix) + (Get-AiCliCodexSummaryPresentationPolicy -Provider $provider)
            $policy | Should -Match 'reasoning_text'
            $policy | Should -Match '公开进度消息'
            $policy | Should -Match '不要求展示或扩写隐藏思维链'
            $policy | Should -Match '公开说明和最终答复是不同内容'
            $policy | Should -Match '最终答案仍单独发送'
        }
    }
}