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

    It 'fails closed when a builtin-named user Profile contains <Case> JSON' -ForEach @(
        @{ Case = 'malformed'; Body = '{ synthetic malformed fixture' },
        @{ Case = 'non-map'; Body = '[]' }
    ) {
        $caseRoot = Join-Path $TestDrive "invalid-builtin-profile-$Case"
        $profilesDir = Join-Path $caseRoot 'AppData\profiles'
        New-Item -ItemType Directory -Force -Path $profilesDir | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $profilesDir 'codex-official.json'),
            $Body,
            [Text.UTF8Encoding]::new($false))

        $code = Invoke-AiCli `
            -Tokens @('profile','show','codex-official','--json') `
            -DataRoot $caseRoot

        $code | Should -Be 4

        $listCode = Invoke-AiCli `
            -Tokens @('profile','list','--available','--json') `
            -DataRoot $caseRoot

        $listCode | Should -Be 4
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

    It 'fails closed for a legacy DeepSeek V4 Flash user Profile instead of silently migrating it' {
        InModuleScope AiCliProfileManager {
            $template = Get-AiCliProviderManifest -Id 'codex-deepseek-flash'
            $user = [ordered]@{
                id = 'codex-deepseek-flash'
                templateId = 'codex-deepseek-flash'
                models = [ordered]@{ primary = 'deepseek-v4-flash'; small = 'deepseek-v4-flash'; candidates = @('deepseek-v4-flash') }
                secretRef = 'opaque-existing-secret-ref'
            }

            { Merge-AiCliProfile -Template $template -UserProfile $user } |
                Should -Throw '*已退役的 DeepSeek V4 Flash*'
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

    It 'fails closed for a retired Qwen3.7 user Profile instead of rerouting it' {
        InModuleScope AiCliProfileManager {
            $template = Get-AiCliProviderManifest -Id 'claude-custom'
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
                Should -Throw '*已退役*Qwen3.7*'
        }
    }

    It 'preserves a matching DeepSeek exact Profile SecretRef without allowing route drift' {
        InModuleScope AiCliProfileManager {
            Mock Test-AiCliSecretExists { $true }
            $template = Get-AiCliProviderManifest -Id 'codex-deepseek-flash'
            $user = [ordered]@{
                id = 'codex-deepseek-flash'
                templateId = 'codex-deepseek-flash'
                region = 'global'
                plan = 'paygo'
                endpoint = 'https://api.deepseek.com/'
                models = [ordered]@{
                    primary = 'deepseek-flash'
                    small = 'deepseek-flash'
                    candidates = @('deepseek-flash')
                }
                secretRef = 'opaque-existing-secret-ref'
            }

            $merged = Merge-AiCliProfile -Template $template -UserProfile $user
            $merged.endpoint | Should -Be 'https://api.deepseek.com'
            $merged.models.primary | Should -Be 'deepseek-flash'
            $merged.secretRef | Should -Be 'opaque-existing-secret-ref'
        }
    }

    It 'rejects configuring one builtin template under another builtin ID' {
        InModuleScope AiCliProfileManager {
            { Invoke-AiCliProfileConfigure -TemplateId 'codex-official' -ProfileId 'codex-deepseek-flash' } |
                Should -Throw '*已由内置模板 codex-deepseek-flash 保留*'
        }
    }

    It 'binds fingerprints to compatibility, model metadata, and model catalog content' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{
                schemaVersion = 1
                id = 'codex-deepseek-flash'
                engine = 'codex'
                codexModelCatalog = 'deepseek-flash.json'
                compatibility = [ordered]@{ minCliVersion = '0.144.0' }
            }
            $script:CatalogHash = ('1' * 64)
            Mock Get-AiCliDataPath { 'C:\test\deepseek-flash.json' }
            Mock Test-Path { $true }
            Mock Get-FileHash { [pscustomobject]@{ Hash = $script:CatalogHash } }

            $first = Get-AiCliProfileFingerprint -Profile $profile
            $script:CatalogHash = ('2' * 64)
            $second = Get-AiCliProfileFingerprint -Profile $profile
            $profile.compatibility.minCliVersion = '0.145.0'
            $third = Get-AiCliProfileFingerprint -Profile $profile
            $profile.modelMetadata = [ordered]@{
                'deepseek-flash' = [ordered]@{
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
