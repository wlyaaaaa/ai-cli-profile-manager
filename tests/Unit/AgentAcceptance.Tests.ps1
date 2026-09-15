#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:AgentAcceptanceRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module AiCliProfileManager -All |
        Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:AgentAcceptanceRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'Codex Agent live acceptance' {
    It 'routes the explicit agent level without changing the existing levels' {
        InModuleScope AiCliProfileManager {
            Mock Invoke-AiCliLiveTest { 0 }

            Invoke-AiCliTestCommand -Tokens @(
                'codex-ollama-qwen3-8-27b', '--live', '--level',
                'agent', '--yes', '--json'
            ) | Should -Be 0

            Should -Invoke Invoke-AiCliLiveTest -Times 1 -Exactly -ParameterFilter {
                $ProfileId -eq 'codex-ollama-qwen3-8-27b' -and
                $Level -eq 'agent' -and $Yes -and $Json
            }
        }
    }

    It 'verifies the deterministic fixture independently of model output text' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $fixture = New-AiCliAgentAcceptanceFixture -WorkDir $Work
            $values = @(12, 5, 12, 3, 8, 3, 5, 8, 13, 2, 13, 7)
            $unique = @($values | Sort-Object -Unique)
            $frequency = [ordered]@{}
            foreach ($value in $values) {
                $key = [string]$value
                $frequency[$key] = [int]$frequency[$key] + 1
            }
            $sum = [int](($unique | Measure-Object -Sum).Sum)
            $canonical = ($unique -join ',') + '|' + $sum
            $checksum = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($canonical)
                )
            ).ToLowerInvariant()
            [ordered]@{
                unique_sorted = $unique
                sum_of_unique = $sum
                frequency = $frequency
                checksum_sha256 = $checksum
            } | ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath $fixture.ResultPath -Encoding utf8

            $verified = Test-AiCliAgentAcceptanceFixture -Fixture $fixture

            $verified.Pass | Should -BeTrue
            $verified.ExitCode | Should -Be 0
            $verified.Sha256 | Should -Match '^sha256:[0-9a-f]{64}$'
        }
    }

    It 'uses the durable exact-resume controller and accepts only bound runtime evidence' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $Work = Join-Path $Work 'durable-agent'
            New-Item -ItemType Directory -Path $Work | Out-Null
            $profile = [ordered]@{
                id = 'codex-ollama-qwen3-8-27b'
                engine = 'codex'
                profileFingerprint = ('a' * 64)
            }
            $plan = [ordered]@{
                model = 'qwen3.8-27b:256k'
                modelProvider = 'aicli_ollama_qwen38_27b'
                effort = 'max'
                effectiveEffort = 'max'
                wire = 'responses'
            }
            Mock New-AiCliRecoverableRun {
                [pscustomobject]@{ runId = '0123456789abcdef0123456789abcdef' }
            }
            Mock Invoke-AiCliRecoverableRun {
                $fixture = Get-Content -LiteralPath (Join-Path $Work 'input.json') -Raw |
                    ConvertFrom-Json -Depth 20
                $values = @($fixture.records | ForEach-Object { @($_.values) })
                $unique = @($values | Sort-Object -Unique)
                $frequency = [ordered]@{}
                foreach ($value in $values) {
                    $key = [string][int]$value
                    $frequency[$key] = [int]$frequency[$key] + 1
                }
                $sum = [int](($unique | Measure-Object -Sum).Sum)
                $canonical = ($unique -join ',') + '|' + $sum
                $checksum = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData(
                        [Text.Encoding]::UTF8.GetBytes($canonical)
                    )
                ).ToLowerInvariant()
                [ordered]@{
                    unique_sorted = $unique
                    sum_of_unique = $sum
                    frequency = $frequency
                    checksum_sha256 = $checksum
                } | ConvertTo-Json -Depth 10 |
                    Set-Content -LiteralPath (Join-Path $Work 'result.json') -Encoding utf8
                [pscustomobject]@{
                    status = 'completed'
                    runId = $RunId
                    resumeCount = 1
                    receipt = [pscustomobject]@{
                        exitCode = 0
                        timedOut = $false
                        errorCode = $null
                        threadId = '01a00000-0000-7000-8000-000000000001'
                        sessionId = '01a00000-0000-7000-8000-000000000001'
                        runtimeIdentity = [ordered]@{
                            model = 'qwen3.8-27b:256k'
                            model_provider = 'aicli_ollama_qwen38_27b'
                            cli_version = '0.147.0'
                            permission = [ordered]@{
                                approval_policy = 'never'
                                requested_policy = 'danger-full-access'
                                sandbox_boundary = 'codex-native'
                                sandbox_type = 'dangerFullAccess'
                                permission_profile = ':danger-full-access'
                            }
                        }
                        usage = [ordered]@{ input_tokens = 100; output_tokens = 20 }
                        limitUsage = [ordered]@{
                            steps = 4
                            toolCalls = 2
                            cleanupConfirmed = $true
                        }
                    }
                }
            }
            $checks = [Collections.Generic.List[object]]::new()

            $result = Invoke-AiCliAgentLiveTest -Plan $plan `
                -MergedProfile $profile -WorkDir $Work -Checks $checks

            $result.Pass | Should -BeTrue
            $result.Receipt.result | Should -Be 'pass'
            $result.Receipt.recovery.run_id |
                Should -Be '0123456789abcdef0123456789abcdef'
            $result.Receipt.recovery.resume_count | Should -Be 1
            $result.Receipt.agent.tool_calls | Should -Be 2
            Should -Invoke New-AiCliRecoverableRun -Times 1 -Exactly -ParameterFilter {
                $ProfileId -eq 'codex-ollama-qwen3-8-27b' -and
                $ProjectPath -eq $Work -and $MaxResumeAttempts -eq 3 -and
                $TimeoutMs -eq 7200000 -and $MaxSteps -eq 200 -and
                $MaxToolCalls -eq 1000
            }
            Should -Invoke Invoke-AiCliRecoverableRun -Times 1 -Exactly -ParameterFilter {
                $RunId -eq '0123456789abcdef0123456789abcdef' -and
                -not [string]::IsNullOrWhiteSpace($InitialTaskText)
            }
        }
    }

    It 'fails closed when the runtime model changes or no real tool activity occurred' {
        InModuleScope AiCliProfileManager {
            $plan = [ordered]@{
                model = 'expected-model'
                modelProvider = 'expected-provider'
                effort = 'max'
                effectiveEffort = 'max'
                wire = 'responses'
            }
            $receipt = New-AiCliAgentAcceptanceReceipt -Plan $plan `
                -Recovery ([ordered]@{ status = 'completed'; runId = ('b' * 32); resumeCount = 0 }) `
                -Run ([ordered]@{
                    exitCode = 0
                    timedOut = $false
                    runtimeIdentity = [ordered]@{
                        model = 'wrong-model'
                        model_provider = 'expected-provider'
                        cli_version = '0.147.0'
                        permission = [ordered]@{
                            approval_policy = 'never'
                            requested_policy = 'danger-full-access'
                            sandbox_boundary = 'codex-native'
                            sandbox_type = 'dangerFullAccess'
                            permission_profile = ':danger-full-access'
                        }
                    }
                    limitUsage = [ordered]@{ toolCalls = 0; cleanupConfirmed = $true }
                }) `
                -Verifier ([ordered]@{ Pass = $true; ExitCode = 0; Method = 'fixture-v1'; Sha256 = ('sha256:' + ('c' * 64)) })

            $receipt.result | Should -Be 'fail'
            $receipt.failure_codes | Should -Contain 'runtime.model_mismatch'
            $receipt.failure_codes | Should -Contain 'agent.tool_activity_missing'
        }
    }

    It 'persists only allowlisted permission evidence and requires a closed agent receipt' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliProfileCliIdentityEvidence {
                [pscustomobject]@{
                    FileName = 'C:\codex.exe'
                    Version = 'codex-cli 0.147.0'
                }
            }
            $plan = [ordered]@{
                model = 'expected-model'
                modelProvider = 'expected-provider'
                effort = 'max'
                effectiveEffort = 'max'
                wire = 'responses'
            }
            $receipt = New-AiCliAgentAcceptanceReceipt -Plan $plan `
                -Recovery ([ordered]@{
                    status = 'completed'; runId = ('d' * 32); resumeCount = 0
                }) `
                -Run ([ordered]@{
                    exitCode = 0
                    timedOut = $false
                    stdout = 'CANARY_SECRET_OUTPUT'
                    runtimeIdentity = [ordered]@{
                        model = 'expected-model'
                        model_provider = 'expected-provider'
                        cli_version = '0.147.0'
                        permission = [ordered]@{
                            approval_policy = 'never'
                            requested_policy = 'danger-full-access'
                            sandbox_boundary = 'codex-native'
                            sandbox_type = 'dangerFullAccess'
                            permission_profile = ':danger-full-access'
                            unexpected_secret = 'CANARY_PERMISSION_SECRET'
                        }
                    }
                    limitUsage = [ordered]@{
                        toolCalls = 1; steps = 2; cleanupConfirmed = $true
                    }
                }) `
                -Verifier ([ordered]@{
                    Pass = $true; ExitCode = 0; Method = 'fixture-v1'
                    Sha256 = ('sha256:' + ('e' * 64))
                })
            $json = $receipt | ConvertTo-Json -Depth 30 -Compress
            $json | Should -Not -Match 'CANARY_SECRET_OUTPUT'
            $json | Should -Not -Match 'CANARY_PERMISSION_SECRET'

            $record = [ordered]@{
                productVersion = (Get-AiCliVersion)
                level = 'agent'
                result = 'pass'
                agentPass = $true
                agentReceipt = $receipt
                model = 'expected-model'
                modelProvider = 'expected-provider'
                cliPath = 'C:\codex.exe'
                cliVersion = 'codex-cli 0.147.0'
                permissionEvidence = 'runtime-identity'
                runtimePermission = $receipt.effective.permission
            }
            $profile = [ordered]@{ engine = 'codex' }
            (Test-AiCliVerificationRecordCurrent -Record $record `
                -MergedProfile $profile).Current | Should -BeTrue

            $record.agentReceipt = $null
            (Test-AiCliVerificationRecordCurrent -Record $record `
                -MergedProfile $profile).Current | Should -BeFalse
        }
    }
}
