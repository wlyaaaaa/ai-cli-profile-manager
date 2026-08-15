#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Qwen38LocalRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module -Name AiCliProfileManager -All -ErrorAction SilentlyContinue |
        Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:Qwen38LocalRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'Exact local Qwen3.8-27B Profiles' {
    It 'publishes separate exact Codex and OpenCode harness Profiles' {
        $ids = @(InModuleScope AiCliProfileManager { Get-AiCliBuiltinTemplateIds })
        $ids | Should -Contain 'codex-ollama-qwen3-8-27b'
        $ids | Should -Contain 'opencode-ollama-qwen3-8-27b'
    }

    It 'seals Codex to qwen3.8:27b Responses, max effort, native context, and no fallback' {
        $manifest = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'codex-ollama-qwen3-8-27b'
        }

        $manifest.engine | Should -BeExactly 'codex'
        $manifest.provider | Should -BeExactly 'ollama'
        $manifest.transport | Should -BeExactly 'responses'
        $manifest.endpoint | Should -BeExactly 'http://127.0.0.1:32100/v1'
        $manifest.codexProviderId | Should -BeExactly 'aicli_ollama_qwen38_27b'
        $manifest.codexModelCatalog | Should -BeExactly 'qwen3.8-27b-codex.json'
        $manifest.models.primary | Should -BeExactly 'qwen3.8:27b'
        $manifest.models.small | Should -BeExactly 'qwen3.8:27b'
        @($manifest.models.candidates) | Should -Be @('qwen3.8:27b')
        @($manifest.models.reserved) | Should -BeNullOrEmpty
        $manifest.modelMetadata.'qwen3.8:27b'.contextWindowTokens | Should -Be 262144
        $manifest.defaultEffort | Should -BeExactly 'max'
        @($manifest.effortLevels) | Should -Be @('low', 'medium', 'high', 'max')
        $manifest.flexible | Should -BeFalse
        $manifest.requiresSecret | Should -BeFalse
        $manifest.compatibility.minCliVersion | Should -BeExactly '0.147.0'
        $manifest.compatibility.ollamaArtifact.minimumVersion | Should -BeExactly '0.32.12'
        $manifest.compatibility.ollamaArtifact.tag | Should -BeExactly 'qwen3.8:27b'
        $manifest.compatibility.ollamaArtifact.quantization | Should -BeExactly 'Q4_K_M'
        $manifest.compatibility.ollamaArtifact.manifestDigest |
            Should -BeExactly 'sha256:22130167c4c20e20c7b71454612966ca8e8171e9b3cc8ab6ce8aa6cbfec79643'
        $manifest.compatibility.ollamaArtifact.configDigest |
            Should -BeExactly 'sha256:492b2922d38e553cabc2d319345644ed482874fbf5e5c9e4495cbf8e17b0cf5f'
        $manifest.compatibility.ollamaArtifact.modelBlobDigest |
            Should -BeExactly 'sha256:f5f1dd8920d417aac2718b0bda3403da274301efdd6760b4f0f4b864ff2ad57d'
        $manifest.compatibility.localGpuBrokerSession.requiredForMachineRun | Should -BeTrue

        InModuleScope AiCliProfileManager -Parameters @{ Profile = $manifest } {
            foreach ($nativeArgs in @(
                [string[]]@('--model', 'wrong-model'),
                [string[]]@('--fallback-model', 'wrong-model')
            )) {
                { Assert-AiCliLockedModelArgs -MergedProfile $Profile -NativeArgs $nativeArgs } |
                    Should -Throw '*模型由 Profile 固定*'
            }
            Test-AiCliRetiredModelId -ModelId 'qwen3.8:27b' | Should -BeFalse
        }
    }

    It 'publishes a deterministic single-model Codex catalog at the native 262144 context' {
        $catalogPath = Join-Path $script:Qwen38LocalRepoRoot 'data\model-catalogs\qwen3.8-27b-codex.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100

        @($catalog.models).Count | Should -Be 1
        $model = $catalog.models[0]
        $model.slug | Should -BeExactly 'qwen3.8:27b'
        $model.context_window | Should -Be 262144
        $model.max_context_window | Should -Be 262144
        $model.effective_context_window_percent | Should -Be 95
        $model.auto_compact_token_limit | Should -BeNullOrEmpty
        $model.default_reasoning_level | Should -BeExactly 'max'
        @($model.supported_reasoning_levels.effort) | Should -Be @('low', 'medium', 'high', 'max')
        @($model.input_modalities) | Should -Be @('text', 'image')
        $model.base_instructions | Should -Not -BeNullOrEmpty

        $generated = Join-Path $TestDrive 'qwen3.8-27b-codex.json'
        & (Join-Path $script:Qwen38LocalRepoRoot 'scripts\Build-QwenCodexCatalog.ps1') `
            -CatalogKind localQwen38_27b -OutputCatalog $generated | Out-Null
        (Get-FileHash -LiteralPath $generated -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
    }

    It 'seals OpenCode to the same exact local model and native context' {
        $manifest = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'opencode-ollama-qwen3-8-27b'
        }

        $manifest.engine | Should -BeExactly 'opencode'
        $manifest.provider | Should -BeExactly 'ollama'
        $manifest.transport | Should -BeExactly 'openai-compatible'
        $manifest.endpoint | Should -BeExactly 'http://127.0.0.1:32100/v1'
        $manifest.models.primary | Should -BeExactly 'qwen3.8:27b'
        $manifest.models.small | Should -BeExactly 'qwen3.8:27b'
        $metadata = $manifest.modelMetadata.'qwen3.8:27b'
        $metadata.contextWindowTokens | Should -Be 262144
        $metadata.inputWindowTokens | Should -Be 262144
        $metadata.outputWindowTokens | Should -Be 32768
        $metadata.compactionReserveTokens | Should -Be 20000
        $manifest.compatibility.minCliVersion | Should -BeExactly '1.18.8'
        $manifest.compatibility.ollamaArtifact.manifestDigest |
            Should -BeExactly 'sha256:22130167c4c20e20c7b71454612966ca8e8171e9b3cc8ab6ce8aa6cbfec79643'
        $manifest.compatibility.ollamaArtifact.configDigest |
            Should -BeExactly 'sha256:492b2922d38e553cabc2d319345644ed482874fbf5e5c9e4495cbf8e17b0cf5f'
        $manifest.compatibility.ollamaArtifact.quantization | Should -BeExactly 'Q4_K_M'
        $manifest.requiresSecret | Should -BeFalse
        $manifest.virtualReady | Should -BeTrue
        $manifest.capabilities.machineRun | Should -BeTrue
    }

    It 'keeps every shared exact Ollama tag on one physical artifact across harnesses' {
        $artifactProfiles = @(InModuleScope AiCliProfileManager {
            foreach ($id in Get-AiCliBuiltinTemplateIds) {
                $profile = Get-AiCliProviderManifest -Id $id
                $artifact = Get-AiCliProperty (Get-AiCliProperty $profile 'compatibility') 'ollamaArtifact'
                if ($null -ne $artifact) {
                    [pscustomobject]@{ id = $id; tag = [string]$artifact.tag; artifact = $artifact }
                }
            }
        })
        @($artifactProfiles | Where-Object tag -eq 'qwen3.8:27b').Count | Should -Be 2

        foreach ($group in @($artifactProfiles | Group-Object tag | Where-Object Count -gt 1)) {
            $reference = $group.Group[0].artifact
            foreach ($profile in @($group.Group | Select-Object -Skip 1)) {
                foreach ($field in @(
                    'tag',
                    'quantization',
                    'manifestDigest',
                    'configDigest',
                    'modelBlobDigest',
                    'projectorBlobDigest'
                )) {
                    $profile.artifact.$field | Should -BeExactly $reference.$field
                }
            }
        }
    }

    It 'builds the Codex launch plan with exact provider, model, Responses, and max' {
        $manifest = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'codex-ollama-qwen3-8-27b'
        }
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $manifest } {
            Mock Resolve-AiCliCodexLaunchExecutable {
                [pscustomobject]@{ FileName = 'C:\fake\codex.exe'; PrefixArgs = @(); Kind = 'test' }
            }
            Mock Get-AiCliResolvedCliVersionEvidence {
                [pscustomobject]@{ Version = 'codex-cli 0.147.0'; FileName = 'C:\fake\codex.exe' }
            }
            Mock Write-AiCliCodexManagedProfile {
                [pscustomobject]@{
                    CliProfileName = 'aicli-codex-ollama-qwen3-8-27b'
                    FilePath = (Join-Path $Work 'qwen38.config.toml')
                    ContentHash = ('0' * 64)
                }
            }
            Mock Publish-AiCliCodexModelCatalog {
                Join-Path $Work 'qwen3.8-27b-codex.json'
            }

            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $Profile -ProjectPath $Work -MachineRun
            $plan.model | Should -BeExactly 'qwen3.8:27b'
            $plan.modelProvider | Should -BeExactly 'aicli_ollama_qwen38_27b'
            $plan.wire | Should -BeExactly 'responses'
            $plan.effort | Should -BeExactly 'max'
            $plan.effectiveEffort | Should -BeExactly 'max'
            $plan.argumentList | Should -Contain 'model="qwen3.8:27b"'
            $plan.argumentList | Should -Contain 'model_provider="aicli_ollama_qwen38_27b"'
            $plan.argumentList | Should -Contain 'model_reasoning_effort="max"'
            $plan.machineRuntime.localGpuBrokerSession.requiredForMachineRun | Should -BeTrue
        }
    }

    It 'builds the OpenCode transient runtime around the exact model metadata' {
        $manifest = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'opencode-ollama-qwen3-8-27b'
        }
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive; Profile = $manifest } {
            Mock Resolve-AiCliLaunchExecutable {
                [pscustomobject]@{ FileName = 'C:\fake\opencode.exe'; PrefixArgs = @(); Kind = 'test' }
            }
            Mock Get-AiCliResolvedCliVersionEvidence {
                [pscustomobject]@{ Version = 'opencode 1.18.8'; FileName = 'C:\fake\opencode.exe' }
            }
            $plan = Build-AiCliOpenCodeLaunchPlan -MergedProfile $Profile -ProjectPath $Work
            $plan = Apply-AiCliContextManagementPolicy -Plan $plan -MergedProfile $Profile

            $plan.model | Should -BeExactly 'qwen3.8:27b'
            $plan.argumentList | Should -Contain 'aicli_ollama/qwen3.8:27b'
            $plan.machineRuntime.model | Should -BeExactly 'qwen3.8:27b'
            $plan.machineRuntime.modelMetadata.contextWindowTokens | Should -Be 262144
            $plan.machineRuntime.modelMetadata.outputWindowTokens | Should -Be 32768
        }
    }

    It 'shows both Profiles through the normal discoverable list surface' {
        $dataRoot = Join-Path $TestDrive 'aicli-data'
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        $oldOut = [Console]::Out
        $writer = [IO.StringWriter]::new()
        try {
            [Console]::SetOut($writer)
            Invoke-AiCli -Tokens @('profile', 'list', '--available', '--json') -DataRoot $dataRoot |
                Should -Be 0
        } finally {
            [Console]::SetOut($oldOut)
        }
        $rows = @(($writer.ToString() | ConvertFrom-Json).profiles)
        @($rows | Where-Object id -eq 'codex-ollama-qwen3-8-27b').Count | Should -Be 1
        @($rows | Where-Object id -eq 'opencode-ollama-qwen3-8-27b').Count | Should -Be 1
    }
}
