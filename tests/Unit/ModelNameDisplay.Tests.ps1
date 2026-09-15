#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ModelNameDisplayRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module AiCliProfileManager -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:ModelNameDisplayRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'human-visible local model names' {
    It 'adds the effective model to generic provider labels without losing plan information' {
        InModuleScope AiCliProfileManager {
            $profile = @{ displayName='Codex 官方 (ChatGPT/OpenAI)'; provider='openai'; models=@{primary='gpt-5.6-sol'} }
            (Get-AiCliProfileDisplayName -Profile $profile) | Should -Match 'gpt-5\.6-sol'
            (Get-AiCliProfileDisplayName -Profile $profile -Model 'gpt-5.6-terra') | Should -Match 'gpt-5\.6-terra'
            $profile = @{ displayName='Claude Code + Ollama'; provider='ollama'; models=@{primary='qwen3:8b'} }
            (Get-AiCliProfileDisplayName -Profile $profile) | Should -Match 'qwen3:8b'
        }
    }
    It 'keeps internal role words out of the local model display names' {
        foreach ($file in @(
            'codex-ollama-main.json', 'codex-ollama-qwen3-8-27b.json', 'codex-ollama-review.json',
            'claude-ollama-main.json', 'opencode-ollama-main.json',
            'opencode-ollama-qwen3-8-27b.json', 'qwen-code-ollama-main.json'
        )) {
            $profile = Get-Content -LiteralPath (Join-Path $script:ModelNameDisplayRepoRoot "data\providers\$file") -Raw | ConvertFrom-Json
            $profile.displayName | Should -Not -Match '主用|辅助|复核|main|local-default'
            $profile.displayName | Should -Match 'Qwen3\.[68]'
        }
    }

    It 'does not change the profile fingerprint when only displayName changes' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{
                schemaVersion = 1; id = 'codex-ollama-main'; templateId = 'codex-ollama-main'
                engine = 'codex'; provider = 'ollama'; plan = 'local'; transport = 'responses'
                endpoint = 'http://127.0.0.1:32100/v1'; models = [ordered]@{ primary = 'aicli-qwen3.8-27b-256k:2026-09-15' }
                compatibility = [ordered]@{}; defaultEffort = 'max'; effortLevels = @('low','medium','high','max')
                displayName = 'Codex CLI + Qwen3.8 27B'
            }
            $before = Get-AiCliProfileFingerprint -Profile $profile
            $profile.displayName = 'internal role text must not affect identity'
            (Get-AiCliProfileFingerprint -Profile $profile) | Should -Be $before
        }
    }

    It 'deduplicates same-model local compatibility entries while retaining the chosen ID' {
        InModuleScope AiCliProfileManager {
            $main = [ordered]@{ id='codex-ollama-main'; displayName='Codex CLI + Qwen3.8 27B'; isVirtual=$true; configured=$true; provider='ollama'; engine='codex'; transport='responses'; endpoint='http://127.0.0.1:32100/v1'; models=[ordered]@{primary='aicli-qwen3.8-27b-256k:2026-09-15'} }
            $compat = [ordered]@{ id='codex-ollama-qwen3-8-27b'; displayName='Codex CLI + Qwen3.8 27B'; isVirtual=$true; configured=$true; provider='ollama'; engine='codex'; transport='responses'; endpoint='http://127.0.0.1:32100/v1'; models=[ordered]@{primary='aicli-qwen3.8-27b-256k:2026-09-15'} }
            $script:capturedChoices = @(); $script:selectedId = ''
            Mock Get-AiCliSettings { [ordered]@{ lastProfileId='codex-ollama-qwen3-8-27b'; defaultProfileId='codex-ollama-main' } }
            Mock Get-AiCliResolvedProfile { if ($Id -eq 'codex-ollama-main') { $main } else { $compat } }
            Mock Get-AiCliProfileList { @($main, $compat) }
            Mock Show-AiCliMenu { param($Title,$Choices) $script:capturedChoices = @($Choices); 0 }
            Mock Start-AiCliProfile { param($ProfileId) $script:selectedId = $ProfileId; 0 }

            Invoke-AiCliInteractiveSelector | Should -Be 0
            $script:capturedChoices | Should -Be @('最近: Codex CLI + Qwen3.8 27B')
            $script:selectedId | Should -Be 'codex-ollama-qwen3-8-27b'
        }
    }
}
