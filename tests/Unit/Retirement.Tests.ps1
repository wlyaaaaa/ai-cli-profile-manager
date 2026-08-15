#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RetirementRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module -Name AiCliProfileManager -All -ErrorAction SilentlyContinue |
        Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RetirementRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'Retired provider identities' {
    It 'restores only the exact Qwen3.7 Max 06-08 Codex entry while old routes and Plus remain absent' {
        $manifest = InModuleScope AiCliProfileManager {
            Get-AiCliProviderManifest -Id 'codex-qwen3-7-max-paygo'
        }
        $manifest.models.primary | Should -Be 'qwen3.7-max-2026-06-08'
        $manifest.flexible | Should -BeFalse

        foreach ($id in @(
            'codex-qwen-paygo', 'codex-qwen-token-plan',
            'codex-qwen3-7-plus-paygo',
            'claude-qwen-paygo', 'claude-qwen-token-plan',
            'claude-qwen-coding-plan', 'oi-qwen-paygo'
        )) {
            Test-Path -LiteralPath (Join-Path $script:RetirementRepoRoot "data\providers\$id.json") |
                Should -BeFalse -Because $id
        }
    }

    It 'allows 06-08 only through the new exact template and rejects the same model in stale profiles' {
        InModuleScope AiCliProfileManager {
            $exact = Get-AiCliProviderManifest -Id 'codex-qwen3-7-max-paygo'
            { Assert-AiCliProfileDoesNotUseRetiredModel -Profile $exact } | Should -Not -Throw

            foreach ($profile in @(
                [ordered]@{
                    id = 'legacy-qwen37'; templateId = 'claude-custom'
                    models = [ordered]@{ primary = 'qwen3.7-max-2026-06-08' }
                },
                [ordered]@{
                    id = 'codex-qwen3-7-max-paygo'; templateId = 'claude-custom'
                    models = [ordered]@{ primary = 'qwen3.7-max-2026-06-08' }
                },
                [ordered]@{
                    id = 'codex-qwen3-7-max-paygo'; templateId = 'codex-qwen3-7-max-paygo'
                    models = [ordered]@{ primary = 'qwen3.7-max-2026-05-20' }
                }
            )) {
                { Assert-AiCliProfileDoesNotUseRetiredModel -Profile $profile } |
                    Should -Throw '*已退役*Qwen3.7*'
            }
        }
    }

    It 'keeps the exact Qwen cloud routes and adds Qwen3.8-27B without removing local slots' {
        $manifests = InModuleScope AiCliProfileManager { Import-AiCliProviderManifests }
        @($manifests.Keys | Where-Object { $_ -like '*qwen*' -or $_ -like '*ollama-main' -or $_ -eq 'codex-ollama-review' } | Sort-Object) | Should -Be @(
            'claude-ollama-main',
            'codex-ollama-main',
            'codex-ollama-qwen3-8-27b',
            'codex-ollama-review',
            'codex-qwen3-7-max-paygo',
            'codex-qwen3-8-max-paygo',
            'opencode-ollama-main',
            'opencode-ollama-qwen3-8-27b',
            'qwen-code-ollama-main'
        )
        $cloud = $manifests['codex-qwen3-8-max-paygo']
        $cloud.models.primary | Should -Be 'qwen3.8-max'
        $cloud.defaultEffort | Should -Be 'max'
        $cloud.effortMap.max | Should -Be 'xhigh'
    }

    It 'fails closed before resolving a stale user Profile that still selects the retired model' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile {
                [ordered]@{
                    id = 'old-qwen-work'
                    templateId = 'claude-custom'
                    models = [ordered]@{
                        primary = 'qwen3.7-max-2026-06-08'
                        small = 'qwen3.7-plus-2026-05-26'
                    }
                    secretRef = 'opaque-existing-secret-ref'
                }
            }

            { Get-AiCliResolvedProfile -Id 'old-qwen-work' } |
                Should -Throw '*已退役*Qwen3.7*'
        }
    }

    It 'rejects native model and fallback arguments for all retired Qwen3.7 identities' {
        InModuleScope AiCliProfileManager {
            foreach ($case in @(
                [pscustomobject]@{ Values = [string[]]@('--model','qwen3.7-plus') },
                [pscustomobject]@{ Values = [string[]]@('--model=qwen3.7-max-preview') },
                [pscustomobject]@{ Values = [string[]]@('--fallback-model','qwen3.7-plus-2026-05-26') },
                [pscustomobject]@{ Values = [string[]]@('-mqwen3.7-max-2026-06-08') }
            )) {
                { Assert-AiCliNativeArgsDoNotUseRetiredModel -NativeArgs $case.Values } |
                    Should -Throw '*已退役*Qwen3.7*'
            }
        }
    }

    It 'keeps only DeepSeek Flash 0731 and Pro 0813 identities without reserved variants' {
        $manifests = InModuleScope AiCliProfileManager {
            $all = Import-AiCliProviderManifests
            @($all.Values | Where-Object provider -eq 'deepseek')
        }

        foreach ($manifest in @($manifests)) {
            @($manifest.models.reserved) | Should -BeNullOrEmpty -Because $manifest.id
            @($manifest.models.candidates) |
                Should -Not -Contain 'deepseek-chat' -Because $manifest.id
            @($manifest.models.candidates) |
                Should -Not -Contain 'deepseek-reasoner' -Because $manifest.id
            foreach ($model in @(
                $manifest.models.primary,
                $manifest.models.small,
                @($manifest.models.candidates)
            ) | Where-Object { $_ }) {
                $model | Should -BeIn @('deepseek-v4-flash', 'deepseek-v4-pro') -Because $manifest.id
            }
        }

        $flash = @($manifests | Where-Object id -eq 'codex-deepseek')[0]
        $pro = @($manifests | Where-Object id -eq 'codex-deepseek-v4-pro')[0]
        $flash.compatibility.modelVersion | Should -Be 'DeepSeek-V4-Flash-0731'
        $pro.compatibility.modelVersion | Should -Be 'DeepSeek-V4-Pro-0813'

        foreach ($id in @('claude-deepseek', 'oi-deepseek')) {
            $profile = @($manifests | Where-Object id -eq $id)[0]
            $profile.models.primary | Should -Be 'deepseek-v4-flash' -Because $id
            $profile.compatibility.modelVersion | Should -Be 'DeepSeek-V4-Flash-0731' -Because $id
        }
    }

    It 'rejects every other DeepSeek V4 model identity in profiles and native arguments' {
        InModuleScope AiCliProfileManager {
            foreach ($modelId in @(
                'deepseek-v4',
                'deepseek-v4-flash-0731',
                'deepseek-v4-pro-0813',
                'deepseek-v4-preview',
                'deepseek-v4:preview',
                'DeepSeek-V4-Pro',
                'DeepSeek-V4-Flash-0731'
            )) {
                { Assert-AiCliModelIsActive -ModelId $modelId -Context '测试模型' } |
                    Should -Throw '*DeepSeek V4*只保留*deepseek-v4-flash*deepseek-v4-pro*' -Because $modelId
                { Assert-AiCliNativeArgsDoNotUseRetiredModel -NativeArgs @('--model', $modelId) } |
                    Should -Throw '*DeepSeek V4*' -Because $modelId
            }

            foreach ($activeAlias in @('deepseek-v4-flash', 'deepseek-v4-pro')) {
                { Assert-AiCliModelIsActive -ModelId $activeAlias -Context '测试模型' } |
                    Should -Not -Throw -Because $activeAlias
            }
        }
    }

    It 'matches retired Qwen3.7 family spellings without reopening local Qwen models' {
        InModuleScope AiCliProfileManager {
            foreach ($modelId in @(
                'Qwen3.7-Max-2026-06-08',
                'qwen3.7max',
                'qwen3.7plus',
                'qwen3_7_plus:preview',
                'qwen37max/legacy'
            )) {
                Test-AiCliRetiredModelId -ModelId $modelId | Should -BeTrue -Because $modelId
            }
            foreach ($modelId in @('qwen3:8b', 'qwen-main-v1', 'qwen-review-v1', 'qwen3.8-max')) {
                Test-AiCliRetiredModelId -ModelId $modelId | Should -BeFalse -Because $modelId
            }
        }
    }

    It 'fails closed when a stale flexible Profile names an unretained DeepSeek V4 identity' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile {
                [ordered]@{
                    id = 'old-deepseek-work'
                    templateId = 'claude-custom'
                    models = [ordered]@{
                        primary = 'deepseek-v4-preview'
                    }
                    secretRef = 'opaque-existing-secret-ref'
                }
            }

            { Get-AiCliResolvedProfile -Id 'old-deepseek-work' } |
                Should -Throw '*DeepSeek V4*只保留*'
        }
    }

    It 'reuses an existing opaque secret reference only when its template proves the same credential domain' {
        InModuleScope AiCliProfileManager {
            Mock Test-AiCliSecretExists { $true }
            $template = Get-AiCliProviderManifest -Id 'codex-deepseek'
            $existing = [ordered]@{
                id = 'codex-deepseek'
                templateId = 'codex-deepseek'
                secretRef = 'opaque-existing-secret-ref'
            }

            Resolve-AiCliReusableSecretRef `
                -Template $template `
                -ProfileId 'codex-deepseek' `
                -ExistingProfile $existing `
                -ReuseExistingSecret |
                Should -Be 'opaque-existing-secret-ref'
        }
    }

    It 'rejects same-id SecretRef reuse when the old template belongs to another provider' {
        InModuleScope AiCliProfileManager {
            Mock Test-AiCliSecretExists { $true }
            $template = Get-AiCliProviderManifest -Id 'codex-deepseek'
            $existing = [ordered]@{
                id = 'codex-deepseek'
                templateId = 'codex-official'
                secretRef = 'opaque-unknown-secret-ref'
            }

            {
                Resolve-AiCliReusableSecretRef -Template $template `
                    -ProfileId 'codex-deepseek' -ExistingProfile $existing -ReuseExistingSecret
            } | Should -Throw '*认证域*拒绝复用*'
        }
    }

    It 'can share one configured DeepSeek SecretRef with the exact Pro Profile' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile {
                [ordered]@{
                    id = 'codex-deepseek'
                    templateId = 'codex-deepseek'
                    secretRef = 'opaque-deepseek-secret-ref'
                }
            }
            Mock Get-AiCliResolvedProfile {
                [ordered]@{
                    id = 'codex-deepseek'
                    provider = 'deepseek'
                    plan = 'paygo'
                    region = 'global'
                    endpoint = 'https://api.deepseek.com'
                    auth = [ordered]@{ type = 'api-key' }
                    secretConfigured = $true
                }
            }
            Mock Test-AiCliSecretExists { $true }
            $template = Get-AiCliProviderManifest -Id 'codex-deepseek-v4-pro'

            Resolve-AiCliReusableSecretRef `
                -Template $template `
                -ProfileId 'codex-deepseek-v4-pro' `
                -ReuseSecretFrom 'codex-deepseek' |
                Should -Be 'opaque-deepseek-secret-ref'
        }
    }

    It 'shares a Qwen Workspace SecretRef only when the exact target uses the same endpoint' {
        InModuleScope AiCliProfileManager {
            $workspaceEndpoint = 'https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1'
            Mock Get-AiCliUserProfile {
                [ordered]@{
                    id = 'codex-qwen3-8-max-paygo'
                    templateId = 'codex-qwen3-8-max-paygo'
                    secretRef = 'opaque-qwen-workspace-secret-ref'
                }
            }
            Mock Get-AiCliResolvedProfile {
                [ordered]@{
                    provider = 'qwen'; plan = 'paygo'; region = 'cn-beijing'
                    endpoint = 'https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1'
                    auth = [ordered]@{ type = 'api-key' }
                    secretConfigured = $true
                }
            }
            Mock Test-AiCliSecretExists { $true }
            $template = Get-AiCliProviderManifest -Id 'codex-qwen3-7-max-paygo'

            Resolve-AiCliReusableSecretRef -Template $template `
                -ProfileId 'codex-qwen3-7-max-paygo' `
                -TargetEndpoint $workspaceEndpoint `
                -ReuseSecretFrom 'codex-qwen3-8-max-paygo' |
                Should -Be 'opaque-qwen-workspace-secret-ref'

            {
                Resolve-AiCliReusableSecretRef -Template $template `
                    -ProfileId 'codex-qwen3-7-max-paygo' `
                    -TargetEndpoint 'https://ws-other.cn-beijing.maas.aliyuncs.com/compatible-mode/v1' `
                    -ReuseSecretFrom 'codex-qwen3-8-max-paygo'
            } | Should -Throw '*认证域*拒绝复用*'
        }
    }

    It 'configures the new exact Qwen Profile by reusing the matching Workspace SecretRef without plaintext access' {
        InModuleScope AiCliProfileManager {
            $script:savedQwen37 = $null
            Mock Get-AiCliUserProfile {
                if ($Id -eq 'codex-qwen3-8-max-paygo') {
                    return [ordered]@{
                        id = $Id; templateId = $Id
                        secretRef = 'opaque-qwen-workspace-secret-ref'
                    }
                }
                return $null
            }
            Mock Get-AiCliResolvedProfile {
                [ordered]@{
                    provider = 'qwen'; plan = 'paygo'; region = 'cn-beijing'
                    endpoint = 'https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1'
                    auth = [ordered]@{ type = 'api-key' }
                    secretConfigured = $true
                }
            }
            Mock Read-Host { 'https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1' }
            Mock Test-AiCliSecretExists { $true }
            Mock Save-AiCliUserProfile { $script:savedQwen37 = $Profile }
            Mock Read-AiCliSecret { throw 'must not read plaintext during reuse' }
            Mock New-AiCliSecret { throw 'must not create a secret during reuse' }
            Mock Write-AiCliInfo {}
            Mock Write-AiCliWarn {}
            Mock Write-AiCliSuccess {}

            Invoke-AiCliProfileConfigure -TemplateId 'codex-qwen3-7-max-paygo' `
                -ReuseSecretFrom 'codex-qwen3-8-max-paygo' | Out-Null

            $script:savedQwen37.id | Should -Be 'codex-qwen3-7-max-paygo'
            $script:savedQwen37.templateId | Should -Be 'codex-qwen3-7-max-paygo'
            $script:savedQwen37.models.primary | Should -Be 'qwen3.7-max-2026-06-08'
            $script:savedQwen37.endpoint | Should -Be 'https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1'
            $script:savedQwen37.secretRef | Should -Be 'opaque-qwen-workspace-secret-ref'
            Should -Invoke Read-Host -Times 0 -Exactly
            Should -Invoke Read-AiCliSecret -Times 0 -Exactly
            Should -Invoke New-AiCliSecret -Times 0 -Exactly
        }
    }

    It 'never deletes a shared DeepSeek SecretRef when saving the target Profile fails' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile {
                if ($Id -eq 'codex-deepseek') {
                    return [ordered]@{
                        id = 'codex-deepseek'
                        templateId = 'codex-deepseek'
                        secretRef = 'opaque-shared-deepseek-ref'
                    }
                }
                return $null
            }
            Mock Get-AiCliResolvedProfile {
                [ordered]@{
                    id = 'codex-deepseek'
                    provider = 'deepseek'
                    plan = 'paygo'
                    region = 'global'
                    endpoint = 'https://api.deepseek.com'
                    auth = [ordered]@{ type = 'api-key' }
                    secretConfigured = $true
                }
            }
            Mock Test-AiCliSecretExists { $true }
            Mock Save-AiCliUserProfile { throw 'simulated target save failure' }
            Mock Remove-AiCliSecret {}
            Mock New-AiCliSecret { throw 'must not create a secret during reuse' }
            Mock Read-AiCliSecret { throw 'must not read plaintext during reuse' }
            Mock Write-AiCliInfo {}
            Mock Write-AiCliWarn {}

            {
                Invoke-AiCliProfileConfigure -TemplateId 'codex-deepseek-v4-pro' `
                    -ReuseSecretFrom 'codex-deepseek'
            } | Should -Throw '*simulated target save failure*'
            Should -Invoke Remove-AiCliSecret -Times 0 -Exactly
            Should -Invoke New-AiCliSecret -Times 0 -Exactly
            Should -Invoke Read-AiCliSecret -Times 0 -Exactly
        }
    }
}

Describe 'Qwen3.7 upgrade retirement migration' {
    BeforeAll {
        function Get-TestSha256Hex {
            param([byte[]]$Bytes)
            $sha = [Security.Cryptography.SHA256]::Create()
            try { return [Convert]::ToHexString($sha.ComputeHash($Bytes)).ToLowerInvariant() }
            finally { $sha.Dispose() }
        }

        function New-TestRetirementFixture {
            param([string]$Root, [switch]$TamperToml)
            $roaming = Join-Path $Root 'Roaming\AiCliProfileManager'
            $local = Join-Path $Root 'Local\AiCliProfileManager'
            $codexHome = Join-Path $Root 'codex'
            $moduleRoot = Join-Path $Root 'Modules\AiCliProfileManager'
            $profiles = Join-Path $roaming 'profiles'
            $stateDir = Join-Path $local 'state'
            $secrets = Join-Path $local 'secrets'
            $catalogRoot = Join-Path $codexHome 'aicli-model-catalogs'
            New-Item -ItemType Directory -Force -Path $profiles, $stateDir, $secrets, $catalogRoot | Out-Null

            $secretId = '0123456789abcdef0123456789abcdef'
            Set-Content -LiteralPath (Join-Path $secrets "$secretId.bin") -Value 'opaque' -Encoding ascii
            [ordered]@{
                id = 'codex-qwen-paygo'; templateId = 'codex-qwen-paygo'
                secretRef = $secretId
                models = [ordered]@{ primary = 'qwen3.7-max-2026-06-08' }
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (
                Join-Path $profiles 'codex-qwen-paygo.json'
            ) -Encoding utf8
            [ordered]@{
                schemaVersion = 1; defaultProfileId = 'codex-qwen-paygo'
                lastProfileId = 'codex-qwen-paygo'; projectBookmarks = @()
                proxyPorts = [ordered]@{}; verification = [ordered]@{}
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (
                Join-Path $roaming 'settings.json'
            ) -Encoding utf8

            $body = "model = `"qwen3.7-max-2026-06-08`"`n"
            $bodyHash = Get-TestSha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($body))
            $safeId = 'aicli-codex-qwen-paygo'
            $toml = Join-Path $codexHome "$safeId.config.toml"
            $managed = @(
                '# aicli-managed=true'
                "# aicli-profile-id=$safeId"
                "# aicli-content-hash=$bodyHash"
                '# aicli-do-not-edit-unless-you-accept-unmanaged'
                $(if ($TamperToml) { $body + '# user change' } else { $body })
            ) -join "`n"
            [IO.File]::WriteAllText($toml, $managed, [Text.UTF8Encoding]::new($false))
            [ordered]@{
                $safeId = [ordered]@{
                    profileId = 'codex-qwen-paygo'; fileName = "$safeId.config.toml"
                    fullPath = $toml; contentHash = $bodyHash
                }
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (
                Join-Path $stateDir 'codex-managed-profiles.json'
            ) -Encoding utf8

            $catalogBytes = [Text.UTF8Encoding]::new($false).GetBytes(
                '{"models":[{"slug":"qwen3.7-max-2026-06-08"}]}'
            )
            $catalogHash = Get-TestSha256Hex -Bytes $catalogBytes
            $catalog = Join-Path $catalogRoot "qwen3.7-codex-$($catalogHash.Substring(0,12)).json"
            [IO.File]::WriteAllBytes($catalog, $catalogBytes)

            foreach ($version in @('0.3.4', '0.3.5')) {
                $versionRoot = Join-Path $moduleRoot $version
                New-Item -ItemType Directory -Force -Path $versionRoot | Out-Null
                @"
@{
    RootModule = 'AiCliProfileManager.psm1'
    ModuleVersion = '$version'
    GUID = 'a1c11c11-0a11-4c11-b111-a1c110110011'
}
"@ | Set-Content -LiteralPath (Join-Path $versionRoot 'AiCliProfileManager.psd1') -Encoding utf8
                Set-Content -LiteralPath (Join-Path $versionRoot 'AiCliProfileManager.psm1') `
                    -Value '# managed test module' -Encoding utf8
            }

            return [pscustomobject]@{
                Roaming = $roaming; Local = $local; CodexHome = $codexHome
                ModuleRoot = $moduleRoot; SecretId = $secretId; Toml = $toml
                Catalog = $catalog; Profile = Join-Path $profiles 'codex-qwen-paygo.json'
            }
        }
    }

    It 'preserves the reintroduced exact 06-08 Profile, managed TOML, state and catalog' {
        $root = Join-Path $TestDrive 'migration-active-exact'
        $roaming = Join-Path $root 'roaming'
        $local = Join-Path $root 'local'
        $codexHome = Join-Path $root 'codex'
        $profiles = Join-Path $roaming 'profiles'
        $stateDir = Join-Path $local 'state'
        $catalogRoot = Join-Path $codexHome 'aicli-model-catalogs'
        foreach ($directory in @($profiles, $stateDir, $catalogRoot)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }

        $profileId = 'codex-qwen3-7-max-paygo'
        $safeId = 'aicli-codex-qwen3-7-max-paygo'
        $model = 'qwen3.7-max-2026-06-08'
        $profilePath = Join-Path $profiles "$profileId.json"
        [ordered]@{
            schemaVersion = 1; id = $profileId; templateId = $profileId
            region = 'cn-beijing'; plan = 'paygo'
            endpoint = 'https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1'
            models = [ordered]@{ primary = $model; small = $model; candidates = @($model) }
            secretRef = 'opaque-secret-ref'
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $profilePath -Encoding utf8

        $catalogBytes = [Text.UTF8Encoding]::new($false).GetBytes(
            ('{"models":[{"slug":"' + $model + '"}]}')
        )
        $catalogHash = Get-TestSha256Hex -Bytes $catalogBytes
        $catalogName = "qwen3.7-max-2026-06-08-codex-$($catalogHash.Substring(0,12)).json"
        $catalogPath = Join-Path $catalogRoot $catalogName
        [IO.File]::WriteAllBytes($catalogPath, $catalogBytes)

        $body = @(
            "model = `"$model`""
            'model_provider = "aicli_qwen37_max_0608_paygo"'
            "model_catalog_json = `"$($catalogPath.Replace('\','\\'))`""
            ''
        ) -join "`n"
        $bodyHash = Get-TestSha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($body))
        $tomlPath = Join-Path $codexHome "$safeId.config.toml"
        $managed = @(
            '# aicli-managed=true'
            "# aicli-profile-id=$safeId"
            "# aicli-content-hash=$bodyHash"
            '# aicli-do-not-edit-unless-you-accept-unmanaged'
            $body
        ) -join "`n"
        [IO.File]::WriteAllText($tomlPath, $managed, [Text.UTF8Encoding]::new($false))
        $statePath = Join-Path $stateDir 'codex-managed-profiles.json'
        [ordered]@{
            $safeId = [ordered]@{
                profileId = $profileId; fileName = "$safeId.config.toml"
                fullPath = $tomlPath; contentHash = $bodyHash
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8
        [ordered]@{
            schemaVersion = 1; defaultProfileId = $profileId; lastProfileId = $profileId
            projectBookmarks = @(); proxyPorts = [ordered]@{}; verification = [ordered]@{}
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (
            Join-Path $roaming 'settings.json'
        ) -Encoding utf8

        $result = & (Join-Path $script:RetirementRepoRoot 'scripts\Invoke-AiCliRetirementMigration.ps1') `
            -RoamingRoot $roaming -LocalRoot $local -CodexHome $codexHome `
            -CurrentVersion '0.3.9' -FailOnBlocked

        $result.status | Should -Be 'complete'
        $result.planned | Should -Be 0
        foreach ($path in @($profilePath, $tomlPath, $statePath, $catalogPath)) {
            Test-Path -LiteralPath $path | Should -BeTrue -Because $path
        }
        (Get-Content -LiteralPath (Join-Path $roaming 'settings.json') -Raw | ConvertFrom-Json).defaultProfileId |
            Should -Be $profileId
        @(Get-ChildItem -LiteralPath (Join-Path $local 'retirement\qwen37-v1') -File -Recurse).Count |
            Should -Be 0
    }

    It 'quarantines verified legacy entrances while preserving SecretRef data and is idempotent' {
        $fixture = New-TestRetirementFixture -Root (Join-Path $TestDrive 'migration-pass')
        $scriptPath = Join-Path $script:RetirementRepoRoot 'scripts\Invoke-AiCliRetirementMigration.ps1'

        $result = & $scriptPath -RoamingRoot $fixture.Roaming -LocalRoot $fixture.Local `
            -CodexHome $fixture.CodexHome -ModuleRoot $fixture.ModuleRoot `
            -CurrentVersion '0.3.5' -FailOnBlocked

        @($result.Blocked).Count | Should -Be 0
        @($result.Moved).Count | Should -BeGreaterThan 3
        Test-Path -LiteralPath $fixture.Profile | Should -BeFalse
        Test-Path -LiteralPath $fixture.Toml | Should -BeFalse
        Test-Path -LiteralPath $fixture.Catalog | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.ModuleRoot '0.3.4') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.ModuleRoot '0.3.5') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.Local "secrets\$($fixture.SecretId).bin") |
            Should -BeTrue
        $settings = Get-Content -LiteralPath (Join-Path $fixture.Roaming 'settings.json') -Raw |
            ConvertFrom-Json
        $settings.defaultProfileId | Should -BeNullOrEmpty
        $settings.lastProfileId | Should -BeNullOrEmpty
        $state = Get-Content -LiteralPath (
            Join-Path $fixture.Local 'state\codex-managed-profiles.json'
        ) -Raw | ConvertFrom-Json
        $state.PSObject.Properties.Name | Should -Not -Contain 'aicli-codex-qwen-paygo'

        $again = & $scriptPath -RoamingRoot $fixture.Roaming -LocalRoot $fixture.Local `
            -CodexHome $fixture.CodexHome -ModuleRoot $fixture.ModuleRoot `
            -CurrentVersion '0.3.5' -FailOnBlocked
        @($again.Blocked).Count | Should -Be 0
        @($again.Moved).Count | Should -Be 0
    }

    It 'fails before mutation when a managed legacy TOML was modified' {
        $fixture = New-TestRetirementFixture -Root (Join-Path $TestDrive 'migration-block') -TamperToml
        $scriptPath = Join-Path $script:RetirementRepoRoot 'scripts\Invoke-AiCliRetirementMigration.ps1'

        {
            & $scriptPath -RoamingRoot $fixture.Roaming -LocalRoot $fixture.Local `
                -CodexHome $fixture.CodexHome -ModuleRoot $fixture.ModuleRoot `
                -CurrentVersion '0.3.5' -FailOnBlocked
        } | Should -Throw '*retirement migration blocked*'

        Test-Path -LiteralPath $fixture.Profile | Should -BeTrue
        Test-Path -LiteralPath $fixture.Toml | Should -BeTrue
        Test-Path -LiteralPath $fixture.Catalog | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.ModuleRoot '0.3.4') | Should -BeTrue
    }

    It 'blocks a quarantine destination collision during preflight without mutation' {
        $fixture = New-TestRetirementFixture -Root (Join-Path $TestDrive 'migration-collision')
        $scriptPath = Join-Path $script:RetirementRepoRoot 'scripts\Invoke-AiCliRetirementMigration.ps1'
        $collisionRoot = Join-Path $fixture.Local 'retirement\qwen37-v1\profiles'
        New-Item -ItemType Directory -Force -Path $collisionRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $collisionRoot 'codex-qwen-paygo.json') `
            -Value 'existing quarantine evidence' -Encoding utf8

        {
            & $scriptPath -RoamingRoot $fixture.Roaming -LocalRoot $fixture.Local `
                -CodexHome $fixture.CodexHome -ModuleRoot $fixture.ModuleRoot `
                -CurrentVersion '0.3.5' -FailOnBlocked -PreflightOnly
        } | Should -Throw '*quarantine 目标已存在*'

        Test-Path -LiteralPath $fixture.Profile | Should -BeTrue
        Test-Path -LiteralPath $fixture.Toml | Should -BeTrue
        Test-Path -LiteralPath $fixture.Catalog | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.ModuleRoot '0.3.4') | Should -BeTrue
    }

    It 'blocks a metadata junction during preflight without touching its external target' {
        $fixture = New-TestRetirementFixture -Root (Join-Path $TestDrive 'metadata-junction')
        $scriptPath = Join-Path $script:RetirementRepoRoot 'scripts\Invoke-AiCliRetirementMigration.ps1'
        $external = Join-Path $TestDrive 'external-metadata-target'
        $metadata = Join-Path $fixture.Local 'retirement\qwen37-v1\metadata'
        New-Item -ItemType Directory -Force -Path $external, (Split-Path -Parent $metadata) |
            Out-Null
        $canary = Join-Path $external 'canary.txt'
        Set-Content -LiteralPath $canary -Value 'preserve' -Encoding utf8
        New-Item -ItemType Junction -Path $metadata -Target $external | Out-Null

        {
            & $scriptPath -RoamingRoot $fixture.Roaming -LocalRoot $fixture.Local `
                -CodexHome $fixture.CodexHome -ModuleRoot $fixture.ModuleRoot `
                -CurrentVersion '0.3.5' -FailOnBlocked -PreflightOnly
        } | Should -Throw '*metadata 目录不是普通目录*'

        (Get-Content -LiteralPath $canary -Raw).Trim() | Should -BeExactly 'preserve'
        @(Get-ChildItem -LiteralPath $external -Force).Count | Should -Be 1
        Test-Path -LiteralPath $fixture.Profile | Should -BeTrue
        Test-Path -LiteralPath $fixture.Toml | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.ModuleRoot '0.3.4') | Should -BeTrue
    }

    It 'blocks a LocalRoot junction before creating quarantine or touching its target' {
        $fixtureRoot = Join-Path $TestDrive 'local-root-junction'
        $external = Join-Path $fixtureRoot 'external-local-root'
        $localJunction = Join-Path $fixtureRoot 'local-link'
        $roaming = Join-Path $fixtureRoot 'roaming'
        $codexHome = Join-Path $fixtureRoot 'codex'
        $moduleRoot = Join-Path $fixtureRoot 'modules\AiCliProfileManager'
        New-Item -ItemType Directory -Force -Path (
            $external, $roaming, $codexHome, $moduleRoot
        ) | Out-Null
        $canary = Join-Path $external 'canary.txt'
        Set-Content -LiteralPath $canary -Value 'preserve' -Encoding utf8
        New-Item -ItemType Junction -Path $localJunction -Target $external | Out-Null
        $scriptPath = Join-Path $script:RetirementRepoRoot `
            'scripts\Invoke-AiCliRetirementMigration.ps1'

        {
            & $scriptPath -RoamingRoot $roaming -LocalRoot $localJunction `
                -CodexHome $codexHome -ModuleRoot $moduleRoot `
                -CurrentVersion '0.3.5' -FailOnBlocked -PreflightOnly
        } | Should -Throw '*LocalRoot*普通目录*'

        (Get-Content -LiteralPath $canary -Raw).Trim() | Should -BeExactly 'preserve'
        @(Get-ChildItem -LiteralPath $external -Force).Count | Should -Be 1
    }

    It 'blocks metadata backup collisions and invalid settings before any mutation' -ForEach @(
        @{ Case = 'collision'; InvalidSettings = $false }
        @{ Case = 'invalid-settings'; InvalidSettings = $true }
    ) {
        $fixture = New-TestRetirementFixture -Root (
            Join-Path $TestDrive "metadata-$Case"
        )
        $scriptPath = Join-Path $script:RetirementRepoRoot 'scripts\Invoke-AiCliRetirementMigration.ps1'
        if ($InvalidSettings) {
            Set-Content -LiteralPath (Join-Path $fixture.Roaming 'settings.json') `
                -Value '{invalid' -Encoding utf8
        } else {
            $metadata = Join-Path $fixture.Local 'retirement\qwen37-v1\metadata'
            New-Item -ItemType Directory -Force -Path $metadata | Out-Null
            Set-Content -LiteralPath (
                Join-Path $metadata 'codex-managed-profiles.before.json'
            ) -Value '{}' -Encoding utf8
        }

        {
            & $scriptPath -RoamingRoot $fixture.Roaming -LocalRoot $fixture.Local `
                -CodexHome $fixture.CodexHome -ModuleRoot $fixture.ModuleRoot `
                -CurrentVersion '0.3.5' -FailOnBlocked -PreflightOnly
        } | Should -Throw

        Test-Path -LiteralPath $fixture.Profile | Should -BeTrue
        Test-Path -LiteralPath $fixture.Toml | Should -BeTrue
        Test-Path -LiteralPath $fixture.Catalog | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.ModuleRoot '0.3.4') | Should -BeTrue
    }

    It 'restores an existing same-version module when retirement migration fails after promotion' {
        $fixtureRoot = Join-Path $TestDrive 'install-rollback'
        $sourceRoot = Join-Path $fixtureRoot 'source'
        $sourceModule = Join-Path $sourceRoot 'src\AiCliProfileManager'
        $sourceScripts = Join-Path $sourceRoot 'scripts'
        $modulePath = Join-Path $fixtureRoot 'Documents\PowerShell\Modules'
        $installed = Join-Path $modulePath 'AiCliProfileManager\0.3.5'
        New-Item -ItemType Directory -Force -Path $sourceModule, $sourceScripts, $installed | Out-Null

        @"
@{
    RootModule = 'AiCliProfileManager.psm1'
    ModuleVersion = '0.3.5'
    GUID = 'a1c11c11-0a11-4c11-b111-a1c110110011'
    FunctionsToExport = @('Get-AiCliVersion')
}
"@ | Set-Content -LiteralPath (Join-Path $sourceModule 'AiCliProfileManager.psd1') -Encoding utf8
        "function Get-AiCliVersion { '0.3.5' }; Export-ModuleMember -Function Get-AiCliVersion" |
            Set-Content -LiteralPath (Join-Path $sourceModule 'AiCliProfileManager.psm1') -Encoding utf8
        Copy-Item -LiteralPath (Join-Path $sourceModule 'AiCliProfileManager.psd1') `
            -Destination $installed
        Set-Content -LiteralPath (Join-Path $installed 'AiCliProfileManager.psm1') `
            -Value "function Get-AiCliVersion { '0.3.5-old' }" -Encoding utf8
        @'
param(
    [string]$ModuleRoot,
    [version]$CurrentVersion,
    [switch]$FailOnBlocked,
    [switch]$PreflightOnly,
    [string]$RoamingRoot,
    [string]$LocalRoot,
    [string]$CodexHome
)
if ($PreflightOnly) { return [pscustomobject]@{ status = 'ready'; moved = @() } }
throw 'simulated retirement migration failure'
'@ | Set-Content -LiteralPath (
            Join-Path $sourceScripts 'Invoke-AiCliRetirementMigration.ps1'
        ) -Encoding utf8
        Set-Content -LiteralPath (Join-Path $installed 'old-marker.txt') -Value 'old payload' -Encoding utf8

        $pathBefore = $env:PSModulePath
        try {
            $env:PSModulePath = $modulePath
            {
                & (Join-Path $script:RetirementRepoRoot 'scripts\Install.ps1') `
                    -SourceRoot $sourceRoot -Force -SkipShellIntegration `
                    -RetirementRootOverride (Join-Path $fixtureRoot 'retirement-state')
            } | Should -Throw '*simulated retirement migration failure*'
        } finally {
            $env:PSModulePath = $pathBefore
        }

        Test-Path -LiteralPath (Join-Path $installed 'old-marker.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installed 'AiCliProfileManager.psd1') | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $installed) -Directory -Force |
            Where-Object Name -Like '.0.3.5.backup-*').Count | Should -Be 0
    }

    It 'rejects a same-version module junction before migration or candidate copy' {
        $fixtureRoot = Join-Path $TestDrive 'install-junction-reject'
        $sourceRoot = Join-Path $fixtureRoot 'source'
        $sourceModule = Join-Path $sourceRoot 'src\AiCliProfileManager'
        $sourceScripts = Join-Path $sourceRoot 'scripts'
        $modulePath = Join-Path $fixtureRoot 'Documents\PowerShell\Modules'
        $moduleRoot = Join-Path $modulePath 'AiCliProfileManager'
        $installed = Join-Path $moduleRoot '0.3.5'
        $external = Join-Path $fixtureRoot 'external-module'
        New-Item -ItemType Directory -Force -Path (
            $sourceModule, $sourceScripts, $moduleRoot, $external
        ) | Out-Null
        @"
@{
    RootModule = 'AiCliProfileManager.psm1'
    ModuleVersion = '0.3.5'
    GUID = 'a1c11c11-0a11-4c11-b111-a1c110110011'
}
"@ | Set-Content -LiteralPath (Join-Path $sourceModule 'AiCliProfileManager.psd1') -Encoding utf8
        Set-Content -LiteralPath (Join-Path $sourceModule 'AiCliProfileManager.psm1') `
            -Value '# candidate' -Encoding utf8
        Copy-Item -LiteralPath (
            Join-Path $script:RetirementRepoRoot 'scripts\Invoke-AiCliRetirementMigration.ps1'
        ) -Destination $sourceScripts
        Set-Content -LiteralPath (Join-Path $external 'canary.txt') `
            -Value 'preserve' -Encoding utf8
        New-Item -ItemType Junction -Path $installed -Target $external | Out-Null

        $oldModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = "$modulePath;$oldModulePath"
            {
                & (Join-Path $script:RetirementRepoRoot 'scripts\Install.ps1') `
                    -SourceRoot $sourceRoot -Force -SkipShellIntegration `
                    -RetirementRootOverride (Join-Path $fixtureRoot 'retirement-root')
            } | Should -Throw '*普通目录*'
        } finally {
            $env:PSModulePath = $oldModulePath
        }

        (Get-Content -LiteralPath (Join-Path $external 'canary.txt') -Raw).Trim() |
            Should -BeExactly 'preserve'
        (Get-Item -LiteralPath $installed -Force).Attributes.HasFlag(
            [IO.FileAttributes]::ReparsePoint
        ) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $moduleRoot -Force |
            Where-Object Name -Like '.0.3.5.*-*').Count | Should -Be 0
    }
}
