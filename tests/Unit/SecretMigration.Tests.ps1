BeforeAll {
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $repo 'src/AiCliProfileManager/AiCliProfileManager.psd1') -Force
}
Describe 'Password Center secret migration' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        InModuleScope AiCliProfileManager -Parameters @{ Root=$script:Root } {
            Set-AiCliDataRootOverride $Root
            $paths = Initialize-AiCliDirectories
            Write-AiCliJsonFile -Path (Join-Path $paths.ProfilesDir 'synthetic-profile.json') -Value @{
                id='synthetic-profile'; secretRef=('a' * 32); endpoint='https://openrouter.ai/api'; other='preserved'
            }
            Mock Get-AiCliVendorRegistrations { @{openrouter=@{native_hosts=@('openrouter.ai');credential_ref='openrouter-aicli'}} }
            Mock Get-AiCliSecret { 'synthetic-migration-canary' }
            Mock Request-AiCliVendorCredential { 'synthetic-migration-canary' }
            Mock Set-AiCliVendorCredentialFromStdin {}
        }
    }
    AfterEach { InModuleScope AiCliProfileManager { Set-AiCliDataRootOverride $null } }
    It 'exports the migration command and migrates equal values with a preimage backup' {
        Get-Command Invoke-AiCliSecretMigration | Should -Not -BeNullOrEmpty
        InModuleScope AiCliProfileManager {
            $row = Invoke-AiCliSecretMigration
            $row.status | Should -BeExactly 'migrated'
            $row.vendor | Should -BeExactly 'openrouter'
            $paths = Get-AiCliAppPaths
            $profile = Read-AiCliJsonFile (Join-Path $paths.ProfilesDir 'synthetic-profile.json')
            $profile.secretRef | Should -BeExactly 'passwordcenter:openrouter'
            $profile.other | Should -BeExactly 'preserved'
            $backup = @(Get-ChildItem $paths.BackupsDir -Filter '*.bak')
            $backup.Count | Should -Be 1
            (Read-AiCliJsonFile $backup[0].FullName).secretRef | Should -BeExactly ('a' * 32)
            ($row | ConvertTo-Json) | Should -Not -Match 'canary|hash|length|secretRef'
            @($row.PSObject.Properties.Name).Count | Should -Be 4
            Should -Invoke Set-AiCliVendorCredentialFromStdin -Times 0
        }
    }
    It 'sets only a missing registered entry through stdin and verifies delivery again' {
        InModuleScope AiCliProfileManager {
            $script:delivery=0
            Mock Request-AiCliVendorCredential { if (++$script:delivery -eq 1) { throw 'Password Center: agent_secretref_credential_entry_missing' }; 'synthetic-migration-canary' }
            $row = Invoke-AiCliSecretMigration
            $row.status | Should -BeExactly 'migrated'
            $row.action | Should -BeExactly 'set_and_migrate'
            Should -Invoke Set-AiCliVendorCredentialFromStdin -Times 1 -ParameterFilter { $Query -eq 'openrouter-aicli' -and $Secret -ceq 'synthetic-migration-canary' }
            Should -Invoke Request-AiCliVendorCredential -Times 2
        }
    }
    It 'leaves a different value unchanged' {
        InModuleScope AiCliProfileManager {
            Mock Request-AiCliVendorCredential { 'different-synthetic-key' }
            (Invoke-AiCliSecretMigration).status | Should -BeExactly 'value_differs'
            (Get-AiCliUserProfile 'synthetic-profile').secretRef | Should -BeExactly ('a' * 32)
            Should -Invoke Set-AiCliVendorCredentialFromStdin -Times 0
        }
    }
    It 'leaves an unregistered endpoint unchanged without fetching values' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliVendorRegistrations { @{deepseek=@{native_hosts=@('api.deepseek.com')}} }
            (Invoke-AiCliSecretMigration).status | Should -BeExactly 'vendor_not_registered'
            Should -Invoke Get-AiCliSecret -Times 0
            Should -Invoke Request-AiCliVendorCredential -Times 0
        }
    }
    It 'matches a template endpoint host independently of its API path' {
        InModuleScope AiCliProfileManager {
            $profile = Get-AiCliUserProfile 'synthetic-profile'
            $profile.Remove('endpoint'); $profile['templateId']='fixture-deepseek'
            Save-AiCliUserProfile $profile
            Mock Get-AiCliProviderManifest { @{endpoint='https://api.deepseek.com/anthropic'} }
            Mock Get-AiCliVendorRegistrations { @{deepseek=@{native_hosts=@('api.deepseek.com');credential_ref='deepseek-fixture'}} }
            $row = Invoke-AiCliSecretMigration
            $row.status | Should -BeExactly 'migrated'
            $row.vendor | Should -BeExactly 'deepseek'
            (Get-AiCliUserProfile 'synthetic-profile').secretRef | Should -BeExactly 'passwordcenter:deepseek'
        }
    }
    It 'preserves a Profile changed while its credential was being delivered' {
        InModuleScope AiCliProfileManager {
            Mock Request-AiCliVendorCredential {
                $profile = Get-AiCliUserProfile 'synthetic-profile'; $profile.other='concurrent-edit'
                Save-AiCliUserProfile $profile
                'synthetic-migration-canary'
            }
            (Invoke-AiCliSecretMigration).status | Should -BeExactly 'profile_changed'
            (Get-AiCliUserProfile 'synthetic-profile').secretRef | Should -BeExactly ('a' * 32)
            (Get-AiCliUserProfile 'synthetic-profile').other | Should -BeExactly 'concurrent-edit'
        }
    }
    It 'does not set, rewrite or back up in DryRun, including a missing entry' {
        InModuleScope AiCliProfileManager {
            (Invoke-AiCliSecretMigration -DryRun).status | Should -BeExactly 'dry_run'
            Mock Request-AiCliVendorCredential { throw 'Password Center: agent_secretref_credential_entry_missing' }
            (Invoke-AiCliSecretMigration -DryRun).action | Should -BeExactly 'set_and_migrate'
            (Get-AiCliUserProfile 'synthetic-profile').secretRef | Should -BeExactly ('a' * 32)
            @(Get-ChildItem (Get-AiCliAppPaths).BackupsDir -File).Count | Should -Be 0
            Should -Invoke Set-AiCliVendorCredentialFromStdin -Times 0
        }
    }
    It 'requires matching readback after Set and does not treat delivery failures as missing' {
        InModuleScope AiCliProfileManager {
            $script:delivery=0
            Mock Request-AiCliVendorCredential { if (++$script:delivery -eq 1) { throw 'Password Center: agent_secretref_credential_entry_missing' }; 'different-synthetic-key' }
            (Invoke-AiCliSecretMigration).status | Should -BeExactly 'value_differs'
            (Get-AiCliUserProfile 'synthetic-profile').secretRef | Should -BeExactly ('a' * 32)
            Mock Request-AiCliVendorCredential { throw 'Password Center: trusted_device_unlock_missing' }
            (Invoke-AiCliSecretMigration).status | Should -BeExactly 'migration_failed'
            Should -Invoke Set-AiCliVendorCredentialFromStdin -Times 1
        }
    }
}
Describe 'Password Center migration stdin' {
    It 'passes a synthetic value solely on the child stdin and bounds failing receipts' {
        $fake = Join-Path $TestDrive 'Invoke-SecretBroker.ps1'
        @'
param($Action,$Query,[switch]$AgentSecretFromStdin,$AuthorityFactor,[switch]$Json)
$secret=[Console]::In.ReadLine()
if($secret -cne 'synthetic-pipe-canary' -or $Action -cne 'Set' -or $Query -cne 'openrouter-aicli' -or -not $AgentSecretFromStdin -or $AuthorityFactor -cne 'Runtime' -or -not $Json){exit 2}
[Console]::Out.Write('{"schema":"pcconfig.secret-broker-result.v1","action":"set","status":"pass","plaintext_returned":false}')
'@ | Set-Content -LiteralPath $fake -Encoding utf8
        InModuleScope AiCliProfileManager -Parameters @{ Fake=$fake } {
            Mock Get-AiCliVendorBrokerPath { Join-Path (Split-Path $Fake -Parent) 'Invoke-PasswordCenterVendor.ps1' }
            Set-AiCliVendorCredentialFromStdin -Query 'openrouter-aicli' -Secret 'synthetic-pipe-canary'
            { Set-AiCliVendorCredentialFromStdin -Query 'openrouter-aicli' -Secret "invalid`nsynthetic-pipe-canary" } | Should -Throw '*migration_set_failed*'
            [IO.File]::WriteAllText($Fake, "[Console]::Out.Write('synthetic-pipe-canary'); exit 2")
            { Set-AiCliVendorCredentialFromStdin -Query 'openrouter-aicli' -Secret 'synthetic-pipe-canary' } | Should -Throw '*migration_set_failed*'
        }
    }
}
