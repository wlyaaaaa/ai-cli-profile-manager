BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Remove-Module AiCliProfileManager -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:Repo 'src/AiCliProfileManager/AiCliProfileManager.psd1') -Force
}

Describe 'Vendor credential references' {
    It 'reports only a bounded Broker error when trusted-device material is missing' {
        InModuleScope AiCliProfileManager {
            Get-AiCliVendorDeliveryError '{"schema":"pcconfig.secret-broker-result.v1","error":"trusted_device_unlock_missing"}' | Should -BeExactly 'trusted_device_unlock_missing'
            Get-AiCliVendorDeliveryError '{"schema":"pcconfig.secret-broker-result.v1","error":"do not echo arbitrary payload!"}' | Should -BeExactly 'vendor_delivery_failed'
        }
    }
    It 'resolves two GLM models to one reference without reading or copying a secret' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile { $null }
            Mock Get-AiCliSettings { @{ verification=@{} } }
            Mock Get-AiCliSecret { throw 'must not read DPAPI' }
            Mock Request-AiCliVendorCredential { throw 'must not fetch a credential' }
            $first = Get-AiCliResolvedProfile -Id 'codex-glm-5-3'
            $second = Get-AiCliResolvedProfile -Id 'codex-glm-5-3-flash'
            $first.secretRef | Should -BeExactly 'passwordcenter:glm'
            $first.secretRef | Should -BeExactly $second.secretRef
            Should -Invoke Get-AiCliSecret -Times 0
            Should -Invoke Request-AiCliVendorCredential -Times 0
        }
    }

    It 'configures a future GLM model without New-AiCliSecret or a model allowlist' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile { $null }
            Mock Save-AiCliUserProfile {}
            Mock New-AiCliSecret { throw 'must not copy a key' }
            Mock Read-AiCliSecret { throw 'must not ask for a key' }
            $profile = Invoke-AiCliProfileConfigure -TemplateId 'codex-glm-5-3' -ProfileId 'codex-vendor-custom' -Model 'glm-future-99'
            $profile.secretRef | Should -BeExactly 'passwordcenter:glm'
            $profile.modelOverride | Should -BeExactly 'glm-future-99'
            $merged = Merge-AiCliProfile -Template (Get-AiCliProviderManifest 'codex-glm-5-3') -UserProfile $profile
            $merged.models.primary | Should -BeExactly 'glm-future-99'
            $merged.codexModelCatalog | Should -BeNullOrEmpty
            Should -Invoke New-AiCliSecret -Times 0
            Should -Invoke Read-AiCliSecret -Times 0
        }
    }

    It 'keeps the credential only in the CLI child environment and leaves config with its variable name' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            Mock Resolve-AiCliCodexLaunchExecutable { [pscustomobject]@{FileName='C:\fixture\codex.exe'; PrefixArgs=@(); Kind='fixture'} }
            Mock Get-AiCliResolvedCliVersionEvidence { [pscustomobject]@{Version='codex-cli 0.154.0'; FileName='C:\fixture\codex.exe'} }
            Mock Publish-AiCliCodexModelCatalog { $null }
            Mock Write-AiCliCodexManagedProfile { [pscustomobject]@{CliProfileName='fixture'; FilePath=(Join-Path $Work 'config.toml')} }
            Mock Request-AiCliVendorCredential { 'synthetic-aicli-vendor-canary' }
            $profile = Merge-AiCliProfile -Template (Get-AiCliProviderManifest 'codex-glm-5-3') -UserProfile $null
            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $profile -ProjectPath $Work -NativeArgs @('--model','glm-future-100')
            $plan.model | Should -BeExactly 'glm-future-100'
            $plan.environmentDelta.AICLI_CODEX_PROVIDER_KEY | Should -BeExactly 'synthetic-aicli-vendor-canary'
            ($plan.argumentList -join ' ') | Should -Not -Match 'synthetic-aicli-vendor-canary'
            $toml = New-AiCliCodexProviderToml -MergedProfile $profile -EnvKeyName 'AICLI_CODEX_PROVIDER_KEY'
            $toml | Should -Match 'env_key = "AICLI_CODEX_PROVIDER_KEY"'
            $toml | Should -Not -Match 'synthetic-aicli-vendor-canary'
            Should -Invoke Request-AiCliVendorCredential -Times 1 -ParameterFilter { $Vendor -eq 'glm' -and $Endpoint -eq 'https://open.bigmodel.cn/api/v1' }
        }
    }

    It 'receives a synthetic key through a real one-shot local pipe in CLI and Desktop modes' {
        $fake = Join-Path $TestDrive 'fake-broker.ps1'
        @'
param([string]$Vendor,[string]$RequestPath,[switch]$NativeClient,[switch]$Json)
$r=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
if($r.vendor -ne $Vendor -or $r.endpoint -ne 'https://open.bigmodel.cn/api/v1'){exit 2}
$p=[IO.Pipes.NamedPipeClientStream]::new('.', $r.pipe_name, [IO.Pipes.PipeDirection]::Out)
try {$p.Connect(10000); $b=[Text.Encoding]::UTF8.GetBytes('synthetic-aicli-vendor-canary');$p.Write($b);$p.Flush()}finally{$p.Dispose()}
[Console]::Out.Write('{"status":"pass","secret_returned":false}')
'@ | Set-Content -LiteralPath $fake -Encoding utf8
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive; Fake=$fake } {
            Mock Get-AiCliVendorBrokerPath { $Fake }
            Mock Get-AiCliAppPaths { @{ LocalRoot=$Work } }
            foreach ($desktop in @($false,$true)) {
                $value = Request-AiCliVendorCredential -Vendor glm -Endpoint 'https://open.bigmodel.cn/api/v1' -Desktop:$desktop
                ($value -ceq 'synthetic-aicli-vendor-canary') | Should -BeTrue
                $value = $null
            }
            @(Get-ChildItem -LiteralPath (Join-Path $Work 'vendor-requests') -File).Count | Should -Be 0
        }
    }
}
