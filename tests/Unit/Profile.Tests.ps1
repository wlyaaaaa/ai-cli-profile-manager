#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Profile' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
        $script:DataRoot = Join-Path $TestDrive 'prof'
        New-Item -ItemType Directory -Force -Path $script:DataRoot | Out-Null
    }

    It 'resolves virtual official profiles' {
        $p = Invoke-AiCli -Tokens @('profile','show','codex-official','--json') -DataRoot $script:DataRoot
        $p | Should -Be 0
    }

    It 'eject refuses existing directory' {
        $out = Join-Path $script:DataRoot 'exists'
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        $code = Invoke-AiCli -Tokens @('eject','codex-official','--output',$out) -DataRoot $script:DataRoot
        $code | Should -Not -Be 0
    }

    It 'eject creates recipe without secrets' {
        $out = Join-Path $script:DataRoot 'eject1'
        $code = Invoke-AiCli -Tokens @('eject','claude-official','--output',$out) -DataRoot $script:DataRoot
        $code | Should -Be 0
        Test-Path (Join-Path $out 'README.md') | Should -BeTrue
        Test-Path (Join-Path $out 'start.ps1') | Should -BeTrue
    }
}
