#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Paths' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
    }

    It 'uses override data root without hard-coded user path requirement' {
        $dr = Join-Path $TestDrive '中文 空格 paths'
        New-Item -ItemType Directory -Force -Path $dr | Out-Null
        InModuleScope AiCliProfileManager -Parameters @{ DataRoot = $dr } {
            Set-AiCliDataRootOverride -Path $DataRoot
            try {
                $p = Get-AiCliAppPaths
                $p.IsTestRoot | Should -BeTrue
                $p.SettingsDir | Should -Match '中文'
                $p.SecretsDir | Should -Match 'Local'
            } finally {
                Set-AiCliDataRootOverride -Path $null
            }
        }
    }

    It 'brand version is 0.3.8' {
        (Get-AiCliVersion) | Should -Be '0.3.8'
        (Get-AiCliBrand).CommandName | Should -Be 'aicli'
    }

    It 'removes only the managed shell integration text and PATH entry' {
        InModuleScope AiCliProfileManager {
            $bin = 'C:\Users\tester\AppData\Local\aicli\bin'
            (Remove-AiCliPathEntry -PathValue "C:\Tools;$bin;D:\More" -Entry ($bin + '\')) |
                Should -Be 'C:\Tools;D:\More'

            $profile = @'
Write-Host "keep-before"
# >>> AI CLI Profile Manager >>>
$__aicliOk = $false
Write-Host "managed"
# <<< AI CLI Profile Manager <<<
Write-Host "keep-after"
'@
            $clean = Remove-AiCliProfileBlockText -Text $profile
            $clean | Should -Match 'keep-before'
            $clean | Should -Match 'keep-after'
            $clean | Should -Not -Match 'managed'
            @($clean -split "`r?`n" | Where-Object { $_ }) | Should -Be @(
                'Write-Host "keep-before"',
                'Write-Host "keep-after"'
            )
        }
    }

    It 'accepts only a normal module directory with the expected manifest identity' {
        $managed = Join-Path $TestDrive 'AiCliProfileManager'
        $version = Join-Path $managed '0.1.0'
        New-Item -ItemType Directory -Force -Path $version | Out-Null
        @"
@{
    RootModule = 'AiCliProfileManager.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'a1c11c11-0a11-4c11-b111-a1c110110011'
}
"@ | Set-Content -LiteralPath (Join-Path $version 'AiCliProfileManager.psd1') -Encoding utf8
        Set-Content -LiteralPath (Join-Path $version 'AiCliProfileManager.psm1') -Value '# test module' -Encoding utf8

        InModuleScope AiCliProfileManager -Parameters @{ Managed = $managed } {
            Test-AiCliManagedModuleDirectory -Path $Managed | Should -BeTrue
        }

        $other = Join-Path $TestDrive 'OtherModule'
        Copy-Item -LiteralPath $managed -Destination $other -Recurse
        InModuleScope AiCliProfileManager -Parameters @{ Other = $other } {
            Test-AiCliManagedModuleDirectory -Path $Other | Should -BeFalse
        }
    }

    It 'rejects a same-name module directory whose manifest identity is wrong' {
        $managed = Join-Path $TestDrive 'wrong\AiCliProfileManager'
        New-Item -ItemType Directory -Force -Path $managed | Out-Null
        @"
@{
    RootModule = 'Wrong.psm1'
    ModuleVersion = '0.1.0'
    GUID = '00000000-0000-0000-0000-000000000000'
}
"@ | Set-Content -LiteralPath (Join-Path $managed 'AiCliProfileManager.psd1') -Encoding utf8

        InModuleScope AiCliProfileManager -Parameters @{ Managed = $managed } {
            Test-AiCliManagedModuleDirectory -Path $Managed | Should -BeFalse
        }
    }

    It 'rejects a nested valid-looking manifest hidden under an unrecognized top-level directory' {
        $managed = Join-Path $TestDrive 'nested\AiCliProfileManager'
        $nested = Join-Path $managed 'not-a-version\deep'
        New-Item -ItemType Directory -Force -Path $nested | Out-Null
        @"
@{
    RootModule = 'AiCliProfileManager.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'a1c11c11-0a11-4c11-b111-a1c110110011'
}
"@ | Set-Content -LiteralPath (Join-Path $nested 'AiCliProfileManager.psd1') -Encoding utf8
        Set-Content -LiteralPath (Join-Path $nested 'AiCliProfileManager.psm1') -Value '# test module' -Encoding utf8

        InModuleScope AiCliProfileManager -Parameters @{ Managed = $managed } {
            Test-AiCliManagedModuleDirectory -Path $Managed | Should -BeFalse
        }
    }
}

Describe 'Exact Codex Profile fast installer' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:FastInstallerPath = Join-Path $root 'scripts\Install-ExactCodexProfileFast.ps1'
        $script:FastInstallerText = Get-Content -LiteralPath $script:FastInstallerPath -Raw
    }

    It 'is valid PowerShell and keeps the fast lane separate from release artifact and Live work' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script:FastInstallerPath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
        $script:FastInstallerText | Should -Not -Match 'Build-Pdfs|Build\.ps1|--live'
        $script:FastInstallerText | Should -Match "liveAcceptance = 'not-run-by-fast-installer'"
    }

    It 'requires clean immutable source and the focused exact-profile safety gates before atomic install' {
        $script:FastInstallerText | Should -Match 'status --porcelain=v1'
        foreach ($testName in @(
            'Manifest.Tests.ps1',
            'ExactCodexProfiles.Tests.ps1',
            'Retirement.Tests.ps1',
            'CommandRouter.Tests.ps1',
            'SecurityRegression.Tests.ps1'
        )) {
            $script:FastInstallerText | Should -Match ([regex]::Escape($testName))
        }
        $script:FastInstallerText | Should -Match 'scripts\\Test-Release.ps1'
        $script:FastInstallerText | Should -Match 'scripts\\Install.ps1'
        $script:FastInstallerText | Should -Match 'pwsh -NoLogo -NoProfile -EncodedCommand'
        $script:FastInstallerText | Should -Match 'AICLI_FAST_PESTER_RESULT='
        $script:FastInstallerText | Should -Match '\*>\&1'
        $script:FastInstallerText | Should -Match 'profile list --available --json'
        $script:FastInstallerText | Should -Match 'profile show \$ProfileId --json'
    }
}
