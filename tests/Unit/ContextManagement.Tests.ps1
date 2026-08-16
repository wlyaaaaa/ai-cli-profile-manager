#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Third-party context management' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module -Name AiCliProfileManager -All -ErrorAction SilentlyContinue |
            Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
    }

    It 'applies the declared DeepSeek Claude window without changing the native baseline' {
        InModuleScope AiCliProfileManager {
            $thirdParty = [ordered]@{
                engine = 'claude'
                provider = 'deepseek'
                models = [ordered]@{ primary = 'deepseek-v4-flash' }
                modelMetadata = [ordered]@{
                    'deepseek-v4-flash' = [ordered]@{
                        contextWindowTokens = 1000000
                        autoCompactWindowTokens = 1000000
                    }
                }
            }
            $thirdPartyPlan = [pscustomobject]@{
                engine = 'claude'
                argumentList = @('--model', 'deepseek-v4-flash')
                environmentDelta = @{}
                removeEnvironment = @()
                notes = @()
            }

            $result = Apply-AiCliContextManagementPolicy -Plan $thirdPartyPlan -MergedProfile $thirdParty

            $result.environmentDelta.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should -Be '1000000'
            $result.environmentDelta.CLAUDE_CODE_AUTO_COMPACT_WINDOW | Should -Be '1000000'
            @($result.environmentDelta.Values) | Should -Not -Contain '1048576'
            @($result.removeEnvironment) | Should -Contain 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE'
            @($result.removeEnvironment) | Should -Contain 'DISABLE_AUTO_COMPACT'
            @($result.removeEnvironment) | Should -Contain 'DISABLE_COMPACT'

            $native = [ordered]@{ engine = 'claude'; provider = 'anthropic'; models = [ordered]@{ primary = 'claude-opus-4-1' } }
            $nativePlan = [pscustomobject]@{
                engine = 'claude'
                argumentList = @()
                environmentDelta = @{ CLAUDE_CODE_MAX_CONTEXT_TOKENS = 'NATIVE_USER_VALUE' }
                removeEnvironment = @('UNCHANGED')
                notes = @('native')
            }
            $nativeResult = Apply-AiCliContextManagementPolicy -Plan $nativePlan -MergedProfile $native
            $nativeResult.environmentDelta.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should -Be 'NATIVE_USER_VALUE'
            @($nativeResult.removeEnvironment) | Should -Be @('UNCHANGED')
            @($nativeResult.notes) | Should -Be @('native')
        }
    }

    It 'uses the final Qwen Claude model and refuses to guess unknown windows' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{
                engine = 'claude'
                provider = 'qwen'
                models = [ordered]@{ primary = 'qwen3.7-plus' }
                modelMetadata = [ordered]@{
                    'qwen3.7-plus' = [ordered]@{ contextWindowTokens = 1000000; autoCompactWindowTokens = 1000000 }
                    'qwen3-coder-next' = [ordered]@{ contextWindowTokens = 262144; autoCompactWindowTokens = 262144 }
                }
            }
            $knownPlan = [pscustomobject]@{
                engine = 'claude'
                argumentList = @('--model', 'qwen3.7-plus', '--model=qwen3-coder-next')
                environmentDelta = @{}
                removeEnvironment = @()
                notes = @()
            }
            $known = Apply-AiCliContextManagementPolicy -Plan $knownPlan -MergedProfile $profile
            $known.environmentDelta.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should -Be '262144'
            $known.environmentDelta.CLAUDE_CODE_AUTO_COMPACT_WINDOW | Should -Be '262144'

            $unknownPlan = [pscustomobject]@{
                engine = 'claude'
                argumentList = @('--model', 'future-model')
                environmentDelta = @{}
                removeEnvironment = @()
                notes = @()
            }
            $unknown = Apply-AiCliContextManagementPolicy -Plan $unknownPlan -MergedProfile $profile
            $unknown.environmentDelta.ContainsKey('CLAUDE_CODE_MAX_CONTEXT_TOKENS') | Should -BeFalse
            @($unknown.removeEnvironment) | Should -Contain 'CLAUDE_CODE_MAX_CONTEXT_TOKENS'
            @($unknown.removeEnvironment) | Should -Contain 'CLAUDE_CODE_AUTO_COMPACT_WINDOW'
            @($unknown.removeEnvironment) | Should -Contain 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE'
            @($unknown.removeEnvironment) | Should -Contain 'DISABLE_AUTO_COMPACT'
            @($unknown.removeEnvironment) | Should -Contain 'DISABLE_COMPACT'
        }
    }

    It 'applies the exact local Qwen window to the managed Claude Ollama profile' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{
                engine = 'claude'
                provider = 'ollama'
                models = [ordered]@{ primary = 'qwen-main-v1' }
                modelMetadata = [ordered]@{
                    'qwen-main-v1' = [ordered]@{
                        contextWindowTokens = 262144
                        autoCompactWindowTokens = 262144
                    }
                }
            }
            $plan = [pscustomobject]@{
                engine = 'claude'
                argumentList = @('--model', 'qwen-main-v1')
                environmentDelta = @{}
                removeEnvironment = @()
                notes = @()
            }

            $result = Apply-AiCliContextManagementPolicy -Plan $plan -MergedProfile $profile

            $result.environmentDelta.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should -Be '262144'
            $result.environmentDelta.CLAUDE_CODE_AUTO_COMPACT_WINDOW | Should -Be '262144'
        }
    }

    It 'passes declared OpenCode limits into the transient machine runtime' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{
                engine = 'opencode'
                provider = 'ollama'
                models = [ordered]@{ primary = 'qwen-main-v1' }
                modelMetadata = [ordered]@{
                    'qwen-main-v1' = [ordered]@{
                        contextWindowTokens = 262144
                        inputWindowTokens = 262144
                        outputWindowTokens = 8192
                        compactionReserveTokens = 20000
                        preserveRecentTokens = 16384
                        tailTurns = 4
                    }
                }
            }
            $plan = [pscustomobject]@{
                engine = 'opencode'
                argumentList = @()
                environmentDelta = @{}
                removeEnvironment = @()
                notes = @()
                machineRuntime = [ordered]@{ kind = 'opencode'; model = 'qwen-main-v1' }
            }

            $result = Apply-AiCliContextManagementPolicy -Plan $plan -MergedProfile $profile

            $result.machineRuntime.modelMetadata.contextWindowTokens | Should -Be 262144
            $result.machineRuntime.modelMetadata.compactionReserveTokens | Should -Be 20000
        }
    }

    It 'enforces the first Claude and OpenCode versions that support the managed policy' {
        InModuleScope AiCliProfileManager {
            $claude = [ordered]@{ compatibility = [ordered]@{ minCliVersion = '2.1.193' } }
            (Test-AiCliProfileMinimumCliVersion -MergedProfile $claude -VersionEvidence ([pscustomobject]@{ Version = '2.1.192' })).Supported |
                Should -BeFalse
            (Test-AiCliProfileMinimumCliVersion -MergedProfile $claude -VersionEvidence ([pscustomobject]@{ Version = '2.1.193' })).Supported |
                Should -BeTrue

            $openCode = [ordered]@{ compatibility = [ordered]@{ minCliVersion = '1.18.8' } }
            (Test-AiCliProfileMinimumCliVersion -MergedProfile $openCode -VersionEvidence ([pscustomobject]@{ Version = 'opencode 1.18.7' })).Supported |
                Should -BeFalse
            (Test-AiCliProfileMinimumCliVersion -MergedProfile $openCode -VersionEvidence ([pscustomobject]@{ Version = 'opencode 1.18.8' })).Supported |
                Should -BeTrue
        }
    }

    It 'publishes a project-owned loss-aware checkpoint contract for third-party clients only' {
        InModuleScope AiCliProfileManager {
            $policy = Get-AiCliThirdPartyContinuityPolicy -Engine 'codex' -Provider 'deepseek'

            $policy.schema | Should -BeExactly 'aicli.third-party-continuity.v1'
            $policy.mode | Should -BeExactly 'loss-aware'
            $policy.nativeBaseline | Should -BeExactly 'unchanged'
            $policy.oneMilestonePerSession | Should -BeTrue
            $policy.manualCompaction | Should -BeExactly 'defer-until-window-pressure'
            $policy.preCompactionCheckpoint.required | Should -BeTrue
            $policy.preCompactionCheckpoint.durableTarget | Should -BeExactly 'existing-project-state'
            @($policy.preCompactionCheckpoint.fields) | Should -Contain 'goal-and-acceptance'
            @($policy.preCompactionCheckpoint.fields) | Should -Contain 'constraints-authorization-owner'
            @($policy.preCompactionCheckpoint.fields) | Should -Contain 'changed-files-and-dirty-ownership'
            @($policy.preCompactionCheckpoint.fields) | Should -Contain 'tests-and-live-gaps'
            @($policy.preCompactionCheckpoint.fields) | Should -Contain 'next-step'
            @($policy.postCompactionRead) | Should -Contain 'project-rules: AGENTS.md or CLAUDE.md'
            @($policy.postCompactionRead) | Should -Contain 'existing-project-state'
            @($policy.postCompactionRead) | Should -Contain 'git status'
            @($policy.postCompactionRead) | Should -Contain 'git diff'
            $policy.summaryIsHint | Should -BeTrue
            $policy.restoreFromSource | Should -BeTrue
            $policy.secondFactSource | Should -BeFalse

            $native = Get-AiCliThirdPartyContinuityPolicy -Engine 'codex' -Provider 'openai'
            $native | Should -BeNullOrEmpty
            $officialClaude = Get-AiCliThirdPartyContinuityPolicy -Engine 'claude' -Provider 'anthropic'
            $officialClaude | Should -BeNullOrEmpty
        }
    }

    It 'attaches the continuity contract to third-party plans without changing the native baseline' {
        InModuleScope AiCliProfileManager {
            $thirdPartyPlan = [pscustomobject]@{
                engine = 'opencode'
                versionArgumentList = @('opencode', '--version')
                fileName = 'opencode'
                launcherKind = 'native'
                environmentDelta = @{}
                removeEnvironment = @()
                notes = @()
                machineRuntime = [ordered]@{ kind = 'opencode'; model = 'qwen-main-v1' }
            }
            $thirdPartyProfile = [ordered]@{
                provider = 'ollama'
                modelMetadata = [ordered]@{
                    'qwen-main-v1' = [ordered]@{
                        contextWindowTokens = 262144
                        inputWindowTokens = 262144
                        outputWindowTokens = 8192
                        compactionReserveTokens = 20000
                        preserveRecentTokens = 16384
                        tailTurns = 4
                    }
                }
            }

            $result = Apply-AiCliContextManagementPolicy -Plan $thirdPartyPlan -MergedProfile $thirdPartyProfile
            $result.continuityPolicy.schema | Should -BeExactly 'aicli.third-party-continuity.v1'
            $result.continuityPolicy.preCompactionCheckpoint.required | Should -BeTrue
            $result.continuityPolicy.secondFactSource | Should -BeFalse

            $nativePlan = [pscustomobject]@{
                engine = 'codex'
                environmentDelta = @{}
                removeEnvironment = @()
                notes = @('native')
            }
            $nativeProfile = [ordered]@{ provider = 'openai' }
            $nativeResult = Apply-AiCliContextManagementPolicy -Plan $nativePlan -MergedProfile $nativeProfile
            @($nativeResult.PSObject.Properties.Name) | Should -Not -Contain 'continuityPolicy'
            @($nativeResult.notes) | Should -Be @('native')
        }
    }
}
