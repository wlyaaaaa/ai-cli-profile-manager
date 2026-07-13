#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'SecretStore' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
        $script:DataRoot = Join-Path $TestDrive 'sec'
        New-Item -ItemType Directory -Force -Path $script:DataRoot | Out-Null
        Set-AiCliDataRootOverride -Path $script:DataRoot
        . (Join-Path $root 'src\AiCliProfileManager\Private\Brand.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\Paths.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\JsonStore.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\Redaction.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\SecretStore.ps1')
    }
    AfterAll {
        Set-AiCliDataRootOverride -Path $null
    }

    It 'round-trips DPAPI secret' {
        $canary = 'canary-secret-VALUE-9f3a2c'
        $id = New-AiCliSecret -PlainText $canary -Label 't'
        $got = Get-AiCliSecret -SecretId $id
        $got | Should -Be $canary
        Test-AiCliSecretExists -SecretId $id | Should -BeTrue
        Remove-AiCliSecret -SecretId $id
        Test-AiCliSecretExists -SecretId $id | Should -BeFalse
    }
}
