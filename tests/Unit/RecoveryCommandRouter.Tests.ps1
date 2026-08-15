#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Recoverable run command routing' {
    BeforeAll {
        $root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module AiCliProfileManager -All|Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
    }

    It 'routes start through the durable controller and preserves the public run receipt' {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive} {
            Mock Get-AiCliResolvedProfile {[pscustomobject]@{engine='codex'}}
            Mock New-AiCliRecoverableRun {
                [pscustomobject]@{runId=('a'*32);status='pending'}
            }
            Mock Invoke-AiCliRecoverableRun {
                [pscustomobject]@{
                    runId=('a'*32);status='completed';resumeSupported=$false
                    resumeReason='terminal_completed';threadId='11111111-1111-4111-8111-111111111111'
                    sessionId='22222222-2222-4222-8222-222222222222'
                    receipt=[pscustomobject]@{exitCode=0;timedOut=$false;stdout='DONE'}
                }
            }
            $old=[Console]::Out;$writer=[IO.StringWriter]::new()
            try {
                [Console]::SetOut($writer)
                $code=Invoke-AiCliRunCommand -Tokens @(
                    'start','future','--stdin','--json','--project',$Work,
                    '--max-resume-attempts','3'
                ) -StdInText 'TASK'
            } finally {[Console]::SetOut($old)}
            $code|Should -Be 0
            $json=$writer.ToString()|ConvertFrom-Json
            $json.command|Should -BeExactly 'run.start'
            $json.run.recoveryRunId|Should -BeExactly ('a'*32)
            $json.run.stdout|Should -BeExactly 'DONE'
            $json.recovery.threadId|Should -BeExactly '11111111-1111-4111-8111-111111111111'
            Should -Invoke New-AiCliRecoverableRun -Times 1 -Exactly -ParameterFilter {
                $ProfileId -eq 'future' -and $ProjectPath -eq $Work -and
                $TaskText -eq 'TASK' -and $MaxResumeAttempts -eq 3
            }
            Should -Invoke Invoke-AiCliRecoverableRun -Times 1 -Exactly -ParameterFilter {
                $RunId -eq ('a'*32) -and $InitialTaskText -eq 'TASK'
            }
        }
    }

    It 'keeps legacy run profile syntax as the recoverable start alias' {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive} {
            Mock Get-AiCliResolvedProfile {[pscustomobject]@{engine='codex'}}
            Mock New-AiCliRecoverableRun {[pscustomobject]@{runId=('b'*32)}}
            Mock Invoke-AiCliRecoverableRun {
                [pscustomobject]@{runId=('b'*32);status='completed';resumeSupported=$false;resumeReason='terminal_completed';receipt=[pscustomobject]@{exitCode=0;timedOut=$false}}
            }
            $code=Invoke-AiCliRunCommand -Tokens @(
                'future','--stdin','--json','--project',$Work
            ) -StdInText TASK
            $code|Should -Be 0
            Should -Invoke New-AiCliRecoverableRun -Times 1 -Exactly
        }
    }

    It 'routes status resume and abort without requiring task stdin' {
        InModuleScope AiCliProfileManager {
            $id='c'*32
            Mock Get-AiCliRecoverableRunStatus {[pscustomobject]@{runId=$id;status='interrupted';resumeSupported=$true}}
            Mock Invoke-AiCliRecoverableRun {[pscustomobject]@{runId=$id;status='completed';resumeSupported=$false}}
            Mock Stop-AiCliRecoverableRun {[pscustomobject]@{runId=$id;status='abort_requested';resumeSupported=$false}}
            Invoke-AiCliRunCommand -Tokens @('status',$id,'--json')|Should -Be 0
            Invoke-AiCliRunCommand -Tokens @('resume',$id,'--json')|Should -Be 0
            Invoke-AiCliRunCommand -Tokens @('abort',$id,'--json')|Should -Be 0
            Should -Invoke Get-AiCliRecoverableRunStatus -Times 1 -Exactly
            Should -Invoke Invoke-AiCliRecoverableRun -Times 1 -Exactly
            Should -Invoke Stop-AiCliRecoverableRun -Times 1 -Exactly
        }
    }

    It 'returns a run id immediately when a background controller is requested' {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive} {
            Mock Get-AiCliResolvedProfile {[pscustomobject]@{engine='codex'}}
            Mock New-AiCliRecoverableRun {
                [pscustomobject]@{runId=('d'*32);status='pending'}
            }
            Mock Start-AiCliRecoverableControllerProcess {
                [pscustomobject]@{
                    runId=('d'*32);controllerPid=43210;status='running'
                    alreadyRunning=$false
                }
            }
            Mock Invoke-AiCliRecoverableRun {throw 'must not block'}
            $old=[Console]::Out;$writer=[IO.StringWriter]::new()
            try {
                [Console]::SetOut($writer)
                $code=Invoke-AiCliRunCommand -Tokens @(
                    'start','future','--stdin','--json','--background',
                    '--project',$Work
                ) -StdInText TASK
            } finally {[Console]::SetOut($old)}
            $code|Should -Be 0
            $json=$writer.ToString()|ConvertFrom-Json
            $json.command|Should -BeExactly 'run.start'
            $json.recovery.runId|Should -BeExactly ('d'*32)
            $json.recovery.controllerPid|Should -Be 43210
            $json.recovery.status|Should -BeExactly 'running'
            $json.run.background|Should -BeTrue
            Should -Invoke Start-AiCliRecoverableControllerProcess `
                -Times 1 -Exactly -ParameterFilter {
                    $RunId -eq ('d'*32) -and $InitialTaskText -eq 'TASK'
                }
            Should -Invoke Invoke-AiCliRecoverableRun -Times 0 -Exactly
        }
    }
}
