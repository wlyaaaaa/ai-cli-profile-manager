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
            Mock Get-AiCliResolvedCliVersionEvidence {
                [pscustomobject]@{ Version = 'codex-cli 0.147.0'; FileName = 'C:\Program Files\nodejs\node.exe' }
            }
            Mock Write-AiCliCodexManagedProfile {
                [pscustomobject]@{
                    CliProfileName = 'aicli-codex-ollama-main'
                    FilePath = (Join-Path $Work 'aicli-codex-ollama-main.config.toml')
                    ContentHash = ('0' * 64)
                }
            }
            Mock Publish-AiCliCodexModelCatalog {
                Join-Path $Work 'qwen3.8-27b-codex.json'
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
            Mock Get-AiCliResolvedCliVersionEvidence {
                [pscustomobject]@{ Version = 'codex-cli 0.147.0'; FileName = 'C:\fake\codex.exe' }
            }
            Mock Write-AiCliCodexManagedProfile {
                [pscustomobject]@{
                    CliProfileName = 'aicli-codex-ollama-main'
                    FilePath = (Join-Path $Work 'aicli-codex-ollama-main.config.toml')
                    ContentHash = ('0' * 64)
                }
            }
            Mock Publish-AiCliCodexModelCatalog {
                Join-Path $Work 'qwen3.8-27b-codex.json'
            }

            $previousNoProxy = [Environment]::GetEnvironmentVariable('NO_PROXY', 'Process')
            try {
                [Environment]::SetEnvironmentVariable('NO_PROXY', '.ts.net,example.org', 'Process')
                $plan = Build-AiCliCodexLaunchPlan -MergedProfile $Profile -ProjectPath $Work
            } finally {
                [Environment]::SetEnvironmentVariable('NO_PROXY', $previousNoProxy, 'Process')
            }
            $launchArgs = @($plan.argumentList)
            $reasoningOverride = 'model_reasoning_effort="max"'
            $reasoningIndex = [Array]::IndexOf([string[]]$launchArgs, $reasoningOverride)

            @($launchArgs | Where-Object { $_ -eq $reasoningOverride }).Count | Should -Be 1
            @($launchArgs | Where-Object { $_ -match '^model_reasoning_effort=' }).Count | Should -Be 1
            $reasoningIndex | Should -BeGreaterThan 0
            $launchArgs[$reasoningIndex - 1] | Should -Be '-c'
            @($launchArgs | Where-Object { $_ -eq '-c' }).Count | Should -Be 11

            $expectedProviderOverrides = @(
                'model="qwen3.8-27b:256k"'
                'model_provider="aicli_ollama_main"'
                'model_providers.aicli_ollama_main.name="Codex CLI + Qwen3.8 27B"'
                'model_providers.aicli_ollama_main.base_url="http://127.0.0.1:32100/v1"'
                'model_providers.aicli_ollama_main.env_key="AICLI_CODEX_PROVIDER_KEY"'
                'model_providers.aicli_ollama_main.wire_api="responses"'
                'model_providers.aicli_ollama_main.env_http_headers={"X-LocalGpuBroker-Lease-Id"="AICLI_LOCAL_GPU_BROKER_LEASE_ID","X-LocalGpuBroker-Capability"="AICLI_LOCAL_GPU_BROKER_CAPABILITY"}'
                'shell_environment_policy.ignore_default_excludes=false'
                'shell_environment_policy.exclude=["AICLI_CODEX_PROVIDER_KEY","OPENAI_API_KEY","CODEX_API_KEY","DASHSCOPE_API_KEY","QWEN_API_KEY","AICLI_LOCAL_GPU_BROKER_LEASE_ID","AICLI_LOCAL_GPU_BROKER_CAPABILITY"]'
                ('model_catalog_json=' + (ConvertTo-AiCliTomlString (Join-Path $Work 'qwen3.8-27b-codex.json')))
            )
            foreach ($expected in $expectedProviderOverrides) {
                $launchArgs | Should -Contain $expected
            }
            @($plan.configFiles) | Should -Contain (Join-Path $Work 'qwen3.8-27b-codex.json')
            $plan.effort | Should -Be 'max'
            $noProxyItems = @(([string]$plan.environmentDelta.NO_PROXY).Split(','))
            foreach ($entry in @('.ts.net', 'example.org', '127.0.0.1', 'localhost', '::1')) {
                $noProxyItems | Should -Contain $entry
            }
            $plan.environmentDelta.no_proxy | Should -BeExactly $plan.environmentDelta.NO_PROXY
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

    It 'falls back to Codex defaults when a profile omits effortLevels' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{
                id = 'codex-qwen-paygo'
                provider = 'qwen'
                preferences = [ordered]@{ effort = 'high' }
            }

            Resolve-AiCliCodexEffort -MergedProfile $profile -NativeArgs @() |
                Should -Be 'high'
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

Describe 'Codex remote Responses machine profile' {
    It 'keeps provider transport outside the command sandbox' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $profile = [ordered]@{
                id = 'codex-qwen-paygo'
                displayName = 'Qwen test'
                provider = 'qwen'
                endpoint = 'https://example.invalid/compatible-mode/v1'
                codexProviderId = 'aicli_qwen_paygo'
                secretConfigured = $true
                secretRef = 'test-only'
                models = [ordered]@{ primary = 'qwen3.7-flash' }
                preferences = [ordered]@{ effort = 'high' }
            }
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\Program Files\nodejs\node.exe'
                    PrefixArgs = @('C:\npm\node_modules\@openai\codex\bin\codex.js')
                    Kind = 'npm-node'
                }
            }
            Mock Write-AiCliCodexManagedProfile {
                [pscustomobject]@{
                    CliProfileName = 'aicli-codex-qwen-paygo'
                    FilePath = (Join-Path $Work 'aicli-codex-qwen-paygo.config.toml')
                    ContentHash = ('0' * 64)
                }
            }
            Mock Get-AiCliSecret { 'test-secret' }

            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $profile `
                -ProjectPath $Work -MachineRun

            $plan.machineRuntime.sandboxBoundary | Should -Be 'codex-native'
            $plan.machineRuntime.harnessAccess | Should -BeExactly 'danger-full-access'
            $plan.environmentDelta.AICLI_CODEX_PROVIDER_KEY | Should -Be 'test-secret'
            $plan.model | Should -Be 'qwen3.7-flash'
        }
    }

    It 'binds a native model override into the machine plan and provider config' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $profile = [ordered]@{
                id = 'codex-qwen-paygo'
                displayName = 'Qwen test'
                provider = 'qwen'
                endpoint = 'https://example.invalid/compatible-mode/v1'
                codexProviderId = 'aicli_qwen_paygo'
                secretConfigured = $true
                secretRef = 'test-only'
                models = [ordered]@{ primary = 'qwen3.7-max-2026-06-08' }
                preferences = [ordered]@{ effort = 'high' }
            }
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\Program Files\nodejs\node.exe'
                    PrefixArgs = @('C:\npm\node_modules\@openai\codex\bin\codex.js')
                    Kind = 'npm-node'
                }
            }
            Mock Write-AiCliCodexManagedProfile {
                [pscustomobject]@{
                    CliProfileName = 'aicli-codex-qwen-paygo'
                    FilePath = (Join-Path $Work 'aicli-codex-qwen-paygo.config.toml')
                    ContentHash = ('0' * 64)
                }
            }
            Mock Get-AiCliSecret { 'test-secret' }

            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $profile `
                -ProjectPath $Work -MachineRun `
                -NativeArgs @('exec', '--json', '--model', 'qwen3.7-flash', '-')

            $plan.model | Should -Be 'qwen3.7-flash'
            $plan.argumentList | Should -Contain 'model="qwen3.7-flash"'
            $plan.argumentList | Should -Not -Contain 'model="qwen3.7-max-2026-06-08"'
        }
    }
}

Describe 'Codex DeepSeek Flash catalog' {
    BeforeAll {
        $script:DeepSeekProfile = Get-Content -LiteralPath (
            Join-Path $script:CodexAdapterRepoRoot 'data\providers\codex-deepseek-flash.json'
        ) -Raw -Encoding utf8 | ConvertFrom-Json
    }

    It 'publishes an immutable content-addressed catalog without a UTF-8 BOM' {
        $sourceCatalog = Join-Path $script:CodexAdapterRepoRoot 'data\model-catalogs\deepseek-flash.json'
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            Profile = $script:DeepSeekProfile
            SourceCatalog = $sourceCatalog
        } {
            Mock Get-AiCliCodexHome { $Work }

            $first = Publish-AiCliCodexModelCatalog -MergedProfile $Profile
            $second = Publish-AiCliCodexModelCatalog -MergedProfile $Profile

            $first | Should -Be $second
            $first | Should -Match 'aicli-model-catalogs[\\/]+deepseek-flash-[a-f0-9]{12}\.json$'
            (Get-FileHash -LiteralPath $first -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $SourceCatalog -Algorithm SHA256).Hash
            $bytes = [IO.File]::ReadAllBytes($first)
            @($bytes[0], $bytes[1], $bytes[2]) | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        }
    }

    It 'adds the catalog to both the managed profile and effective provider overrides' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $script:DeepSeekProfile } {
            $catalogPath = Join-Path $Work 'deepseek-flash-0123456789ab.json'
            Mock Publish-AiCliCodexModelCatalog { $catalogPath }
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\Program Files\nodejs\node.exe'
                    PrefixArgs = @('C:\npm\node_modules\@openai\codex\bin\codex.js')
                    Kind = 'npm-node'
                }
            }
            Mock Get-AiCliResolvedCliVersionEvidence {
                [pscustomobject]@{ Version = 'codex-cli 0.146.0'; FileName = 'C:\Program Files\nodejs\node.exe' }
            }
            Mock Write-AiCliCodexManagedProfile {
                param($MergedProfile, $TomlBody)
                $TomlBody | Should -Match 'model_catalog_json\s*='
                $TomlBody | Should -Match 'env_key\s*=\s*"AICLI_CODEX_PROVIDER_KEY"'
                $TomlBody | Should -Not -Match 'experimental_bearer_token'
                [pscustomobject]@{
                    CliProfileName = 'aicli-codex-deepseek-flash'
                    FilePath = (Join-Path $Work 'aicli-codex-deepseek-flash.config.toml')
                    ContentHash = ('0' * 64)
                }
            }
            Mock Get-AiCliSecret { 'test-secret-never-serialize' }

            $profile = $Profile | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
            $profile.secretConfigured = $true
            $profile.secretRef = 'test-only'
            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $profile -ProjectPath $Work

            $plan.model | Should -Be 'deepseek-flash'
            $plan.argumentList | Should -Contain ('model_catalog_json=' + (ConvertTo-AiCliTomlString $catalogPath))
            $plan.argumentList | Should -Contain 'model_providers.aicli_deepseek_flash.wire_api="responses"'
            $plan.environmentDelta.AICLI_CODEX_PROVIDER_KEY | Should -Be 'test-secret-never-serialize'
            ($plan.argumentList -join "`n") | Should -Not -Match 'test-secret-never-serialize'
        }
    }

    It 'fails closed before launch when Codex is below the official DeepSeek minimum' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $script:DeepSeekProfile } {
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{ FileName = 'C:\codex.exe'; PrefixArgs = @(); Kind = 'test' }
            }
            Mock Get-AiCliResolvedCliVersionEvidence {
                [pscustomobject]@{ Version = 'codex-cli 0.143.9'; FileName = 'C:\codex.exe' }
            }
            {
                Build-AiCliCodexLaunchPlan -MergedProfile $Profile -ProjectPath $Work
            } | Should -Throw '*需要 0.144.0+*0.143.9*'
        }
    }

    It 'rejects the reserved Pro model until it is present in the active catalog' {
        InModuleScope AiCliProfileManager -Parameters @{ Profile = $script:DeepSeekProfile } {
            {
                Resolve-AiCliCodexModel -MergedProfile $Profile -NativeArgs @('--model', 'deepseek-v4-pro')
            } | Should -Throw '*当前目录未启用*deepseek-v4-pro*'
        }
    }

    It 'rejects native Provider-routing flags that could bypass the managed DeepSeek Provider' {
        InModuleScope AiCliProfileManager {
            $cases = [System.Collections.Generic.List[object]]::new()
            $cases.Add([string[]]@('-p', 'other'))
            $cases.Add([string[]]@('-pother'))
            $cases.Add([string[]]@('--profile=other'))
            $cases.Add([string[]]@('-cmodel_provider="openai"'))
            $cases.Add([string[]]@('--oss'))
            $cases.Add([string[]]@('--local-provider', 'ollama'))
            $cases.Add([string[]]@('--local-provider=lmstudio'))
            foreach ($nativeCase in $cases) {
                { Assert-AiCliCodexNativeArgs -NativeArgList $nativeCase } |
                    Should -Throw '*启动计划冲突*'
            }
        }
    }

    It 'parses attached short model values into the effective plan identity' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{ models = [ordered]@{ primary = 'default-model' } }
            Resolve-AiCliCodexModel -MergedProfile $profile -NativeArgs @('-mselected-model') |
                Should -Be 'selected-model'
            Resolve-AiCliCodexModel -MergedProfile $profile -NativeArgs @('-m=selected-model') |
                Should -Be 'selected-model'
        }
    }
}
