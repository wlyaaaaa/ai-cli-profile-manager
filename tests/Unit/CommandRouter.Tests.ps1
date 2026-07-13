#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'CommandRouter' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
        $script:DataRoot = Join-Path $TestDrive 'aicli-data'
        New-Item -ItemType Directory -Force -Path $script:DataRoot | Out-Null
    }

    It 'version returns 0' {
        $code = Invoke-AiCli -Tokens @('version') -DataRoot $script:DataRoot
        $code | Should -Be 0
    }

    It 'unknown command returns 2' {
        $code = Invoke-AiCli -Tokens @('definitely-not-a-command') -DataRoot $script:DataRoot
        $code | Should -Be 2
    }

    It 'test without --live fails' {
        $code = Invoke-AiCli -Tokens @('test', 'codex-official') -DataRoot $script:DataRoot
        $code | Should -BeIn @(2, 4)
    }

    It 'profile list --json is pure-ish success' {
        $code = Invoke-AiCli -Tokens @('profile', 'list', '--available', '--json') -DataRoot $script:DataRoot
        $code | Should -Be 0
    }

    It 'help compare works' {
        $code = Invoke-AiCli -Tokens @('help', 'compare') -DataRoot $script:DataRoot
        $code | Should -Be 0
    }

    It 'rejects unknown options instead of silently ignoring them' {
        (Invoke-AiCli -Tokens @('version','--definitely-invalid') -DataRoot $script:DataRoot) | Should -Be 2
        (Invoke-AiCli -Tokens @('native','codex-official','unexpected') -DataRoot $script:DataRoot) | Should -Be 2
        (Invoke-AiCli -Tokens @('profile','list','--definitely-invalid') -DataRoot $script:DataRoot) | Should -Be 2
    }

    It 'rejects an unknown help topic' {
        (Invoke-AiCli -Tokens @('help','definitely-invalid') -DataRoot $script:DataRoot) | Should -Be 2
    }

    It 'rejects a Claude login request for ccp instead of silently using Codex OAuth' {
        (Invoke-AiCli -Tokens @('proxy','ccp','login','claude') -DataRoot $script:DataRoot) | Should -Be 2
    }

    It 'provides command help topics' {
        foreach ($topic in @('setup','profile','start','doctor','test','proxy','update','native','eject','uninstall')) {
            (Invoke-AiCli -Tokens @('help',$topic) -DataRoot $script:DataRoot) | Should -Be 0
        }
    }
}
