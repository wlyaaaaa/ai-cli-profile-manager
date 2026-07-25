#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:CodexAdapterRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module -Name AiCliProfileManager -All -ErrorAction SilentlyContinue |
        Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:CodexAdapterRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'Codex Ollama reasoning effort' {
    It 'uses the outer Windows sandbox for local app-server machine runs' {
        $profile = Get-Content -LiteralPath (
            Join-Path $script:CodexAdapterRepoRoot 'data\providers\codex-ollama-main.json'
        ) -Raw | ConvertFrom-Json

        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $profile } {
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\Program Files\nodejs\node.exe'
                    PrefixArgs = @('C:\npm\node_modules\@openai\codex\bin\codex.js')
                    Kind = 'npm-node'
                }
            }
            Mock Write-AiCliCodexManagedProfile {
                [pscustomobject]@{
                    CliProfileName = 'aicli-codex-ollama-main'
                    FilePath = (Join-Path $Work 'aicli-codex-ollama-main.config.toml')
                    ContentHash = ('0' * 64)
                }
            }

            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $Profile `
                -ProjectPath $Work -MachineRun

            $plan.machineRuntime.sandboxBoundary | Should -Be 'outer-codex'
        }
    }

    It 'emits max exactly once as a -c pair and preserves every provider override' {
        $profile = Get-Content -LiteralPath (
            Join-Path $script:CodexAdapterRepoRoot 'data\providers\codex-ollama-main.json'
        ) -Raw | ConvertFrom-Json

        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $profile } {
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\fake\codex.exe'
                    PrefixArgs = @()
                    Kind = 'test'
                }
            }
            Mock Write-AiCliCodexManagedProfile {
                [pscustomobject]@{
                    CliProfileName = 'aicli-codex-ollama-main'
                    FilePath = (Join-Path $Work 'aicli-codex-ollama-main.config.toml')
                    ContentHash = ('0' * 64)
                }
            }

            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $Profile -ProjectPath $Work
            $launchArgs = @($plan.argumentList)
            $reasoningOverride = 'model_reasoning_effort="max"'
            $reasoningIndex = [Array]::IndexOf([string[]]$launchArgs, $reasoningOverride)

            @($launchArgs | Where-Object { $_ -eq $reasoningOverride }).Count | Should -Be 1
            @($launchArgs | Where-Object { $_ -match '^model_reasoning_effort=' }).Count | Should -Be 1
            $reasoningIndex | Should -BeGreaterThan 0
            $launchArgs[$reasoningIndex - 1] | Should -Be '-c'
            @($launchArgs | Where-Object { $_ -eq '-c' }).Count | Should -Be 9

            $expectedProviderOverrides = @(
                'model="qwen-main-v1"'
                'model_provider="aicli_ollama_main"'
                'model_providers.aicli_ollama_main.name="Codex CLI + local Qwen main"'
                'model_providers.aicli_ollama_main.base_url="http://127.0.0.1:32100/v1"'
                'model_providers.aicli_ollama_main.env_key="AICLI_CODEX_PROVIDER_KEY"'
                'model_providers.aicli_ollama_main.wire_api="responses"'
                'shell_environment_policy.ignore_default_excludes=false'
                'shell_environment_policy.exclude=["AICLI_CODEX_PROVIDER_KEY","OPENAI_API_KEY","CODEX_API_KEY"]'
            )
            foreach ($expected in $expectedProviderOverrides) {
                $launchArgs | Should -Contain $expected
            }
            $plan.effort | Should -Be 'max'
        }
    }

    It 'declares only the Ollama 0.32 Responses effort levels and defaults the local main profile to max' {
        $manifest = Get-Content -LiteralPath (
            Join-Path $script:CodexAdapterRepoRoot 'data\providers\codex-ollama-main.json'
        ) -Raw | ConvertFrom-Json

        $manifest.defaultEffort | Should -Be 'max'
        @($manifest.effortLevels) | Should -Be @('low', 'medium', 'high', 'max')
        @($manifest.effortLevels) | Should -Not -Contain 'xhigh'
    }

    It 'rejects xhigh when the Ollama profile declares only low through max' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{
                id = 'codex-ollama-main'
                provider = 'ollama'
                defaultEffort = 'max'
                effortLevels = @('low', 'medium', 'high', 'max')
                preferences = [ordered]@{ effort = 'xhigh' }
            }

            {
                Resolve-AiCliCodexEffort -MergedProfile $profile -NativeArgs @()
            } | Should -Throw '*可选: low, medium, high, max*'
        }
    }
}

Describe 'Codex Spark machine profile' {
    It 'pins the exact Spark model and xhigh effort on the npm machine launcher' {
        $profile = Get-Content -LiteralPath (
            Join-Path $script:CodexAdapterRepoRoot 'data\providers\codex-spark-xhigh.json'
        ) -Raw | ConvertFrom-Json

        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $profile } {
            $realHome = Join-Path $Work 'real-codex-home'
            New-Item -ItemType Directory -Path $realHome -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $realHome 'auth.json') -Value '{"auth":"test-only"}' -Encoding utf8
            Mock Get-AiCliCodexHome { $realHome }
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\Program Files\nodejs\node.exe'
                    PrefixArgs = @('C:\npm\node_modules\@openai\codex\bin\codex.js')
                    Kind = 'npm-node'
                }
            } -ParameterFilter { $MachineRun }

            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $Profile -ProjectPath $Work -MachineRun

            $plan.model | Should -Be 'gpt-5.3-codex-spark'
            $plan.effort | Should -Be 'xhigh'
            $plan.fileName | Should -Be 'C:\Program Files\nodejs\node.exe'
            $plan.argumentList[0] | Should -Be 'C:\npm\node_modules\@openai\codex\bin\codex.js'
            $plan.argumentList | Should -Contain 'model="gpt-5.3-codex-spark"'
            $plan.argumentList | Should -Contain 'model_reasoning_effort="xhigh"'
            $plan.machineRuntime.authSourceFile | Should -Be (Join-Path $realHome 'auth.json')
            Should -Invoke Resolve-AiCliCodexLaunchExecutable -Times 1 -Exactly -ParameterFilter { $MachineRun }
        }
    }

    It 'keeps the official interactive launcher independent from the machine launcher' {
        $profile = Get-Content -LiteralPath (
            Join-Path $script:CodexAdapterRepoRoot 'data\providers\codex-official.json'
        ) -Raw | ConvertFrom-Json

        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $profile } {
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\desktop\codex.exe'
                    PrefixArgs = @()
                    Kind = 'desktop-codex'
                }
            } -ParameterFilter { -not $MachineRun }

            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $Profile -ProjectPath $Work

            $plan.fileName | Should -Be 'C:\desktop\codex.exe'
            $plan.launcherKind | Should -Be 'desktop-codex'
            Should -Invoke Resolve-AiCliCodexLaunchExecutable -Times 1 -Exactly -ParameterFilter { -not $MachineRun }
        }
    }
}
