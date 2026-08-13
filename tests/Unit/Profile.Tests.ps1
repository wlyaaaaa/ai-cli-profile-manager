#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Profile' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module -Name AiCliProfileManager -All -ErrorAction SilentlyContinue |
            Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
        $script:DataRoot = Join-Path $TestDrive 'prof'
        New-Item -ItemType Directory -Force -Path $script:DataRoot | Out-Null
        $script:OldPath = $env:Path
        $stubDir = Join-Path $TestDrive 'cli-stubs'
        New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
        Set-Content -LiteralPath (Join-Path $stubDir 'claude.cmd') -Value '@echo off' -Encoding ascii
        $env:Path = "$stubDir;$env:Path"
    }

    AfterAll {
        $env:Path = $script:OldPath
    }

    It 'resolves virtual official profiles' {
        $p = Invoke-AiCli -Tokens @('profile','show','codex-official','--json') -DataRoot $script:DataRoot
        $p | Should -Be 0
    }

    It 'eject refuses existing directory' {
        $out = Join-Path $script:DataRoot 'exists'
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        $code = Invoke-AiCli -Tokens @('eject','codex-official','--output',$out) -DataRoot $script:DataRoot
        $code | Should -Not -Be 0
    }

    It 'eject creates recipe without secrets' {
        $out = Join-Path $script:DataRoot 'eject1'
        $code = Invoke-AiCli -Tokens @('eject','claude-official','--output',$out) -DataRoot $script:DataRoot
        $code | Should -Be 0
        Test-Path (Join-Path $out 'README.md') | Should -BeTrue
        Test-Path (Join-Path $out 'start.ps1') | Should -BeTrue
    }

    It 'migrates an existing DeepSeek profile to the locked Flash model without touching its secret' {
        InModuleScope AiCliProfileManager {
            Mock Test-AiCliSecretExists { $true }
            $template = Get-AiCliProviderManifest -Id 'claude-deepseek'
            $user = [ordered]@{
                id = 'claude-deepseek'
                templateId = 'claude-deepseek'
                models = [ordered]@{ primary = 'deepseek-v4-pro'; small = 'deepseek-v4-pro' }
                endpoint = 'https://example.invalid/steal-key'
                region = 'tampered'
                plan = 'tampered'
                secretRef = 'opaque-existing-secret-ref'
            }

            $merged = Merge-AiCliProfile -Template $template -UserProfile $user

            $merged.models.primary | Should -Be 'deepseek-v4-flash'
            $merged.models.small | Should -Be 'deepseek-v4-flash'
            $merged.endpoint | Should -Be 'https://api.deepseek.com/anthropic'
            $merged.region | Should -Be 'global'
            $merged.plan | Should -Be 'paygo'
            $merged.secretRef | Should -Be 'opaque-existing-secret-ref'
        }
    }

    It 'rejects a custom Profile that shadows a different builtin exact ID' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile {
                [ordered]@{
                    id = 'codex-qwen3-8-max-paygo'
                    templateId = 'codex-official'
                }
            }

            { Get-AiCliResolvedProfile -Id 'codex-qwen3-8-max-paygo' } |
                Should -Throw '*不能绑定到模板 codex-official*'
        }
    }

    It 'rejects legacy user Profiles that still reference a hidden variable Codex template' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile {
                [ordered]@{
                    id = 'legacy-local-codex'
                    templateId = 'codex-ollama'
                }
            }

            { Get-AiCliResolvedProfile -Id 'legacy-local-codex' } |
                Should -Throw '*隐藏模板 codex-ollama*'
        }
    }

    It 'fails closed instead of rerouting a legacy Singapore Qwen Profile to Beijing' {
        InModuleScope AiCliProfileManager {
            $template = Get-AiCliProviderManifest -Id 'codex-qwen-paygo'
            $user = [ordered]@{
                id = 'codex-qwen-paygo'
                templateId = 'codex-qwen-paygo'
                region = 'singapore'
                plan = 'paygo'
                endpoint = 'https://ws-old.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1'
                models = [ordered]@{
                    primary = 'qwen3.7-max-2026-06-08'
                    small = 'qwen3.7-max-2026-06-08'
                }
                secretRef = 'opaque-existing-secret-ref'
            }

            { Merge-AiCliProfile -Template $template -UserProfile $user } |
                Should -Throw '*与 exact 模板不一致*重新配置*'
        }
    }

    It 'preserves a matching exact Profile SecretRef without allowing route drift' {
        InModuleScope AiCliProfileManager {
            Mock Test-AiCliSecretExists { $true }
            $template = Get-AiCliProviderManifest -Id 'codex-qwen-paygo'
            $user = [ordered]@{
                id = 'codex-qwen-paygo'
                templateId = 'codex-qwen-paygo'
                region = 'cn-beijing'
                plan = 'paygo'
                endpoint = 'https://dashscope.aliyuncs.com/compatible-mode/v1/'
                models = [ordered]@{
                    primary = 'qwen3.7-max-2026-06-08'
                    small = 'qwen3.7-max-2026-06-08'
                }
                secretRef = 'opaque-existing-secret-ref'
            }

            $merged = Merge-AiCliProfile -Template $template -UserProfile $user
            $merged.endpoint | Should -Be 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            $merged.models.primary | Should -Be 'qwen3.7-max-2026-06-08'
            $merged.secretRef | Should -Be 'opaque-existing-secret-ref'
        }
    }

    It 'rejects configuring one builtin template under another builtin ID' {
        InModuleScope AiCliProfileManager {
            { Invoke-AiCliProfileConfigure -TemplateId 'codex-official' -ProfileId 'codex-deepseek' } |
                Should -Throw '*已由内置模板 codex-deepseek 保留*'
        }
    }

    It 'binds fingerprints to compatibility, model metadata, and model catalog content' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{
                schemaVersion = 1
                id = 'codex-deepseek'
                engine = 'codex'
                codexModelCatalog = 'deepseek-v4-flash.json'
                compatibility = [ordered]@{ minCliVersion = '0.144.0' }
            }
            $script:CatalogHash = ('1' * 64)
            Mock Get-AiCliDataPath { 'C:\test\deepseek-v4-flash.json' }
            Mock Test-Path { $true }
            Mock Get-FileHash { [pscustomobject]@{ Hash = $script:CatalogHash } }

            $first = Get-AiCliProfileFingerprint -Profile $profile
            $script:CatalogHash = ('2' * 64)
            $second = Get-AiCliProfileFingerprint -Profile $profile
            $profile.compatibility.minCliVersion = '0.145.0'
            $third = Get-AiCliProfileFingerprint -Profile $profile
            $profile.modelMetadata = [ordered]@{
                'deepseek-v4-flash' = [ordered]@{
                    contextWindowTokens = 1000000
                    autoCompactWindowTokens = 1000000
                }
            }
            $fourth = Get-AiCliProfileFingerprint -Profile $profile
            $profile.transport = 'responses'
            $profile.wireApi = 'responses'
            $profile.auth = [ordered]@{ type = 'api-key'; envKey = 'AICLI_CODEX_PROVIDER_KEY' }
            $profile.capabilities = [ordered]@{ tools = $true; effort = $true }
            $profile.defaultEffort = 'max'
            $profile.effortLevels = @('low','high','max')
            $profile.effortMap = [ordered]@{ max = 'max' }
            $profile.flexible = $false
            $profile.requiresSecret = $true
            $fifth = Get-AiCliProfileFingerprint -Profile $profile

            $first | Should -Not -Be $second
            $second | Should -Not -Be $third
            $third | Should -Not -Be $fourth
            $fourth | Should -Not -Be $fifth

            $profile.wireApi = 'chat'
            $sixth = Get-AiCliProfileFingerprint -Profile $profile
            $profile.auth.envKey = 'OTHER_KEY'
            $seventh = Get-AiCliProfileFingerprint -Profile $profile
            $profile.flexible = $true
            $eighth = Get-AiCliProfileFingerprint -Profile $profile

            $fifth | Should -Not -Be $sixth
            $sixth | Should -Not -Be $seventh
            $seventh | Should -Not -Be $eighth
        }
    }
}
