#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Cancellation before runtime attestation' {
    BeforeAll {
        $root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
    }
    It 'keeps cleanup and identity separate for <Case>' -TestCases @(
        @{Case='valid_cancel'; Throws=$false; Cleanup=$true},
        @{Case='cleanup_unknown'; Throws=$false; Cleanup=$false},
        @{Case='missing_signal'; Throws=$true; Cleanup=$true},
        @{Case='fake_flag'; Throws=$true; Cleanup=$true},
        @{Case='success_without_identity'; Throws=$true; Cleanup=$true},
        @{Case='mismatching_identity'; Throws=$true; Cleanup=$true}
    ) {
        param($Case,$Throws,$Cleanup)
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive;Case=$Case;Throws=$Throws;Cleanup=$Cleanup} {
            $signal=Join-Path $Work ($Case+'.abort.requested')
            if($Case -ne 'missing_signal'){[IO.File]::WriteAllBytes($signal,[byte[]]::new(0))}
            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{engine='codex';fileName='C:\fixture\codex.exe';workingDirectory=$Work;argumentList=@();model='fixture-model';modelProvider='fixture-provider';profileFingerprint=('a'*64);effort='max';effectiveEffort='max';environmentDelta=@{};removeEnvironment=@()}
            }
            Mock Initialize-AiCliMachineRuntime {
                [pscustomobject]@{FileName='C:\fixture\codex.exe';ArgumentList=@('bridge');WorkingDirectory=$Work;EnvironmentDelta=@{};StdInText='PUBLIC_FIXTURE';UseOuterSandbox=$false;EventProtocol='codex-app-server';RuntimePath=$Work;AdditionalReadRoots=@();PrivateTaskPipeName=$null}
            }
            Mock Remove-AiCliMachineRuntime {[pscustomobject]@{Removed=$true}}
            Mock Invoke-AiCliChildCapture {
                $flag=if($Case -eq 'fake_flag'){'true'}else{$true}
                $identity=if($Case -eq 'mismatching_identity'){@{model='OTHER_MODEL';model_provider='fixture-provider'}}else{$null}
                [pscustomobject]@{ExitCode=$(if($Case -eq 'success_without_identity'){0}else{6});StdOut='';StdErr='';TimedOut=$false;DurationMs=1;OutputTruncated=$false;LimitsHard=$true;CleanupConfirmed=$Cleanup;CleanupMethod='dotnet-kill-tree';Usage=@{};RuntimeIdentity=$identity;AbortRequested=$flag}
            }
            $ctx=@{runId=('b'*32);mode='start';workspace=$Work;workspaceHash=('c'*64);profileFingerprint=('a'*64);model='fixture-model';modelProvider='fixture-provider';requestedEffort='max';effectiveEffort='max';abortSignalPath=$signal;eventSequenceBase=0}
            if($Throws) {
                {Invoke-AiCliProfileCapture -ProfileId fixture -ProjectPath $Work -StdInText 'PUBLIC_FIXTURE' -RecoveryContext $ctx}|Should -Throw '*runtime identity*'
            } else {
                $result=Invoke-AiCliProfileCapture -ProfileId fixture -ProjectPath $Work -StdInText 'PUBLIC_FIXTURE' -RecoveryContext $ctx
                $result.exitCode|Should -Be 6
                $result.abortRequested|Should -BeTrue
                $result.model|Should -BeNullOrEmpty
                $result.modelProvider|Should -BeNullOrEmpty
                $result.runtimeIdentity|Should -BeNullOrEmpty
                $result.requestedModel|Should -BeExactly 'fixture-model'
                $result.modelIdentityEvidence|Should -BeExactly 'not_observed_cancelled'
                $result.limitUsage.cleanupConfirmed|Should -Be $Cleanup
            }
        }
    }
}
