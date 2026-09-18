#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.0.0'}
Describe 'Installer no-effect modes' {
    BeforeAll { $root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path; $installer=Join-Path $root 'scripts\Install.ps1' }
    It 'rejects unknown parameters before source resolution' {
        { & $installer -SourceRoot 'Z:\nonexistent-fixture' -UnexpectedFixtureFlag } | Should -Throw '*UnexpectedFixtureFlag*'
    }
    It 'DryRun returns an explicit plan without installation' {
        $result=& $installer -SourceRoot $root -DryRun | ConvertFrom-Json
        $result.schema|Should -BeExactly 'aicli.install-plan.v1'
        $result.write_mode|Should -BeExactly 'zero_write'
        $result.installed|Should -BeFalse
        $result.version|Should -BeExactly '0.3.17'
    }
    It 'WhatIf never calls retirement migration' {
        $fixture=Join-Path $TestDrive 'source';$module=Join-Path $fixture 'src\AiCliProfileManager';$scripts=Join-Path $fixture 'scripts'
        [void][IO.Directory]::CreateDirectory($module);[void][IO.Directory]::CreateDirectory($scripts)
        [IO.File]::WriteAllText((Join-Path $module 'AiCliProfileManager.psd1'),"@{ModuleVersion='88.99.77'}")
        [IO.File]::WriteAllText((Join-Path $scripts 'Invoke-AiCliRetirementMigration.ps1'),"throw 'MIGRATION_MUST_NOT_RUN'")
        { & $installer -SourceRoot $fixture -WhatIf }|Should -Not -Throw
    }
}