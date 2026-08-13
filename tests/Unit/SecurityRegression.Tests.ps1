#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:SecurityRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module -Name AiCliProfileManager -All -ErrorAction SilentlyContinue |
        Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:SecurityRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'Path isolation' {
    It 'rejects Profile path traversal without deleting a sibling JSON file' {
        $dataRoot = Join-Path $TestDrive 'profile-root'
        New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
        $victim = Join-Path $dataRoot 'victim.json'
        Set-Content -LiteralPath $victim -Value '{"keep":true}' -Encoding utf8

        $code = Invoke-AiCli -Tokens @('profile','remove','..\..\victim','--yes') -DataRoot $dataRoot

        $code | Should -Not -Be 0
        Test-Path -LiteralPath $victim | Should -BeTrue
    }

    It 'rejects Secret path traversal' {
        $dataRoot = Join-Path $TestDrive 'secret-root'
        InModuleScope AiCliProfileManager -Parameters @{ Root = $dataRoot } {
            Set-AiCliDataRootOverride -Path $Root
            try {
                { Get-AiCliSecret -SecretId '..\..\victim' } | Should -Throw '*Secret ID*'
                { Remove-AiCliSecret -SecretId '..\..\victim' } | Should -Throw '*Secret ID*'
            } finally {
                Set-AiCliDataRootOverride -Path $null
            }
        }
    }
}

Describe 'Verification evidence' {
    It 'does not let a saved proxy Profile bypass installation and auth readiness' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliProxyExecutable { 'C:\managed\claude-code-proxy.exe' }
            Mock Test-AiCliProxyAuthPresent { $false }
            Mock Get-AiCliSettings { [ordered]@{ verification = [ordered]@{} } }
            $template = [ordered]@{
                schemaVersion = 1
                id = 'claude-chatgpt-ccp'
                displayName = 'ccp'
                engine = 'claude'
                proxyRef = 'ccp'
                requiresSecret = $false
                virtualReady = $false
            }
            $user = [ordered]@{ id = 'my-ccp'; displayName = 'My ccp' }

            $resolved = Merge-AiCliProfile -Template $template -UserProfile $user

            $resolved.proxyInstalled | Should -BeTrue
            $resolved.proxyAuthPresent | Should -BeFalse
            $resolved.configured | Should -BeFalse
        }
    }

    It 'never promotes a skipped tool test to fully usable and rejects stale fingerprints' {
        $dataRoot = Join-Path $TestDrive 'verification-root'
        InModuleScope AiCliProfileManager -Parameters @{ Root = $dataRoot } {
            Mock Get-AiCliProfileCliIdentityEvidence {
                [pscustomobject]@{ FileName = 'C:\codex.exe'; Version = 'codex-cli 0.1-test'; Kind = 'test' }
            }
            Set-AiCliDataRootOverride -Path $Root
            try {
                $profile = Get-AiCliResolvedProfile -Id 'codex-official'
                $fingerprint = Get-AiCliProfileFingerprint -Profile $profile
                $settings = Get-AiCliSettings
                $settings.verification['codex-official'] = [ordered]@{
                    level = 'all'; result = 'pass'; textPass = $true
                    toolPass = $false; toolSkipped = $true; profileFingerprint = $fingerprint
                    productVersion = (Get-AiCliVersion); cliPath = 'C:\codex.exe'; cliVersion = 'codex-cli 0.1-test'
                }
                Save-AiCliSettings -Settings $settings
                (Get-AiCliResolvedProfile -Id 'codex-official').status | Should -Be '可用但有限制'

                $settings = Get-AiCliSettings
                $settings.verification['codex-official'] = [ordered]@{
                    level = 'all'; result = 'pass'; textPass = $true
                    toolPass = $true; toolSkipped = $false; profileFingerprint = ('0' * 64)
                    productVersion = (Get-AiCliVersion); cliPath = 'C:\codex.exe'; cliVersion = 'codex-cli 0.1-test'
                }
                Save-AiCliSettings -Settings $settings
                (Get-AiCliResolvedProfile -Id 'codex-official').status | Should -Be '可用但有限制'

                $settings.verification['codex-official'] = [ordered]@{
                    level = 'all'; result = 'pass'; textPass = $true
                    toolPass = $true; toolSkipped = $false; profileFingerprint = $fingerprint
                    productVersion = '9.9.9'; cliPath = 'C:\codex.exe'; cliVersion = 'codex-cli 0.1-test'
                }
                Save-AiCliSettings -Settings $settings
                $invalidated = Get-AiCliResolvedProfile -Id 'codex-official'
                $invalidated.verification | Should -BeNullOrEmpty
                $invalidated.verificationInvalidation | Should -Be '产品版本已变化'
            } finally {
                Set-AiCliDataRootOverride -Path $null
            }
        }
    }
}

Describe 'Live text evidence' {
    It 'binds a preferred Codex sandbox launch to one npm package and its helper' {
        $npmRoot = Join-Path $TestDrive 'npm'
        $shim = Join-Path $npmRoot 'codex.cmd'
        $node = Join-Path $TestDrive 'node.exe'
        $package = Join-Path $npmRoot 'node_modules\@openai\codex'
        $launcher = Join-Path $package 'bin\codex.js'
        $helper = Join-Path $package 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex-resources\codex-windows-sandbox-setup.exe'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $launcher), (Split-Path -Parent $helper) | Out-Null
        Set-Content -LiteralPath $shim -Value '@echo off' -Encoding ascii
        Set-Content -LiteralPath $node -Value '' -Encoding ascii
        Set-Content -LiteralPath $launcher -Value '' -Encoding ascii
        Set-Content -LiteralPath $helper -Value '' -Encoding ascii

        InModuleScope AiCliProfileManager -Parameters @{ Shim = $shim; Node = $node; Package = $package; Helper = $helper } {
            Mock Find-AiCliCommandPath {
                if ($Name -eq 'codex') { return $Shim }
                if ($Name -eq 'node') { return $Node }
                return $null
            }

            $resolved = Resolve-AiCliLaunchExecutable -Name 'codex' -PreferNpmCodex

            $resolved.Kind | Should -Be 'npm-node'
            $resolved.ManagedPackageRoot | Should -Be $Package
            $resolved.SandboxHelperPath | Should -Be $Helper
        }
    }

    It 'runs a CMD shim with its launcher prefix when collecting CLI version evidence' {
        $shim = Join-Path $TestDrive 'claude test shim.cmd'
        [IO.File]::WriteAllLines($shim, @('@echo off', 'echo Claude Code 9.8.7-test'))
        InModuleScope AiCliProfileManager -Parameters @{ Shim = $shim } {
            Mock Find-AiCliCommandPath { $Shim } -ParameterFilter { $Name -eq 'claude' }
            $resolved = Resolve-AiCliLaunchExecutable -Name 'claude'
            $resolved.Kind | Should -Be 'cmd-shim'
            $evidence = Get-AiCliResolvedCliVersionEvidence -Resolved $resolved
            $evidence.Version | Should -Be 'Claude Code 9.8.7-test'
            @($evidence.PrefixArgs) | Should -Be @('/c', $Shim)
        }
    }

    It 'requires the final non-empty body line to equal PONG' {
        InModuleScope AiCliProfileManager {
            Test-AiCliExactPongOutput -Text "noise`nPONG`n" | Should -BeTrue
            Test-AiCliExactPongOutput -Text 'Reply with exactly: PONG' | Should -BeFalse
            Test-AiCliExactPongOutput -Text "PONG`nrequest failed" | Should -BeFalse
        }
    }

    It 'fails when a CLI prints PONG but exits nonzero' {
        $fake = Join-Path $TestDrive 'fake-claude-fail.ps1'
        Set-Content -LiteralPath $fake -Encoding utf8 -Value "Write-Output 'PONG'`nexit 23"
        InModuleScope AiCliProfileManager -Parameters @{ Fake = $fake; Work = $TestDrive } {
            $checks = [System.Collections.Generic.List[object]]::new()
            $plan = [pscustomobject]@{
                engine = 'claude'; fileName = (Get-Command pwsh).Source
                argumentList = @('-NoProfile','-File',$Fake)
                environmentDelta = @{}; removeEnvironment = @()
            }
            $result = Invoke-AiCliTextLiveTest -Plan $plan -WorkDir $Work -Checks $checks
            $result.Pass | Should -BeFalse
            $result.ExitCode | Should -Be 23
        }
    }

    It 'passes non-sk provider secrets to bounded live capture for exact redaction' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:capturedSecretValues = @()
            Mock Invoke-AiCliChildCapture {
                $script:capturedSecretValues = @($SecretValues)
                $lastMessageIndex = [Array]::IndexOf($ArgumentList, '--output-last-message')
                Set-Content -LiteralPath $ArgumentList[$lastMessageIndex + 1] -Value 'PONG' -Encoding utf8
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = ''
                    StdErr = ''
                }
            }
            $checks = [System.Collections.Generic.List[object]]::new()
            $plan = [pscustomobject]@{
                engine = 'codex'; fileName = 'C:\fake\codex.exe'
                argumentList = @(); removeEnvironment = @()
                environmentDelta = @{
                    AICLI_CODEX_PROVIDER_KEY = 'CANARY_PROVIDER_VALUE_42'
                    AICLI_PUBLIC_SETTING = 'public-setting'
                }
            }

            $result = Invoke-AiCliTextLiveTest -Plan $plan -WorkDir $Work -Checks $checks

            $result.Pass | Should -BeTrue
            $script:capturedSecretValues | Should -Contain 'CANARY_PROVIDER_VALUE_42'
            $script:capturedSecretValues | Should -Not -Contain 'public-setting'
        }
    }

    It 'does not claim launch-plan effort evidence when plan construction fails' {
        $dataRoot = Join-Path $TestDrive 'failed-live-plan-root'
        InModuleScope AiCliProfileManager -Parameters @{ Root = $dataRoot } {
            Mock Get-AiCliResolvedProfile {
                [ordered]@{
                    id = 'failed-plan'; engine = 'codex'; provider = 'qwen'
                    transport = 'responses'; defaultEffort = 'max'
                    models = [ordered]@{ primary = 'qwen3.8-max' }
                }
            }
            Mock Build-AiCliLaunchPlan { throw 'synthetic plan failure' }
            Mock Write-AiCliJson {}
            Set-AiCliDataRootOverride -Path $Root
            try {
                $code = Invoke-AiCliLiveTest -ProfileId 'failed-plan' -Level text -Yes -Json
                $code | Should -Be (Get-AiCliExitCode Unavailable)
                $record = (Get-AiCliSettings).verification['failed-plan']
                $record.requestedEffort | Should -Be 'max'
                $record.effectiveEffort | Should -BeNullOrEmpty
                $record.effortEvidence | Should -Be 'profile-default'
                $record.attestedEffort | Should -BeNullOrEmpty
            } finally {
                Set-AiCliDataRootOverride -Path $null
            }
        }
    }
}

Describe 'Secret redaction and eject' {
    It 'redacts custom provider key names while preserving presence metadata' {
        InModuleScope AiCliProfileManager {
            $safe = Protect-AiCliObject @{
                AICLI_OI_PROVIDER_KEY = 'CANARY_CUSTOM_PROVIDER_SECRET'
                secretPresence = '已配置'
                secretConfigured = $true
            }
            $safe.AICLI_OI_PROVIDER_KEY | Should -Be '***REDACTED***'
            $safe.secretPresence | Should -Be '已配置'
            $safe.secretConfigured | Should -BeTrue
        }
    }

    It 'never writes an environment canary into an eject directory' {
        $out = Join-Path $TestDrive 'eject-canary'
        InModuleScope AiCliProfileManager -Parameters @{ Out = $out } {
            Mock Get-AiCliResolvedProfile {
                [ordered]@{ id='fake'; engine='interpreter'; dataDestination='test'; configured=$true }
            }
            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{
                    engine='interpreter'; fileName='C:\fake\interpreter.exe'; argumentList=@('-c','model="x"')
                    workingDirectory='C:\work'; environmentDelta=@{ AICLI_OI_PROVIDER_KEY='CANARY_EJECT_SECRET_123' }
                    removeEnvironment=@(); configFiles=@(); notes=@('test')
                }
            }
            Export-AiCliEject -ProfileId 'fake' -OutputPath $Out | Out-Null
            $allText = (Get-ChildItem -LiteralPath $Out -Recurse -File | Get-Content -Raw) -join "`n"
            $allText | Should -Not -Match 'CANARY_EJECT_SECRET_123'
            $allText | Should -Match 'AICLI_EJECT_SECRET'
        }
    }
}

Describe 'Codex configuration safety' {
    It 'keeps long Profile filenames deterministic and collision resistant' {
        InModuleScope AiCliProfileManager {
            $prefix = 'profile-' + ('a' * 40)
            $first = Get-AiCliSafeProfileFileId -Id ($prefix + '-first')
            $second = Get-AiCliSafeProfileFileId -Id ($prefix + '-second')

            $first | Should -Not -Be $second
            $first | Should -Be (Get-AiCliSafeProfileFileId -Id ($prefix + '-first'))
            $first.Length | Should -BeLessOrEqual 46
        }
    }

    It 'rejects a model ID that attempts TOML injection' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{
                id='bad'; displayName='bad'; endpoint='https://example.com/v1'
                codexProviderId='aicli_bad'
                models=[ordered]@{ primary = "ok`"`n[model_providers.injected]" }
            }
            { New-AiCliCodexProviderToml -MergedProfile $profile } | Should -Throw '*模型 ID*'
        }
    }

    It 'emits every Codex provider override as its own -c argument' {
        InModuleScope AiCliProfileManager {
            $args = [System.Collections.Generic.List[string]]::new()
            $profile = [ordered]@{
                id='qwen-test'; displayName='Qwen Test'; endpoint='https://example.com/v1'
                models=[ordered]@{ primary='model-x' }
            }
            Add-AiCliCodexProviderOverrides -ArgumentList $args -MergedProfile $profile `
                -ProviderId 'aicli_qwen_test' -EnvironmentKey 'AICLI_CODEX_PROVIDER_KEY'

            $args.Count | Should -Be 16
            for ($i = 0; $i -lt $args.Count; $i += 2) {
                $args[$i] | Should -Be '-c'
                $args[$i + 1] | Should -Not -Match '\smodel_provider='
            }
            $args | Should -Contain 'model_provider="aicli_qwen_test"'
            $args | Should -Contain 'model_providers.aicli_qwen_test.wire_api="responses"'
        }
    }
}

Describe 'Installer safety' {
    It 'refuses to overwrite an installed version without Force' {
        $moduleRoot = Join-Path $TestDrive 'Documents\PowerShell\Modules'
        New-Item -ItemType Directory -Force -Path $moduleRoot | Out-Null
        $oldModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = $moduleRoot
            & (Join-Path $script:SecurityRepoRoot 'scripts\Install.ps1') -SourceRoot $script:SecurityRepoRoot -SkipShellIntegration
            $version = [string](Import-PowerShellDataFile -LiteralPath (
                Join-Path $script:SecurityRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1'
            )).ModuleVersion
            $installedManifest = Join-Path $moduleRoot "AiCliProfileManager\$version\AiCliProfileManager.psd1"
            Test-Path -LiteralPath $installedManifest | Should -BeTrue
            $before = (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash

            { & (Join-Path $script:SecurityRepoRoot 'scripts\Install.ps1') -SourceRoot $script:SecurityRepoRoot -SkipShellIntegration } |
                Should -Throw '*默认拒绝覆盖*'
            (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash | Should -Be $before
        } finally {
            $env:PSModulePath = $oldModulePath
        }
    }
}

Describe 'Uninstall safety' {
    It 'clears a stale proxy state whose recorded process no longer exists' {
        InModuleScope AiCliProfileManager {
            Mock Test-Path { $false }
            Mock Get-AiCliProxyState {
                if ($ProxyId -eq 'ccp') { [ordered]@{ pid = 999999; proxyId = 'ccp' } } else { $null }
            }
            Mock Test-AiCliProcessIdentity { [pscustomobject]@{ Match = $false; Reason = 'process-missing' } }
            Mock Get-Process { $null }
            Mock Confirm-AiCliAction { $true }
            Mock Clear-AiCliProxyState {}
            Mock Remove-AiCliShellIntegration {}

            Invoke-AiCliUninstallCommand -Tokens @('--yes') | Should -Be 0
            Should -Invoke Clear-AiCliProxyState -Times 1 -Exactly -ParameterFilter { $ProxyId -eq 'ccp' }
            Should -Invoke Remove-AiCliShellIntegration -Times 1 -Exactly
        }
    }

    It 'refuses an unknown same-name module before confirmation or user-data purge' {
        InModuleScope AiCliProfileManager {
            Mock Test-Path { [string]$LiteralPath -like '*AiCliProfileManager' }
            Mock Test-AiCliManagedModuleDirectory { $false }
            Mock Get-AiCliProxyState { $null }
            Mock Confirm-AiCliAction { $true }
            Mock Remove-Item {}
            Mock Remove-AiCliShellIntegration {}

            { Invoke-AiCliUninstallCommand -Tokens @('--purge-user-data','--yes') } |
                Should -Throw '*身份无法确认*'
            Should -Invoke Confirm-AiCliAction -Times 0 -Exactly
            Should -Invoke Remove-Item -Times 0 -Exactly
            Should -Invoke Remove-AiCliShellIntegration -Times 0 -Exactly
        }
    }
}
