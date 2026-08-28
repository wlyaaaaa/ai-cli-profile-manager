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

    It 'treats the app-server bare version and CLI-prefixed version as the same runtime' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliProfileCliIdentityEvidence {
                [pscustomobject]@{
                    FileName = 'C:\codex.exe'
                    Version = 'codex-cli 0.147.0'
                    Kind = 'npm-native'
                }
            }
            $permission = [ordered]@{
                approval_policy = 'never'
                requested_policy = 'danger-full-access'
                sandbox_boundary = 'codex-native'
                sandbox_type = 'dangerFullAccess'
                permission_profile = ':danger-full-access'
            }
            $record = [ordered]@{
                productVersion = (Get-AiCliVersion)
                level = 'tool'
                permissionEvidence = 'runtime-identity'
                runtimePermission = $permission
                cliPath = 'C:\codex.exe'
                cliVersion = '0.147.0'
            }
            $profile = [ordered]@{ engine = 'codex' }

            $current = Test-AiCliVerificationRecordCurrent `
                -Record $record -MergedProfile $profile

            $current.Current | Should -BeTrue
            $current.Reason | Should -BeExactly '当前'
        }
    }

    It 'keeps distinct CLI prerelease versions stale' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliProfileCliIdentityEvidence {
                [pscustomobject]@{
                    FileName = 'C:\codex.exe'
                    Version = 'codex-cli 0.148.0-alpha.9'
                    Kind = 'npm-native'
                }
            }
            $record = [ordered]@{
                productVersion = (Get-AiCliVersion)
                level = 'tool'
                permissionEvidence = 'runtime-identity'
                runtimePermission = [ordered]@{
                    approval_policy = 'never'
                    requested_policy = 'danger-full-access'
                    sandbox_boundary = 'codex-native'
                    sandbox_type = 'dangerFullAccess'
                    permission_profile = ':danger-full-access'
                }
                cliPath = 'C:\codex.exe'
                cliVersion = '0.148.0-alpha.8'
            }

            $current = Test-AiCliVerificationRecordCurrent `
                -Record $record -MergedProfile ([ordered]@{ engine = 'codex' })

            $current.Current | Should -BeFalse
            $current.Reason | Should -BeExactly '目标 CLI 版本已变化'
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

    It 'uses --version when a Live plan omits versionArgumentList' {
        InModuleScope AiCliProfileManager {
            Mock Invoke-AiCliChildCapture {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = "codex-cli 0.147.0`n"
                    StdErr = ''
                }
            }
            $plan = [pscustomobject]@{
                engine = 'codex'
                fileName = 'C:\fake\codex.exe'
                argumentList = @()
            }

            Get-AiCliPlanVersionEvidence -Plan $plan |
                Should -BeExactly 'codex-cli 0.147.0'
            Should -Invoke Invoke-AiCliChildCapture -Times 1 -Exactly `
                -ParameterFilter {
                    $FileName -ceq 'C:\fake\codex.exe' -and
                    @($ArgumentList).Count -eq 1 -and
                    [string]$ArgumentList[0] -ceq '--version'
                }
        }
    }

    It 'requires the final non-empty body line to equal PONG' {
        InModuleScope AiCliProfileManager {
            Test-AiCliExactPongOutput -Text "noise`nPONG`n" | Should -BeTrue
            Test-AiCliExactPongOutput -Text 'Reply with exactly: PONG' | Should -BeFalse
            Test-AiCliExactPongOutput -Text "PONG`nrequest failed" | Should -BeFalse
        }
    }

    It 'extracts exact PONG only from the final safe Codex agent-message event' {
        InModuleScope AiCliProfileManager {
            $valid = @(
                '{"type":"thread.started","thread_id":"019ffccf-e3e4-7133-ac71-20499a14f2a7"}'
                '{"type":"item.completed","item":{"type":"agent_message","text":"PONG"}}'
            ) -join "`n"
            Test-AiCliExactPongOutput -Text (
                Get-AiCliCodexFinalAgentMessageText -JsonLines $valid
            ) | Should -BeTrue

            Get-AiCliCodexFinalAgentMessageText -JsonLines "PONG`n" |
                Should -BeNullOrEmpty
            $notFinal = @(
                '{"type":"item.completed","item":{"type":"agent_message","text":"PONG"}}'
                '{"type":"thread.started","thread_id":"019ffccf-e3e4-7133-ac71-20499a14f2a7"}'
            ) -join "`n"
            Get-AiCliCodexFinalAgentMessageText -JsonLines $notFinal |
                Should -BeNullOrEmpty
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
            $script:capturedEnvironmentDelta = @{}
            $script:capturedRemoveEnvironment = @()
            Mock Invoke-AiCliChildCapture {
                $script:capturedSecretValues = @($SecretValues)
                $script:capturedEnvironmentDelta = @{}
                foreach ($key in $EnvironmentDelta.Keys) {
                    $script:capturedEnvironmentDelta[$key] = $EnvironmentDelta[$key]
                }
                $script:capturedRemoveEnvironment = @($RemoveEnvironment)
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
                engine = 'interpreter'; fileName = 'C:\fake\interpreter.exe'
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
            $script:capturedEnvironmentDelta.INTERPRETER_HOME | Should -Be (Join-Path $Work 'interpreter-home')
            $script:capturedEnvironmentDelta.CODEX_HOME | Should -Be (Join-Path $Work 'interpreter-home')
            $script:capturedRemoveEnvironment | Should -Contain 'INTERPRETER_HOME'
            $script:capturedRemoveEnvironment | Should -Contain 'CODEX_HOME'
        }
    }

    It 'overrides polluted parent OI and Codex homes after ChildCapture removals' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $oldInterpreterHome = [Environment]::GetEnvironmentVariable('INTERPRETER_HOME', 'Process')
            $oldCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
            try {
                [Environment]::SetEnvironmentVariable('INTERPRETER_HOME', (Join-Path $Work 'parent-interpreter'), 'Process')
                [Environment]::SetEnvironmentVariable('CODEX_HOME', (Join-Path $Work 'parent-codex'), 'Process')
                $delta = @{}
                $isolatedInterpreterHome = Set-AiCliIsolatedInterpreterHome -Environment $delta -Root $Work
                $remove = @('INTERPRETER_HOME','CODEX_HOME')

                $interpreter = Invoke-AiCliChildCapture -FileName $env:ComSpec `
                    -ArgumentList @('/d','/c','set INTERPRETER_HOME') `
                    -EnvironmentDelta $delta -RemoveEnvironment $remove `
                    -WorkingDirectory $Work -TimeoutMs 10000 -CloseStdIn
                $codex = Invoke-AiCliChildCapture -FileName $env:ComSpec `
                    -ArgumentList @('/d','/c','set CODEX_HOME') `
                    -EnvironmentDelta $delta -RemoveEnvironment $remove `
                    -WorkingDirectory $Work -TimeoutMs 10000 -CloseStdIn

                $interpreter.ExitCode | Should -Be 0
                $codex.ExitCode | Should -Be 0
                $interpreter.StdOut.Trim() | Should -Be "INTERPRETER_HOME=$isolatedInterpreterHome"
                $codex.StdOut.Trim() | Should -Be "CODEX_HOME=$isolatedInterpreterHome"
            } finally {
                [Environment]::SetEnvironmentVariable('INTERPRETER_HOME', $oldInterpreterHome, 'Process')
                [Environment]::SetEnvironmentVariable('CODEX_HOME', $oldCodexHome, 'Process')
            }
        }
    }

    It 'uses the Codex app-server harness and verified runtime identity for DeepSeek live text acceptance' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:harnessCall = $null
            Mock Invoke-AiCliProfileCapture {
                $script:harnessCall = [pscustomobject]@{
                    ProfileId = $ProfileId
                    ProjectPath = $ProjectPath
                    StdInText = $StdInText
                    SandboxPolicy = $SandboxPolicy
                    NativeArgs = @($NativeArgs)
                    MaxToolCalls = $MaxToolCalls
                    EnforceToolCallLimit = [bool]$EnforceToolCallLimit
                }
                [pscustomobject]@{
                    exitCode = 0
                    outputTruncated = $false
                    stdout = @(
                        '{"type":"thread.started","thread_id":"019ffccf-e3e4-7133-ac71-20499a14f2a7"}'
                        '{"type":"item.completed","item":{"type":"agent_message","text":"PONG"}}'
                    ) -join "`n"
                    StdErr = ''
                    limitUsage = [ordered]@{ toolCalls = 0 }
                    runtimeCliPath = 'C:\fake\codex.exe'
                    runtimeIdentity = [ordered]@{
                        model = 'deepseek-v4-flash'
                        model_provider = 'aicli_deepseek'
                        cli_version = '0.147.0'
                        permission = [ordered]@{
                            approval_policy = 'never'; requested_policy = 'danger-full-access'
                            sandbox_boundary = 'codex-native'; sandbox_type = 'dangerFullAccess'
                            permission_profile = ':danger-full-access'
                        }
                    }
                }
            }
            Mock Invoke-AiCliChildCapture { throw 'legacy exec live path must not run' }
            $checks = [System.Collections.Generic.List[object]]::new()
            $plan = [pscustomobject]@{
                engine = 'codex'; fileName = 'C:\fake\codex.exe'
                argumentList = @(); removeEnvironment = @()
                environmentDelta = @{ AICLI_CODEX_PROVIDER_KEY = 'CANARY' }
                model = 'deepseek-v4-flash'; modelProvider = 'aicli_deepseek'
            }

            $result = Invoke-AiCliTextLiveTest -ProfileId 'codex-deepseek' `
                -Plan $plan -WorkDir $Work -Checks $checks

            $result.Pass | Should -BeTrue
            $result.ExitCode | Should -Be 0
            $result.RuntimeIdentity.model | Should -BeExactly 'deepseek-v4-flash'
            $result.RuntimeIdentity.model_provider | Should -BeExactly 'aicli_deepseek'
            $script:harnessCall.ProfileId | Should -BeExactly 'codex-deepseek'
            $script:harnessCall.ProjectPath | Should -BeExactly $Work
            $script:harnessCall.StdInText | Should -BeExactly (Get-AiCliPongLivePrompt)
            $script:harnessCall.SandboxPolicy | Should -BeExactly 'danger-full-access'
            $script:harnessCall.NativeArgs | Should -Be @('exec', '--json', '-')
            $script:harnessCall.MaxToolCalls | Should -Be 0
            $script:harnessCall.EnforceToolCallLimit | Should -BeTrue
            Should -Invoke Invoke-AiCliProfileCapture -Times 1 -Exactly -Scope It
            Should -Invoke Invoke-AiCliChildCapture -Times 0 -Exactly -Scope It
        }
    }

    It 'uses the same full-access harness for a future non-DeepSeek Codex Profile' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:futureHarness = $null
            Mock Invoke-AiCliProfileCapture {
                $script:futureHarness = [pscustomobject]@{
                    ProfileId = $ProfileId
                    NativeArgs = @($NativeArgs)
                    SandboxPolicy = $SandboxPolicy
                    MaxToolCalls = $MaxToolCalls
                    EnforceToolCallLimit = [bool]$EnforceToolCallLimit
                }
                [pscustomobject]@{
                    exitCode = 0
                    outputTruncated = $false
                    stdout = @(
                        '{"type":"thread.started","thread_id":"019ffccf-e3e4-7133-ac71-20499a14f2a7"}'
                        '{"type":"item.completed","item":{"type":"agent_message","text":"PONG"}}'
                    ) -join "`n"
                    limitUsage = [ordered]@{ toolCalls = 0 }
                    runtimeCliPath = 'C:\fake\codex.exe'
                    runtimeIdentity = [ordered]@{
                        model = 'future-codex-model'
                        model_provider = 'future_provider'
                        cli_version = '0.147.0'
                        permission = [ordered]@{
                            approval_policy = 'never'; requested_policy = 'danger-full-access'
                            sandbox_boundary = 'codex-native'; sandbox_type = 'dangerFullAccess'
                            permission_profile = ':danger-full-access'
                        }
                    }
                }
            }
            Mock Invoke-AiCliChildCapture { throw 'direct Codex live path must never run' }
            $checks = [System.Collections.Generic.List[object]]::new()
            $plan = [pscustomobject]@{
                engine = 'codex'; fileName = 'C:\fake\codex.exe'
                argumentList = @(); removeEnvironment = @(); environmentDelta = @{}
                model = 'future-codex-model'; modelProvider = 'future_provider'
            }

            $result = Invoke-AiCliTextLiveTest -ProfileId 'future-codex-profile' `
                -Plan $plan -WorkDir $Work -Checks $checks

            $result.Pass | Should -BeTrue
            $script:futureHarness.NativeArgs | Should -Be @('exec', '--json', '-')
            $script:futureHarness.SandboxPolicy | Should -BeExactly 'danger-full-access'
            $script:futureHarness.MaxToolCalls | Should -Be 0
            $script:futureHarness.EnforceToolCallLimit | Should -BeTrue
            Should -Invoke Invoke-AiCliProfileCapture -Times 1 -Exactly -Scope It
            Should -Invoke Invoke-AiCliChildCapture -Times 0 -Exactly -Scope It
        }
    }

    It 'does not pass a Codex text acceptance after any tool call' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Invoke-AiCliProfileCapture {
                [pscustomobject]@{
                    exitCode = 0
                    outputTruncated = $false
                    stdout = @(
                        '{"type":"thread.started","thread_id":"019ffccf-e3e4-7133-ac71-20499a14f2a7"}'
                        '{"type":"item.completed","item":{"type":"agent_message","text":"PONG"}}'
                    ) -join "`n"
                    limitUsage = [ordered]@{ toolCalls = 1 }
                    runtimeIdentity = [ordered]@{
                        model = 'future-codex-model'; model_provider = 'future_provider'
                        cli_version = '0.147.0'
                        permission = [ordered]@{
                            approval_policy = 'never'; requested_policy = 'danger-full-access'
                            sandbox_boundary = 'codex-native'; sandbox_type = 'dangerFullAccess'
                            permission_profile = ':danger-full-access'
                        }
                    }
                }
            }
            $checks = [Collections.Generic.List[object]]::new()
            $plan = [pscustomobject]@{
                engine = 'codex'; fileName = 'C:\fake\codex.exe'; argumentList = @()
                removeEnvironment = @(); environmentDelta = @{}
                model = 'future-codex-model'; modelProvider = 'future_provider'
            }
            $result = Invoke-AiCliTextLiveTest -ProfileId 'future-codex-profile' `
                -Plan $plan -WorkDir $Work -Checks $checks
            $result.Pass | Should -BeFalse
        }
    }

    It 'rejects non-exact or truncated Codex final agent text' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Invoke-AiCliProfileCapture {
                $finalEvent = [ordered]@{
                    type = 'item.completed'
                    item = [ordered]@{
                        type = 'agent_message'
                        text = $script:codexFinalText
                    }
                } | ConvertTo-Json -Compress -Depth 10
                [pscustomobject]@{
                    exitCode = 0
                    outputTruncated = $script:codexOutputTruncated
                    stdout = @(
                        '{"type":"thread.started","thread_id":"019ffccf-e3e4-7133-ac71-20499a14f2a7"}'
                        $finalEvent
                    ) -join "`n"
                    limitUsage = [ordered]@{ toolCalls = 0 }
                    runtimeIdentity = [ordered]@{
                        model = 'future-codex-model'; model_provider = 'future_provider'
                        cli_version = '0.147.0'
                        permission = [ordered]@{
                            approval_policy = 'never'; requested_policy = 'danger-full-access'
                            sandbox_boundary = 'codex-native'; sandbox_type = 'dangerFullAccess'
                            permission_profile = ':danger-full-access'
                        }
                    }
                }
            }
            $plan = [pscustomobject]@{
                engine = 'codex'; fileName = 'C:\fake\codex.exe'; argumentList = @()
                removeEnvironment = @(); environmentDelta = @{}
                model = 'future-codex-model'; modelProvider = 'future_provider'
            }
            $cases = @(
                [ordered]@{ Text = "explanation`nPONG"; Truncated = $false }
                [ordered]@{ Text = ' PONG'; Truncated = $false }
                [ordered]@{ Text = "PONG`n"; Truncated = $false }
                [ordered]@{ Text = 'PONG'; Truncated = $true }
            )
            foreach ($case in $cases) {
                $script:codexFinalText = [string]$case.Text
                $script:codexOutputTruncated = [bool]$case.Truncated
                $checks = [Collections.Generic.List[object]]::new()
                $result = Invoke-AiCliTextLiveTest -ProfileId 'future-codex-profile' `
                    -Plan $plan -WorkDir $Work -Checks $checks
                $result.Pass | Should -BeFalse
            }
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

    It 'invalidates Codex text receipts without exact zero-tool evidence' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliProfileCliIdentityEvidence {
                [pscustomobject]@{
                    FileName = 'C:\codex.exe'
                    Version = 'codex-cli 0.147.0'
                }
            }
            $profile = [ordered]@{ engine = 'codex' }
            $base = [ordered]@{
                productVersion = (Get-AiCliVersion)
                level = 'text'
                textPass = $true
                cliPath = 'C:\codex.exe'
                cliVersion = 'codex-cli 0.147.0'
                permissionEvidence = 'runtime-identity'
                runtimePermission = [ordered]@{
                    approval_policy = 'never'
                    requested_policy = 'danger-full-access'
                    sandbox_boundary = 'codex-native'
                    sandbox_type = 'dangerFullAccess'
                    permission_profile = ':danger-full-access'
                }
            }
            foreach ($value in @($null, 1, '0')) {
                $record = [ordered]@{}
                foreach ($key in $base.Keys) { $record[$key] = $base[$key] }
                if ($null -ne $value) { $record['observedToolCalls'] = $value }
                (Test-AiCliVerificationRecordCurrent `
                    -Record $record -MergedProfile $profile).Current |
                    Should -BeFalse
            }
            $base['observedToolCalls'] = 0
            (Test-AiCliVerificationRecordCurrent `
                -Record $base -MergedProfile $profile).Current |
                Should -BeTrue
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
            & (Join-Path $script:SecurityRepoRoot 'scripts\Install.ps1') `
                -SourceRoot $script:SecurityRepoRoot -SkipShellIntegration `
                -RetirementRootOverride (Join-Path $TestDrive 'retirement-root')
            $version = [string](Import-PowerShellDataFile -LiteralPath (
                Join-Path $script:SecurityRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1'
            )).ModuleVersion
            $installedManifest = Join-Path $moduleRoot "AiCliProfileManager\$version\AiCliProfileManager.psd1"
            Test-Path -LiteralPath $installedManifest | Should -BeTrue
            $before = (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash

            { & (Join-Path $script:SecurityRepoRoot 'scripts\Install.ps1') `
                    -SourceRoot $script:SecurityRepoRoot -SkipShellIntegration `
                    -RetirementRootOverride (Join-Path $TestDrive 'retirement-root') } |
                Should -Throw '*默认拒绝覆盖*'
            (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash | Should -Be $before
        } finally {
            $env:PSModulePath = $oldModulePath
        }
    }

    It 'keeps the old module whole when an atomic same-parent backup move is locked' {
        $moduleRoot = Join-Path $TestDrive 'locked-install\Documents\PowerShell\Modules'
        $retirementRoot = Join-Path $TestDrive 'locked-install\retirement-root'
        New-Item -ItemType Directory -Force -Path $moduleRoot | Out-Null
        $installScript = Join-Path $script:SecurityRepoRoot 'scripts\Install.ps1'
        $version = [string](Import-PowerShellDataFile -LiteralPath (
            Join-Path $script:SecurityRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1'
        )).ModuleVersion
        $installed = Join-Path $moduleRoot "AiCliProfileManager\$version"
        $lockPath = Join-Path $installed 'AiCliProfileManager.psd1'
        $readyPath = Join-Path $TestDrive 'locked-install-ready.txt'
        $holderScript = Join-Path $TestDrive 'hold-install-file.ps1'
        @'
param([string]$LockPath, [string]$ReadyPath)
$stream = [IO.File]::Open($LockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
[IO.File]::WriteAllText($ReadyPath, 'ready')
Start-Sleep -Milliseconds 3500
$stream.Dispose()
'@ | Set-Content -LiteralPath $holderScript -Encoding utf8
        function Get-TestInstallInventory {
            param([Parameter(Mandatory)][string]$Root)
            return @(
                Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
                    Sort-Object FullName |
                    ForEach-Object {
                        $relative = $_.FullName.Substring($Root.Length).TrimStart('\')
                        "${relative}:$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
                    }
            )
        }

        $oldModulePath = $env:PSModulePath
        $holder = $null
        try {
            $env:PSModulePath = $moduleRoot
            & $installScript -SourceRoot $script:SecurityRepoRoot -SkipShellIntegration `
                -RetirementRootOverride $retirementRoot
            $before = Get-TestInstallInventory -Root $installed

            $psi = [Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = Join-Path $PSHOME 'pwsh.exe'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            foreach ($argument in @('-NoProfile','-File',$holderScript,'-LockPath',$lockPath,'-ReadyPath',$readyPath)) {
                [void]$psi.ArgumentList.Add($argument)
            }
            $holder = [Diagnostics.Process]::Start($psi)
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and $deadline.ElapsedMilliseconds -lt 3000) {
                Start-Sleep -Milliseconds 25
            }
            Test-Path -LiteralPath $readyPath -PathType Leaf | Should -BeTrue

            { & $installScript -SourceRoot $script:SecurityRepoRoot -Force -SkipShellIntegration `
                    -RetirementRootOverride $retirementRoot } | Should -Throw
            Test-Path -LiteralPath $installed -PathType Container | Should -BeTrue
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $installed) -Directory -Force |
                Where-Object Name -Like ".$version.backup-*").Count | Should -Be 0

            $holder.WaitForExit()
            Get-TestInstallInventory -Root $installed | Should -Be $before

            & $installScript -SourceRoot $script:SecurityRepoRoot -Force -SkipShellIntegration `
                -RetirementRootOverride $retirementRoot
            Test-Path -LiteralPath (Join-Path $installed 'AiCliProfileManager.psd1') -PathType Leaf | Should -BeTrue
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $installed) -Directory -Force |
                Where-Object Name -Like ".$version.backup-*").Count | Should -Be 0
        } finally {
            if ($holder) { $holder.Dispose() }
            $env:PSModulePath = $oldModulePath
        }
    }
}

Describe 'Build output safety' {
    It 'refuses a stale stage reparse point without touching its external target' {
        $outDir = Join-Path $TestDrive 'build-output'
        $outside = Join-Path $TestDrive 'outside-stage-target'
        New-Item -ItemType Directory -Force -Path $outDir, $outside | Out-Null
        $canary = Join-Path $outside 'keep.txt'
        Set-Content -LiteralPath $canary -Value 'keep' -Encoding utf8
        $junction = Join-Path $outDir 'stage-aicli-0.3.4'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null

        $output = & pwsh -NoLogo -NoProfile -File (
            Join-Path $script:SecurityRepoRoot 'scripts\Build.ps1'
        ) -OutDir $outDir 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Not -Be 0 -Because ($output -join "`n")
        Test-Path -LiteralPath $junction | Should -BeTrue
        Test-Path -LiteralPath $canary -PathType Leaf | Should -BeTrue
    }

    It 'refuses an output ancestor junction without touching its external target' {
        $outside = Join-Path $TestDrive 'outside-build-ancestor'
        $link = Join-Path $TestDrive 'build-output-link'
        $outDir = Join-Path $link 'newdist'
        $stale = Join-Path $outside 'newdist\stage-aicli-0.3.4'
        New-Item -ItemType Directory -Force -Path $stale | Out-Null
        $canary = Join-Path $stale 'keep.txt'
        Set-Content -LiteralPath $canary -Value 'keep' -Encoding utf8
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null

        $output = & pwsh -NoLogo -NoProfile -File (
            Join-Path $script:SecurityRepoRoot 'scripts\Build.ps1'
        ) -OutDir $outDir 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Not -Be 0 -Because ($output -join "`n")
        Test-Path -LiteralPath $link | Should -BeTrue
        (Get-Content -LiteralPath $canary -Raw).Trim() | Should -BeExactly 'keep'
        @(Get-ChildItem -LiteralPath (Join-Path $outside 'newdist') -Force).Count |
            Should -Be 1
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
