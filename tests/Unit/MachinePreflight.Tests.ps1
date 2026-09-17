#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Read-only machine run preflight' {
    BeforeAll {
        $root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module AiCliProfileManager -All|Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
    }
    It 'uses the real parser for <Engine> without controller, mirror or runtime creation' -ForEach @(
        @{Engine='codex';Policy='danger-full-access'},
        @{Engine='claude';Policy='workspace-write'},
        @{Engine='opencode';Policy='read-only'},
        @{Engine='qwen-code';Policy='workspace-write'}
    ) {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive;Engine=$Engine;Policy=$Policy} {
            Mock Get-AiCliResolvedProfile {
                [pscustomobject]@{id='public-profile';engine=$Engine;models=@{primary='public-model'};configured=$true;profileFingerprint=('a'*64)}
            }
            Mock Initialize-AiCliDirectories {throw 'Unexpected runtime creation'}
            Mock New-AiCliRecoverableRun {throw 'Unexpected model controller'}
            Mock Invoke-AiCliProfileCapture {throw 'Unexpected model invocation'}
            Mock Resolve-AiCliMachineEventMirrorFile {throw 'Unexpected mirror creation'}
            $output=[IO.StringWriter]::new();$previous=[Console]::Out
            try {
                [Console]::SetOut($output)
                $code=Invoke-AiCliRunCommand -Tokens @('public-profile','--project',$Work,
                    '--stdin','--json','--sandbox-policy',$Policy,'--watchdog-only',
                    '--timeout-seconds','300','--dry-run') -StdInText ''
            } finally {[Console]::SetOut($previous)}
            $code|Should -Be 0
            $result=$output.ToString()|ConvertFrom-Json
            $result.preflight.schema|Should -BeExactly 'aicli.machine-run-preflight.v1'
            $result.preflight.model|Should -BeExactly 'public-model'
            $result.preflight.policy|Should -BeExactly $Policy
            $result.preflight.budgetMode|Should -BeExactly 'watchdog_only'
            $result.preflight.modelInvoked|Should -BeFalse
            $result.preflight.runtimeCreated|Should -BeFalse
            $result.preflight.authenticationChecked|Should -BeFalse
            Should -Invoke Initialize-AiCliDirectories -Times 0 -Exactly
            Should -Invoke New-AiCliRecoverableRun -Times 0 -Exactly
            Should -Invoke Invoke-AiCliProfileCapture -Times 0 -Exactly
            Should -Invoke Resolve-AiCliMachineEventMirrorFile -Times 0 -Exactly
            Test-Path (Join-Path $Work 'events.ndjson')|Should -BeFalse
        }
    }
    It 'rejects an unsupported current Codex policy during preflight' {
        InModuleScope AiCliProfileManager -Parameters @{Work=$TestDrive} {
            Mock Get-AiCliResolvedProfile {[pscustomobject]@{engine='codex'}}
            Mock New-AiCliRecoverableRun {throw 'Unexpected model controller'}
            $output=[IO.StringWriter]::new();$previous=[Console]::Out
            try {
                [Console]::SetOut($output)
                $code=Invoke-AiCliRunCommand -Tokens @('public','--project',$Work,
                    '--stdin','--json','--sandbox-policy','workspace-write','--dry-run') -StdInText ''
            } finally {[Console]::SetOut($previous)}
            $code|Should -Not -Be 0
            ($output.ToString()|ConvertFrom-Json).error.summary|Should -Match 'danger-full-access'
            Should -Invoke New-AiCliRecoverableRun -Times 0 -Exactly
        }
    }
}