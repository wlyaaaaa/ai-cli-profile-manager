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
        $expectedVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $root 'src/AiCliProfileManager/AiCliProfileManager.psd1')).ModuleVersion
        $result.version|Should -BeExactly $expectedVersion
    }
    It 'WhatIf requires no migration script or installed directories' {
        $fixture=Join-Path $TestDrive 'source';$module=Join-Path $fixture 'src\AiCliProfileManager'
        [void][IO.Directory]::CreateDirectory($module)
        [IO.File]::WriteAllText((Join-Path $module 'AiCliProfileManager.psd1'),"@{ModuleVersion='88.99.77'}")
        { & $installer -SourceRoot $fixture -WhatIf }|Should -Not -Throw
    }
    It 'rejects a concurrent install without touching the active transaction directory' {
        $modulePath = Join-Path $TestDrive 'locked\Documents\PowerShell\Modules'
        $managedRoot = Join-Path $modulePath 'AiCliProfileManager'
        $active = Join-Path $managedRoot ('.0.1.0.install-' + ('a' * 32))
        [void][IO.Directory]::CreateDirectory($active)
        $lock = [IO.FileStream]::new((Join-Path $managedRoot '.install.lock'), 'OpenOrCreate', 'ReadWrite', 'None',
            4096, [IO.FileOptions]::DeleteOnClose)
        $pathBefore = $env:PSModulePath
        try {
            $env:PSModulePath = $modulePath
            { & $installer -SourceRoot $root -SkipShellIntegration } | Should -Throw '*另一个 AICLI 安装事务*'
            @(Get-ChildItem -LiteralPath $managedRoot -Force).Count | Should -Be 2
            Test-Path -LiteralPath $active | Should -BeTrue
        } finally { $env:PSModulePath = $pathBefore; $lock.Dispose() }
    }
}

Describe 'Installer obsolete version cleanup' {
    It 'removes verified old versions and transaction leftovers while retaining unknown and newer directories' {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $source = Join-Path $TestDrive 'source'
        $module = Join-Path $source 'src\AiCliProfileManager'
        $modulePath = Join-Path $TestDrive 'Documents\PowerShell\Modules'
        $installed = Join-Path $modulePath 'AiCliProfileManager'
        [void][IO.Directory]::CreateDirectory($module)
        [IO.File]::WriteAllText((Join-Path $module 'AiCliProfileManager.psd1'), "@{RootModule='AiCliProfileManager.psm1';ModuleVersion='1.2.3';GUID='a1c11c11-0a11-4c11-b111-a1c110110011';FunctionsToExport=@('Get-AiCliVersion')}")
        [IO.File]::WriteAllText((Join-Path $module 'AiCliProfileManager.psm1'), "function Get-AiCliVersion { '1.2.3' }")
        $old = @('1.0.0', ('.1.1.0.backup-' + ('a' * 32)), ('.1.2.3.install-' + ('b' * 32)))
        $keep = @('1.0.1', '2.0.0', 'user-data', ('.1.2.3.install-' + ('c' * 32)))
        foreach ($name in @($old) + @($keep)) {
            $directory = Join-Path $installed $name
            [void][IO.Directory]::CreateDirectory($directory)
            if ($name -in @('user-data', $keep[-1])) { continue }
            $version = if ($name.StartsWith('.')) { $name.Split('.')[1..3] -join '.' } else { $name }
            $guid = if ($name -eq '1.0.1') { [guid]::Empty } else { 'a1c11c11-0a11-4c11-b111-a1c110110011' }
            [IO.File]::WriteAllText((Join-Path $directory 'AiCliProfileManager.psd1'), "@{RootModule='AiCliProfileManager.psm1';ModuleVersion='$version';GUID='$guid'}")
            [IO.File]::WriteAllText((Join-Path $directory 'AiCliProfileManager.psm1'), '# fixture')
        }
        New-Item -ItemType Junction -Path (Join-Path $installed '0.9.9') -Target $module | Out-Null
        $keep += '0.9.9'
        $pathBefore = $env:PSModulePath
        try {
            $env:PSModulePath = $modulePath
            & (Join-Path $root 'scripts\Install.ps1') -SourceRoot $source -SkipShellIntegration
        } finally { $env:PSModulePath = $pathBefore }
        foreach ($name in $old) { Test-Path -LiteralPath (Join-Path $installed $name) | Should -BeFalse }
        foreach ($name in @($keep) + @('1.2.3')) { Test-Path -LiteralPath (Join-Path $installed $name) | Should -BeTrue }
        Test-Path -LiteralPath (Join-Path $module 'AiCliProfileManager.psd1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installed '.install.lock') | Should -BeFalse
    }
}
