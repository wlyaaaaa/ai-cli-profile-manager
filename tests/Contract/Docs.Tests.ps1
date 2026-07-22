#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Docs contract' {
    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:UserDocs = Join-Path $script:Root 'docs\user'
    }

    It 'has required user handbook files' {
        $required = @(
            'QUICKSTART.md','START-AND-PROFILES.md','DOCTOR-AND-TEST.md','PROXIES.md',
            'CLI-COMMANDS.md','CLI-LEARNING.md','UPDATE-AND-REPAIR.md','TROUBLESHOOTING.md','PRIVACY-AND-UNINSTALL.md',
            'OPEN-INTERPRETER.md','CLAUDE-PERMISSIONS-AND-QWEN.md'
        )
        foreach ($f in $required) {
            Test-Path (Join-Path $script:UserDocs $f) | Should -BeTrue -Because $f
        }
    }

    It 'README mentions aicli and 0.2.1' {
        $readme = Get-Content (Join-Path $script:Root 'README.md') -Raw
        $readme | Should -Match 'aicli'
        $readme | Should -Match '0\.2\.1'
    }

    It 'no TODO placeholders in user docs' {
        Get-ChildItem $script:UserDocs -Filter '*.md' | ForEach-Object {
            $t = Get-Content $_.FullName -Raw
            $t | Should -Not -Match 'TODO\(implement\)'
        }
    }
}
