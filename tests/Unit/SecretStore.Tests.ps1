#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
Describe 'SecretStore legacy read compatibility' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        Import-Module (Join-Path $root 'src/AiCliProfileManager/AiCliProfileManager.psd1') -Force
    }
    BeforeEach {
        $script:DataRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        InModuleScope AiCliProfileManager -Parameters @{ Root = $script:DataRoot } { Set-AiCliDataRootOverride $Root }
    }
    AfterEach { InModuleScope AiCliProfileManager { Set-AiCliDataRootOverride $null } }

    It 'reads a synthetic legacy ciphertext only from the isolated root' {
        InModuleScope AiCliProfileManager -Parameters @{ Root = $script:DataRoot } {
            $id = '0123456789abcdef0123456789abcdef'
            $paths = Get-AiCliAppPaths
            $paths.IsTestRoot | Should -BeTrue
            $paths.SecretsDir | Should -Be (Join-Path $Root 'Local/secrets')
            $plain = [Text.Encoding]::UTF8.GetBytes('synthetic-legacy-key')
            $cipher = [Security.Cryptography.ProtectedData]::Protect($plain, (Get-AiCliSecretEntropy), [Security.Cryptography.DataProtectionScope]::CurrentUser)
            $file = Join-Path $paths.SecretsDir "$id.json"
            Write-AiCliJsonFile $file @{ formatVersion=1; cipherBase64=[Convert]::ToBase64String($cipher) }
            Get-AiCliSecret $id | Should -BeExactly 'synthetic-legacy-key'
            Test-AiCliSecretExists $id | Should -BeTrue
            Test-AiCliSecretExists 'ffffffffffffffffffffffffffffffff' | Should -BeFalse
            Test-Path -LiteralPath $file | Should -BeTrue
        }
    }
    It 'has no local secret writer or dedicated ACL function' {
        InModuleScope AiCliProfileManager {
            foreach ($name in @('New-AiCliSecret','Protect-AiCliSecretBytes','Set-AiCliSecretAcl')) {
                Get-Command $name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            }
            $paths = Initialize-AiCliDirectories
            Test-Path -LiteralPath $paths.SecretsDir | Should -BeFalse
            Test-AiCliSecretExists 'passwordcenter:unregistered-future-vendor' | Should -BeNullOrEmpty
        }
    }
}
