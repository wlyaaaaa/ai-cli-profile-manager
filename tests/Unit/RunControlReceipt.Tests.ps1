#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Immutable run control receipts' {
    BeforeAll {
        $root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
    }
    It 'publishes only the owning run identity, once' {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive} {
            Mock Get-AiCliRecoverableRunState {
                [pscustomobject]@{runId=('a'*32);sessionMeta=@{profileId='fixture';model='fixture-model';workspace=$Work};taskText='PRIVATE_TEST_SENTINEL'}
            }
            $path=Join-Path $Work 'control.json'
            Publish-AiCliRunControlReceipt -Path $path -RunId ('a'*32)
            $text=Get-Content -LiteralPath $path -Raw
            $data=$text|ConvertFrom-Json
            $data.schema|Should -BeExactly 'aicli.run-control.v1'
            $data.run_id|Should -BeExactly ('a'*32)
            $data.profile_id|Should -BeExactly 'fixture'
            $data.model|Should -BeExactly 'fixture-model'
            $text|Should -Not -Match 'PRIVATE_TEST_SENTINEL'
            {Publish-AiCliRunControlReceipt -Path $path -RunId ('a'*32)}|Should -Throw '*already exists*'
            (Get-Content -LiteralPath $path -Raw)|Should -BeExactly $text
            @(Get-ChildItem -LiteralPath $Work -Filter '*.tmp').Count|Should -Be 0
        }
    }
    It 'does not create directories and rejects relative receipt paths' {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive} {
            Mock Get-AiCliRecoverableRunState {throw 'No state should be read'}
            {Publish-AiCliRunControlReceipt -Path 'relative.json' -RunId ('a'*32)}|Should -Throw '*absolute*'
            {Publish-AiCliRunControlReceipt -Path (Join-Path $Work 'absent\control.json') -RunId ('a'*32)}|Should -Throw '*parent must exist*'
            Test-Path (Join-Path $Work 'absent')|Should -BeFalse
            Should -Invoke Get-AiCliRecoverableRunState -Times 0
        }
    }
    It 'publishes the control handle before executing the native run' {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive} {
            Mock Get-AiCliResolvedProfile {[pscustomobject]@{engine='codex'}}
            Mock New-AiCliRecoverableRun {[pscustomobject]@{runId=('b'*32);status='pending'}}
            Mock Publish-AiCliRunControlReceipt {[IO.File]::WriteAllText($Path,'PUBLISHED')}
            Mock Invoke-AiCliRecoverableRun {
                Test-Path (Join-Path $Work 'handle.json')|Should -BeTrue
                [pscustomobject]@{runId=('b'*32);status='completed';resumeSupported=$false;resumeReason='terminal';receipt=[pscustomobject]@{exitCode=0;timedOut=$false}}
            }
            $code=Invoke-AiCliRunCommand -Tokens @('start','fixture','--stdin','--json','--project',$Work,'--control-file',(Join-Path $Work 'handle.json')) -StdInText 'PUBLIC_FIXTURE'
            $code|Should -Be 0
            Should -Invoke Publish-AiCliRunControlReceipt -Times 1 -Exactly -ParameterFilter {$RunId -eq ('b'*32)}
        }
    }
    It 'dry-run advertises the protocol without runtime or handle creation' {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive} {
            Mock Get-AiCliResolvedProfile {[pscustomobject]@{engine='codex';models=@{primary='fixture-model'};profileFingerprint=('c'*64)}}
            Mock New-AiCliRecoverableRun {throw 'No runtime creation'}
            Mock Publish-AiCliRunControlReceipt {throw 'No receipt write'}
            $writer=[IO.StringWriter]::new();$old=[Console]::Out
            try {
                [Console]::SetOut($writer)
                $code=Invoke-AiCliRunCommand -Tokens @('start','fixture','--stdin','--json','--project',$Work,'--dry-run','--control-file',(Join-Path $Work 'must-not-exist.json'))
            } finally {[Console]::SetOut($old)}
            $code|Should -Be 0
            $result=$writer.ToString()|ConvertFrom-Json
            $result.preflight.runControlReceipt|Should -BeExactly 'aicli.run-control.v1'
            $result.preflight.modelInvoked|Should -BeFalse
            Test-Path (Join-Path $Work 'must-not-exist.json')|Should -BeFalse
            Should -Invoke New-AiCliRecoverableRun -Times 0
            Should -Invoke Publish-AiCliRunControlReceipt -Times 0
        }
    }
    It 'rejects unsupported engines before runtime creation' {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive} {
            Mock Get-AiCliResolvedProfile {[pscustomobject]@{engine='claude'}}
            Mock Invoke-AiCliProfileCapture {throw 'No execution'}
            $code=Invoke-AiCliRunCommand -Tokens @('start','fixture','--stdin','--json','--project',$Work,'--control-file',(Join-Path $Work 'no.json')) -StdInText 'PUBLIC_FIXTURE'
            $code|Should -Not -Be 0
            Should -Invoke Invoke-AiCliProfileCapture -Times 0
        }
    }
}
