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

Describe 'Installer same-version safety' {
    BeforeEach {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $source = Join-Path $fixture 'source'
        $sourceModule = Join-Path $source 'src\AiCliProfileManager'
        $modulePath = Join-Path $fixture 'Documents\PowerShell\Modules'
        $moduleRoot = Join-Path $modulePath 'AiCliProfileManager'
        $installed = Join-Path $moduleRoot '0.3.5'
        New-Item -ItemType Directory -Path $sourceModule, $moduleRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $sourceModule 'AiCliProfileManager.psd1'), "@{RootModule='AiCliProfileManager.psm1';ModuleVersion='0.3.5';GUID='a1c11c11-0a11-4c11-b111-a1c110110011';FunctionsToExport=@('Get-AiCliVersion')}")
        [IO.File]::WriteAllText((Join-Path $sourceModule 'AiCliProfileManager.psm1'), "function Get-AiCliVersion { '0.3.5' }")
        $pathBefore = $env:PSModulePath
        $env:PSModulePath = $modulePath
    }
    AfterEach { $env:PSModulePath = $pathBefore }

    It 'rejects a same-version module junction before candidate copy' {
        $external = Join-Path $fixture 'external-module'
        New-Item -ItemType Directory -Path $external | Out-Null
        $canary = Join-Path $external 'canary.txt'
        [IO.File]::WriteAllText($canary, 'preserve')
        New-Item -ItemType Junction -Path $installed -Target $external | Out-Null

        { & (Join-Path $root 'scripts\Install.ps1') -SourceRoot $source -Force -SkipShellIntegration } |
            Should -Throw '*普通目录*'

        [IO.File]::ReadAllText($canary) | Should -BeExactly 'preserve'
        (Get-Item -LiteralPath $installed -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) |
            Should -BeTrue
        @(Get-ChildItem -LiteralPath $moduleRoot -Force).Count | Should -Be 1
    }

    It 'restores an existing same-version module when installed validation fails after promotion' {
        New-Item -ItemType Directory -Path $installed | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceModule 'AiCliProfileManager.psd1') -Destination $installed
        $oldModule = Join-Path $installed 'AiCliProfileManager.psm1'
        [IO.File]::WriteAllText($oldModule, "function Get-AiCliVersion { '0.3.5-old' }")
        $oldHash = (Get-FileHash -LiteralPath $oldModule).Hash
        $marker = Join-Path $installed 'old-marker.txt'
        [IO.File]::WriteAllText($marker, 'old payload')
        [IO.File]::WriteAllText((Join-Path $sourceModule 'AiCliProfileManager.psm1'), @'
function Get-AiCliVersion {
    if ($PSScriptRoot -notmatch '\.install-') { throw 'simulated installed validation failure' }
    '0.3.5'
}
'@)

        { & (Join-Path $root 'scripts\Install.ps1') -SourceRoot $source -Force -SkipShellIntegration } |
            Should -Throw '*simulated installed validation failure*'

        (Get-FileHash -LiteralPath $oldModule).Hash | Should -BeExactly $oldHash
        [IO.File]::ReadAllText($marker) | Should -BeExactly 'old payload'
        Test-Path -LiteralPath (Join-Path $installed 'AiCliProfileManager.psd1') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $moduleRoot -Force).Count | Should -Be 1
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
