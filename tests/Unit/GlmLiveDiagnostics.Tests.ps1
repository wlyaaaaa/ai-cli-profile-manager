BeforeAll {
    Remove-Module AiCliProfileManager -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot '../../src/AiCliProfileManager/AiCliProfileManager.psd1') -Force
}

Describe 'GLM live failure diagnostics' {
    It 'allows a slow CLI version probe and caches only successful evidence' {
        InModuleScope AiCliProfileManager {
            $script:AiCliVersionEvidenceCache = @{}
            Mock Invoke-AiCliChildCapture {
                if ($TimeoutMs -lt 35000) { return @{ ExitCode=4; StdOut=''; StdErr='timeout' } }
                @{ ExitCode=0; StdOut='codex-cli 0.167.0'; StdErr='' }
            }
            $resolved = @{ FileName='C:\fixture\node.exe'; PrefixArgs=@('codex.js'); Kind='npm-node' }
            (Get-AiCliResolvedCliVersionEvidence -Resolved $resolved).Version | Should -Be 'codex-cli 0.167.0'
            (Get-AiCliResolvedCliVersionEvidence -Resolved $resolved).Version | Should -Be 'codex-cli 0.167.0'
            Should -Invoke Invoke-AiCliChildCapture -Times 1 -Exactly
            $plan = @{ engine='codex'; fileName='C:\fixture\codex.exe'; argumentList=@() }
            Get-AiCliPlanVersionEvidence -Plan $plan | Should -Be 'codex-cli 0.167.0'
        }
    }

    It 'reports a failed probe as unknown rather than an unsupported CLI version' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliResolvedCliVersionEvidence { $null }
            $profile = @{ compatibility=@{ minCliVersion='0.154.0' } }
            { Assert-AiCliProfileMinimumCliVersion -MergedProfile $profile -Resolved @{FileName='codex.exe'} } |
                Should -Throw '*无法取得 CLI 版本*尚不能判断*'
        }
    }

    It 'persists the public quota failure and observed CLI version without provider details' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            Mock Get-AiCliResolvedProfile {
                @{ id='codex-glm-5-3'; engine='codex'; provider='glm'; models=@{primary='glm-5.3'} }
            }
            Mock Build-AiCliLaunchPlan {
                @{ engine='codex'; fileName='codex.exe'; model='glm-5.3'; modelProvider='aicli_glm_5_3'
                   argumentList=@(); environmentDelta=@{}; removeEnvironment=@() }
            }
            Mock Invoke-AiCliProfileCapture {
                @{ exitCode=1; outputTruncated=$false; stdout=''; stderr='provider-private-detail'
                   errorCode='codex_appserver.provider_quota_pause'; limitUsage=@{toolCalls=0}
                   runtimeCliPath='C:\fixture\codex.exe'
                   runtimeIdentity=@{model='glm-5.3'; model_provider='aicli_glm_5_3'; cli_version='0.167.0'} }
            }
            Mock Set-AiCliVerificationRecord { $script:savedLiveRecord=$Record }
            Mock Get-AiCliProfileFingerprint { 'fixture-fingerprint' }
            Mock Get-AiCliPlanVersionEvidence { throw 'verified runtime version must be reused' }
            Mock Write-AiCliLog {}
            Mock Write-AiCliJson { $script:liveOutput=$Object }
            $code = Invoke-AiCliLiveTest -ProfileId 'codex-glm-5-3' -Level text -Yes -Json
            $code | Should -Be (Get-AiCliExitCode Unavailable)
            $script:savedLiveRecord.result | Should -Be 'fail'
            $script:savedLiveRecord.failureSummary | Should -Be '用量已满'
            $script:savedLiveRecord.cliVersion | Should -Be '0.167.0'
            $script:liveOutput.checks[0].summary | Should -Be '用量已满'
            ($script:savedLiveRecord | ConvertTo-Json -Depth 10) | Should -Not -Match 'provider-private-detail'
        }
    }
}
