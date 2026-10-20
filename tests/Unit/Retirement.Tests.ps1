#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RetirementRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module -Name AiCliProfileManager -All -ErrorAction SilentlyContinue |
        Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RetirementRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'Retired provider identities' {
    It 'rejects retired entry IDs even when rebound to an active model or missing models' {
        InModuleScope AiCliProfileManager {
            foreach ($id in @('codex-deepseek', 'claude-deepseek', 'oi-deepseek', 'CODEX-DEEPSEEK')) {
                foreach ($template in @('codex-official', 'codex-deepseek-flash')) {
                    $profile = @{ id = $id; templateId = $template; models = @{ primary = 'gpt-5.6-sol' } }
                    { Assert-AiCliProfileDoesNotUseRetiredModel -Profile $profile } | Should -Throw '*已退役的 Profile ID*'
                    $profile.Remove('models')
                    { Assert-AiCliProfileDoesNotUseRetiredModel -Profile $profile } | Should -Throw '*已退役的 Profile ID*'
                }
                { Assert-AiCliProfileDoesNotUseRetiredModel -Profile @{ id = 'my-work'; templateId = $id } } |
                    Should -Throw '*已退役的 Profile ID*'
            }
        }
    }

    It 'preserves ordinary aliases and active DeepSeek exact Profiles' {
        InModuleScope AiCliProfileManager {
            { Assert-AiCliProfileDoesNotUseRetiredModel -Profile @{
                id = 'my-deepseek-work'; templateId = 'codex-official'; models = @{ primary = 'gpt-5.6-sol' }
            } } | Should -Not -Throw
            foreach ($id in @('codex-deepseek-flash', 'codex-deepseek-v4-pro')) {
                { Assert-AiCliProfileDoesNotUseRetiredModel -Profile (Get-AiCliProviderManifest -Id $id) } |
                    Should -Not -Throw
            }
        }
    }

    It 'rejects configuring a retired name before interaction, credentials or profile writes' {
        InModuleScope AiCliProfileManager {
            Mock Read-Host { throw 'unexpected interaction' }
            Mock Get-AiCliUserProfile { throw 'unexpected user profile read' }
            Mock Resolve-AiCliReusableSecretRef { throw 'unexpected credential access' }
            Mock Save-AiCliUserProfile { throw 'unexpected profile write' }
            foreach ($id in @('codex-deepseek', 'claude-deepseek', 'oi-deepseek')) {
                { Invoke-AiCliProfileConfigure -TemplateId 'codex-official' -ProfileId $id } |
                    Should -Throw '*已退役的 Profile ID*'
            }
            Should -Invoke Read-Host -Times 0
            Should -Invoke Get-AiCliUserProfile -Times 0
            Should -Invoke Resolve-AiCliReusableSecretRef -Times 0
            Should -Invoke Save-AiCliUserProfile -Times 0
        }
    }

    It 'rejects legacy show and start without changing the user file or listing it as available' {
        $dataRoot = Join-Path $TestDrive 'retired-entry-rebound'
        $profiles = Join-Path $dataRoot 'AppData/profiles'
        $null = New-Item -ItemType Directory -Path $profiles -Force
        $path = Join-Path $profiles 'codex-deepseek.json'
        [IO.File]::WriteAllText($path, '{"schemaVersion":1,"id":"codex-deepseek","templateId":"codex-official","models":{"primary":"gpt-5.6-sol"}}')
        $before = (Get-FileHash -LiteralPath $path).Hash
        Invoke-AiCli -Tokens @('profile','show','codex-deepseek','--json') -DataRoot $dataRoot | Should -Be 4
        Invoke-AiCli -Tokens @('start','codex-deepseek','--project',$dataRoot) -DataRoot $dataRoot | Should -Be 4
        $writer = [IO.StringWriter]::new()
        $oldOut = [Console]::Out
        try {
            [Console]::SetOut($writer)
            $code = Invoke-AiCli -Tokens @('profile','list','--available','--json') -DataRoot $dataRoot
        } finally {
            [Console]::SetOut($oldOut)
        }
        $code | Should -Be 0
        $list = $writer.ToString() | ConvertFrom-Json
        $writer.Dispose()
        @($list.profiles.id) | Should -Not -Contain 'codex-deepseek'
        @($list.profiles.id) | Should -Contain 'codex-official'
        (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $before
    }

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

    It 'keeps the exact Qwen cloud routes and retains the 35B cross-check slot' {
        $manifests = InModuleScope AiCliProfileManager { Import-AiCliProviderManifests }
        @($manifests.Keys | Where-Object { $_ -like '*qwen*' -or $_ -like '*ollama-main' -or $_ -eq 'codex-ollama-review' } | Sort-Object) | Should -Be @(
            'claude-ollama-main',
            'codex-ollama-main',
            'codex-ollama-qwen3-6-35b-abliterated',
            'codex-ollama-qwen3-8-27b',
            'codex-ollama-qwen3-8-27b-abliterated',
            'codex-ollama-review',
            'codex-qwen3-7-max-paygo',
            'codex-qwen3-8-max-paygo',
            'opencode-ollama-main',
            'opencode-ollama-qwen3-8-27b',
            'qwen-code-ollama-main'
        )
        $cloud = $manifests['codex-qwen3-8-max-paygo']
        $cloud.models.primary | Should -Be 'qwen3.8-max-0902'
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

    It 'keeps the auto-updating DeepSeek Flash ID and CLI-only V4 Pro without reserved variants' {
        $manifests = InModuleScope AiCliProfileManager {
            $all = Import-AiCliProviderManifests
            @($all.Values | Where-Object provider -eq 'deepseek')
        }

        foreach ($manifest in @($manifests)) {
            @($manifest.models.reserved) | Should -BeNullOrEmpty -Because $manifest.id
            @($manifest.models.candidates) | Should -Not -Contain 'deepseek-chat' -Because $manifest.id
            @($manifest.models.candidates) | Should -Not -Contain 'deepseek-reasoner' -Because $manifest.id
            foreach ($model in @(
                $manifest.models.primary,
                $manifest.models.small,
                @($manifest.models.candidates)
            ) | Where-Object { $_ }) {
                $model | Should -BeIn @('deepseek-flash', 'deepseek-v4-pro') -Because $manifest.id
            }
        }

        $flash = @($manifests | Where-Object id -eq 'codex-deepseek-flash')[0]
        $pro = @($manifests | Where-Object id -eq 'codex-deepseek-v4-pro')[0]
        $flash.compatibility.modelVersion | Should -Be 'DeepSeek-V4.1-Flash'
        $pro.compatibility.modelVersion | Should -Be 'DeepSeek-V4-Pro-0813'
        @($manifests.id) | Should -Not -Contain 'codex-deepseek'
        @($manifests.id) | Should -Not -Contain 'claude-deepseek'
        @($manifests.id) | Should -Not -Contain 'oi-deepseek'
    }

    It 'rejects retired DeepSeek V4 Flash identities while retaining deepseek-flash and exact V4 Pro' {
        InModuleScope AiCliProfileManager {
            foreach ($modelId in @(
                'deepseek-v4',
                'deepseek-v4-flash',
                'deepseek-v4-flash-0731',
                'deepseek-v4-pro-0813',
                'deepseek-v4-preview',
                'deepseek-v4:preview',
                'DeepSeek-V4-Pro',
                'DeepSeek-V4-Flash-0731'
            )) {
                { Assert-AiCliModelIsActive -ModelId $modelId -Context '测试模型' } |
                    Should -Throw '*已退役的 DeepSeek V4 Flash*deepseek-flash*deepseek-v4-pro*' -Because $modelId
                { Assert-AiCliNativeArgsDoNotUseRetiredModel -NativeArgs @('--model', $modelId) } |
                    Should -Throw '*DeepSeek V4 Flash*' -Because $modelId
            }

            foreach ($activeAlias in @('deepseek-flash', 'deepseek-v4-pro')) {
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
            foreach ($modelId in @('qwen3:8b', 'qwen3.6-35b:256k', 'qwen3.8-max-0902')) {
                Test-AiCliRetiredModelId -ModelId $modelId | Should -BeFalse -Because $modelId
            }
            Test-AiCliRetiredModelId -ModelId 'qwen3.8-max' | Should -BeTrue
            foreach ($modelId in @('qwen-review-v1', 'qwen3.6:27b', 'qwen3.6-27b-256k')) {
                Test-AiCliRetiredModelId -ModelId $modelId | Should -BeTrue -Because $modelId
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
                Should -Throw '*已退役的 DeepSeek V4 Flash*'
        }
    }

    It 'reuses an existing opaque secret reference only when its template proves the same credential domain' {
        InModuleScope AiCliProfileManager {
            Mock Test-AiCliSecretExists { $true }
            $template = Get-AiCliProviderManifest -Id 'codex-deepseek-flash'
            $existing = [ordered]@{
                id = 'codex-deepseek-flash'
                templateId = 'codex-deepseek-flash'
                secretRef = 'opaque-existing-secret-ref'
            }

            Resolve-AiCliReusableSecretRef `
                -Template $template `
                -ProfileId 'codex-deepseek-flash' `
                -ExistingProfile $existing `
                -ReuseExistingSecret |
                Should -Be 'opaque-existing-secret-ref'
        }
    }

    It 'rejects same-id SecretRef reuse when the old template belongs to another provider' {
        InModuleScope AiCliProfileManager {
            Mock Test-AiCliSecretExists { $true }
            $template = Get-AiCliProviderManifest -Id 'codex-deepseek-flash'
            $existing = [ordered]@{
                id = 'codex-deepseek-flash'
                templateId = 'codex-official'
                secretRef = 'opaque-unknown-secret-ref'
            }

            {
                Resolve-AiCliReusableSecretRef -Template $template `
                    -ProfileId 'codex-deepseek-flash' -ExistingProfile $existing -ReuseExistingSecret
            } | Should -Throw '*认证域*拒绝复用*'
        }
    }

    It 'can share one configured DeepSeek SecretRef with the exact Pro Profile' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile {
                [ordered]@{
                    id = 'codex-deepseek-flash'
                    templateId = 'codex-deepseek-flash'
                    secretRef = 'opaque-deepseek-secret-ref'
                }
            }
            Mock Get-AiCliResolvedProfile {
                [ordered]@{
                    id = 'codex-deepseek-flash'
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
                -ReuseSecretFrom 'codex-deepseek-flash' |
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

    It 'configures the exact Qwen Profile from the matching Workspace endpoint with the vendor reference' {
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
            $script:savedQwen37.secretRef | Should -Be 'passwordcenter:qwen'
            Should -Invoke Read-Host -Times 0 -Exactly
            Should -Invoke Read-AiCliSecret -Times 0 -Exactly
            Should -Invoke New-AiCliSecret -Times 0 -Exactly
        }
    }

    It 'never deletes a shared DeepSeek SecretRef when saving the target Profile fails' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile {
                if ($Id -eq 'codex-deepseek-flash') {
                    return [ordered]@{
                        id = 'codex-deepseek-flash'
                        templateId = 'codex-deepseek-flash'
                        secretRef = 'opaque-shared-deepseek-ref'
                    }
                }
                return $null
            }
            Mock Get-AiCliResolvedProfile {
                [ordered]@{
                    id = 'codex-deepseek-flash'
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
                    -ReuseSecretFrom 'codex-deepseek-flash'
            } | Should -Throw '*simulated target save failure*'
            Should -Invoke Remove-AiCliSecret -Times 0 -Exactly
            Should -Invoke New-AiCliSecret -Times 0 -Exactly
            Should -Invoke Read-AiCliSecret -Times 0 -Exactly
        }
    }
}
